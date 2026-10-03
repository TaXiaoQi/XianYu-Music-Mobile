use std::sync::atomic::{AtomicI64, AtomicU64, Ordering};
use std::sync::{Arc, Mutex as StdMutex};

use rquickjs::{AsyncContext, AsyncRuntime, Ctx};

use super::bridges::register_bridges;
use super::{FallbackEngine, FallbackLog, FALLBACK_SHIM_JS};

// 兜底模块轻量（单方法纯计算为主），资源上限较插件宿主收紧一半。
const MEMORY_LIMIT: usize = 64 * 1024 * 1024;
const MAX_STACK_SIZE: usize = 1 * 1024 * 1024;

pub(super) fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

pub(super) fn take_logs(logs: &Arc<StdMutex<Vec<FallbackLog>>>, call_id: u64) -> Vec<FallbackLog> {
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

impl FallbackEngine {
    pub(super) async fn create_runtime(
        &self,
    ) -> Result<(AsyncRuntime, AsyncContext, Arc<AtomicI64>), String> {
        let runtime = AsyncRuntime::new().map_err(|e| e.to_string())?;
        runtime.set_memory_limit(MEMORY_LIMIT).await;
        runtime.set_max_stack_size(MAX_STACK_SIZE).await;
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
        let ctx = AsyncContext::full(&runtime)
            .await
            .map_err(|e| e.to_string())?;
        Ok((runtime, ctx, deadline))
    }

    /// 注册 native 桥 + 注入 shim（ctx 构造、load/call 入口）。
    pub(super) async fn setup_context(
        &self,
        ctx: &AsyncContext,
        logs: &Arc<StdMutex<Vec<FallbackLog>>>,
        current_call: &Arc<AtomicU64>,
        app_version: &str,
    ) -> Result<(), String> {
        let http = self.http.clone();
        let cache = self.cache.clone();
        let config = self.config.clone();
        ctx.async_with(async |ctx| {
            let inner: rquickjs::Result<()> = (|| {
                let globals = ctx.globals();
                globals.set("__xyFbAppVersion", app_version.to_string())?;
                register_bridges(&ctx, &http, &cache, &config, logs, current_call)?;
                ctx.eval::<(), _>(FALLBACK_SHIM_JS)?;
                Ok(())
            })();
            inner.map_err(|e| engine_error_message(&ctx, &e))
        })
        .await
    }
}

pub(super) fn engine_error_message<'js>(ctx: &Ctx<'js>, e: &rquickjs::Error) -> String {
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
