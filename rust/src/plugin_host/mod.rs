//! QuickJS 插件宿主引擎（移动端移植）
//!
//! 每个插件独占一个 AsyncRuntime + AsyncContext（完全隔离），
//! 通过 host_shim.js 复刻浏览器环境，原生桥（__xyNative*）提供：
//!   - HTTP（reqwest，含 Cookie 注入/捕获）
//!   - Cookie / Storage（PluginStore 持久化）
//!   - zlib inflate/deflate（flate2）
//!   - 文本解码（encoding_rs，TextDecoder 全编码标签支持）
//!   - 随机字节 / 日志 / 延时
//!
//! 超时双保险：interrupt handler 打断同步死循环；外层 tokio timeout
//! 兜底挂起的原生 future（触发后销毁实例）。
//!
//! 结果协议（与 host_shim.js 的 __xyOk/__xyErr 对齐）：
//!   {"ok":true,"data":...} / {"ok":false,"error":"..."}

mod http;
mod store;

use std::collections::HashMap;
use std::sync::atomic::{AtomicI64, AtomicU64, Ordering};
use std::sync::{Arc, Mutex as StdMutex};
use std::time::Duration;

use base64::{engine::general_purpose, Engine as _};
use rquickjs::function::{Async, This};
use rquickjs::{
    AsyncContext, AsyncRuntime, CatchResultExt, CaughtError, Ctx, Exception, FromJs, Function,
    Promise, Value,
};
use tokio::sync::Mutex as AsyncMutex;

pub use http::HttpBridge;
pub use store::PluginStore;

pub const HOST_SHIM_JS: &str = include_str!("host_shim.js");
pub const PACKAGES_BUNDLE_JS: &str = include_str!("packages_bundle.js");

const MEMORY_LIMIT: usize = 256 * 1024 * 1024;
const MAX_STACK_SIZE: usize = 2 * 1024 * 1024;
const LOAD_TIMEOUT_MS: u64 = 30_000;
const MAX_LOG_ENTRIES: usize = 2000;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum PluginKind {
    MusicFree,
    Lx,
}

#[derive(Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EngineLog {
    pub level: String,
    pub message: String,
    pub call_id: u64,
}

#[derive(serde::Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct EngineLoadResult {
    pub ok: bool,
    pub error: Option<String>,
    pub metadata: Option<serde_json::Value>,
    pub logs: Vec<EngineLog>,
}

#[derive(serde::Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct EngineCallResult {
    pub ok: bool,
    pub error: Option<String>,
    pub data: Option<serde_json::Value>,
    pub logs: Vec<EngineLog>,
}

pub struct PluginInstance {
    #[allow(dead_code)]
    pub id: String,
    pub kind: PluginKind,
    #[allow(dead_code)]
    pub metadata: serde_json::Value,
    // ctx 必须先于 runtime 声明：parallel 模式下 ctx 析构把指针送入
    // runtime 的 drop 通道，由 runtime Drop 统一释放
    pub ctx: AsyncContext,
    // runtime 字段仅用于持有句柄直到实例销毁
    #[allow(dead_code)]
    pub runtime: AsyncRuntime,
    deadline_ms: Arc<AtomicI64>,
    call_seq: Arc<AtomicU64>,
    current_call: Arc<AtomicU64>,
    logs: Arc<StdMutex<Vec<EngineLog>>>,
    call_lock: AsyncMutex<()>,
}

