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
pub use store::{CookieEntry, PluginStore};

pub const HOST_SHIM_JS: &str = include_str!("host_shim.js");
pub const PACKAGES_BUNDLE_JS: &str = include_str!("packages_bundle.js");

const MEMORY_LIMIT: usize = 256 * 1024 * 1024;
// JS 层栈上限必须显著小于 JS 线程的原生栈（JS_THREAD_STACK）。QuickJS 按
// 「执行线程栈顶 - 上限」判定超限：若上限 ≥ 线程实际可用原生栈（FRB/tokio
// worker 仅 2MB，Android 主线程 1MB），栈检查永远来不及触发，深递归脚本
// （如 jsjiami 混淆 VM 的初始化解密链）会打穿 OS 守护页，整个 App 原生
// 崩溃（HelloWorld 插件更新即崩客户端的根因）。
// 注意：rquickjs 0.12 的 set_max_stack_size 会把 >16MiB 的值静默视为 0
// （完全关闭栈检查），因此这里必须取 16MiB 且不可再调大。
const MAX_STACK_SIZE: usize = 16 * 1024 * 1024;
const JS_THREAD_STACK: usize = 64 * 1024 * 1024;
const LOAD_TIMEOUT_MS: u64 = 30_000;
const MAX_LOG_ENTRIES: usize = 2000;

/// 插件 JS 专用执行线程（64MB 原生栈）。
///
/// 插件 JS 的栈预算由 MAX_STACK_SIZE 相对「执行线程栈顶」划定，不能超过
/// 线程实际原生栈。此前 JS 在 FRB/tokio worker（2MB）上执行，深递归插件
/// 直接杀进程；所有插件 JS（加载 / 调用 / 收尾驱动 / 运行时释放）统一
/// 路由到这条大栈线程执行。单线程串行即可满足：插件 JS 以网络等待为主，
/// 且同插件调用本就由 call_lock 串行。
static JS_THREAD: OnceLock<tokio::runtime::Handle> = OnceLock::new();

fn js_thread() -> &'static tokio::runtime::Handle {
    JS_THREAD.get_or_init(|| {
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::Builder::new()
            .name("plugin-js".to_string())
            .stack_size(JS_THREAD_STACK)
            .spawn(move || {
                let Ok(rt) = tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build()
                else {
                    return;
                };
                let _ = tx.send(rt.handle().clone());
                // 常驻泵：驱动插件 JS 的全部任务直到进程退出
                rt.block_on(std::future::pending::<()>());
            })
            .expect("spawn plugin-js thread");
        rx.recv().expect("plugin-js runtime handle")
    })
}

/// 把一段 JS 驱动 future 路由到插件 JS 线程执行（要求 'static，按值捕获）。
async fn drive_js<F, T>(fut: F) -> Result<T, String>
where
    F: std::future::Future<Output = T> + Send + 'static,
    T: Send + 'static,
{
    let (tx, rx) = tokio::sync::oneshot::channel();
    js_thread().spawn(async move {
        let out = fut.await;
        let _ = tx.send(out);
    });
    rx.await.map_err(|_| "插件 JS 任务已被丢弃".to_string())
}

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
    /// LX 插件自报更新（updateAlert）待处理载荷，非空时随结果送达前端。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub lx_update_alerts: Option<Vec<serde_json::Value>>,
}

#[derive(serde::Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct EngineCallResult {
    pub ok: bool,
    pub error: Option<String>,
    pub data: Option<serde_json::Value>,
    pub logs: Vec<EngineLog>,
    /// LX 插件自报更新（updateAlert）待处理载荷，非空时随结果送达前端。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub lx_update_alerts: Option<Vec<serde_json::Value>>,
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
    /// LX 插件自报更新待处理队列（桥写入，load/call 结果取走送达前端）。
    pending_lx_alerts: Arc<StdMutex<Vec<serde_json::Value>>>,
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
        lx_update_alerts: None,
    }
}

