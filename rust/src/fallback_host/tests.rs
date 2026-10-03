use std::sync::Arc;

use super::{FallbackCallManyResult, FallbackCallResult, FallbackLoadResult, FallbackEngine};
use crate::plugin_host::{HttpBridge, PluginStore};

fn engine() -> FallbackEngine {
    FallbackEngine::new(Arc::new(HttpBridge::new(Arc::new(PluginStore::load(None)))))
}

fn env_seed() -> Option<[u8; 32]> {
    let hex = std::env::var("XY_FALLBACK_TEST_SEED").ok()?;
    let bytes: Vec<u8> = (0..hex.len())
        .step_by(2)
        .filter_map(|i| u8::from_str_radix(&hex[i..i + 2], 16).ok())
        .collect();
    if bytes.len() != 32 {
        return None;
    }
    let mut seed = [0u8; 32];
    seed.copy_from_slice(&bytes);
    Some(seed)
}

fn signed(key: &str, version: i64, code: &str) -> Option<String> {
    use ed25519_dalek::{Signer, SigningKey};
    let seed = env_seed()?;
    let signing = SigningKey::from_bytes(&seed);
    let msg = crate::fallback_verify::fallback_module_message(key, version, code);
    Some(hex::encode(signing.sign(&msg).to_bytes()))
}

const PING_CODE: &str = r#"
return {
  version: 1,
  fetchLyric() { return 'lyric'; },
  ping(args) { return { pong: args.value }; },
  fail() { throw new Error('boom'); },
  order(args) { return { i: args.i }; },
  mapOut() { return new Map([['a', 1], ['b', 'x']]); },
  configProbe(args) { return ctx.config.get(args.path); },
};
"#;

async fn load_ok(engine: &FallbackEngine, code: &str) -> FallbackLoadResult {
    let sig = signed("lx_lyric", 1, code).expect("需要 XY_FALLBACK_TEST_SEED");
    engine.load("lx_lyric", 1, code, &sig, "2.0.4-test").await
}

#[tokio::test]
async fn rejects_unregistered_module_key() {
    let engine = engine();
    let r = engine
        .load("no_such_key", 1, "return { version: 1 }", "deadbeef", "x")
        .await;
    assert!(!r.ok);
    assert!(r.error.unwrap().contains("未注册的兜底模块"));
}

#[tokio::test]
async fn rejects_bad_signature() {
    let engine = engine();
    let r = engine
        .load("lx_lyric", 1, PING_CODE, "00".repeat(64).as_str(), "x")
        .await;
    assert!(!r.ok);
    assert!(r.error.unwrap().contains("签名"));
}

#[tokio::test]
async fn rejects_factory_not_returning_object() {
    let engine = engine();
    if env_seed().is_none() {
        return; // 无 seed 时无法通过验签，跳过
    }
    let code = "const x = 1; return null;";
    let r = engine
        .load("lx_lyric", 1, code, &signed("lx_lyric", 1, code).unwrap(), "x")
        .await;
    assert!(!r.ok);
    assert!(r.error.unwrap().contains("对象"));
}

#[tokio::test]
async fn rejects_invalid_version() {
    let engine = engine();
    if env_seed().is_none() {
        return;
    }
    let code = "return { version: 0, fetchLyric() { return ''; } }";
    let r = engine
        .load("lx_lyric", 0, code, &signed("lx_lyric", 0, code).unwrap(), "x")
        .await;
    assert!(!r.ok);
    assert!(r.error.unwrap().contains("version"));
}

#[tokio::test]
async fn rejects_missing_expected_methods() {
    let engine = engine();
    if env_seed().is_none() {
        return;
    }
    let code = "return { version: 1, unrelated() { return 1; } }";
    let r = engine
        .load("lx_lyric", 1, code, &signed("lx_lyric", 1, code).unwrap(), "x")
        .await;
    assert!(!r.ok);
    assert!(r.error.unwrap().contains("约定方法"));
}