pub struct PluginEngine {
    http: Arc<HttpBridge>,
    store: Arc<PluginStore>,
    instances: AsyncMutex<HashMap<String, Arc<PluginInstance>>>,
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn json_quote(s: &str) -> String {
    serde_json::to_string(s).unwrap_or_else(|_| "\"\"".to_string())
}

fn take_logs(logs: &Arc<StdMutex<Vec<EngineLog>>>, call_id: u64) -> Vec<EngineLog> {
    let mut guard = logs.lock().unwrap();
    let mut out = Vec::new();
    guard.retain(|entry| {
        if entry.call_id == call_id {
            out.push(entry.clone());
            false
        } else {
            true
        }
    });
    out
}

fn load_err(error: String) -> EngineLoadResult {
    EngineLoadResult {
        ok: false,
        error: Some(error),
        metadata: None,
        logs: Vec::new(),
    }
}

fn call_err(error: String, logs: Vec<EngineLog>) -> EngineCallResult {
    EngineCallResult {
        ok: false,
        error: Some(error),
        data: None,
        logs,
    }
}

// ==================== zlib 桥实现 ====================

fn inflate_bytes(method: &str, data: &[u8]) -> Result<Vec<u8>, String> {
    use std::io::Read;
    let mut out = Vec::new();
    let effective = match method {
        "gzip" | "zlib" | "raw" => method,
        _ => {
            if data.len() >= 2 && data[0] == 0x1f && data[1] == 0x8b {
                "gzip"
            } else if !data.is_empty() && data[0] == 0x78 {
                "zlib"
            } else {
                "raw"
            }
        }
    };
    match effective {
        "gzip" => {
            let mut d = flate2::read::GzDecoder::new(data);
            d.read_to_end(&mut out).map_err(|e| e.to_string())?;
        }
        "zlib" => {
            let mut d = flate2::read::ZlibDecoder::new(data);
            d.read_to_end(&mut out).map_err(|e| e.to_string())?;
        }
        _ => {
            let mut d = flate2::read::DeflateDecoder::new(data);
            d.read_to_end(&mut out).map_err(|e| e.to_string())?;
        }
    }
    Ok(out)
}

fn deflate_bytes(method: &str, data: &[u8]) -> Result<Vec<u8>, String> {
    use std::io::Write;
    match method {
        "gzip" => {
            let mut e = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
            e.write_all(data).map_err(|e| e.to_string())?;
            e.finish().map_err(|e| e.to_string())
        }
        "zlib" => {
            let mut e = flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::default());
            e.write_all(data).map_err(|e| e.to_string())?;
            e.finish().map_err(|e| e.to_string())
        }
        _ => {
            let mut e = flate2::write::DeflateEncoder::new(Vec::new(), flate2::Compression::default());
            e.write_all(data).map_err(|e| e.to_string())?;
            e.finish().map_err(|e| e.to_string())
        }
    }
}

// ==================== 原生桥注册 ====================

