use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;

use rquickjs::{Function, Promise};

use super::runtime::{engine_error_message, now_ms, take_logs};
use super::{
    FallbackCallItem, FallbackCallManyResult, FallbackCallResult, FallbackEngine, FallbackInstance,
    FallbackLoadResult, FallbackLog,
};

const LOAD_TIMEOUT_MS: u64 = 5_000;
const DEFAULT_CALL_TIMEOUT_MS: u64 = 15_000;

fn load_result(ok: bool, error: Option<String>, version: Option<i64>, logs: Vec<FallbackLog>) -> FallbackLoadResult {
    FallbackLoadResult { ok, error, version, logs }
}

fn call_err(error: String, logs: Vec<FallbackLog>) -> FallbackCallResult {
    FallbackCallResult { ok: false, error: Some(error), data: None, logs }
}

impl FallbackEngine {
    /// 验签 + 编译 + 四条硬校验一体；同 key 覆盖 = 热替换（共享 cache 不清空）。
    pub async fn load(
        &self,
        module_key: &str,
        version: i64,
        code: &str,
        signature: &str,
        app_version: &str,
    ) -> FallbackLoadResult {
        // 硬校验之 0：模块 key 已注册
        let expected = match super::expected_methods(module_key) {
            Some(m) => m,
            None => return load_result(false, Some(format!("未注册的兜底模块: {module_key}")), None, Vec::new()),
        };

        if code.trim().is_empty() {
            return load_result(false, Some("模块代码为空".to_string()), None, Vec::new());
        }

        // 验签（复用 fallback_verify，公钥与消息格式单一来源）
        match crate::fallback_verify::verify_fallback_module_signature(module_key, version, code, signature) {
            Ok(true) => {}
            Ok(false) => return load_result(false, Some("模块签名校验失败".to_string()), None, Vec::new()),
            Err(e) => return load_result(false, Some(format!("模块签名校验异常: {e}")), None, Vec::new()),
        }

        let (runtime, ctx, deadline) = match self.create_runtime().await {
            Ok(x) => x,
            Err(e) => return load_result(false, Some(e), None, Vec::new()),
        };

        let logs = Arc::new(std::sync::Mutex::new(Vec::new()));
        let current_call = Arc::new(AtomicU64::new(0));

        deadline.store(now_ms() + LOAD_TIMEOUT_MS as i64, Ordering::Relaxed);
        let app_version = app_version.to_string();
        let code_owned = code.to_string();

        let setup = self.setup_context(&ctx, &logs, &current_call, &app_version).await;
        let load_json: Result<String, String> = match setup {
            Err(e) => Err(e),
            Ok(()) => {
                let outcome = tokio::time::timeout(
                    Duration::from_millis(LOAD_TIMEOUT_MS + 2000),
                    ctx.async_with(async |ctx| -> Result<String, String> {
                        let globals = ctx.globals();
                        let inner: rquickjs::Result<String> = (|| {
                            let load: Function = globals.get("__xyFbLoad")?;
                            load.call((code_owned.as_str(),))
                        })();
                        inner.map_err(|e| engine_error_message(&ctx, &e))
                    }),
                )
                .await;
                match outcome {
                    Err(_) => Err("模块加载超时(5s)".to_string()),
                    Ok(Err(e)) => Err(e),
                    Ok(Ok(json)) => Ok(json),
                }
            }
        };
        deadline.store(0, Ordering::Relaxed);

        let json = match load_json {
            Ok(json) => json,
            Err(e) => return load_result(false, Some(e), None, take_logs(&logs, 0)),
        };

        let parsed: serde_json::Value = match serde_json::from_str(&json) {
            Ok(v) => v,
            Err(e) => {
                return load_result(
                    false,
                    Some(format!("模块加载结果解析失败: {e}")),
                    None,
                    take_logs(&logs, 0),
                )
            }
        };
        if !parsed.get("ok").and_then(|x| x.as_bool()).unwrap_or(false) {
            let error = parsed
                .get("error")
                .and_then(|x| x.as_str())
                .unwrap_or("模块加载失败")
                .to_string();
            return load_result(false, Some(error), None, take_logs(&logs, 0));
        }

        // 硬校验之 4：至少实现一个约定方法（与前端 expected.some(...) 一致）
        let methods: Vec<String> = parsed
            .get("methods")
            .and_then(|x| x.as_array())
            .map(|arr| {
                arr.iter()
                    .filter_map(|v| v.as_str().map(|s| s.to_string()))
                    .collect()
            })
            .unwrap_or_default();
        if !expected.iter().any(|m| methods.contains(&m.to_string())) {
            return load_result(
                false,
                Some(format!(
                    "模块未实现任何约定方法（期望其一: {}）",
                    expected.join(", ")
                )),
                None,
                take_logs(&logs, 0),
            );
        }

        let version = parsed.get("version").and_then(|x| x.as_i64()).unwrap_or(version);
        let instance = Arc::new(FallbackInstance {
            ctx,
            runtime,
            deadline_ms: deadline,
            call_seq: Arc::new(AtomicU64::new(0)),
            current_call,
            logs: logs.clone(),
            call_lock: tokio::sync::Mutex::new(()).into(),
        });
        // 同 key 覆盖 = 热替换；正在执行的旧调用持有 Arc 不受影响
        self.instances
            .lock()
            .await
            .insert(module_key.to_string(), instance);

        load_result(true, None, Some(version), take_logs(&logs, 0))
    }

