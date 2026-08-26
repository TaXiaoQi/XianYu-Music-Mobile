//! 宿主侧平台签名/加密（移植自桌面端 host_crypto.rs 的纯逻辑，去 Tauri 依赖）。
//!
//! 覆盖音乐平台接口所需的签名算法：
//!   - QQ 音乐 zzcSign（SHA1 + 索引选取 + XOR 混淆 + Base64）
//!   - 酷狗参数签名（MD5，web/android 两种盐）
//!   - 咪咕搜索签名（MD5）
//!   - 网易云 linuxapi（AES-128-ECB PKCS7 → hex 大写）
//!   - 网易云 weapi（AES-CBC 双重加密 + RSA 模幂）
//!   - 通用 MD5/SHA256（插件脚本哈希等）
//!
//! 网络请求本身仍走 plugin_http_request 后端代理，本模块只负责签名计算。
//! 由 `api/mod.rs` 通过 FRB 暴露给 Flutter 调用。

use aes::cipher::{block_padding::Pkcs7, BlockEncrypt, BlockEncryptMut, KeyInit, KeyIvInit};
use base64::Engine as _;
use num_bigint::BigUint;
use sha1::{Digest, Sha1};

type Aes128CbcEnc = cbc::Encryptor<aes::Aes128>;

const B64: base64::engine::GeneralPurpose = base64::engine::general_purpose::STANDARD;

// ===== QQ zzcSign =====

const TX_PART_1_INDEXES: [usize; 8] = [23, 14, 6, 36, 16, 40, 7, 19];
const TX_PART_2_INDEXES: [usize; 8] = [16, 1, 32, 12, 19, 27, 8, 5];
const TX_SCRAMBLE_VALUES: [u8; 20] = [
    89, 39, 179, 150, 218, 82, 58, 252, 177, 52, 186, 123, 120, 64, 242, 133, 143, 161, 121, 179,
];

pub fn zzc_sign(text: &str) -> String {
    let hash = hex::encode(Sha1::digest(text.as_bytes()));
    let bytes = hash.as_bytes();

    // SHA1 hex 为 40 字符，JS 端 hash[40] 越界得 undefined，join 时被跳过
    let part1: String = TX_PART_1_INDEXES
        .iter()
        .filter_map(|&i| bytes.get(i).map(|&b| b as char))
        .collect();
    let part2: String = TX_PART_2_INDEXES
        .iter()
        .filter_map(|&i| bytes.get(i).map(|&b| b as char))
        .collect();

    let mut part3 = [0u8; 20];
    for i in 0..20 {
        let byte = u8::from_str_radix(&hash[i * 2..i * 2 + 2], 16).unwrap_or(0);
        part3[i] = TX_SCRAMBLE_VALUES[i] ^ byte;
    }
    let b64_part = B64.encode(part3);
    let b64_clean: String = b64_part
        .chars()
        .filter(|c| !matches!(c, '/' | '\\' | '+' | '='))
        .collect();

    format!("zzc{part1}{b64_clean}{part2}").to_lowercase()
}

// ===== 酷狗签名 =====

pub const KG_SALT_ANDROID: &str = "OIlwieks28dk2k092lksi2UIkp";
const KG_SALT_WEB: &str = "NVPh5oo715z5DIWAeQlhMDsWXXQV4hwt";

/// `md5(salt + sort(params.split('&')).join('') + body + salt)`
/// platform: "web" 用 web 盐，其余用 android 盐；body 传空串时与酷狗评论签名等价
pub fn kugou_sign(params: &str, platform: &str, body: &str) -> String {
    let salt = if platform == "web" {
        KG_SALT_WEB
    } else {
        KG_SALT_ANDROID
    };
    let mut list: Vec<&str> = params.split('&').collect();
    list.sort_unstable();
    let sign_input = format!("{}{}{}{}", salt, list.join(""), body, salt);
    format!("{:x}", md5::compute(sign_input.as_bytes()))
}

// ===== 咪咕签名 =====

