//! LX Music 音源脚本沙箱。
//!
//! 在 [`boa_engine`] 中执行用户导入的音源脚本，向脚本注入 `globalThis.lx`，
//! 契约与桌面端 `pluginSandbox.worker.ts` 保持一致：
//!
//! - `lx.request(url, options, callback)` — HTTP 请求
//! - `lx.send('inited', info)` — 脚本上报支持的音源与音质
//! - `lx.on('request', handler)` — 注册请求处理器，宿主据此获取直链
//! - `lx.utils.crypto` / `buffer` / `zlib` — 加解密与压缩工具
//!
//! # 同步执行模型
//!
//! boa 是同步引擎，而 `lx.request` 需要真实网络 IO。这里的做法是：
//! JS 调用 `request` 时，经 `__lx_http` 同步进入 Rust，由内部 runtime
//! 阻塞执行 HTTP，拿到响应后立即回调 JS。对脚本而言 callback 是同步触发的，
//! 与浏览器下的异步语义略有差异，但落雪一类脚本均把 request 包装成
//! Promise 后 await，行为一致。

use std::collections::HashMap;

use boa_engine::object::builtins::JsFunction;
use boa_engine::property::Attribute;
use boa_engine::{
    js_string, Context, JsArgs, JsError, JsNativeError, JsObject, JsResult, JsValue,
    NativeFunction, Source,
};
use serde_json::Value as Json;

/// 脚本上报的单个音源能力。
#[derive(Debug, Clone, serde::Serialize)]
pub struct SourceCapability {
    pub name: String,
    /// 支持的动作，通常为 `["musicUrl"]`。
    pub actions: Vec<String>,
    /// 支持的音质档位。
    pub qualitys: Vec<String>,
}

/// 脚本元信息（取自脚本头部注释）。
#[derive(Debug, Clone, Default, serde::Serialize)]
pub struct ScriptMeta {
    pub name: String,
    pub version: String,
    pub author: String,
    pub description: String,
    pub homepage: String,
}

/// 一次脚本执行的产出。
#[derive(Debug, Clone, serde::Serialize)]
pub struct SandboxInitResult {
    pub meta: ScriptMeta,
    /// 音源标识 → 能力。
    pub sources: HashMap<String, SourceCapability>,
}

/// 从脚本头部注释解析元信息。
///
/// 形如：
/// ```text
/// /*!
///  * @name ikun音源
///  * @version v26
///  * @author ikunshare
///  */
/// ```
pub fn parse_script_meta(script: &str) -> ScriptMeta {
    let mut meta = ScriptMeta::default();
    // 只扫描前若干行，避免在混淆正文里误匹配。
    for line in script.lines().take(40) {
        let line = line.trim().trim_start_matches('*').trim();
        let Some(rest) = line.strip_prefix('@') else {
            continue;
        };
        let mut parts = rest.splitn(2, char::is_whitespace);
        let key = parts.next().unwrap_or("").to_ascii_lowercase();
        let value = parts.next().unwrap_or("").trim().to_string();
        if value.is_empty() {
            continue;
        }
        match key.as_str() {
            "name" => meta.name = value,
            "version" => meta.version = value,
            "author" => meta.author = value,
            "description" => meta.description = value,
            "homepage" => meta.homepage = value,
            _ => {}
        }
    }
    meta
}

/// 沙箱内部共享状态。
#[derive(Default)]
struct SharedState {
    /// 脚本调用 `send('inited', ...)` 时上报的内容。
    inited: Option<Json>,
    /// 脚本运行期的日志（便于定位插件问题）。
    logs: Vec<String>,
}

// boa 的原生函数只接受 Copy 捕获或 unsafe 闭包，无法直接携带 Arc。
// 沙箱本身是单线程使用的，改用线程局部状态：注入的原生函数写入这里，
// 载入流程随后读取。
thread_local! {
    static SANDBOX_STATE: std::cell::RefCell<SharedState> =
        std::cell::RefCell::new(SharedState::default());
}

/// 重置线程局部状态（每次载入脚本前调用）。
fn reset_state() {
    SANDBOX_STATE.with(|s| *s.borrow_mut() = SharedState::default());
}

/// 读取脚本上报的 inited 内容。
fn take_inited() -> Option<Json> {
    SANDBOX_STATE.with(|s| s.borrow_mut().inited.take())
}

