//! 兜底模块签名校验（移植自桌面端 fallback_verify.rs，去 Tauri 依赖）。
//!
//! 服务器会定期下发 JS 模块（歌词/搜索/音源兜底）由前端执行。仅靠 HTTPS + 客户端自算
//! SHA-256 无法防篡改（digest 与代码同源下发）。改为 ed25519：服务端私钥签名
//! （code + moduleKey + version），客户端公钥验签通过才执行。

use ed25519_dalek::{Signature, Verifier, VerifyingKey};

/// 客户端内嵌的验签公钥（hex，32 字节），与私钥成对（私钥存于服务端）。
const FALLBACK_VERIFY_PUBLIC_KEY_HEX: &str =
    "fd2f887e74adb2009079bc822536d8f09d1404656f748289608592b6a4c974c5";

/// 签名消息构造（服务端 client/server 两端必须逐字一致）。
/// 含 moduleKey + version 防止签名在不同模块/版本间复用。
pub(crate) fn fallback_module_message(module_key: &str, version: i64, code: &str) -> Vec<u8> {
    format!("xianyu-fallback-v1\x00{module_key}\x00{version}\x00{code}").into_bytes()
}

fn hex_to_bytes(hex: &str) -> Result<Vec<u8>, String> {
    if hex.len() % 2 != 0 {
        return Err("签名不是合法 hex".to_string());
    }
    (0..hex.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&hex[i..i + 2], 16).map_err(|_| "签名不是合法 hex".to_string()))
        .collect()
}

/// 校验服务端下发的兜底模块签名。返回 true 表示签名有效，可安全执行该模块。
pub fn verify_fallback_module_signature(
    module_key: &str,
    version: i64,
    code: &str,
    signature: &str,
) -> Result<bool, String> {
    let pub_bytes = hex_to_bytes(FALLBACK_VERIFY_PUBLIC_KEY_HEX)?;
    let pub_key = VerifyingKey::from_bytes(
        pub_bytes
            .as_slice()
            .try_into()
            .map_err(|_| "内嵌公钥非法".to_string())?,
    )
    .map_err(|e| format!("公钥解析失败: {e}"))?;

    let sig_bytes = hex_to_bytes(signature)?;
    if sig_bytes.len() != 64 {
        return Ok(false);
    }
    let sig = Signature::from_bytes(sig_bytes.as_slice().try_into().unwrap());

    let msg = fallback_module_message(module_key, version, code);
    Ok(pub_key.verify(&msg, &sig).is_ok())
}

#[cfg(test)]
mod tests {
    use super::*;
    use ed25519_dalek::{Signer, SigningKey};

    /// 私钥种子绝不入源码：仅从环境变量读取，未设置则跳过依赖匹配密钥的用例。
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

    fn sign_of(module_key: &str, version: i64, code: &str) -> Option<String> {
        let key = SigningKey::from_bytes(&env_seed()?);
        let msg = fallback_module_message(module_key, version, code);
        Some(hex::encode(key.sign(&msg).to_bytes()))
    }

    #[test]
    fn message_is_stable() {
        let m = String::from_utf8(fallback_module_message("lx_search", 1, "function(){}")).unwrap();
        assert!(m.starts_with("xianyu-fallback-v1\x00lx_search\x00"));
        assert_eq!(m, "xianyu-fallback-v1\x00lx_search\x001\x00function(){}");
    }

    #[test]
    fn rejects_malformed_signature() {
        assert!(verify_fallback_module_signature("lx_search", 1, "function(){}", "not-hex!!").is_err());
    }

    #[test]
    fn rejects_signature_reused_across_versions() {
        let Some(sig) = sign_of("lx_search", 1, "function(){}") else {
            eprintln!("跳过：未设置 XY_FALLBACK_TEST_SEED");
            return;
        };
        assert!(
            !verify_fallback_module_signature("lx_search", 2, "function(){}", &sig).unwrap()
        );
    }
}