const MG_DEVICE_ID: &str = "963B7AA0D21511ED807EE5846EC87D20";
const MG_SIGNATURE_MD5: &str = "6cdc72a439cef99a3418d2a78aa28c73";

pub fn migu_sign(text: &str, time: &str) -> (String, String) {
    let sign_input = format!(
        "{}{}yyapp2d16148780a1dcc7408e06336b98cfd50{}{}",
        text, MG_SIGNATURE_MD5, MG_DEVICE_ID, time
    );
    let sign = format!("{:x}", md5::compute(sign_input.as_bytes()));
    (sign, MG_DEVICE_ID.to_string())
}

// ===== 网易云 linuxapi（AES-128-ECB PKCS7 → hex 大写） =====

const WY_LINUXAPI_KEY: &[u8; 16] = b"rFgB&h#%2?^eDg:Q";

pub fn linuxapi_encrypt(payload: &str) -> String {
    let cipher = aes::Aes128::new(WY_LINUXAPI_KEY.into());
    let data = payload.as_bytes();
    let pad_len = 16 - (data.len() % 16);
    let mut padded = Vec::with_capacity(data.len() + pad_len);
    padded.extend_from_slice(data);
    padded.extend(std::iter::repeat_n(pad_len as u8, pad_len));

    let mut out = Vec::with_capacity(padded.len());
    for chunk in padded.chunks(16) {
        let mut block = aes::cipher::generic_array::GenericArray::default();
        block.copy_from_slice(chunk);
        cipher.encrypt_block(&mut block);
        out.extend_from_slice(&block);
    }
    hex::encode_upper(out)
}

// ===== 网易云 weapi（AES-CBC 双重 + RSA 模幂） =====

const WEAPI_PRESET_KEY: &[u8; 16] = b"0CoJUm6Qyw8W8jud";
const WEAPI_IV: &[u8; 16] = b"0102030405060708";
const BASE62: &[u8] = b"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
const RSA_MODULUS_HEX: &str = "00e0b509f6259df8642dbc35662901477df22677ec152b5ff68ace615bb7b725152b3ab17a876aea8a5aa76d2e417629ec4ee341f56135fccf695280104e0312ecbda92557c93870114af6c9d05c4f7f0c3685b7a46bee255932575cce10b424d813cfe4875d3e82047b97ddef52741d546b8e289dc6935b3ece0462db0a22b8e7";

fn aes_cbc_b64(plaintext: &[u8], key: &[u8; 16]) -> String {
    let mut buf = vec![0u8; plaintext.len() + 16];
    buf[..plaintext.len()].copy_from_slice(plaintext);
    let ct = Aes128CbcEnc::new(key.into(), WEAPI_IV.into())
        .encrypt_padded_mut::<Pkcs7>(&mut buf, plaintext.len())
        .expect("AES-CBC PKCS7");
    B64.encode(ct)
}

fn rsa_modpow_128(data: &[u8; 16]) -> String {
    let mut padded = [0u8; 128];
    padded[128 - 16..].copy_from_slice(data);
    let m = BigUint::from_bytes_be(&padded);
    let n = BigUint::parse_bytes(RSA_MODULUS_HEX.as_bytes(), 16).expect("RSA modulus");
    let e = BigUint::from(65537u32);
    let result = m.modpow(&e, &n);
    format!("{:0256x}", result)
}

/// 固定密钥版本（测试对照用）
pub fn weapi_encrypt_with_key(payload: &str, key_bytes: &[u8; 16]) -> (String, String) {
    let first = aes_cbc_b64(payload.as_bytes(), WEAPI_PRESET_KEY);
    let params = aes_cbc_b64(first.as_bytes(), key_bytes);
    let mut reversed = [0u8; 16];
    for i in 0..16 {
        reversed[i] = key_bytes[15 - i];
    }
    let enc_sec_key = rsa_modpow_128(&reversed);
    (params, enc_sec_key)
}

pub fn random_weapi_key() -> [u8; 16] {
    let mut key_bytes = [0u8; 16];
    getrandom::fill(&mut key_bytes).expect("getrandom");
    for b in key_bytes.iter_mut() {
        *b = BASE62[(*b as usize) % 62];
    }
    key_bytes
}