#[tokio::test]
async fn load_ok_and_call_roundtrip() {
    let engine = engine();
    if env_seed().is_none() {
        return; // 无 seed 时无法构造合法签名，跳过
    }
    let loaded = load_ok(&engine, PING_CODE).await;
    assert!(loaded.ok, "load 失败: {:?}", loaded.error);
    assert_eq!(loaded.version, Some(1));

    let r: FallbackCallResult = engine
        .call("lx_lyric", "ping", r#"{"value":"hello"}"#, 0)
        .await;
    assert!(r.ok, "call 失败: {:?}", r.error);
    assert_eq!(r.data.unwrap()["pong"], "hello");
}

#[tokio::test]
async fn call_exception_returns_error() {
    let engine = engine();
    if env_seed().is_some() {
        let loaded = load_ok(&engine, PING_CODE).await;
        assert!(loaded.ok);
        let r = engine.call("lx_lyric", "fail", "null", 0).await;
        assert!(!r.ok);
        assert_eq!(r.error.unwrap(), "boom");
    }
}

#[tokio::test]
async fn call_many_preserves_order() {
    let engine = engine();
    if env_seed().is_none() {
        return;
    }
    let loaded = load_ok(&engine, PING_CODE).await;
    assert!(loaded.ok);

    let args: Vec<String> = (0..5).map(|i| format!(r#"{{"i":{i}}}"#)).collect();
    let many: FallbackCallManyResult = engine
        .call_many("lx_lyric", "order", &args, 0)
        .await;
    assert_eq!(many.results.len(), 5);
    for (i, item) in many.results.iter().enumerate() {
        assert!(item.ok, "第 {i} 项失败: {:?}", item.error);
        assert_eq!(item.data.as_ref().unwrap()["i"], i as f64);
    }
}

#[tokio::test]
async fn cache_set_get_del_and_ttl() {
    let engine = engine();
    if env_seed().is_none() {
        return;
    }
    let loaded = load_ok(&engine, PING_CODE).await;
    assert!(loaded.ok);

    // 写入共享 cache（TTL 1s）→ 另一次 call 内可读 → 过期后为 null
    let setup = r#"
      return {
        version: 2,
        fetchLyric() { return ''; },
        cachePut(args) { ctx.cache.set(args.key, args.value, args.ttl || 0); },
        cacheGet(args) { return ctx.cache.get(args.key); },
        cacheDel(args) { ctx.cache.del(args.key); },
      };
    "#;
    let sig = signed("lx_lyric", 2, setup).unwrap();
    let loaded2 = engine.load("lx_lyric", 2, setup, &sig, "x").await;
    assert!(loaded2.ok, "热替换失败: {:?}", loaded2.error);
    assert_eq!(loaded2.version, Some(2));

    engine
        .call("lx_lyric", "cachePut", r#"{"key":"k1","value":{"n":42},"ttl":2}"#, 0)
        .await;
    let got = engine.call("lx_lyric", "cacheGet", r#"{"key":"k1"}"#, 0).await;
    assert!(got.ok);
    assert_eq!(got.data.unwrap()["n"], 42);

    engine
        .call("lx_lyric", "cachePut", r#"{"key":"k2","value":"gone","ttl":0.05}"#, 0)
        .await;
    tokio::time::sleep(std::time::Duration::from_millis(120)).await;
    let expired = engine.call("lx_lyric", "cacheGet", r#"{"key":"k2"}"#, 0).await;
    assert!(expired.ok);
    assert!(expired.data.unwrap().is_null());

    engine.call("lx_lyric", "cacheDel", r#"{"key":"k1"}"#, 0).await;
    let deleted = engine.call("lx_lyric", "cacheGet", r#"{"key":"k1"}"#, 0).await;
    assert!(deleted.data.unwrap().is_null());
}

#[tokio::test]
async fn config_deep_path_lookup() {
    let engine = engine();
    if env_seed().is_none() {
        return;
    }
    let loaded = load_ok(&engine, PING_CODE).await;
    assert!(loaded.ok);

    engine
        .update_config(r#"{"net":{"proxy":{"enabled":true,"host":"127.0.0.1"}},"plain":7}"#)
        .unwrap();

    let hit = engine
        .call("lx_lyric", "configProbe", r#"{"path":"net.proxy.host"}"#, 0)
        .await;
    assert!(hit.ok);
    assert_eq!(hit.data.unwrap(), "127.0.0.1");

    let miss = engine
        .call("lx_lyric", "configProbe", r#"{"path":"net.proxy.nothing.deep"}"#, 0)
        .await;
    assert!(miss.ok);
    assert!(miss.data.unwrap().is_null());
}

#[tokio::test]
async fn map_return_value_normalized_to_object() {
    let engine = engine();
    if env_seed().is_none() {
        return;
    }
    let loaded = load_ok(&engine, PING_CODE).await;
    assert!(loaded.ok);

    let r = engine.call("lx_lyric", "mapOut", "null", 0).await;
    assert!(r.ok);
    let data = r.data.unwrap();
    assert_eq!(data["a"], 1);
    assert_eq!(data["b"], "x");
}

#[tokio::test]
async fn hot_replace_keeps_shared_cache() {
    let engine = engine();
    if env_seed().is_none() {
        return;
    }
    let v1 = r#"
      return {
        version: 1,
        fetchLyric() { return 'v1'; },
        cachePut(args) { ctx.cache.set(args.key, args.value, 60); },
        cacheGet(args) { return ctx.cache.get(args.key); },
      };
    "#;
    let loaded = engine
        .load("lx_lyric", 1, v1, &signed("lx_lyric", 1, v1).unwrap(), "x")
        .await;
    assert!(loaded.ok);

    engine
        .call("lx_lyric", "cachePut", r#"{"key":"shared","value":"kept"}"#.into(), 0)
        .await;

    // v2 热替换：cache 不清空，新版本读到旧数据
    let v2 = r#"
      return {
        version: 2,
        fetchLyric() { return 'v2'; },
        cacheGet(args) { return ctx.cache.get(args.key); },
      };
    "#;
    let reloaded = engine
        .load("lx_lyric", 2, v2, &signed("lx_lyric", 2, v2).unwrap(), "x")
        .await;
    assert!(reloaded.ok);
    assert_eq!(reloaded.version, Some(2));

    let lyric = engine.call("lx_lyric", "fetchLyric", "null", 0).await;
    assert_eq!(lyric.data.unwrap(), "v2");
    let kept = engine.call("lx_lyric", "cacheGet", r#"{"key":"shared"}"#.into(), 0).await;
    assert_eq!(kept.data.unwrap(), "kept");
}

#[tokio::test]
async fn call_without_load_errors() {
    let engine = engine();
    let r = engine.call("lx_lyric", "fetchLyric", "null", 0).await;
    assert!(!r.ok);
    assert!(r.error.unwrap().contains("模块未加载"));
}

#[tokio::test]
async fn timeout_destroys_instance() {
    let engine = engine();
    if env_seed().is_none() {
        return;
    }
    let code = r#"
      return {
        version: 1,
        fetchLyric() {
          const start = Date.now();
          while (Date.now() - start < 10_000) { /* 自旋阻塞 */ }
          return '';
        },
      };
    "#;
    let loaded = engine
        .load("lx_lyric", 1, code, &signed("lx_lyric", 1, code).unwrap(), "x")
        .await;
    assert!(loaded.ok);

    let r = engine.call("lx_lyric", "fetchLyric", "null", 300).await;
    assert!(!r.ok);
    assert!(r.error.unwrap().contains("超时"));

    // 超时销毁后需重新 load
    let r2 = engine.call("lx_lyric", "fetchLyric", "null", 300).await;
    assert!(!r2.ok);
    assert!(r2.error.unwrap().contains("模块未加载"));
}