/// 承载一个已初始化的音源脚本。
///
/// 内部持有 boa 上下文，非线程安全，需在单一任务内使用。
pub struct LxSandbox {
    ctx: Context,
    /// 脚本通过 `on('request', handler)` 注册的处理器。
    request_handler: Option<JsFunction>,
    meta: ScriptMeta,
    sources: HashMap<String, SourceCapability>,
}

impl LxSandbox {
    /// 载入并初始化脚本。
    ///
    /// 执行完成后要求脚本已调用 `send('inited', ...)`，否则视为初始化失败。
    pub fn load(script: &str) -> Result<Self, String> {
        let meta = parse_script_meta(script);
        reset_state();
        let mut ctx = Context::default();

        install_host_globals(&mut ctx, script, &meta)?;

        // 执行脚本本体。语法或运行期异常都在此暴露。
        ctx.eval(Source::from_bytes(script))
            .map_err(|e| format!("脚本执行失败: {e}"))?;
        // 结算脚本内挂起的 Promise（如 async 初始化）。
        ctx.run_jobs();

        let inited = take_inited()
            .ok_or_else(|| "脚本未调用 send('inited')，可能不是有效的音源脚本".to_string())?;

        let sources = parse_sources(&inited);
        if sources.is_empty() {
            return Err("脚本未上报任何可用音源".to_string());
        }

        // 取出脚本注册的 request 处理器。
        let request_handler = ctx
            .global_object()
            .get(js_string!("__lx_request_handler"), &mut ctx)
            .ok()
            .and_then(|v| JsFunction::from_object(v.as_object()?.clone()));

        Ok(Self {
            ctx,
            request_handler,
            meta,
            sources,
        })
    }

    pub fn meta(&self) -> &ScriptMeta {
        &self.meta
    }

    pub fn sources(&self) -> &HashMap<String, SourceCapability> {
        &self.sources
    }

    pub fn init_result(&self) -> SandboxInitResult {
        SandboxInitResult {
            meta: self.meta.clone(),
            sources: self.sources.clone(),
        }
    }

    /// 取出运行期日志（用于诊断插件问题）。
    pub fn take_logs(&self) -> Vec<String> {
        SANDBOX_STATE.with(|s| std::mem::take(&mut s.borrow_mut().logs))
    }

