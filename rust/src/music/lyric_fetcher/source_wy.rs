//! 网易云（wy）歌词抓取：eapi 加密与 yrc/krc 逐字歌词解析。

use super::*;
use base64::Engine;
use regex::Regex;
use std::sync::OnceLock;

static WY_YRC_LINE_TIME_RE: OnceLock<Regex> = OnceLock::new();
static WY_YRC_WORD_TAG_RE: OnceLock<Regex> = OnceLock::new();
static WY_YRC_CHECK_RE: OnceLock<Regex> = OnceLock::new();
static WY_FIX_TIME_RE: OnceLock<Regex> = OnceLock::new();
static WY_FIX_ROMA_TIME_RE: OnceLock<Regex> = OnceLock::new();
static WY_FIX_ROMA_TRAIL_RE: OnceLock<Regex> = OnceLock::new();

const WY_EAPI_KEY: &[u8] = b"e82ckenh8dichen8";

fn wy_eapi_encrypt(url: &str, data: &str) -> Result<String, String> {
    use aes::cipher::{generic_array::GenericArray, BlockEncrypt, KeyInit};
    let message = format!("nobody{}use{}md5forencrypt", url, data);
    let digest = md5::compute(message.as_bytes());
    let digest_hex = format!("{:x}", digest);
    let data_str = format!("{}-36cd479b6b5-{}-36cd479b6b5-{}", url, data, digest_hex);

    // AES-ECB encrypt
    let key = GenericArray::from_slice(WY_EAPI_KEY);
    let cipher = aes::Aes128::new(key);

    // PKCS7 pad
    let data_bytes = data_str.as_bytes();
    let pad_len = 16 - (data_bytes.len() % 16);
    let mut padded = data_bytes.to_vec();
    padded.extend(vec![pad_len as u8; pad_len]);

    let mut encrypted = Vec::new();
    for chunk in padded.chunks(16) {
        let mut block = GenericArray::from_slice(chunk).clone();
        cipher.encrypt_block(&mut block);
        encrypted.extend_from_slice(&block);
    }

    let hex_str: String = encrypted.iter().map(|b| format!("{:02X}", b)).collect();
    Ok(hex_str)
}

// ==================== WY (NetEase) Lyric Fetching ====================

fn parse_yrc(yrc_text: &str) -> String {
    let line_time_re = WY_YRC_LINE_TIME_RE.get_or_init(|| Regex::new(r"^\[(\d+),(\d+)]").unwrap());
    let word_tag_re = WY_YRC_WORD_TAG_RE.get_or_init(|| Regex::new(r"\((\d+),(\d+),\d+\)").unwrap());
    let mut result: Vec<String> = Vec::new();

    for raw_line in yrc_text.split('\n') {
        let line = raw_line.trim();
        if line.is_empty() || line.starts_with('{') {
            continue;
        }
        if let Some(caps) = line_time_re.captures(line) {
            let start_ms: u64 = caps[1].parse().unwrap_or(0);
            let content = &line[caps[0].len()..];

            // Find all (wordStart,wordDur,0) tags
            let tags: Vec<(u64, u64, usize, usize)> = word_tag_re
                .captures_iter(content)
                .map(|c| {
                    let s: u64 = c[1].parse().unwrap_or(0);
                    let d: u64 = c[2].parse().unwrap_or(0);
                    let (start, end) = c.get(0).map(|m| (m.start(), m.end())).unwrap_or((0, 0));
                    (s, d, start, end)
                })
                .collect();

            if tags.is_empty() {
                continue;
            }

            let time_str = format!(
                "[{:0>2}:{:0>2}.{:0>3}]",
                start_ms / 60000,
                (start_ms % 60000) / 1000,
                start_ms % 1000
            );
            let mut sb = time_str;

            for (i, (tag_start, tag_dur, _match_start, match_end)) in tags.iter().enumerate() {
                let offset = if (*tag_start as i64) - (start_ms as i64) < 0 {
                    0
                } else {
                    *tag_start - start_ms
                };
                let text_start = *match_end;
                let text_end = if i + 1 < tags.len() {
                    tags[i + 1].2
                } else {
                    content.len()
                };
                let text = &content[text_start..text_end];
                sb.push_str(&format!("<{},{}>{}", offset, tag_dur, text));
            }
            result.push(sb);
        }
    }
    result.join("\n")
}

