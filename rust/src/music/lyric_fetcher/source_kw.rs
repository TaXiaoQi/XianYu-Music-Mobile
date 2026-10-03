//! 酷我（kw）歌词抓取：XOR 加密请求与逐字歌词解析。

use super::*;
use base64::Engine;
use regex::Regex;
use std::sync::OnceLock;

static KW_LRC_TIME_RE: OnceLock<Regex> = OnceLock::new();
static KW_TAG_RE: OnceLock<Regex> = OnceLock::new();
static KW_LYRICX_TAG_RE: OnceLock<Regex> = OnceLock::new();
static KW_WORD_TIME_ALL_RE: OnceLock<Regex> = OnceLock::new();
static KW_TIME_CHECK_RE: OnceLock<Regex> = OnceLock::new();

const KW_BUF_KEY: &[u8] = b"yeelion";

fn kw_build_params(id: &str, is_get_lyricx: bool) -> String {
    let mut params = format!(
        "user=12345,web,web,web&requester=localhost&req=1&rid=MUSIC_{}",
        id
    );
    if is_get_lyricx {
        params.push_str("&lrcx=1");
    }
    let mut output = vec![0u8; params.len()];
    let mut i = 0;
    while i < params.len() {
        let mut j = 0;
        while j < KW_BUF_KEY.len() && i < params.len() {
            output[i] = KW_BUF_KEY[j] ^ params.as_bytes()[i];
            i += 1;
            j += 1;
        }
    }
    base64::engine::general_purpose::STANDARD.encode(&output)
}

fn decode_kw_lyric(body_base64: &str) -> Result<String, String> {
    let b64 = pad_base64(body_base64);
    let buf = base64::engine::general_purpose::STANDARD
        .decode(&b64)
        .map_err(|e| e.to_string())?;
    if buf.is_empty() {
        return Ok(String::new());
    }

    // Split header and binary data: find \r\n\r\n or \n\n
    let mut binary_start = None;
    for i in 0..buf.len().saturating_sub(3) {
        if buf[i] == 0x0d && buf[i + 1] == 0x0a && buf[i + 2] == 0x0d && buf[i + 3] == 0x0a {
            binary_start = Some(i + 4);
            break;
        }
    }
    if binary_start.is_none() {
        for i in 0..buf.len().saturating_sub(1) {
            if buf[i] == 0x0a && buf[i + 1] == 0x0a {
                binary_start = Some(i + 2);
                break;
            }
        }
    }
    let start = binary_start.ok_or("No header delimiter found")?;
    if start >= buf.len() {
        return Ok(String::new());
    }
    let binary_data = &buf[start..];

    // zlib decompress
    let lrc_data = decompress_zlib_to_bytes_skip_header(binary_data)?;
    if lrc_data.is_empty() {
        return Ok(String::new());
    }

    // Check if plain LRC (starts with '[')
    if lrc_data[0] == 0x5b {
        return Ok(encoding_rs::GB18030.decode(&lrc_data).0.into_owned());
    }

    // Otherwise it's base64-encoded XOR encrypted data
    let lrc_str = String::from_utf8_lossy(&lrc_data);
    let lrc_trimmed = lrc_str.trim();
    if !is_valid_base64(lrc_trimmed) {
        return Ok(String::new());
    }
    let buf_str = base64::engine::general_purpose::STANDARD
        .decode(lrc_trimmed)
        .map_err(|e| e.to_string())?;
    let mut output = vec![0u8; buf_str.len()];
    let mut i = 0;
    while i < buf_str.len() {
        let mut j = 0;
        while j < KW_BUF_KEY.len() && i < buf_str.len() {
            output[i] = KW_BUF_KEY[j] ^ buf_str[i];
            i += 1;
            j += 1;
        }
    }
    Ok(encoding_rs::GB18030.decode(&output).0.into_owned())
}

// ==================== WY eapi Encryption (NetEase) ====================


// ==================== KW (Kuwo) Lyric Fetching ====================

pub(crate) fn ms_format(time_ms: u64) -> String {
    let ms = time_ms % 1000;
    let total_secs = time_ms / 1000;
    let m = total_secs / 60;
    let s = total_secs % 60;
    format!("[{:0>2}:{:0>2}.{:0>3}]", m, s, ms)
}