fn register_bridges<'js>(
    ctx: &Ctx<'js>,
    http: &Arc<HttpBridge>,
    store: &Arc<PluginStore>,
    logs: &Arc<StdMutex<Vec<EngineLog>>>,
    current_call: &Arc<AtomicU64>,
) -> rquickjs::Result<()> {
    let globals = ctx.globals();

    // ---- __xyNativeLog(level, message) 同步 ----
    {
        let logs = logs.clone();
        let current_call = current_call.clone();
        let f = Function::new(ctx.clone(), move |level: String, message: String| {
            let call_id = current_call.load(Ordering::Relaxed);
            let mut guard = logs.lock().unwrap();
            if guard.len() < MAX_LOG_ENTRIES {
                guard.push(EngineLog {
                    level,
                    message,
                    call_id,
                });
            }
        })?;
        globals.set("__xyNativeLog", f)?;
    }

    // ---- __xyNativeDelay(ms) 异步 ----
    {
        let f = Function::new(
            ctx.clone(),
            Async(|ms: f64| async move {
                let ms = if ms.is_finite() && ms > 0.0 {
                    ms.min(120_000.0)
                } else {
                    0.0
                };
                if ms >= 1.0 {
                    tokio::time::sleep(Duration::from_millis(ms as u64)).await;
                }
                Ok::<(), rquickjs::Error>(())
            }),
        )?;
        globals.set("__xyNativeDelay", f)?;
    }

    // ---- __xyNativeRandomBytes(n) -> base64 同步 ----
    {
        let f = Function::new(
            ctx.clone(),
            move |ctx: Ctx, n: f64| -> rquickjs::Result<String> {
                let n = if n.is_finite() && n > 0.0 {
                    n.min(65_536.0) as usize
                } else {
                    0
                };
                let mut buf = vec![0u8; n];
                getrandom::fill(&mut buf)
                    .map_err(|e| Exception::throw_message(&ctx, &format!("random: {}", e)))?;
                Ok(general_purpose::STANDARD.encode(&buf))
            },
        )?;
        globals.set("__xyNativeRandomBytes", f)?;
    }

    // ---- __xyNativeInflate / __xyNativeDeflate(method, base64) -> base64 同步 ----
    {
        let f = Function::new(
            ctx.clone(),
            move |ctx: Ctx, method: String, data_b64: String| -> rquickjs::Result<String> {
                let data = general_purpose::STANDARD
                    .decode(data_b64.as_bytes())
                    .map_err(|e| Exception::throw_message(&ctx, &format!("inflate: {}", e)))?;
                inflate_bytes(&method, &data)
                    .map_err(|e| Exception::throw_message(&ctx, &e))
                    .map(|out| general_purpose::STANDARD.encode(out))
            },
        )?;
        globals.set("__xyNativeInflate", f)?;
    }
    {
        let f = Function::new(
            ctx.clone(),
            move |ctx: Ctx, method: String, data_b64: String| -> rquickjs::Result<String> {
                let data = general_purpose::STANDARD
                    .decode(data_b64.as_bytes())
                    .map_err(|e| Exception::throw_message(&ctx, &format!("deflate: {}", e)))?;
                deflate_bytes(&method, &data)
                    .map_err(|e| Exception::throw_message(&ctx, &e))
                    .map(|out| general_purpose::STANDARD.encode(out))
            },
        )?;
        globals.set("__xyNativeDeflate", f)?;
    }

    // ---- __xyNativeDecodeText(base64, label) -> string 同步（浏览器 TextDecoder 语义）----
    // 插件（如 Baka 酷我）用 new TextDecoder("gb18030") 解码歌词，shim 无法用
    // 纯 JS 覆盖全部 WHATWG 编码标签，统一桥到 encoding_rs 解码
    {
        let f = Function::new(
            ctx.clone(),
            move |ctx: Ctx, data_b64: String, label: String| -> rquickjs::Result<String> {
                let data = general_purpose::STANDARD
                    .decode(data_b64.as_bytes())
                    .map_err(|e| Exception::throw_message(&ctx, &format!("decodeText: {}", e)))?;
                let encoding = encoding_rs::Encoding::for_label(label.as_bytes()).ok_or_else(
                    || {
                        Exception::throw_message(
                            &ctx,
                            &format!("The encoding label provided ('{label}') is invalid."),
                        )
                    },
                )?;
                let (text, _, _) = encoding.decode(&data);
                Ok(text.into_owned())
            },
        )?;
        globals.set("__xyNativeDecodeText", f)?;
    }

    // ---- __xyNativeHttpRequest 异步 ----
    {
        let http = http.clone();
        let f = Function::new(
            ctx.clone(),
            Async(
                move |method: String,
                      url: String,
                      headers_json: String,
                      body: String,
                      timeout_ms: f64,
                      follow: f64,
                      want_binary: bool| {
                    let http = http.clone();
                    async move {
                        let headers: HashMap<String, String> =
                            serde_json::from_str(&headers_json).unwrap_or_default();
                        let timeout_ms = if timeout_ms.is_finite() && timeout_ms > 0.0 {
                            timeout_ms as u64
                        } else {
                            0
                        };
                        let follow = if follow.is_finite() { follow as i64 } else { -1 };
                        let body = if body.is_empty() { None } else { Some(body) };
                        let resp = http
                            .request(&method, &url, headers, body, timeout_ms, follow, want_binary)
                            .await;
                        let json = serde_json::to_string(&resp)
                            .unwrap_or_else(|_| "{\"error\":\"响应序列化失败\"}".to_string());
                        Ok::<String, rquickjs::Error>(json)
                    }
                },
            ),
        )?;
        globals.set("__xyNativeHttpRequest", f)?;
    }

    // ---- Cookie 桥（异步，返回 {ok,data/error} JSON）----
    {
        let store = store.clone();
        let f = Function::new(
            ctx.clone(),
            Async(move |url: String, cookie_json: String| {
                let store = store.clone();
                async move {
                    let payload = match serde_json::from_str::<serde_json::Value>(&cookie_json) {
                        Ok(v) => v,
                        Err(e) => {
                            return Ok::<String, rquickjs::Error>(json_error(&e.to_string()));
                        }
                    };
                    let name = payload.get("name").and_then(|x| x.as_str()).unwrap_or("");
                    let value = payload.get("value").and_then(|x| x.as_str()).unwrap_or("");
                    let domain = payload.get("domain").and_then(|x| x.as_str());
                    let ok = store.set_cookie(&url, name, value, domain);
                    Ok::<String, rquickjs::Error>(json_ok_bool(ok))
                }
            }),
        )?;
        globals.set("__xyNativeCookieSet", f)?;
    }
    {
        let store = store.clone();
        let f = Function::new(
            ctx.clone(),
            Async(move |url: String| {
                let store = store.clone();
                async move {
                    let cookies = store.get_cookies_for_url(&url);
                    let json = serde_json::to_string(&cookies).unwrap_or_else(|_| "{}".to_string());
                    Ok::<String, rquickjs::Error>(format!("{{\"ok\":true,\"data\":{}}}", json))
                }
            }),
        )?;
        globals.set("__xyNativeCookieGet", f)?;
    }
    {
        let f = Function::new(
            ctx.clone(),
            Async(|| async move { Ok::<String, rquickjs::Error>("{\"ok\":true}".to_string()) }),
        )?;
        globals.set("__xyNativeCookieFlush", f)?;
    }

    // ---- Storage 桥 ----
    {
        let store = store.clone();
        let f = Function::new(
            ctx.clone(),
            Async(move |key: String, raw: String| {
                let store = store.clone();
                async move {
                    store.storage_set(&key, &raw);
                    Ok::<String, rquickjs::Error>("{\"ok\":true}".to_string())
                }
            }),
        )?;
        globals.set("__xyNativeStorageSet", f)?;
    }
    {
        let store = store.clone();
        let f = Function::new(
            ctx.clone(),
            Async(move |key: String| {
                let store = store.clone();
                async move {
                    let value = store.storage_get(&key);
                    let json = serde_json::to_string(&value).unwrap_or_else(|_| "null".to_string());
                    Ok::<String, rquickjs::Error>(format!("{{\"ok\":true,\"data\":{}}}", json))
                }
            }),
        )?;
        globals.set("__xyNativeStorageGet", f)?;
    }
    {
        let store = store.clone();
        let f = Function::new(
            ctx.clone(),
            Async(move |key: String| {
                let store = store.clone();
                async move {
                    store.storage_remove(&key);
                    Ok::<String, rquickjs::Error>("{\"ok\":true}".to_string())
                }
            }),
        )?;
        globals.set("__xyNativeStorageRemove", f)?;
    }

    Ok(())
}