const WYY_KRC_KEY: [u8; 16] = [
    0x40, 0x47, 0x61, 0x77, 0x5e, 0x66, 0x44, 0x6d, 0x63, 0x71, 0x6f, 0x69, 0x67, 0x41, 0x39, 0x74,
];

fn wyy_decode_krc(encoded: &str) -> Vec<u8> {
    if !is_valid_base64(encoded) {
        return Vec::new();
    }
    let b64 = pad_base64(encoded);
    let data = match base64::engine::general_purpose::STANDARD.decode(&b64) {
        Ok(d) => d,
        Err(_) => return Vec::new(),
    };
    if data.is_empty() {
        return Vec::new();
    }
    let mut result = vec![0u8; data.len()];
    for i in 0..data.len() {
        result[i] = data[i] ^ WYY_KRC_KEY[i % WYY_KRC_KEY.len()];
    }
    result
}

fn read_uint32_le(data: &[u8], pos: usize) -> u32 {
    if pos + 4 > data.len() {
        return 0;
    }
    (data[pos] as u32)
        | ((data[pos + 1] as u32) << 8)
        | ((data[pos + 2] as u32) << 16)
        | ((data[pos + 3] as u32) << 24)
}

struct KrcLine {
    time: u32,
    words: Vec<(u32, u32, String)>, // (start, dur, text)
}

fn wyy_parse_krc(raw: &[u8]) -> Vec<KrcLine> {
    if raw.len() < 4 {
        return Vec::new();
    }
    let header_len = read_uint32_le(raw, 0) as usize;
    if header_len == 0 || header_len >= raw.len() {
        return Vec::new();
    }
    let body = &raw[header_len..];
    if body.len() < 4 {
        return Vec::new();
    }
    let tag_len = read_uint32_le(body, 0) as usize;
    let offset = tag_len + 4;
    if offset >= body.len() {
        return Vec::new();
    }
    let data = &body[offset..];
    let data_len = data.len();
    let mut pos = 0;
    let mut lines: Vec<KrcLine> = Vec::new();

    while pos + 4 <= data_len {
        let line_time = read_uint32_le(data, pos);
        pos += 4;
        if pos + 4 > data_len {
            break;
        }
        let word_count = read_uint32_le(data, pos) as usize;
        pos += 4;

        let mut words: Vec<(u32, u32, String)> = Vec::new();
        let mut prev_end = line_time;

        for _ in 0..word_count {
            if pos + 4 > data_len {
                break;
            }
            let word_dur = read_uint32_le(data, pos);
            pos += 4;
            if pos + 1 > data_len {
                break;
            }
            let str_len = data[pos] as usize;
            pos += 1;
            if pos + str_len > data_len {
                break;
            }
            let text = String::from_utf8_lossy(&data[pos..pos + str_len]).into_owned();
            pos += str_len;

            let start = prev_end;
            let end = start + word_dur;
            words.push((start, end - start, text));
            prev_end = end;
        }
        lines.push(KrcLine {
            time: line_time,
            words,
        });
    }
    lines
}

fn krc_lines_to_lxlyric(lines: &[KrcLine]) -> String {
    let mut result: Vec<String> = Vec::new();
    for line in lines {
        if line.words.is_empty() {
            continue;
        }
        let line_start = line.time;
        let time_str = format!(
            "[{:0>2}:{:0>2}.{:0>3}]",
            line_start / 60000,
            (line_start % 60000) / 1000,
            line_start % 1000
        );
        let mut sb = time_str;
        for (start, dur, text) in &line.words {
            let offset = if (*start as i32) - (line_start as i32) < 0 {
                0
            } else {
                *start - line_start
            };
            sb.push_str(&format!("<{},{}>{}", offset, dur, text));
        }
        result.push(sb);
    }
    result.join("\n")
}

