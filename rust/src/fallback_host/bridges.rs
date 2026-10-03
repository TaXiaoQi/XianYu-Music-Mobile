use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex as StdMutex};
use std::time::Duration;

use rquickjs::function::Async;
use rquickjs::{Ctx, Exception, Function};

use super::{CacheEntry, FallbackLog};

const MAX_LOG_ENTRIES: usize = 500;
const MAX_CACHE_ENTRIES: usize = 2000;

type SharedCache = Arc<StdMutex<HashMap<String, CacheEntry>>>;
type SharedConfig = Arc<std::sync::RwLock<serde_json::Value>>;

pub(super) fn register_bridges<'js>(
    ctx: &Ctx<'js>,
    http: &Arc<crate::plugin_host::HttpBridge>,
    cache: &SharedCache,
    config: &SharedConfig,
    logs: &Arc<StdMutex<Vec<FallbackLog>>>,
    current_call: &Arc<AtomicU64>,
) -> rquickjs::Result<()> {
    let globals = ctx.globals();

    // ---- __xyFbLog(level, message) 同步 ----
    {
        let logs = logs.clone();
        let current_call = current_call.clone();
        let f = Function::new(ctx.clone(), move |level: String, message: String| {
            let call_id = current_call.load(Ordering::Relaxed);
            let mut guard = logs.lock().unwrap();
            if guard.len() < MAX_LOG_ENTRIES {
                guard.push(FallbackLog {
                    level,
                    message,
                    call_id,
                });
            }
        })?;
        globals.set("__xyFbLog", f)?;
    }

    // ---- __xyFbHttpRequest(method, url, headers_json, body, timeout_ms, follow, want_binary) 异步 ----
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
                        let follow = if follow.is_finite() {
                            follow as i64
                        } else {
                            -1
                        };
                        let body = if body.is_empty() { None } else { Some(body) };
                        let resp = http
                            .request(
                                &method,
                                &url,
                                headers,
                                body,
                                timeout_ms,
                                follow,
                                want_binary,
                            )
                            .await;
                        let json = serde_json::to_string(&resp)
                            .unwrap_or_else(|_| "{\"error\":\"响应序列化失败\"}".to_string());
                        Ok::<String, rquickjs::Error>(json)
                    }
                },
            ),
        )?;
        globals.set("__xyFbHttpRequest", f)?;
    }

    // ---- cache 桥（同步，JSON 文本往返）----
    {
        let cache = cache.clone();
        let f = Function::new(
            ctx.clone(),
            move |ctx: Ctx, key: String| -> rquickjs::Result<String> {
                let guard = cache.lock().unwrap();
                let entry = match guard.get(&key) {
                    Some(e) => e,
                    None => return Ok("null".to_string()),
                };
                if let Some(expire_at) = entry.expire_at {
                    if std::time::Instant::now() >= expire_at {
                        return Ok("null".to_string());
                    }
                }
                serde_json::to_string(&entry.value)
                    .map_err(|e| Exception::throw_message(&ctx, &format!("cache: {}", e)))
            },
        )?;
        globals.set("__xyFbCacheGet", f)?;
    }
    {
        let cache = cache.clone();
        let f = Function::new(
            ctx.clone(),
            move |ctx: Ctx,
                  key: String,
                  value_json: String,
                  ttl_seconds: f64|
                  -> rquickjs::Result<()> {
                let value: serde_json::Value = match serde_json::from_str(&value_json) {
                    Ok(v) => v,
                    Err(e) => {
                        return Err(Exception::throw_message(
                            &ctx,
                            &format!("cache: {}", e),
                        ));
                    }
                };
                let expire_at = if ttl_seconds.is_finite() && ttl_seconds > 0.0 {
                    Some(std::time::Instant::now() + Duration::from_secs_f64(ttl_seconds))
                } else {
                    None
                };
                let mut guard = cache.lock().unwrap();
                if guard.len() >= MAX_CACHE_ENTRIES && !guard.contains_key(&key) {
                    // 容量兜底：清掉已过期项后仍满则拒绝写入（静默，与内存缓存语义一致）
                    guard.retain(|_, e| {
                        e.expire_at
                            .map(|at| std::time::Instant::now() < at)
                            .unwrap_or(true)
                    });
                }
                if guard.len() < MAX_CACHE_ENTRIES || guard.contains_key(&key) {
                    guard.insert(key, CacheEntry { value, expire_at });
                }
                Ok(())
            },
        )?;
        globals.set("__xyFbCacheSet", f)?;
    }
    {
        let cache = cache.clone();
        let f = Function::new(ctx.clone(), move |key: String| {
            cache.lock().unwrap().remove(&key);
        })?;
        globals.set("__xyFbCacheDel", f)?;
    }

    // ---- config 桥（深路径取值，缺失返回 "null"）----
    {
        let config = config.clone();
        let f = Function::new(ctx.clone(), move |key: String| -> String {
            let guard = config.read().unwrap();
            let mut cursor = &*guard;
            for part in key.split('.') {
                match cursor.get(part) {
                    Some(v) => cursor = v,
                    None => return "null".to_string(),
                }
            }
            serde_json::to_string(cursor).unwrap_or_else(|_| "null".to_string())
        })?;
        globals.set("__xyFbConfigGet", f)?;
    }

    Ok(())
}