fn json_error(message: &str) -> String {
    format!("{{\"ok\":false,\"error\":{}}}", json_quote(message))
}

/// 把 rquickjs 错误转成可读消息：JS 异常时提取异常消息与堆栈
fn engine_error_message<'js>(ctx: &Ctx<'js>, e: &rquickjs::Error) -> String {
    if matches!(e, rquickjs::Error::Exception) {
        let v = ctx.catch();
        if v.is_null() || v.is_undefined() {
            return "QuickJS 异常（无详情）".to_string();
        }
        let msg = v
            .clone()
            .into_exception()
            .and_then(|exc| exc.message())
            .filter(|m| !m.is_empty())
            .unwrap_or_else(|| "QuickJS 异常（无消息）".to_string());
        let stack = v
            .as_object()
            .and_then(|obj| obj.get::<_, String>("stack").ok())
            .unwrap_or_default();
        if stack.is_empty() {
            msg
        } else {
            format!("{}\n{}", msg, stack)
        }
    } else {
        e.to_string()
    }
}

fn json_ok_bool(data: bool) -> String {
    format!("{{\"ok\":true,\"data\":{}}}", data)
}

/// promise 结果统一转 JSON 协议字符串（拒绝时提取异常消息）
async fn promise_to_json<'js>(
    ctx: &Ctx<'js>,
    promise: Promise<'js>,
) -> rquickjs::Result<String> {
    match promise.into_future::<String>().await.catch(ctx) {
        Ok(s) => Ok(s),
        Err(CaughtError::Exception(exc)) => {
            let msg = exc.message().unwrap_or_else(|| "未知异常".to_string());
            Ok(json_error(&msg))
        }
        Err(CaughtError::Value(v)) => {
            if let Ok(s) = rquickjs::String::from_js(ctx, v) {
                if let Ok(text) = s.to_string() {
                    return Ok(json_error(&text));
                }
            }
            Ok(json_error("未知异常"))
        }
        Err(CaughtError::Error(e)) => Ok(json_error(&e.to_string())),
    }
}