    /// 调用脚本的 `musicUrl` 动作获取播放直链。
    ///
    /// - `source`：音源标识（kw/kg/tx/wy 等）
    /// - `song_info_json`：歌曲信息 JSON，脚本据此取 songmid/hash
    /// - `quality`：音质档位
    pub fn get_music_url(
        &mut self,
        source: &str,
        song_info_json: &str,
        quality: &str,
    ) -> Result<String, String> {
        let handler = self
            .request_handler
            .clone()
            .ok_or_else(|| "脚本未注册 request 处理器".to_string())?;

        // 构造 { source, action: 'musicUrl', info: { musicInfo, type } }
        let arg_src = format!(
            r#"({{
                source: {},
                action: 'musicUrl',
                info: {{ musicInfo: {}, type: {} }}
            }})"#,
            serde_json::to_string(source).unwrap_or_else(|_| "\"\"".into()),
            song_info_json,
            serde_json::to_string(quality).unwrap_or_else(|_| "\"320k\"".into()),
        );
        let arg = self
            .ctx
            .eval(Source::from_bytes(&arg_src))
            .map_err(|e| format!("构造请求参数失败: {e}"))?;

        let ret = handler
            .call(&JsValue::undefined(), &[arg], &mut self.ctx)
            .map_err(|e| format!("调用插件失败: {e}"))?;

        // 处理器通常返回 Promise，需结算后取值。
        let resolved = self.resolve_value(ret)?;
        let url = resolved
            .to_string(&mut self.ctx)
            .map_err(|e| format!("读取直链失败: {e}"))?
            .to_std_string_escaped();

        if url.is_empty() || url == "undefined" || url == "null" {
            return Err("插件未返回播放链接".to_string());
        }
        Ok(url)
    }

    /// 结算可能是 Promise 的返回值。
    fn resolve_value(&mut self, value: JsValue) -> Result<JsValue, String> {
        let Some(obj) = value.as_object() else {
            return Ok(value);
        };
        // 非 Promise 直接返回原值。
        if !obj.is::<boa_engine::builtins::promise::Promise>() {
            return Ok(value);
        }

        // 把 Promise 结果暂存到全局，跑完任务队列后再取。
        let stash = js_string!("__lx_promise_result");
        let err_stash = js_string!("__lx_promise_error");
        let global = self.ctx.global_object();
        let _ = global.set(stash.clone(), JsValue::undefined(), false, &mut self.ctx);
        let _ = global.set(err_stash.clone(), JsValue::undefined(), false, &mut self.ctx);

        let on_ok = NativeFunction::from_fn_ptr(|_, args, ctx| {
            let v = args.get_or_undefined(0).clone();
            ctx.global_object()
                .set(js_string!("__lx_promise_result"), v, false, ctx)?;
            Ok(JsValue::undefined())
        });
        let on_err = NativeFunction::from_fn_ptr(|_, args, ctx| {
            let v = args.get_or_undefined(0).clone();
            let msg = v
                .to_string(ctx)
                .map(|s| s.to_std_string_escaped())
                .unwrap_or_else(|_| "插件内部错误".to_string());
            ctx.global_object().set(
                js_string!("__lx_promise_error"),
                js_string!(msg),
                false,
                ctx,
            )?;
            Ok(JsValue::undefined())
        });

        let then = obj
            .get(js_string!("then"), &mut self.ctx)
            .map_err(|e| format!("Promise.then 缺失: {e}"))?;
        let then_fn = then
            .as_object()
            .and_then(|o| JsFunction::from_object(o.clone()))
            .ok_or_else(|| "Promise.then 非函数".to_string())?;

        let ok_fn = NativeFunction::to_js_function(on_ok, self.ctx.realm());
        let err_fn = NativeFunction::to_js_function(on_err, self.ctx.realm());
        then_fn
            .call(
                &value,
                &[ok_fn.into(), err_fn.into()],
                &mut self.ctx,
            )
            .map_err(|e| format!("Promise 注册回调失败: {e}"))?;

        self.ctx.run_jobs();

        let global = self.ctx.global_object();
        if let Ok(err) = global.get(err_stash, &mut self.ctx) {
            if !err.is_undefined() {
                let msg = err
                    .to_string(&mut self.ctx)
                    .map(|s| s.to_std_string_escaped())
                    .unwrap_or_else(|_| "插件返回错误".to_string());
                return Err(msg);
            }
        }
        global
            .get(stash, &mut self.ctx)
            .map_err(|e| format!("读取 Promise 结果失败: {e}"))
    }
}

/// 从 inited 上报内容解析音源能力。
fn parse_sources(inited: &Json) -> HashMap<String, SourceCapability> {
    let mut out = HashMap::new();
    let Some(sources) = inited.get("sources").and_then(|s| s.as_object()) else {
        return out;
    };
    for (key, val) in sources {
        let actions = val
            .get("actions")
            .and_then(|a| a.as_array())
            .map(|arr| {
                arr.iter()
                    .filter_map(|v| v.as_str().map(str::to_string))
                    .collect()
            })
            .unwrap_or_default();
        let qualitys = val
            .get("qualitys")
            .and_then(|q| q.as_array())
            .map(|arr| {
                arr.iter()
                    .filter_map(|v| v.as_str().map(str::to_string))
                    .collect()
            })
            .unwrap_or_default();
        out.insert(
            key.clone(),
            SourceCapability {
                name: val
                    .get("name")
                    .and_then(|n| n.as_str())
                    .unwrap_or(key)
                    .to_string(),
                actions,
                qualitys,
            },
        );
    }
    out
}

/// 注入宿主环境：`globalThis.lx` 及脚本可能访问的全局对象。
fn install_host_globals(
    ctx: &mut Context,
    script: &str,
    meta: &ScriptMeta,
) -> Result<(), String> {
    // 全部注入的原生函数都不捕获外部状态，改写线程局部 SANDBOX_STATE，
    // 以满足 boa 对 Copy 闭包的要求。
    register_native(ctx, "__lx_http", native_http)?;
    register_native(ctx, "__lx_md5", native_md5)?;
    register_native(ctx, "__lx_random_hex", native_random_hex)?;
    register_native(ctx, "__lx_inflate", native_inflate)?;
    register_native(ctx, "__lx_report_inited", native_report_inited)?;
    register_native(ctx, "__lx_log", native_log)?;

    // ---- JS 层：拼装 globalThis.lx ----
    let bootstrap = build_bootstrap(script, meta);
    ctx.eval(Source::from_bytes(&bootstrap))
        .map_err(|e| format!("宿主环境注入失败: {e}"))?;
    Ok(())
}

