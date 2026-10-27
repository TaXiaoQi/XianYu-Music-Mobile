//! 兜底配置签名校验（移植自桌面端 fallback_verify.rs，去 Tauri 依赖）。
//!
//! 服务端下发兜底行为配置（各元数据链路的开关/参数，不含任何可执行代码）。
//! 仅靠 HTTPS + 客户端自算摘要无法防篡改，改为 ed25519：服务端私钥对配置
//! JSON 原始字符串签名，客户端公钥验签通过才采纳。
//!
//! 同文件还提供内测资格响应（check_beta_access）的签名校验。

use ed25519_dalek::{Signature, Verifier, VerifyingKey};

/// 三端统一的双公钥槽位 `(keyId, 公钥hex)`（32 字节），与私钥成对（私钥在
/// 服务端签发侧）。轮换三步走：
/// 1. T0 预发布：解开下一行注释，填入下一把公钥（keyId 形如 "2026b"）并发版；
/// 2. 切换：服务端签发槽位切到新 keyId（旧钥在 previous 槽位过渡）；
/// 3. 收尾：全量覆盖后移除旧槽位。
/// 验签先按响应 keyId 精确匹配槽位（严格绑定），无 keyId/未知 keyId 则遍历
/// 全部槽位；签名对某槽位有效但 keyId 不在槽位 → valid + key_unknown
/// （客户端采纳配置并上报 FallbackConfigKeyUnknown 事件）。
const FALLBACK_VERIFY_KEYS: &[(&str, &str)] = &[
    ("2026a", "fd2f887e74adb2009079bc822536d8f09d1404656f748289608592b6a4c974c5"),
    // 轮换 T0 预发布：解开注释并填入下一把公钥
    // ("2026b", "<next-public-key-hex>"),
];

/// 兜底配置验签结果。
/// `valid`: 签名对某内嵌公钥有效（可采纳该配置）。
/// `key_unknown`: 签名有效但响应 keyId 不在已知槽位（疑似新公钥上线或
/// 密钥降级攻击；采纳的同时应上报事件）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct FallbackVerifyResult {
    pub valid: bool,
    pub key_unknown: bool,
}

/// 配置签名消息构造（服务端 client/server 两端必须逐字一致）：
/// 对配置 JSON 原始字符串（未解析、未重排序）直接签名，避免 JSON
/// 规范化差异；前缀防止签名在其他消息类型间复用。
pub(crate) fn fallback_config_message(config_json: &str) -> Vec<u8> {
    format!("xianyu-fallback-config-v1\x00{config_json}").into_bytes()
}