fn kw_parse_lrc(lrc: &str) -> Result<LyricResult, String> {
    let time_re = KW_LRC_TIME_RE.get_or_init(|| Regex::new(r"^\[([\d:.]*)]").unwrap());
    let tag_re =
        KW_TAG_RE.get_or_init(|| Regex::new(r"\[(ver|ti|ar|al|offset|by|kuwo):\s*(\S+(?:\s+\S+)*)\s*]").unwrap());
    let lyricx_tag_re = KW_LYRICX_TAG_RE.get_or_init(|| Regex::new(r"^<-?\d+,-?\d+>").unwrap());

    let mut tags: Vec<String> = Vec::new();
    let mut lrc_arr: Vec<(String, String)> = Vec::new(); // (time, text)

    for line in lrc.split(|c| c == '\r' || c == '\n') {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        if let Some(caps) = time_re.captures(line) {
            let time = caps[1].to_string();
            let text = time_re.replace(line, "").trim().to_string();
            let mut fixed_time = time.clone();
            // Pad to 3 decimal digits
            if fixed_time.matches('.').count() == 1 {
                let parts: Vec<&str> = fixed_time.split('.').collect();
                if parts.len() == 2 && parts[1].len() == 2 {
                    fixed_time = format!("{}.{}0", parts[0], parts[1]);
                }
            }
            lrc_arr.push((fixed_time, text));
        } else if tag_re.is_match(line) {
            tags.push(line.to_string());
        }
    }

    // Sort and split into lrc and lrcT
    let mut lrc_set = std::collections::HashSet::new();
    let mut lrc: Vec<(String, String)> = Vec::new();
    let mut lrc_t: Vec<(String, String)> = Vec::new();
    let mut is_lyricx = false;

    for item in &lrc_arr {
        if lrc_set.contains(&item.0) {
            if lrc.len() < 2 {
                continue;
            }
            let t_item = lrc.pop().ok_or("lrc pop failed".to_string())?;
            let t_time = if lrc.is_empty() {
                t_item.0.clone()
            } else {
                lrc[lrc.len() - 1].0.clone()
            };
            lrc_t.push((t_time, t_item.1));
            lrc.push(item.clone());
        } else {
            lrc.push(item.clone());
            lrc_set.insert(item.0.clone());
        }
        if !is_lyricx && lyricx_tag_re.is_match(&item.1) {
            is_lyricx = true;
        }
    }

    if !is_lyricx && lrc_t.len() as f64 > lrc.len() as f64 * 0.3 && lrc.len() > lrc_t.len() + 6 {
        return Err("failed".to_string());
    }

    let transform = |tags: &[String], lrclist: &[(String, String)]| -> String {
        let mut result = tags.join("\n");
        result.push('\n');
        if lrclist.is_empty() {
            result.push_str("暂无歌词");
        } else {
            for l in lrclist {
                result.push_str(&format!("[{}]{}\n", l.0, l.1));
            }
        }
        result
    };

    let lyric = decode_html_entities(&transform(&tags, &lrc));
    let tlyric = if !lrc_t.is_empty() {
        decode_html_entities(&transform(&tags, &lrc_t))
    } else {
        String::new()
    };

    Ok(LyricResult {
        lyric,
        tlyric,
        rlyric: String::new(),
        lxlyric: String::new(),
    })
}

pub(crate) async fn fetch_kw_lyric(song_info: &LyricSongInfo) -> Result<Option<LyricResult>, String> {
    let url = format!(
        "http://newlyric.kuwo.cn/newlyric.lrc?{}",
        kw_build_params(&song_info.songmid, true)
    );

    let resp = http_fetch_binary(
        &url,
        "GET",
        &[
            ("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"),
            ("Referer", "http://www.kuwo.cn/"),
            ("Accept", "*/*"),
        ],
        None,
    )
    .await?;

    if resp.status != 200 {
        return Ok(None);
    }

    let body_b64 = base64::engine::general_purpose::STANDARD.encode(&resp.body_bytes);
    let decoded = decode_kw_lyric(&body_b64)?;

    let mut lrc_info = match kw_parse_lrc(&decoded) {
        Ok(info) => info,
        Err(_) => return Ok(None),
    };

    let word_time_re = KW_WORD_TIME_ALL_RE.get_or_init(|| Regex::new(r"<(-?\d+),(-?\d+)(?:,-?\d+)?>").unwrap());
    if !lrc_info.tlyric.is_empty() {
        lrc_info.tlyric = word_time_re.replace_all(&lrc_info.tlyric, "").to_string();
    }

    // 与酷狗(kg)处理方式一致：后端直接输出原始歌词（含 [kuwo:] 标签和 <a,b> 加密标签），
    // 前端 convertLxLyricToEnhancedLrc 检测到 [kuwo:] 标签后会对全文统一使用酷我公式解析。
    // 不再在 Rust 侧用 kw_parse_lxlyric 转换，避免转换 bug 导致逐字行丢失。
    if word_time_re.is_match(&lrc_info.lyric) {
        lrc_info.lxlyric = lrc_info.lyric.clone();
    }

    lrc_info.lyric = word_time_re.replace_all(&lrc_info.lyric, "").to_string();

    // Validate lyric has time tags
    let time_check = KW_TIME_CHECK_RE.get_or_init(|| Regex::new(r"\[\d{1,2}:.*\d{1,4}]").unwrap());
    if !time_check.is_match(&lrc_info.lyric) {
        return Ok(None);
    }

    Ok(Some(lrc_info))
}