/// `__lx_report_inited(info)` — 记录脚本上报的音源信息。
fn native_report_inited(_: &JsValue, args: &[JsValue], ctx: &mut Context) -> JsResult<JsValue> {
    let v = args.get_or_undefined(0).clone();
    let json = js_to_json(&v, ctx);
    SANDBOX_STATE.with(|s| s.borrow_mut().inited = Some(json));
    Ok(JsValue::undefined())
}

/// `__lx_log(msg)` — 收集插件日志，便于排查问题。
fn native_log(_: &JsValue, args: &[JsValue], ctx: &mut Context) -> JsResult<JsValue> {
    let msg = args
        .get_or_undefined(0)
        .to_string(ctx)
        .map(|s| s.to_std_string_escaped())
        .unwrap_or_default();
    SANDBOX_STATE.with(|s| {
        let mut st = s.borrow_mut();
        // 限制日志量，避免长时间运行占用内存。
        if st.logs.len() < 200 {
            st.logs.push(msg);
        }
    });
    Ok(JsValue::undefined())
}

fn register_native(
    ctx: &mut Context,
    name: &str,
    f: fn(&JsValue, &[JsValue], &mut Context) -> JsResult<JsValue>,
) -> Result<(), String> {
    let func = NativeFunction::to_js_function(NativeFunction::from_fn_ptr(f), ctx.realm());
    ctx.register_global_property(js_string!(name.to_string()), func, Attribute::all())
        .map_err(|e| format!("注入 {name} 失败: {e}"))
}

/// `__lx_http(method, url, headersJson, body, timeout, follow)` → 响应 JSON 字符串。
fn native_http(_: &JsValue, args: &[JsValue], ctx: &mut Context) -> JsResult<JsValue> {
    let method = arg_string(args, 0, ctx).unwrap_or_else(|| "GET".into());
    let url = arg_string(args, 1, ctx).unwrap_or_default();
    let headers_json = arg_string(args, 2, ctx).unwrap_or_else(|| "{}".into());
    let body = arg_string(args, 3, ctx).filter(|s| !s.is_empty());
    let timeout = args.get_or_undefined(4).as_number().map(|n| n as u64);
    let follow = args.get_or_undefined(5).as_number().map(|n| n as u32);

    if url.is_empty() {
        return Err(JsError::from_native(
            JsNativeError::error().with_message("请求 URL 为空"),
        ));
    }

    let headers: HashMap<String, String> =
        serde_json::from_str(&headers_json).unwrap_or_default();

    // 在独立 runtime 中阻塞执行，供同步的 JS 调用。
    let result = run_blocking(async move {
        crate::plugins::plugin_http_request(
            method,
            url,
            Some(headers),
            body,
            timeout,
            follow,
        )
        .await
    });

    match result {
        Ok(resp) => {
            let payload = serde_json::json!({
                "statusCode": resp.status,
                "statusMessage": "",
                "url": resp.url,
                "headers": resp.headers,
                "body": resp.body,
            });
            Ok(js_string!(payload.to_string()).into())
        }
        Err(e) => Err(JsError::from_native(
            JsNativeError::error().with_message(e),
        )),
    }
}

fn native_md5(_: &JsValue, args: &[JsValue], ctx: &mut Context) -> JsResult<JsValue> {
    let input = arg_string(args, 0, ctx).unwrap_or_default();
    let digest = md5::compute(input.as_bytes());
    Ok(js_string!(format!("{digest:x}")).into())
}

fn native_random_hex(_: &JsValue, args: &[JsValue], _ctx: &mut Context) -> JsResult<JsValue> {
    let size = args
        .get_or_undefined(0)
        .as_number()
        .map(|n| n as usize)
        .unwrap_or(16)
        .min(1024);
    // 用 uuid 拼足长度，避免额外引入随机源依赖。
    let mut hex = String::new();
    while hex.len() < size * 2 {
        hex.push_str(&uuid::Uuid::new_v4().simple().to_string());
    }
    hex.truncate(size * 2);
    Ok(js_string!(hex).into())
}