/// 将调用 promise 链接到 __xyOk/__xyErr 序列化
fn chain_result_serialization<'js>(
    globals: &rquickjs::Object<'js>,
    promise: Promise<'js>,
) -> rquickjs::Result<Promise<'js>> {
    let ok_fn: Function = globals.get("__xyOk")?;
    let err_fn: Function = globals.get("__xyErr")?;
    let then: Function = promise.then()?;
    then.call((This(promise), ok_fn, err_fn))
}

impl PluginEngine {
    pub fn new(store_path: Option<std::path::PathBuf>) -> Self {
        let store = Arc::new(PluginStore::load(store_path));
        let http = Arc::new(HttpBridge::new(store.clone()));
        Self {
            http,
            store,
            instances: AsyncMutex::new(HashMap::new()),
        }
    }

    pub fn store(&self) -> &Arc<PluginStore> {
        &self.store
    }

    async fn destroy(&self, plugin_id: &str) {
        self.instances.lock().await.remove(plugin_id);
    }

    async fn create_runtime(
        &self,
    ) -> Result<(AsyncRuntime, AsyncContext, Arc<AtomicI64>), String> {
        let runtime = AsyncRuntime::new().map_err(|e| e.to_string())?;
        runtime
            .set_memory_limit(MEMORY_LIMIT)
            .await;
        runtime
            .set_max_stack_size(MAX_STACK_SIZE)
            .await;
        let deadline = Arc::new(AtomicI64::new(0));
        let d = deadline.clone();
        runtime
            .set_interrupt_handler(Some(Box::new(move || {
                let until = d.load(Ordering::Relaxed);
                if until <= 0 {
                    return false;
                }
                now_ms() >= until
            })))
            .await;
        let ctx = AsyncContext::full(&runtime).await.map_err(|e| e.to_string())?;
        Ok((runtime, ctx, deadline))
    }

    /// 环境初始化：原生桥 + shim + 依赖包 + __xyPostSetup
    async fn setup_context(
        &self,
        ctx: &AsyncContext,
        logs: &Arc<StdMutex<Vec<EngineLog>>>,
        current_call: &Arc<AtomicU64>,
    ) -> Result<(), String> {
        let http = self.http.clone();
        let store = self.store.clone();
        ctx.async_with(async |ctx| {
            let inner: rquickjs::Result<()> = (|| {
                register_bridges(&ctx, &http, &store, logs, current_call)?;
                ctx.eval::<(), _>(HOST_SHIM_JS)?;
                ctx.eval::<(), _>(PACKAGES_BUNDLE_JS)?;
                let globals = ctx.globals();
                let post: Function = globals.get("__xyPostSetup")?;
                post.call::<_, ()>(())
            })();
            inner.map_err(|e| engine_error_message(&ctx, &e))
        })
        .await
    }