    async fn call_once(
        instance: &Arc<FallbackInstance>,
        method: &str,
        args_json: &str,
        timeout_ms: u64,
    ) -> (Result<String, String>, Vec<FallbackLog>) {
        let _guard = instance.call_lock.lock().await;

        let call_id = instance.call_seq.fetch_add(1, Ordering::Relaxed) + 1;
        instance.current_call.store(call_id, Ordering::Relaxed);
        instance
            .deadline_ms
            .store(now_ms() + timeout_ms as i64, Ordering::Relaxed);

        let method_owned = method.to_string();
        let args_owned = args_json.to_string();

        let outcome = tokio::time::timeout(
            Duration::from_millis(timeout_ms + 2000),
            instance.ctx.async_with(async |ctx| -> Result<String, String> {
                let globals = ctx.globals();
                let inner: rquickjs::Result<Promise> = (|| {
                    let call_fn: Function = globals.get("__xyFbCall")?;
                    call_fn.call((method_owned.as_str(), args_owned.as_str()))
                })();
                let promise = match inner {
                    Ok(p) => p,
                    Err(e) => return Err(engine_error_message(&ctx, &e)),
                };
                promise
                    .into_future::<String>()
                    .await
                    .map_err(|e| engine_error_message(&ctx, &e))
            }),
        )
        .await;

        instance.deadline_ms.store(0, Ordering::Relaxed);
        instance.current_call.store(0, Ordering::Relaxed);
        let logs = take_logs(&instance.logs, call_id);

        match outcome {
            // tokio 兜底超时
            Err(_) => (
                Err(format!("模块调用超时: {method} ({timeout_ms}ms)")),
                logs,
            ),
            Ok(Err(e)) if e.contains("interrupt") => {
                // deadline 中断（interrupt handler 触发）即超时
                (Err(format!("模块调用超时: {method} ({timeout_ms}ms)")), logs)
            }
            Ok(Err(e)) => (Err(format!("引擎调用失败: {e}")), logs),
            Ok(Ok(json)) => (Ok(json), logs),
        }
    }