/// `__lx_inflate(base64)` → base64（解压后）。
fn native_inflate(_: &JsValue, args: &[JsValue], ctx: &mut Context) -> JsResult<JsValue> {
    use base64::Engine;
    use std::io::Read;

    let b64 = arg_string(args, 0, ctx).unwrap_or_default();
    let raw = base64::engine::general_purpose::STANDARD
        .decode(b64.as_bytes())
        .unwrap_or_default();

    // 依次尝试 zlib 与 raw deflate。
    let mut out = Vec::new();
    let ok = {
        let mut dec = flate2::read::ZlibDecoder::new(&raw[..]);
        dec.read_to_end(&mut out).is_ok()
    } || {
        out.clear();
        let mut dec = flate2::read::DeflateDecoder::new(&raw[..]);
        dec.read_to_end(&mut out).is_ok()
    };
    if !ok {
        // 解压失败时原样返回，与桌面端行为一致。
        return Ok(js_string!(b64).into());
    }
    Ok(js_string!(base64::engine::general_purpose::STANDARD.encode(&out)).into())
}

fn arg_string(args: &[JsValue], idx: usize, ctx: &mut Context) -> Option<String> {
    let v = args.get_or_undefined(idx);
    if v.is_undefined() || v.is_null() {
        return None;
    }
    v.to_string(ctx)
        .ok()
        .map(|s| s.to_std_string_escaped())
}

/// 在当前线程阻塞执行 future。
///
/// 沙箱可能已运行在 tokio 上下文中，此时不能直接 `block_on`，
/// 需切到独立线程执行以避免运行时嵌套 panic。
fn run_blocking<F, T>(fut: F) -> T
where
    F: std::future::Future<Output = T> + Send + 'static,
    T: Send + 'static,
{
    match tokio::runtime::Handle::try_current() {
        Ok(handle) => std::thread::scope(|s| {
            s.spawn(|| handle.block_on(fut)).join().expect("插件请求线程 panic")
        }),
        Err(_) => tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("构建插件请求 runtime 失败")
            .block_on(fut),
    }
}

/// 将 JS 值转为 serde_json::Value。
fn js_to_json(value: &JsValue, ctx: &mut Context) -> Json {
    // 借道 JSON.stringify，避免手工遍历对象图。
    let Ok(json_obj) = ctx
        .global_object()
        .get(js_string!("JSON"), ctx)
        .and_then(|v| {
            v.as_object()
                .ok_or_else(|| JsError::from_opaque(JsValue::undefined()))
        })
    else {
        return Json::Null;
    };
    let Ok(stringify) = json_obj.get(js_string!("stringify"), ctx) else {
        return Json::Null;
    };
    let Some(f) = stringify
        .as_object()
        .and_then(|o| JsFunction::from_object(o.clone()))
    else {
        return Json::Null;
    };
    let Ok(s) = f.call(&JsValue::undefined(), &[value.clone()], ctx) else {
        return Json::Null;
    };
    let Ok(text) = s.to_string(ctx) else {
        return Json::Null;
    };
    serde_json::from_str(&text.to_std_string_escaped()).unwrap_or(Json::Null)
}