    pub async fn load_musicfree(
        &self,
        plugin_id: &str,
        script: &str,
        user_vars_json: &str,
    ) -> EngineLoadResult {
        self.destroy(plugin_id).await;

        if script.trim().is_empty() {
            return load_err("插件内容为空".to_string());
        }

        let (runtime, ctx, deadline) = match self.create_runtime().await {
            Ok(x) => x,
            Err(e) => return load_err(e),
        };

        let logs = Arc::new(StdMutex::new(Vec::new()));
        let current_call = Arc::new(AtomicU64::new(0));

        deadline.store(now_ms() + LOAD_TIMEOUT_MS as i64, Ordering::Relaxed);
        let script_owned = script.to_string();
        let user_vars_owned = user_vars_json.to_string();

        let setup_result = self.setup_context(&ctx, &logs, &current_call).await;
        let load_json: Result<String, String> = match setup_result {
            Err(e) => Err(e),
            Ok(()) => {
                let outcome = tokio::time::timeout(
                    Duration::from_millis(LOAD_TIMEOUT_MS + 2000),
                    ctx.async_with(async |ctx| -> Result<String, String> {
                        let globals = ctx.globals();
                        let inner: rquickjs::Result<String> = (|| {
                            let load: Function = globals.get("__xyLoadMusicFree")?;
                            load.call((
                                script_owned.as_str(),
                                user_vars_owned.as_str(),
                            ))
                        })();
                        inner.map_err(|e| engine_error_message(&ctx, &e))
                    }),
                )
                .await;
                match outcome {
                    Err(_) => Err("插件加载超时(30s)".to_string()),
                    Ok(Err(e)) => Err(e),
                    Ok(Ok(json)) => Ok(json),
                }
            }
        };
        deadline.store(0, Ordering::Relaxed);

        let json = match load_json {
            Ok(json) => json,
            Err(e) => return load_err(e),
        };

        let parsed = match serde_json::from_str::<serde_json::Value>(&json) {
            Ok(v) => v,
            Err(e) => {
                return EngineLoadResult {
                    ok: false,
                    error: Some(format!("插件加载结果解析失败: {}", e)),
                    metadata: None,
                    logs: take_logs(&logs, 0),
                }
            }
        };

        if parsed.get("ok").and_then(|x| x.as_bool()).unwrap_or(false) {
            let metadata = parsed.get("metadata").cloned().unwrap_or(serde_json::Value::Null);
            let instance = Arc::new(PluginInstance {
                id: plugin_id.to_string(),
                kind: PluginKind::MusicFree,
                metadata: metadata.clone(),
                ctx,
                runtime,
                deadline_ms: deadline,
                call_seq: Arc::new(AtomicU64::new(0)),
                current_call,
                logs: logs.clone(),
                call_lock: AsyncMutex::new(()),
            });
            self.instances
                .lock()
                .await
                .insert(plugin_id.to_string(), instance);
            EngineLoadResult {
                ok: true,
                error: None,
                metadata: Some(metadata),
                logs: take_logs(&logs, 0),
            }
        } else {
            let error = parsed
                .get("error")
                .and_then(|x| x.as_str())
                .unwrap_or("插件加载失败")
                .to_string();
            EngineLoadResult {
                ok: false,
                error: Some(error),
                metadata: None,
                logs: take_logs(&logs, 0),
            }
        }
    }