pub fn weapi_encrypt(payload: &str) -> (String, String) {
    let key_bytes = random_weapi_key();
    weapi_encrypt_with_key(payload, &key_bytes)
}

/// SHA-256 hex（插件/脚本哈希、测试对照等通用用途）。
pub fn sha256_hex(text: &str) -> String {
    use sha2::Sha256;
    hex::encode(Sha256::digest(text.as_bytes()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_zzc_sign() {
        assert_eq!(
            zzc_sign(
                r#"{"comm":{"ct":19,"cv":1859,"uin":"0"},"req":{"module":"music.search.SearchCgiService","method":"DoSearchForQQMusicDesktop","param":{"search_type":0,"query":"test","page_num":1,"num_per_page":30}}}"#
            ),
            "zzcfe761c2myum6ntupxsjzpwe5pwij7defo183925a5"
        );
        assert_eq!(zzc_sign("hello world 中文测试"), "zzccbdcf94uzqbt2ymvkxoghoxqhluaysuvaqf2a649b2");
    }

    #[test]
    fn test_kugou_sign() {
        assert_eq!(
            kugou_sign(
                "appid=1005&clienttime=1700000000000&clienttoken=0&clientver=11409&code=fc4be23b4e972707f36b8a828a93ba8a&dfid=0&extdata=ABCDEF&kugouid=0&mid=16249512204336365674023395779019&mixsongid=123&p=1&pagesize=20&uuid=0&ver=10",
                "android",
                ""
            ),
            "20b720a85d3ba48138ea1df1997c1ecd"
        );
        assert_eq!(kugou_sign("b=2&a=1&c=3", "android", "BODYDATA"), "e4ec17307d2c2328b4f2d7221e3e8400");
    }

    #[test]
    fn test_linuxapi_encrypt() {
        assert_eq!(
            linuxapi_encrypt(r#"{"hello":"world"}"#),
            "DD2462670DBFF71DD202A99E5142717BFC5965DED0B85514DD5B3281C0C36ECB"
        );
    }

    #[test]
    fn test_weapi_fixed_key() {
        let key_bytes: [u8; 16] = [
            b'0', b'1', b'2', b'3', b'4', b'5', b'6', b'7', b'8', b'9', b'a', b'b', b'c', b'd', b'e', b'f',
        ];
        let (params, enc_sec_key) = weapi_encrypt_with_key(r#"{"c":"[{\"id\":123}]","ids":"[123]"}"#, &key_bytes);
        assert_eq!(params, "auDeheFn0YvsgT3xR8gl97LdNR+b1Rg6DtWzyihBvdC2c+cxPsgZBqPPCgH5ql9XycrCwrS2ACEjHxto45U6Av0AdLvSnXwhWGRSqaz+9FQ=");
        assert_eq!(enc_sec_key, "35701388baf89fed412e11269b9c76625d095ecaf17f03fa018abe19ea2d38b949debf242ee39a71ca1f6cda71b1b86a45aa909ee27f7e78e267d34e732f0de948206c3340a788d0003372183e2f753c1f78b66ac23d134ac1fc9b993156520ea826b8aa89a962d4491b4b8d7e08738e1da9b07aa39bf4a7ef0b1c210728cd52");
    }

    #[test]
    fn test_weapi_random_key_shape() {
        let (params, enc_sec_key) = weapi_encrypt(r#"{"ids":"[1]"}"#);
        assert!(!params.is_empty());
        assert_eq!(enc_sec_key.len(), 256);
        assert!(enc_sec_key.chars().all(|c| c.is_ascii_hexdigit()));
        let key = random_weapi_key();
        assert!(key.iter().all(|b| BASE62.contains(b)));
    }

    #[test]
    fn test_sha256_hex() {
        assert_eq!(
            sha256_hex("hello world 中文测试"),
            "611565143c922a055e8d1faddf895fa5cb6a12a0969ce154965976a0a58da74e"
        );
    }
}