fn try_extract_yrc(body: &serde_json::Value) -> String {
    // 不再强制检查 code==200：eapi 响应可能不包含 code 字段，
    // 只要有 yrc/klyric 字段就尝试提取。

    // Check yrc field
    if let Some(yrc) = body
        .get("yrc")
        .and_then(|v| v.get("lyric"))
        .and_then(|v| v.as_str())
    {
        let result = parse_yrc(yrc);
        if !result.is_empty() {
            return result;
        }
    }

    // Check klyric field for YRC format
    if let Some(klyric) = body.get("klyric") {
        if let Some(lyric) = klyric.get("lyric").and_then(|v| v.as_str()) {
            if lyric.len() > 50 {
                let re = WY_YRC_CHECK_RE.get_or_init(|| Regex::new(r"^\[\d+,\d+]").unwrap());
                if re.is_match(lyric) {
                    let result = parse_yrc(lyric);
                    if !result.is_empty() {
                        return result;
                    }
                }
            }
        }
        if let Some(lyric) = klyric.as_str() {
            if lyric.len() > 50 {
                let re = WY_YRC_CHECK_RE.get_or_init(|| Regex::new(r"^\[\d+,\d+]").unwrap());
                if re.is_match(lyric) {
                    let result = parse_yrc(lyric);
                    if !result.is_empty() {
                        return result;
                    }
                }
            }
        }
    }

    String::new()
}

fn try_extract_krc(body: &serde_json::Value) -> String {
    // 不再强制检查 code==200：同 try_extract_yrc。

    if let Some(klyric) = body.get("klyric") {
        if let Some(lyric) = klyric.as_str() {
            if lyric.len() > 100 && lyric != "null" && is_valid_base64(lyric) {
                let decoded = wyy_decode_krc(lyric);
                if !decoded.is_empty() {
                    let lines = wyy_parse_krc(&decoded);
                    if !lines.is_empty() {
                        return krc_lines_to_lxlyric(&lines);
                    }
                }
            }
        }
        if let Some(lyric) = klyric.get("lyric").and_then(|v| v.as_str()) {
            if lyric.len() > 100 && is_valid_base64(lyric) {
                let decoded = wyy_decode_krc(lyric);
                if !decoded.is_empty() {
                    let lines = wyy_parse_krc(&decoded);
                    if !lines.is_empty() {
                        return krc_lines_to_lxlyric(&lines);
                    }
                }
            }
        }
    }
    String::new()
}

fn wy_fix_time_label(lrc: &str, tlrc: &str, romalrc: &str) -> (String, String, String) {
    if lrc.is_empty() {
        return (lrc.to_string(), tlrc.to_string(), romalrc.to_string());
    }
    let re = WY_FIX_TIME_RE.get_or_init(|| Regex::new(r"\[(\d{2}:\d{2}):(\d{2})]").unwrap());
    let new_lrc = re.replace_all(lrc, "[$1.$2]").to_string();
    let new_tlrc = if !tlrc.is_empty() {
        re.replace_all(tlrc, "[$1.$2]").to_string()
    } else {
        tlrc.to_string()
    };

    if new_lrc != lrc || new_tlrc != tlrc {
        let new_romalrc = if !romalrc.is_empty() {
            let re2 = WY_FIX_ROMA_TIME_RE.get_or_init(|| Regex::new(r"\[(\d{2}:\d{2}):(\d{2,3})]").unwrap());
            let intermediate = re2.replace_all(romalrc, "[$1.$2]").to_string();
            let re3 = WY_FIX_ROMA_TRAIL_RE.get_or_init(|| Regex::new(r"\[(\d{2}:\d{2}\.\d{2})0]").unwrap());
            re3.replace_all(&intermediate, "[$1]").to_string()
        } else {
            romalrc.to_string()
        };
        (new_lrc, new_tlrc, new_romalrc)
    } else {
        (new_lrc, new_tlrc, romalrc.to_string())
    }
}

/// WY eapi POST request helper: encrypts params and sends POST to the given eapi endpoint
async fn wy_eapi_post(
    eapi_path: &str,
    data: serde_json::Value,
    extra_headers: &[(&str, &str)],
) -> Result<Option<serde_json::Value>, String> {
    let data_str = serde_json::to_string(&data).unwrap_or_default();
    let params = wy_eapi_encrypt(eapi_path, &data_str)?;
    let api_url = format!("https://interface3.music.163.com{}", eapi_path);
    let body = format!("params={}", params);

    let mut headers: Vec<(&str, &str)> = vec![
        ("User-Agent", "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/60.0.3112.90 Safari/537.36"),
        ("origin", "https://music.163.com"),
        ("Content-Type", "application/x-www-form-urlencoded"),
    ];
    headers.extend_from_slice(extra_headers);

    let resp = http_fetch_text(&api_url, "POST", &headers, Some(&body)).await?;
    if resp.status != 200 {
        return Ok(None);
    }
    match serde_json::from_str::<serde_json::Value>(&resp.body) {
        Ok(v) => Ok(Some(v)),
        Err(_) => Ok(None),
    }
}