    pub async fn load_lx(
        &self,
        plugin_id: &str,
        script: &str,
        script_info_json: &str,
    ) -> EngineLoadResult {
        self.destroy(plugin_id).await;

        if script.trim().is_empty() {
            return load_err("插件内容为空".to_string());
        }

        let (runtime, ctx, deadline) = match self.create_runtime().await {
            Ok(x) => x,
            Err(e) => return load_err(e),
        };

        let logs = Arc::new(StdMutex::new(Vec::new()));
        let current_call = Arc::new(AtomicU64::new(0));

        deadline.store(now_ms() + LOAD_TIMEOUT_MS as i64, Ordering::Relaxed);
        let script_owned = script.to_string();
        let script_info_owned = script_info_json.to_string();

        let setup_result = self.setup_context(&ctx, &logs, &current_call).await;
        let load_json: Result<String, String> = match setup_result {
            Err(e) => Err(e),
            Ok(()) => {
                let outcome = tokio::time::timeout(
                    Duration::from_millis(LOAD_TIMEOUT_MS + 2000),
                    ctx.async_with(async |ctx| -> Result<String, String> {
                        let globals = ctx.globals();
                        let inner: rquickjs::Result<Option<String>> = (|| {
                            let setup: Function = globals.get("__xySetupLx")?;
                            let setup_result: Value = setup.call((
                                script_info_owned.as_str(),
                                script_owned.as_str(),
                            ))?;
                            if !setup_result.is_null() && !setup_result.is_undefined() {
                                // 同步加载失败，返回错误 JSON
                                let s = rquickjs::String::from_js(&ctx, setup_result)?;
                                return Ok(Some(s.to_string()?));
                            }
                            Ok(None)
                        })();
                        match inner {
                            Err(e) => return Err(engine_error_message(&ctx, &e)),
                            Ok(Some(json)) => return Ok(json),
                            Ok(None) => {}
                        }
                        // 等待 inited 事件（驱动 job 队列直到 resolve/reject）
                        let init_promise: Promise = match globals.get("__xyLxInitPromise") {
                            Ok(p) => p,
                            Err(e) => return Err(engine_error_message(&ctx, &e)),
                        };
                        promise_to_json(&ctx, init_promise)
                            .await
                            .map_err(|e| engine_error_message(&ctx, &e))
                    }),
                )
                .await;
                match outcome {
                    Err(_) => Err("LX 插件初始化超时(30s)".to_string()),
                    Ok(Err(e)) => Err(e),
                    Ok(Ok(json)) => Ok(json),
                }
            }
        };
        deadline.store(0, Ordering::Relaxed);

        let json = match load_json {
            Ok(json) => json,
            Err(e) => return load_err(e),
        };

        let parsed = match serde_json::from_str::<serde_json::Value>(&json) {
            Ok(v) => v,
            Err(e) => {
                return EngineLoadResult {
                    ok: false,
                    error: Some(format!("LX 插件初始化结果解析失败: {}", e)),
                    metadata: None,
                    logs: take_logs(&logs, 0),
                }
            }
        };

        if parsed.get("ok").and_then(|x| x.as_bool()).unwrap_or(false) {
            let metadata = parsed.get("initInfo").cloned().unwrap_or(serde_json::Value::Null);
            let instance = Arc::new(PluginInstance {
                id: plugin_id.to_string(),
                kind: PluginKind::Lx,
                metadata: metadata.clone(),
                ctx,
                runtime,
                deadline_ms: deadline,
                call_seq: Arc::new(AtomicU64::new(0)),
                current_call,
                logs: logs.clone(),
                call_lock: AsyncMutex::new(()),
            });
            self.instances
                .lock()
                .await
                .insert(plugin_id.to_string(), instance);
            EngineLoadResult {
                ok: true,
                error: None,
                metadata: Some(metadata),
                logs: take_logs(&logs, 0),
            }
        } else {
            let error = parsed
                .get("error")
                .and_then(|x| x.as_str())
                .unwrap_or("LX 插件初始化失败")
                .to_string();
            EngineLoadResult {
                ok: false,
                error: Some(error),
                metadata: None,
                logs: take_logs(&logs, 0),
            }
        }
    }