fn call_err(error: String, logs: Vec<EngineLog>) -> EngineCallResult {
    EngineCallResult {
        ok: false,
        error: Some(error),
        data: None,
        logs,
        lx_update_alerts: None,
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
    plugin_id: &str,
    pending_lx_alerts: &Arc<StdMutex<Vec<serde_json::Value>>>,
) -> rquickjs::Result<()> {
    let globals = ctx.globals();

    // ---- __xyNativeUpdateAlert(json) 同步（LX 插件自报更新，入待处理队列）----
    {
        let plugin_id = plugin_id.to_string();
        let pending = pending_lx_alerts.clone();
        let f = Function::new(ctx.clone(), move |json: String| {
            if let Ok(mut payload) = serde_json::from_str::<serde_json::Value>(&json) {
                if let Some(obj) = payload.as_object_mut() {
                    obj.insert(
                        "pluginId".to_string(),
                        serde_json::Value::String(plugin_id.clone()),
                    );
                    let mut guard = pending.lock().unwrap();
                    if guard.len() < 16 {
                        guard.push(payload);
                    }
                }
            }
        })?;
        globals.set("__xyNativeUpdateAlert", f)?;
    }

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
            pending_lx_alerts: Arc::new(StdMutex::new(Vec::new())),
        }
    }

    pub fn store(&self) -> &Arc<PluginStore> {
        &self.store
    }

    /// 兜底模块宿主复用同一 HttpBridge（SSRF 防护与 Cookie 存储共享）。
    pub fn http_bridge(&self) -> Arc<HttpBridge> {
        self.http.clone()
    }

    /// 取走并清空待送达的 LX 自报更新载荷（无则返回 None）。
    fn drain_pending_lx_alerts(&self) -> Option<Vec<serde_json::Value>> {
        let mut guard = self.pending_lx_alerts.lock().unwrap();
        if guard.is_empty() {
            None
        } else {
            Some(std::mem::take(&mut *guard))
        }
    }

    async fn destroy(&self, plugin_id: &str) {
        if let Some(inst) = self.instances.lock().await.remove(plugin_id) {
            // 运行时释放也路由到 JS 线程：与栈预算按执行线程划定的语义一致，
            // 深堆 free 链在小栈线程上有溢出风险。
            js_thread().spawn(async move {
                drop(inst);
            });
        }
    }

    async fn create_runtime(
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
        http: &Arc<HttpBridge>,
        store: &Arc<PluginStore>,
        ctx: &AsyncContext,
        logs: &Arc<StdMutex<Vec<EngineLog>>>,
        current_call: &Arc<AtomicU64>,
        plugin_id: &str,
        pending_lx_alerts: &Arc<StdMutex<Vec<serde_json::Value>>>,
    ) -> Result<(), String> {
        ctx.async_with(async |ctx| {
            let http = http.clone();
            let store = store.clone();
            let inner: rquickjs::Result<()> = (|| {
                register_bridges(&ctx, &http, &store, logs, current_call, plugin_id, pending_lx_alerts)?;
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

        // JS 必须在专用大栈线程上执行（见 js_thread 注释）；drive_js 要求
        // 'static future，共享组件与脚本全部按值捕获。
        let prepared = drive_js(prepare_musicfree(
            self.http.clone(),
            self.store.clone(),
            self.pending_lx_alerts.clone(),
            plugin_id.to_string(),
            script.to_string(),
            user_vars_json.to_string(),
        ))
        .await;

        let prepared = match prepared {
            Ok(p) => p,
            Err(e) => return load_err(e),
        };

        let result = prepared.result;
        if result.ok {
            let live = prepared.live.expect("ok load carries live parts");
            let metadata = result.metadata.clone().unwrap_or(serde_json::Value::Null);
            let instance = Arc::new(PluginInstance {
                id: plugin_id.to_string(),
                kind: PluginKind::MusicFree,
                metadata: metadata.clone(),
                ctx: live.ctx,
                runtime: live.runtime,
                deadline_ms: live.deadline,
                call_seq: Arc::new(AtomicU64::new(0)),
                current_call: live.current_call,
                logs: live.logs,
                call_lock: AsyncMutex::new(()),
            });
            self.instances
                .lock()
                .await
                .insert(plugin_id.to_string(), instance);
        }
        result
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

        let prepared = drive_js(prepare_lx(
            self.http.clone(),
            self.store.clone(),
            self.pending_lx_alerts.clone(),
            plugin_id.to_string(),
            script.to_string(),
            script_info_json.to_string(),
        ))
        .await;

        let prepared = match prepared {
            Ok(p) => p,
            Err(e) => return load_err(e),
        };

        let mut result = prepared.result;
        if result.ok {
            let live = prepared.live.expect("ok load carries live parts");
            let metadata = result.metadata.clone().unwrap_or(serde_json::Value::Null);
            // 常驻驱动句柄：idle() 会在 executor 首次 Empty 时提前返回，
            // 而 LX 脚本常在 init 后经 setTimeout/异步 HTTP 自调 checkUpdate()
            // 或 send(updateAlert)。drive() 持续驱动直到 runtime 随实例销毁
            // drop；必须在 JS 线程上驱动（栈预算按执行线程划定）。
            let rt_handle = live.runtime.clone();
            let instance = Arc::new(PluginInstance {
                id: plugin_id.to_string(),
                kind: PluginKind::Lx,
                metadata: metadata.clone(),
                ctx: live.ctx,
                runtime: live.runtime,
                deadline_ms: live.deadline,
                call_seq: Arc::new(AtomicU64::new(0)),
                current_call: live.current_call,
                logs: live.logs,
                call_lock: AsyncMutex::new(()),
            });
            self.instances
                .lock()
                .await
                .insert(plugin_id.to_string(), instance);
            js_thread().spawn(async move {
                rt_handle.drive().await;
            });
            result.lx_update_alerts = self.drain_pending_lx_alerts();
        }
        result
    }
}

/// 池内加载产出：结果 + 成功时携带待登记的活实例部件。
struct PreparedLoad {
    result: EngineLoadResult,
    live: Option<PreparedLive>,
}

struct PreparedLive {
    runtime: AsyncRuntime,
    ctx: AsyncContext,
    deadline: Arc<AtomicI64>,
    logs: Arc<StdMutex<Vec<EngineLog>>>,
    current_call: Arc<AtomicU64>,
}

fn failed(result: EngineLoadResult) -> PreparedLoad {
    PreparedLoad { result, live: None }
}

async fn prepare_musicfree(
    http: Arc<HttpBridge>,
    store: Arc<PluginStore>,
    pending_lx_alerts: Arc<StdMutex<Vec<serde_json::Value>>>,
    plugin_id: String,
    script: String,
    user_vars_json: String,
) -> PreparedLoad {
    let (runtime, ctx, deadline) = match PluginEngine::create_runtime().await {
        Ok(x) => x,
        Err(e) => return failed(load_err(e)),
    };

        let logs = Arc::new(StdMutex::new(Vec::new()));
        let current_call = Arc::new(AtomicU64::new(0));

        deadline.store(now_ms() + LOAD_TIMEOUT_MS as i64, Ordering::Relaxed);

        let setup_result = PluginEngine::setup_context(
            &http, &store, &ctx, &logs, &current_call, &plugin_id, &pending_lx_alerts,
        )
        .await;
        let load_json: Result<String, String> = match setup_result {
            Err(e) => Err(e),
            Ok(()) => {
                let outcome = tokio::time::timeout(
                    Duration::from_millis(LOAD_TIMEOUT_MS + 2000),
                    ctx.async_with(async |ctx| -> Result<String, String> {
                        let globals = ctx.globals();
                        let inner: rquickjs::Result<String> = (|| {
                            let load: Function = globals.get("__xyLoadMusicFree")?;
                            load.call((script.as_str(), user_vars_json.as_str()))
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
        // 失败（尤其外层超时）时池内任务可能仍持有 ctx 在跑 JS：置过期 deadline
        // 让中断处理器尽快掐断；成功路径照常解除。
        deadline.store(if load_json.is_err() { 1 } else { 0 }, Ordering::Relaxed);

        let json = match load_json {
            Ok(json) => json,
            Err(e) => return failed(load_err(e)),
        };

        let parsed = match serde_json::from_str::<serde_json::Value>(&json) {
            Ok(v) => v,
            Err(e) => {
                return failed(EngineLoadResult {
                    ok: false,
                    error: Some(format!("插件加载结果解析失败: {}", e)),
                    metadata: None,
                    logs: take_logs(&logs, 0),
                    lx_update_alerts: None,
                })
            }
        };

        if parsed.get("ok").and_then(|x| x.as_bool()).unwrap_or(false) {
            let metadata = parsed.get("metadata").cloned().unwrap_or(serde_json::Value::Null);
            PreparedLoad {
                result: EngineLoadResult {
                    ok: true,
                    error: None,
                    metadata: Some(metadata),
                    logs: take_logs(&logs, 0),
                    lx_update_alerts: None,
                },
                live: Some(PreparedLive {
                    runtime,
                    ctx,
                    deadline,
                    logs,
                    current_call,
                }),
            }
        } else {
            let error = parsed
                .get("error")
                .and_then(|x| x.as_str())
                .unwrap_or("插件加载失败")
                .to_string();
            PreparedLoad {
                result: EngineLoadResult {
                    ok: false,
                    error: Some(error),
                    metadata: None,
                    logs: take_logs(&logs, 0),
                    lx_update_alerts: None,
                },
                live: None,
            }
        }
    }

    async fn prepare_lx(
        http: Arc<HttpBridge>,
        store: Arc<PluginStore>,
        pending_lx_alerts: Arc<StdMutex<Vec<serde_json::Value>>>,
        plugin_id: String,
        script: String,
        script_info_json: String,
    ) -> PreparedLoad {
        let (runtime, ctx, deadline) = match PluginEngine::create_runtime().await {
            Ok(x) => x,
            Err(e) => return failed(load_err(e)),
        };

        let logs = Arc::new(StdMutex::new(Vec::new()));
        let current_call = Arc::new(AtomicU64::new(0));

        deadline.store(now_ms() + LOAD_TIMEOUT_MS as i64, Ordering::Relaxed);

        let setup_result = PluginEngine::setup_context(
            &http, &store, &ctx, &logs, &current_call, &plugin_id, &pending_lx_alerts,
        )
        .await;
        let load_json: Result<String, String> = match setup_result {
            Err(e) => Err(e),
            Ok(()) => {
                let outcome = tokio::time::timeout(
                    Duration::from_millis(LOAD_TIMEOUT_MS + 2000),
                    ctx.async_with(async |ctx| -> Result<String, String> {
                        let globals = ctx.globals();
                        let inner: rquickjs::Result<Option<String>> = (|| {
                            let setup: Function = globals.get("__xySetupLx")?;
                            let setup_result: Value =
                                setup.call((script_info_json.as_str(), script.as_str()))?;
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
        // 同 prepare_musicfree：失败时掐断仍在跑的 JS
        deadline.store(if load_json.is_err() { 1 } else { 0 }, Ordering::Relaxed);

        let json = match load_json {
            Ok(json) => json,
            Err(e) => return failed(load_err(e)),
        };

        let parsed = match serde_json::from_str::<serde_json::Value>(&json) {
            Ok(v) => v,
            Err(e) => {
                return failed(EngineLoadResult {
                    ok: false,
                    error: Some(format!("LX 插件初始化结果解析失败: {}", e)),
                    metadata: None,
                    logs: take_logs(&logs, 0),
                    lx_update_alerts: None,
                })
            }
        };

        if parsed.get("ok").and_then(|x| x.as_bool()).unwrap_or(false) {
            let metadata = parsed.get("initInfo").cloned().unwrap_or(serde_json::Value::Null);
            // runtime 即将 move 进实例，先克隆句柄用于 settle 驱动。
            // LX 脚本常在 init 中自调 checkUpdate()，其 HTTP 响应往往在
            // send(inited) 之后才到达；此处仍在 JS 线程上给一个短落地窗口，
            // 让自报更新进入 pending 队列随加载结果送达（上限 1500ms）。
            let rt_handle = runtime.clone();
            let _ = tokio::time::timeout(Duration::from_millis(1500), rt_handle.idle()).await;
            PreparedLoad {
                result: EngineLoadResult {
                    ok: true,
                    error: None,
                    metadata: Some(metadata),
                    logs: take_logs(&logs, 0),
                    lx_update_alerts: None,
                },
                live: Some(PreparedLive {
                    runtime,
                    ctx,
                    deadline,
                    logs,
                    current_call,
                }),
            }
        } else {
            let error = parsed
                .get("error")
                .and_then(|x| x.as_str())
                .unwrap_or("LX 插件初始化失败")
                .to_string();
            PreparedLoad {
                result: EngineLoadResult {
                    ok: false,
                    error: Some(error),
                    metadata: None,
                    logs: take_logs(&logs, 0),
                    lx_update_alerts: None,
                },
                live: None,
            }
        }
    }

impl PluginEngine {
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
        let ctx = instance.ctx.clone();
        let deadline = instance.deadline_ms.clone();

        // JS 驱动路由到插件 JS 专用大栈线程（见 js_thread 注释）。
        // WithFuture 借用 ctx，须在 'static async 块内持有 ctx 本体再驱动。
        // 层级：timeout(Elapsed) → drive_js(桥接错误) → JS 执行 Result<String,String>。
        let outcome = tokio::time::timeout(
            Duration::from_millis(timeout_ms + 2000),
            drive_js(async move {
                ctx.async_with(async |ctx| -> Result<String, String> {
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
                })
                .await
            }),
        )
        .await;

        instance.deadline_ms.store(0, Ordering::Relaxed);
        instance.current_call.store(0, Ordering::Relaxed);

        let logs = take_logs(&instance.logs, call_id);

        match outcome {
            Err(_) => {
                // 外层超时：池内任务仍持有 ctx 在跑 JS，置过期 deadline 让中断
                // 处理器尽快掐断；实例 JS 状态未知，销毁重建
                deadline.store(1, Ordering::Relaxed);
                instance.current_call.store(0, Ordering::Relaxed);
                self.destroy(plugin_id).await;
                call_err(
                    format!("方法调用超时: {} ({}ms)", method, timeout_ms),
                    logs,
                )
            }
            Ok(Err(e)) => call_err(format!("JS 线程错误: {}", e), logs),
            Ok(Ok(Err(e))) => call_err(format!("引擎调用失败: {}", e), logs),
            Ok(Ok(Ok(json))) => {
                match serde_json::from_str::<serde_json::Value>(&json) {
                    Ok(v) if v.get("ok").and_then(|x| x.as_bool()).unwrap_or(false) => {
                        EngineCallResult {
                            ok: true,
                            error: None,
                            data: v.get("data").cloned(),
                            logs,
                            // 兜底通道：load settle 窗口外迟到的自报更新随本次调用送达
                            lx_update_alerts: self.drain_pending_lx_alerts(),
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
        // 实例释放路由到 JS 线程（同 destroy：深堆 free 链在小栈线程有溢出风险）
        let instances: Vec<Arc<PluginInstance>> = self
            .instances
            .lock()
            .await
            .drain()
            .map(|(_, v)| v)
            .collect();
        if !instances.is_empty() {
            js_thread().spawn(async move {
                drop(instances);
            });
        }
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