/// Fallback karaoke lyrics extraction: tries two parameter sets to get YRC/KRC
async fn wyy_get_karaoke(song_id: &str) -> String {
    let song_id_value = song_id
        .parse::<i64>()
        .map(serde_json::Value::from)
        .unwrap_or_else(|_| serde_json::Value::from(song_id.to_string()));
    // First try: same params as main request (kv=0, yv=0)
    let data1 = serde_json::json!({
        "id": song_id_value, "cp": false, "tv": 0, "lv": 0, "rv": 0, "kv": 0, "yv": 0, "ytv": 0, "yrv": 0,
    });
    if let Ok(Some(body)) = wy_eapi_post("/api/song/lyric/v1", data1, &[]).await {
        let yrc = try_extract_yrc(&body);
        if !yrc.is_empty() {
            return yrc;
        }
        let krc = try_extract_krc(&body);
        if !krc.is_empty() {
            return krc;
        }
    }

    // Second try: Go code params (kv=1, requests klyric binary KRC)
    let id_num: i64 = song_id.parse().unwrap_or(0);
    let data2 = serde_json::json!({
        "cp": -1, "id": id_num, "kv": 1, "lv": -1, "rv": 0, "tv": -1, "yt": false, "yv": 0,
    });
    // Override User-Agent for this request
    let data_str = serde_json::to_string(&data2).unwrap_or_default();
    let params = match wy_eapi_encrypt("/api/song/lyric/v1", &data_str) {
        Ok(p) => p,
        Err(_) => return String::new(),
    };
    let api_url = "https://interface3.music.163.com/api/song/lyric/v1";
    let body = format!("params={}", params);
    let resp = http_fetch_text(
        &api_url,
        "POST",
        &[
            ("User-Agent", "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Safari/537.36 Chrome/91.0.4472.164 NeteaseMusicDesktop/2.10.2.200154"),
            ("Cookie", "os=pc; appver=8.9.75; osver=; deviceId=pyncm!"),
            ("Content-Type", "application/x-www-form-urlencoded"),
        ],
        Some(&body),
    ).await;

    if let Ok(resp) = resp {
        if resp.status == 200 {
            if let Ok(body) = serde_json::from_str::<serde_json::Value>(&resp.body) {
                let yrc = try_extract_yrc(&body);
                if !yrc.is_empty() {
                    return yrc;
                }
                let krc = try_extract_krc(&body);
                if !krc.is_empty() {
                    return krc;
                }
            }
        }
    }

    String::new()
}

async fn fetch_wy_legacy_lyric(song_id: &str) -> Result<Option<LyricResult>, String> {
    let url = format!(
        "https://music.163.com/api/song/lyric?id={}&lv=-1&kv=-1&tv=-1&rv=-1",
        urlencoding::encode(song_id)
    );
    let resp = http_fetch_text(
        &url,
        "GET",
        &[
            ("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"),
            ("Referer", "https://music.163.com/"),
            ("Cookie", "os=pc; appver=8.9.75; osver=; deviceId=pyncm!"),
        ],
        None,
    )
    .await?;

    if resp.status != 200 {
        return Ok(None);
    }
    let body: serde_json::Value = match serde_json::from_str(&resp.body) {
        Ok(value) => value,
        Err(_) => return Ok(None),
    };

    let final_lxlyric = {
        let yrc = try_extract_yrc(&body);
        if !yrc.is_empty() {
            yrc
        } else {
            try_extract_krc(&body)
        }
    };
    let lrc = body
        .get("lrc")
        .and_then(|v| v.get("lyric"))
        .and_then(|v| v.as_str())
        .unwrap_or("");
    let tlrc = body
        .get("tlyric")
        .and_then(|v| v.get("lyric"))
        .and_then(|v| v.as_str())
        .unwrap_or("");
    let romalrc = body
        .get("romalrc")
        .and_then(|v| v.get("lyric"))
        .and_then(|v| v.as_str())
        .unwrap_or("");
    let (fixed_lrc, fixed_tlrc, fixed_romalrc) = wy_fix_time_label(lrc, tlrc, romalrc);

    if fixed_lrc.is_empty() && final_lxlyric.is_empty() {
        return Ok(None);
    }
    Ok(Some(LyricResult {
        lyric: fixed_lrc,
        tlyric: fixed_tlrc,
        rlyric: fixed_romalrc,
        lxlyric: final_lxlyric,
    }))
}