    pub async fn call(
        &self,
        module_key: &str,
        method: &str,
        args_json: &str,
        timeout_ms: u64,
    ) -> FallbackCallResult {
        let instance = {
            let instances = self.instances.lock().await;
            match instances.get(module_key) {
                Some(i) => i.clone(),
                None => {
                    return call_err(
                        format!("模块未加载: {module_key}"),
                        Vec::new(),
                    )
                }
            }
        };

        let timeout_ms = if timeout_ms == 0 { DEFAULT_CALL_TIMEOUT_MS } else { timeout_ms };
        let (outcome, logs) = Self::call_once(&instance, method, args_json, timeout_ms).await;

        match outcome {
            Err(e) => {
                // 超时/中断后实例状态不可信，销毁等待重新 load（热替换恢复）
                self.instances.lock().await.remove(module_key);
                call_err(e, logs)
            }
            Ok(json) => match serde_json::from_str::<serde_json::Value>(&json) {
                Ok(v) if v.get("ok").and_then(|x| x.as_bool()).unwrap_or(false) => FallbackCallResult {
                    ok: true,
                    error: None,
                    data: v.get("data").cloned(),
                    logs,
                },
                Ok(v) => {
                    let error = v
                        .get("error")
                        .and_then(|x| x.as_str())
                        .unwrap_or("模块调用失败")
                        .to_string();
                    call_err(error, logs)
                }
                Err(e) => call_err(format!("调用结果解析失败: {e}"), logs),
            },
        }
    }

    /// 保序逐项调用；logs 聚合到顶层，单项只留 {ok, data, error}。
    pub async fn call_many(
        &self,
        module_key: &str,
        method: &str,
        args_json_list: &[String],
        timeout_ms: u64,
    ) -> FallbackCallManyResult {
        let instance = {
            let instances = self.instances.lock().await;
            match instances.get(module_key) {
                Some(i) => i.clone(),
                None => {
                    return FallbackCallManyResult {
                        results: Vec::new(),
                        logs: Vec::new(),
                    }
                }
            }
        };

        let timeout_ms = if timeout_ms == 0 { DEFAULT_CALL_TIMEOUT_MS } else { timeout_ms };
        let mut results = Vec::with_capacity(args_json_list.len());
        let mut all_logs = Vec::new();

        for args_json in args_json_list {
            let (outcome, logs) = Self::call_once(&instance, method, args_json, timeout_ms).await;
            all_logs.extend(logs);
            match outcome {
                Err(e) => results.push(FallbackCallItem {
                    ok: false,
                    error: Some(e),
                    data: None,
                }),
                Ok(json) => match serde_json::from_str::<serde_json::Value>(&json) {
                    Ok(v) if v.get("ok").and_then(|x| x.as_bool()).unwrap_or(false) => {
                        results.push(FallbackCallItem {
                            ok: true,
                            error: None,
                            data: v.get("data").cloned(),
                        })
                    }
                    Ok(v) => results.push(FallbackCallItem {
                        ok: false,
                        error: Some(
                            v.get("error")
                                .and_then(|x| x.as_str())
                                .unwrap_or("模块调用失败")
                                .to_string(),
                        ),
                        data: None,
                    }),
                    Err(e) => results.push(FallbackCallItem {
                        ok: false,
                        error: Some(format!("调用结果解析失败: {e}")),
                        data: None,
                    }),
                },
            }
        }

        FallbackCallManyResult {
            results,
            logs: all_logs,
        }
    }

    /// 整包替换配置快照；返回所存配置的 sha256-hex（对原始入参字符串取摘要）。
    /// 前端用 crypto.subtle 对同一 JSON 字符串算同样的 hash 做启动对账。
    pub fn update_config(&self, config_json: &str) -> Result<String, String> {
        let value: serde_json::Value = serde_json::from_str(config_json)
            .map_err(|e| format!("配置解析失败: {e}"))?;
        let hash = {
            use sha2::{Digest, Sha256};
            let mut hasher = Sha256::new();
            hasher.update(config_json.as_bytes());
            hex::encode(hasher.finalize())
        };
        *self.config.write().unwrap() = value;
        *self.config_hash.write().unwrap() = hash.clone();
        Ok(hash)
    }

    /// 当前已存配置的 hash；从未推送过时为空串（前端对账必不相等 → 触发推送）。
    pub fn config_hash(&self) -> String {
        self.config_hash.read().unwrap().clone()
    }
}