    pub async fn call(
        &self,
        plugin_id: &str,
        method: &str,
        args_json: &str,
        user_vars_json: Option<&str>,
        timeout_ms: u64,
    ) -> EngineCallResult {
        let instance = {
            let instances = self.instances.lock().await;
            match instances.get(plugin_id) {
                Some(i) => i.clone(),
                None => return call_err(format!("插件实例不存在: {}", plugin_id), Vec::new()),
            }
        };

        // 同插件调用串行：日志按 call_id 归属 + 避免插件内部状态被并发覆盖
        let _guard = instance.call_lock.lock().await;

        let call_id = instance.call_seq.fetch_add(1, Ordering::Relaxed) + 1;
        instance.current_call.store(call_id, Ordering::Relaxed);
        let timeout_ms = if timeout_ms == 0 { 30_000 } else { timeout_ms };
        instance
            .deadline_ms
            .store(now_ms() + timeout_ms as i64, Ordering::Relaxed);

        let method_owned = method.to_string();
        let args_owned = args_json.to_string();
        let user_vars_owned = user_vars_json.map(|s| s.to_string());
        let kind = instance.kind;

        let outcome = tokio::time::timeout(
            Duration::from_millis(timeout_ms + 2000),
            instance.ctx.async_with(async |ctx| -> Result<String, String> {
                let globals = ctx.globals();
                let inner: rquickjs::Result<Promise> = (|| {
                    match kind {
                        PluginKind::MusicFree => {
                            if let Some(vars) = &user_vars_owned {
                                let set_vars: Function = globals.get("__xySetUserVars")?;
                                set_vars.call::<_, ()>((vars.as_str(),))?;
                            }
                            let call_fn: Function = globals.get("__xyCallMusicFree")?;
                            Ok(call_fn.call((method_owned.as_str(), args_owned.as_str()))?)
                        }
                        PluginKind::Lx => {
                            // LX: method 固定为 request，参数取 args[0]
                            let data_json = extract_first_arg(&args_owned);
                            let call_fn: Function = globals.get("__xyLxRequest")?;
                            Ok(call_fn.call((data_json.as_str(),))?)
                        }
                    }
                })();
                let promise = match inner {
                    Ok(p) => p,
                    Err(e) => return Err(engine_error_message(&ctx, &e)),
                };
                let chained = match chain_result_serialization(&globals, promise) {
                    Ok(p) => p,
                    Err(e) => return Err(engine_error_message(&ctx, &e)),
                };
                promise_to_json(&ctx, chained)
                    .await
                    .map_err(|e| engine_error_message(&ctx, &e))
            }),
        )
        .await;

        instance.deadline_ms.store(0, Ordering::Relaxed);
        instance.current_call.store(0, Ordering::Relaxed);

        let logs = take_logs(&instance.logs, call_id);

        match outcome {
            Err(_) => {
                // 外层超时：原生 future 挂起，实例 JS 状态未知，销毁重建
                self.destroy(plugin_id).await;
                call_err(
                    format!("方法调用超时: {} ({}ms)", method, timeout_ms),
                    logs,
                )
            }
            Ok(Err(e)) => call_err(format!("引擎调用失败: {}", e), logs),
            Ok(Ok(json)) => {
                match serde_json::from_str::<serde_json::Value>(&json) {
                    Ok(v) if v.get("ok").and_then(|x| x.as_bool()).unwrap_or(false) => {
                        EngineCallResult {
                            ok: true,
                            error: None,
                            data: v.get("data").cloned(),
                            logs,
                        }
                    }
                    Ok(v) => {
                        let error = v
                            .get("error")
                            .and_then(|x| x.as_str())
                            .unwrap_or("方法调用失败")
                            .to_string();
                        call_err(error, logs)
                    }
                    Err(e) => call_err(format!("调用结果解析失败: {}", e), logs),
                }
            }
        }
    }

    pub async fn unload(&self, plugin_id: &str) {
        self.destroy(plugin_id).await;
    }

    pub async fn unload_all(&self) {
        self.instances.lock().await.clear();
    }
}

fn extract_first_arg(args_json: &str) -> String {
    match serde_json::from_str::<serde_json::Value>(args_json) {
        Ok(serde_json::Value::Array(items)) => match items.into_iter().next() {
            Some(first) => first.to_string(),
            None => "null".to_string(),
        },
        _ => args_json.to_string(),
    }
}

// ==================== 全局引擎（移动端单例） ====================

use std::sync::OnceLock;

static ENGINE: OnceLock<PluginEngine> = OnceLock::new();

/// 获取全局插件引擎。首次调用时以 `data_dir` 初始化存储路径。
pub fn global_engine(data_dir: &str) -> &'static PluginEngine {
    ENGINE.get_or_init(|| {
        let store_path = std::path::Path::new(data_dir).join("plugin_host_store.json");
        PluginEngine::new(Some(store_path))
    })
}