fn collect_wy_song_ids(song_info: &LyricSongInfo) -> Vec<String> {
    let mut ids: Vec<String> = Vec::new();
    if let Some(value) = &song_info.song_id {
        if let Some(id) = value.as_str() {
            if !id.trim().is_empty() {
                ids.push(id.trim().to_string());
            }
        } else if let Some(id) = value.as_i64() {
            ids.push(id.to_string());
        } else if let Some(id) = value.as_u64() {
            ids.push(id.to_string());
        }
    }
    if !song_info.songmid.trim().is_empty() && !ids.iter().any(|id| id == &song_info.songmid) {
        ids.push(song_info.songmid.clone());
    }
    ids
}

pub(crate) async fn fetch_wy_lyric_by_id(song_id: &str) -> Result<Option<LyricResult>, String> {
    let song_id_value = song_id
        .parse::<i64>()
        .map(serde_json::Value::from)
        .unwrap_or_else(|_| serde_json::Value::from(song_id.to_string()));

    // Use /api/song/lyric/v1 with POST (matching frontend's proven approach)
    // kv=0 + yv=0 lets the API return yrc field for YRC word-by-word lyrics
    let data = serde_json::json!({
        "id": song_id_value, "cp": false, "tv": 0, "lv": 0, "rv": 0, "kv": 0, "yv": 0, "ytv": 0, "yrv": 0,
    });
    let body = match wy_eapi_post("/api/song/lyric/v1", data, &[]).await? {
        Some(b) => b,
        None => return fetch_wy_legacy_lyric(song_id).await,
    };

    // Try YRC first, then KRC
    let lxlyric = try_extract_yrc(&body);
    let krc_lxlyric = if lxlyric.is_empty() {
        try_extract_krc(&body)
    } else {
        String::new()
    };
    let mut final_lxlyric = if !lxlyric.is_empty() {
        lxlyric
    } else {
        krc_lxlyric
    };

    // If no word-by-word lyrics, try fallback karaoke extraction
    if final_lxlyric.is_empty() {
        final_lxlyric = wyy_get_karaoke(song_id).await;
    }

    // Get plain lyrics
    let lrc = body
        .get("lrc")
        .and_then(|v| v.get("lyric"))
        .and_then(|v| v.as_str())
        .unwrap_or("");
    let tlrc = body
        .get("tlyric")
        .and_then(|v| v.get("lyric"))
        .and_then(|v| v.as_str())
        .unwrap_or("");
    let romalrc = body
        .get("romalrc")
        .and_then(|v| v.get("lyric"))
        .and_then(|v| v.as_str())
        .unwrap_or("");

    let (fixed_lrc, fixed_tlrc, fixed_romalrc) = wy_fix_time_label(lrc, tlrc, romalrc);

    if fixed_lrc.is_empty() && final_lxlyric.is_empty() {
        return fetch_wy_legacy_lyric(song_id).await;
    }

    // eapi 返回了普通歌词但没有逐字歌词时，尝试 legacy API 获取 YRC/KRC。
    // 某些歌曲的逐字歌词只在非加密 API 中可用。
    if final_lxlyric.is_empty() && !fixed_lrc.is_empty() {
        if let Ok(Some(legacy)) = fetch_wy_legacy_lyric(song_id).await {
            if !legacy.lxlyric.is_empty() {
                final_lxlyric = legacy.lxlyric;
            }
        }
    }

    Ok(Some(LyricResult {
        lyric: fixed_lrc,
        tlyric: fixed_tlrc,
        rlyric: fixed_romalrc,
        lxlyric: final_lxlyric,
    }))
}

pub(crate) async fn fetch_wy_lyric(song_info: &LyricSongInfo) -> Result<Option<LyricResult>, String> {
    let ids = collect_wy_song_ids(song_info);
    if ids.is_empty() {
        return Ok(None);
    }

    let mut last_error: Option<String> = None;
    for song_id in ids {
        match fetch_wy_lyric_by_id(&song_id).await {
            Ok(Some(result)) => return Ok(Some(result)),
            Ok(None) => {
            }
            Err(error) => {
                last_error = Some(error);
            }
        }
    }

    if let Some(_error) = last_error {}
    Ok(None)
}