/// 生成注入脚本：在 JS 层拼出 `globalThis.lx` 与常用全局对象。
fn build_bootstrap(script: &str, meta: &ScriptMeta) -> String {
    let script_md5 = format!("{:x}", md5::compute(script.as_bytes()));
    format!(
        r#"
(function() {{
  'use strict';

  const noop = function() {{}};
  globalThis.console = {{
    log: function() {{ __lx_log(Array.prototype.join.call(arguments, ' ')); }},
    warn: function() {{ __lx_log('[warn] ' + Array.prototype.join.call(arguments, ' ')); }},
    error: function() {{ __lx_log('[error] ' + Array.prototype.join.call(arguments, ' ')); }},
    info: noop, debug: noop, group: noop, groupEnd: noop, trace: noop,
  }};

  // setTimeout：脚本多用于超时兜底，这里同步立即执行以保证链路继续。
  if (typeof globalThis.setTimeout !== 'function') {{
    globalThis.setTimeout = function(fn) {{ return 0; }};
    globalThis.clearTimeout = noop;
    globalThis.setInterval = function() {{ return 0; }};
    globalThis.clearInterval = noop;
  }}

  const EVENT_NAMES = {{ request: 'request', inited: 'inited', updateAlert: 'updateAlert' }};

  function toHeaderObject(h) {{
    const out = {{}};
    if (h && typeof h === 'object') {{
      for (const k in h) {{
        if (h[k] != null) out[k] = String(h[k]);
      }}
    }}
    return out;
  }}

  function encodeForm(obj) {{
    if (typeof obj === 'string') return obj;
    const parts = [];
    for (const k in obj) {{
      if (obj[k] == null) continue;
      parts.push(encodeURIComponent(k) + '=' + encodeURIComponent(String(obj[k])));
    }}
    return parts.join('&');
  }}

  globalThis.lx = {{
    EVENT_NAMES: EVENT_NAMES,
    version: '2.0.0',
    env: 'mobile',
    currentScriptInfo: {{
      name: {name},
      description: {description},
      version: {version},
      author: {author},
      homepage: {homepage},
      rawScript: '',
    }},

    request: function(url, options, callback) {{
      options = options || {{}};
      const method = String(options.method || 'GET').toUpperCase();
      const headers = toHeaderObject(options.headers);
      let body = '';

      if (options.body != null) {{
        if (typeof options.body === 'string') body = options.body;
        else {{
          body = JSON.stringify(options.body);
          if (!headers['Content-Type'] && !headers['content-type']) headers['Content-Type'] = 'application/json';
        }}
      }} else if (options.form != null) {{
        body = encodeForm(options.form);
        if (!headers['Content-Type'] && !headers['content-type']) headers['Content-Type'] = 'application/x-www-form-urlencoded';
      }} else if (options.formData != null) {{
        body = encodeForm(options.formData);
        if (!headers['Content-Type'] && !headers['content-type']) headers['Content-Type'] = 'application/x-www-form-urlencoded';
      }}

      try {{
        const raw = __lx_http(method, url, JSON.stringify(headers), body,
                              options.timeout == null ? undefined : options.timeout,
                              options.follow_max == null ? options.follow : options.follow_max);
        const resp = JSON.parse(raw);
        let parsed = resp.body;
        try {{ parsed = JSON.parse(resp.body); }} catch (e) {{ /* 保持原始字符串 */ }}
        callback(null, {{
          statusCode: resp.statusCode,
          statusMessage: resp.statusMessage,
          headers: resp.headers,
          bytes: resp.body ? resp.body.length : 0,
          raw: resp.body,
          body: parsed,
        }}, parsed);
      }} catch (err) {{
        callback(err, null, null);
      }}
      return noop;
    }},

    send: function(eventName, data) {{
      if (eventName === EVENT_NAMES.inited) {{
        __lx_report_inited(data);
        return Promise.resolve();
      }}
      if (eventName === EVENT_NAMES.updateAlert) return Promise.resolve();
      return Promise.reject(new Error('Unknown event name: ' + eventName));
    }},

    on: function(eventName, handler) {{
      if (eventName === EVENT_NAMES.request) {{
        globalThis.__lx_request_handler = handler;
        return Promise.resolve();
      }}
      if (eventName === EVENT_NAMES.inited || eventName === EVENT_NAMES.updateAlert) {{
        return Promise.resolve();
      }}
      return Promise.reject(new Error('The event is not supported: ' + eventName));
    }},

    utils: {{
      crypto: {{
        md5: function(str) {{ return __lx_md5(String(str)); }},
        randomBytes: function(size) {{ return __lx_random_hex(size); }},
        // AES/RSA 在移动端暂未实现，返回原值以免脚本抛错中断初始化。
        aesEncrypt: function(buffer) {{ return buffer; }},
        rsaEncrypt: function(buffer) {{ return buffer; }},
      }},
      buffer: {{
        from: function(v) {{ return v; }},
        bufToString: function(buf, format) {{ return String(buf); }},
      }},
      zlib: {{
        inflate: function(buf) {{ return Promise.resolve(__lx_inflate(String(buf))); }},
        inflateSync: function(buf) {{ return __lx_inflate(String(buf)); }},
        deflate: function(buf) {{ return Promise.resolve(buf); }},
        deflateSync: function(buf) {{ return buf; }},
      }},
    }},
  }};

  // 混淆脚本常以 globalThis 方式访问这些全局量。
  globalThis.window = globalThis;
  globalThis.self = globalThis;
  globalThis.global = globalThis;
  globalThis.process = {{ versions: {{ node: '18.0.0' }}, env: {{}}, platform: 'android' }};
  globalThis.require = function() {{ return {{}}; }};
  globalThis.SCRIPT_MD5 = {script_md5};
}})();
"#,
        name = json_str(&meta.name),
        description = json_str(&meta.description),
        version = json_str(&meta.version),
        author = json_str(&meta.author),
        homepage = json_str(&meta.homepage),
        script_md5 = json_str(&script_md5),
    )
}

fn json_str(s: &str) -> String {
    serde_json::to_string(s).unwrap_or_else(|_| "\"\"".to_string())
}