/// 内测资格响应签名消息（与服务端 check_beta_access 逐字一致）：
/// `xianyu-beta-access-v1\x00{device_id}\x00{allowed01}\x00{pending01}\x00{exp}`
pub(crate) fn beta_access_message(device_id: &str, allowed: bool, pending: bool, exp: i64) -> Vec<u8> {
    format!(
        "xianyu-beta-access-v1\x00{device_id}\x00{}\x00{}\x00{exp}",
        i32::from(allowed),
        i32::from(pending),
    )
    .into_bytes()
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

/// 校验服务端 check_beta_access 响应签名（ed25519，绑定 device_id + 过期时间；
/// 内测协议无 keyId，遍历全部公钥槽位）。返回 true 表示响应可信。
pub fn verify_beta_access_signature(
    device_id: &str,
    allowed: bool,
    pending: bool,
    exp: i64,
    signature: &str,
) -> Result<bool, String> {
    Ok(verify_with_public_keys(
        &beta_access_message(device_id, allowed, pending, exp),
        signature,
        None,
    )?
    .valid)
}

/// 校验服务端下发的兜底配置签名（双公钥槽位）。`key_id` 为服务端响应携带的
/// keyId（可选）：已知 keyId 仅对该槽位严格验签；缺失/未知则遍历全部槽位，
/// 签名有效且 keyId 未知时返回 `key_unknown = true`（采纳并上报事件）。
pub fn verify_fallback_config_signature(
    config_json: &str,
    signature: &str,
    key_id: Option<&str>,
) -> Result<FallbackVerifyResult, String> {
    verify_with_public_keys(
        &fallback_config_message(config_json),
        signature,
        key_id,
    )
}

fn slot_verifying_key(slot: &(&str, &str)) -> Option<VerifyingKey> {
    let bytes = hex_to_bytes(slot.1).ok()?;
    let arr: [u8; 32] = bytes.as_slice().try_into().ok()?;
    VerifyingKey::from_bytes(&arr).ok()
}

fn verify_with_public_keys(
    msg: &[u8],
    signature: &str,
    key_id: Option<&str>,
) -> Result<FallbackVerifyResult, String> {
    let sig_bytes = hex_to_bytes(signature)?;
    if sig_bytes.len() != 64 {
        return Ok(FallbackVerifyResult::default());
    }
    let sig = Signature::from_bytes(sig_bytes.as_slice().try_into().unwrap());

    let trimmed_key_id = key_id.map(str::trim).filter(|k| !k.is_empty());
    if let Some(kid) = trimmed_key_id {
        if let Some(slot) = FALLBACK_VERIFY_KEYS.iter().find(|(id, _)| *id == kid) {
            if let Some(vk) = slot_verifying_key(slot) {
                // 已知 keyId：严格绑定该槽位，失败不回退遍历（防密钥降级）
                return Ok(FallbackVerifyResult {
                    valid: vk.verify(msg, &sig).is_ok(),
                    key_unknown: false,
                });
            }
        }
    }
    let mut valid = false;
    for slot in FALLBACK_VERIFY_KEYS {
        if let Some(vk) = slot_verifying_key(slot) {
            if vk.verify(msg, &sig).is_ok() {
                valid = true;
                break;
            }
        }
    }
    Ok(FallbackVerifyResult {
        valid,
        key_unknown: valid && trimmed_key_id.is_some(),
    })
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

    fn sign_of(config_json: &str) -> Option<String> {
        let key = SigningKey::from_bytes(&env_seed()?);
        let msg = fallback_config_message(config_json);
        Some(hex::encode(key.sign(&msg).to_bytes()))
    }

    #[test]
    fn message_is_stable() {
        let m = String::from_utf8(fallback_config_message("{\"version\":1}")).unwrap();
        assert!(m.starts_with("xianyu-fallback-config-v1\x00"));
        assert_eq!(m, "xianyu-fallback-config-v1\x00{\"version\":1}");
    }

    #[test]
    fn beta_access_message_is_stable() {
        let m = String::from_utf8(beta_access_message("dev1", true, false, 123)).unwrap();
        assert_eq!(m, "xianyu-beta-access-v1\x00dev1\x001\x000\x00123");
    }

    #[test]
    fn beta_access_rejects_tampered_fields() {
        let Some(sig) = (|| {
            let key = SigningKey::from_bytes(&env_seed()?);
            Some(hex::encode(
                key.sign(&beta_access_message("dev1", true, false, 123))
                    .to_bytes(),
            ))
        })() else {
            eprintln!("跳过：未设置 XY_FALLBACK_TEST_SEED");
            return;
        };
        assert!(verify_beta_access_signature("dev1", true, false, 123, &sig).unwrap());
        assert!(!verify_beta_access_signature("dev2", true, false, 123, &sig).unwrap());
        assert!(!verify_beta_access_signature("dev1", false, false, 123, &sig).unwrap());
        assert!(!verify_beta_access_signature("dev1", true, true, 123, &sig).unwrap());
        assert!(!verify_beta_access_signature("dev1", true, false, 124, &sig).unwrap());
    }

    #[test]
    fn rejects_malformed_signature() {
        assert!(verify_fallback_config_signature("{\"version\":1}", "not-hex!!", None).is_err());
        assert!(!verify_fallback_config_signature("{\"version\":1}", "abcd", None)
            .unwrap()
            .valid);
    }

    #[test]
    fn rejects_tampered_config() {
        let Some(sig) = sign_of("{\"version\":1}") else {
            eprintln!("跳过：未设置 XY_FALLBACK_TEST_SEED");
            return;
        };
        assert!(verify_fallback_config_signature("{\"version\":1}", &sig, None)
            .unwrap()
            .valid);
        assert!(!verify_fallback_config_signature("{\"version\":2}", &sig, None)
            .unwrap()
            .valid);
    }

    #[test]
    fn key_id_binding_semantics() {
        // 未知 keyId + 有效签名（随机密钥即未知槽位）→ 采纳但 key_unknown
        let key = SigningKey::from_bytes(&[7u8; 32]);
        let sig = hex::encode(key.sign(&fallback_config_message("{\"version\":1}")).to_bytes());
        let r = verify_fallback_config_signature("{\"version\":1}", &sig, Some("zzz-unknown")).unwrap();
        assert!(r.valid && r.key_unknown);
        // 无 keyId → 正常采纳
        let r = verify_fallback_config_signature("{\"version\":1}", &sig, None).unwrap();
        assert!(r.valid && !r.key_unknown);
        // 已知 keyId（2026a）但签名来自其他密钥 → 严格绑定，直接拒绝
        let r = verify_fallback_config_signature("{\"version\":1}", &sig, Some("2026a")).unwrap();
        assert!(!r.valid && !r.key_unknown);
        // 空 keyId 视同缺失
        let r = verify_fallback_config_signature("{\"version\":1}", &sig, Some("")).unwrap();
        assert!(r.valid && !r.key_unknown);
    }

    #[test]
    fn known_key_id_strict_match_with_env_seed() {
        let Some(sig) = sign_of("{\"version\":1}") else {
            eprintln!("跳过：未设置 XY_FALLBACK_TEST_SEED");
            return;
        };
        // 环境变量种子即 2026a 槽位私钥：已知 keyId 命中槽位 → valid
        let r = verify_fallback_config_signature("{\"version\":1}", &sig, Some("2026a")).unwrap();
        assert!(r.valid && !r.key_unknown);
        // keyId 未知（9999 不在槽位）→ 遍历命中 2026a 槽位 → 采纳并上报 key_unknown
        let r = verify_fallback_config_signature("{\"version\":1}", &sig, Some("9999")).unwrap();
        assert!(r.valid && r.key_unknown);
    }
}
