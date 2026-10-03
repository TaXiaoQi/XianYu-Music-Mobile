// lyric_fetcher.rs - 四音源歌词抓取与解密
//
// 将前端 lxLyricFetcher.ts 中的请求构造+解密逻辑迁移到 Rust。
// 支持的音源：
// - kg (酷狗): KRC 加密歌词，包含逐字时间
// - kw (酷我): XOR 加密请求 → zlib 解压 → 逐字歌词解析
// - tx (QQ音乐): QRC 3DES 解密 → 逐字歌词解析
// - wy (网易云): eapi AES-ECB 加密 → yrc/krc 逐字歌词

//! 拆分说明：QRC 解密见 qrc_crypto，HTTP 管道见 http_util，各音源见 source_*。

use serde::{Deserialize, Serialize};

mod http_util;
mod qrc_crypto;
mod source_kg;
mod source_kw;
mod source_tx;
mod source_wy;

pub(crate) use http_util::*;
pub(crate) use qrc_crypto::*;
use source_kg::*;
use source_kw::*;
use source_tx::*;
use source_wy::*;

// ==================== Types ====================

/// 歌词源返回的歌曲信息，作为纯反序列化 DTO。
/// 部分字段只在特定歌词源（酷狗/腾讯/网易）分支被消费，其余随 payload 保留。
#[derive(Deserialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
#[allow(dead_code)]
pub struct LyricSongInfo {
    pub songmid: String,
    pub hash: Option<String>,
    pub name: String,
    pub singer: String,
    pub album_name: Option<String>,
    pub interval: Option<String>,
    #[serde(rename = "_interval")]
    pub interval_ms: Option<u32>,
    pub song_id: Option<serde_json::Value>,
    pub str_media_mid: Option<String>,
    pub album_mid: Option<String>,
    pub album_id: Option<serde_json::Value>,
    pub copyright_id: Option<String>,
    pub source: Option<String>,
}

#[derive(Serialize, Clone, Debug, Default)]
#[serde(rename_all = "camelCase")]
pub struct LyricResult {
    pub lyric: String,
    pub tlyric: String,
    pub rlyric: String,
    pub lxlyric: String,
}

// ==================== Utility ====================

pub(crate) fn decode_html_entities(s: &str) -> String {
    s.replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#039;", "'")
        .replace("&#39;", "'")
        .replace("&nbsp;", " ")
}

fn decompress_zlib_sync_flush(bytes: &[u8]) -> Result<Vec<u8>, String> {
    use flate2::{Decompress, FlushDecompress, Status};
    let mut d = Decompress::new(true);
    let mut out = Vec::with_capacity(bytes.len() * 3 + 64);
    let mut buf = [0u8; 16384];
    let mut in_pos = 0usize;
    let mut guard = 0usize;
    loop {
        guard += 1;
        if guard > 1_000_000 {
            return Err("zlib inflate loop limit".to_string());
        }
        let before = d.total_out();
        let available_in = bytes.len().saturating_sub(in_pos);
        let status = d
            .decompress(
                &bytes[in_pos..in_pos + available_in],
                &mut buf,
                FlushDecompress::Sync,
            )
            .map_err(|e| e.to_string())?;
        let produced = (d.total_out() - before) as usize;
        out.extend_from_slice(&buf[..produced.min(buf.len())]);
        in_pos = d.total_in() as usize;
        match status {
            Status::StreamEnd => break,
            Status::BufError => break,
            Status::Ok => {
                if produced == 0 && in_pos >= bytes.len() {
                    break;
                }
            }
        }
    }
    Ok(out)
}

// ==================== Deflate/Zlib Decompression ====================

fn decompress_deflate_to_bytes(bytes: &[u8]) -> Result<Vec<u8>, String> {
    use flate2::read::DeflateDecoder;
    use std::io::Read;
    let mut decoder = DeflateDecoder::new(bytes);
    let mut result = Vec::new();
    decoder
        .read_to_end(&mut result)
        .map_err(|e| e.to_string())?;
    Ok(result)
}

fn decompress_zlib_to_bytes(bytes: &[u8]) -> Result<Vec<u8>, String> {
    use flate2::read::ZlibDecoder;
    use std::io::Read;
    let mut decoder = ZlibDecoder::new(bytes);
    let mut result = Vec::new();
    decoder
        .read_to_end(&mut result)
        .map_err(|e| e.to_string())?;
    Ok(result)
}

fn decompress_zlib_to_bytes_skip_header(bytes: &[u8]) -> Result<Vec<u8>, String> {
    // Try normal zlib first
    if let Ok(result) = decompress_zlib_to_bytes(bytes) {
        return Ok(result);
    }
    // Try skipping 2-byte zlib header
    if bytes.len() > 2 {
        if let Ok(result) = decompress_zlib_to_bytes(&bytes[2..]) {
            return Ok(result);
        }
    }
    Err("zlib decompression failed".to_string())
}

fn decompress_gzip_to_bytes(bytes: &[u8]) -> Result<Vec<u8>, String> {
    use flate2::read::GzDecoder;
    use std::io::Read;
    let mut decoder = GzDecoder::new(bytes);
    let mut result = Vec::new();
    decoder
        .read_to_end(&mut result)
        .map_err(|e| e.to_string())?;
    Ok(result)
}

fn bytes_to_lossy_string(bytes: Vec<u8>) -> String {
    String::from_utf8(bytes).unwrap_or_else(|e| {
        let bytes = e.into_bytes();
        String::from_utf8_lossy(&bytes).into_owned()
    })
}

// ==================== 对外入口 ====================

pub async fn fetch_lyric_from_source(
    source: String,
    song_info: LyricSongInfo,
) -> Result<Option<LyricResult>, String> {
    let result = match source.as_str() {
        "kg" => fetch_kg_lyric(&song_info).await?,
        "kw" => fetch_kw_lyric(&song_info).await?,
        "tx" => fetch_tx_lyric(&song_info).await?,
        "wy" => fetch_wy_lyric(&song_info).await?,
        _ => return Ok(None),
    };
    Ok(result)
}

#[cfg(test)]
mod qrc_roundtrip_tests {
    use super::qrc_decrypt;

    /// 密文由 BakaMusic lyric-decrypt.ts 同款 JS 实现（Node + zlib.deflateSync）
    /// 对 fixtures/lyrics/baby.qrc 加密生成，验证 Rust 移植与 BakaMusic 等价。
    #[test]
    fn qrc_decrypt_roundtrip_baka_music_sample() {
        let hex = "28feb85c1e5b0aee52751548debf8cec52f70ac1da86688e31bcd4d2a45cb2c8160f5c250523e901f07ebf7fe6d77f6faa0f5043b807fcc537f7187d35c7679b37036be3184b3105526561110e1753714a7e6d1d7f17b0b2a10fe8c072d2e43ef5ec7d25bc331953a9ca7bf72bc291aa1c86176920dd579407719661fa2779178156cd4d9c435d39b7d92fad21e1e16de1096ea95d514b6e9d649c010e4f4003d763cf03ee9144d0ee69b070891a4636";
        let decrypted = qrc_decrypt(hex).expect("decrypt failed");
        let expected = include_str!("../fixtures/lyrics/baby.qrc");
        // 行级比较：行尾空白不敏感（与 QRC/YRC 解析器宽松容错对齐）
        let norm = |s: &str| s.lines().map(|l| l.trim()).collect::<Vec<_>>().join("\n");
        assert_eq!(norm(&decrypted), norm(expected));
    }
}
