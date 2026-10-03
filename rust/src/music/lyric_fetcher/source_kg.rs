//! 酷狗（kg）歌词抓取：KRC 解密与逐字歌词解析。

use super::*;
use base64::Engine;
use regex::Regex;
use std::sync::OnceLock;

// ==================== Regex caches (module-level, compiled once) ====================
static KG_ID_HEADER_RE: OnceLock<Regex> = OnceLock::new();
static KG_LANGUAGE_RE: OnceLock<Regex> = OnceLock::new();
static KG_LX_TIME_RE: OnceLock<Regex> = OnceLock::new();
static KG_WORD_TAG_RE: OnceLock<Regex> = OnceLock::new();
static KG_WORD_PLAIN_RE: OnceLock<Regex> = OnceLock::new();

// ==================== KRC Decryption (Kugou) ====================

const KG_KRC_KEY: [u8; 16] = [
    0x40, 0x47, 0x61, 0x77, 0x5e, 0x32, 0x74, 0x47, 0x51, 0x36, 0x31, 0x2d, 0xce, 0xd2, 0x6e, 0x69,
];

fn decode_kg_krc(base64_data: &str) -> Result<String, String> {
    let b64 = pad_base64(base64_data);
    let buf = base64::engine::general_purpose::STANDARD
        .decode(&b64)
        .map_err(|e| e.to_string())?;
    if buf.len() <= 4 {
        return Err("KRC data too short".to_string());
    }
    let mut data = buf[4..].to_vec();
    for i in 0..data.len() {
        data[i] ^= KG_KRC_KEY[i % 16];
    }

    let mut errors: Vec<String> = Vec::new();
    for (name, attempt) in [
        ("raw deflate", decompress_deflate_to_bytes(&data)),
        ("zlib", decompress_zlib_to_bytes(&data)),
        ("zlib/skip-header", decompress_zlib_to_bytes_skip_header(&data)),
        ("gzip", decompress_gzip_to_bytes(&data)),
    ] {
        match attempt {
            Ok(bytes) if !bytes.is_empty() => return Ok(bytes_to_lossy_string(bytes)),
            Ok(_) => errors.push(format!("{name}: empty")),
            Err(error) => errors.push(format!("{name}: {error}")),
        }
    }

    Err(format!("KRC 解压失败: {}", errors.join(" | ")))
}

// ==================== KW Lyric Encryption/Decryption (Kuwo) ====================


// ==================== KG (Kugou) Lyric Fetching ====================

fn kg_parse_lyric(str_in: &str) -> LyricResult {
    let str_in = str_in.replace('\r', "");
    let s = if let Some(stripped) =
        str_in.strip_prefix(|c: char| c.is_ascii() && !c.is_alphanumeric())
    {
        // Remove [id:$...] header
        let re = KG_ID_HEADER_RE.get_or_init(|| Regex::new(r"^.*\[id:\$\w+\]\n").unwrap());
        re.replace(stripped, "").to_string()
    } else {
        let re = KG_ID_HEADER_RE.get_or_init(|| Regex::new(r"^.*\[id:\$\w+\]\n").unwrap());
        re.replace(&str_in, "").to_string()
    };

    let mut result = LyricResult::default();

    // Extract translation
    let trans_re = KG_LANGUAGE_RE.get_or_init(|| Regex::new(r"\[language:([\w=\\/+]+)\]").unwrap());
    let mut work_str = s.clone();
    if let Some(caps) = trans_re.captures(&s) {
        let encoded = &caps[1];
        work_str = trans_re.replace(&s, "").to_string();
        if let Ok(decoded) = base64::engine::general_purpose::STANDARD.decode(pad_base64(encoded)) {
            if let Ok(json) = serde_json::from_slice::<serde_json::Value>(&decoded) {
                if let Some(content) = json.get("content").and_then(|v| v.as_array()) {
                    let mut rlyric_lines: Vec<String> = Vec::new();
                    let mut tlyric_lines: Vec<String> = Vec::new();
                    for item in content {
                        match item.get("type").and_then(|v| v.as_i64()) {
                            Some(0) => {
                                if let Some(lc) =
                                    item.get("lyricContent").and_then(|v| v.as_array())
                                {
                                    for line in lc {
                                        if let Some(arr) = line.as_array() {
                                            rlyric_lines.push(
                                                arr.iter()
                                                    .filter_map(|v| v.as_str().map(String::from))
                                                    .collect::<Vec<_>>()
                                                    .join(""),
                                            );
                                        }
                                    }
                                }
                            }
                            Some(1) => {
                                if let Some(lc) =
                                    item.get("lyricContent").and_then(|v| v.as_array())
                                {
                                    for line in lc {
                                        if let Some(arr) = line.as_array() {
                                            tlyric_lines.push(
                                                arr.iter()
                                                    .filter_map(|v| v.as_str().map(String::from))
                                                    .collect::<Vec<_>>()
                                                    .join(""),
                                            );
                                        }
                                    }
                                }
                            }
                            _ => {}
                        }
                    }
                    result.rlyric = decode_html_entities(&rlyric_lines.join("\n"));
                    result.tlyric = decode_html_entities(&tlyric_lines.join("\n"));
                }
            }
        }
    }

    // Parse lxlyric from [time,duration] format
    let time_re = KG_LX_TIME_RE.get_or_init(|| Regex::new(r"\[(\d+),(\d+)\]").unwrap());
    let word_tag_re = KG_WORD_TAG_RE.get_or_init(|| Regex::new(r"<(\d+,\d+),\d+>").unwrap());

    let mut lxlyric = work_str.clone();
    let mut line_idx = 0;
    let mut rlyric_arr: Vec<String> = if result.rlyric.is_empty() {
        Vec::new()
    } else {
        result.rlyric.split('\n').map(String::from).collect()
    };
    let mut tlyric_arr: Vec<String> = if result.tlyric.is_empty() {
        Vec::new()
    } else {
        result.tlyric.split('\n').map(String::from).collect()
    };

    lxlyric = time_re
        .replace_all(&lxlyric, |caps: &regex::Captures| {
            let time: u64 = caps[1].parse().unwrap_or(0);
            let ms = time % 1000;
            let secs = time / 1000;
            let m = (secs / 60).to_string();
            let s = (secs % 60).to_string();
            let time_str = format!("{:0>2}:{:0>2}.{:0>3}", m, s, ms);

            if line_idx < rlyric_arr.len() {
                rlyric_arr[line_idx] = format!("[{}]{}", time_str, rlyric_arr[line_idx]);
            }
            if line_idx < tlyric_arr.len() {
                tlyric_arr[line_idx] = format!("[{}]{}", time_str, tlyric_arr[line_idx]);
            }
            line_idx += 1;
            format!("[{}]", time_str)
        })
        .to_string();

    if !rlyric_arr.is_empty() {
        result.rlyric = decode_html_entities(&rlyric_arr.join("\n"));
    }
    if !tlyric_arr.is_empty() {
        result.tlyric = decode_html_entities(&tlyric_arr.join("\n"));
    }

    // Simplify word tags: <offset,duration,extra> → <offset,duration>
    lxlyric = word_tag_re.replace_all(&lxlyric, "<$1>").to_string();
    lxlyric = decode_html_entities(&lxlyric);

    // Generate plain lyric by removing word tags
    let word_re = KG_WORD_PLAIN_RE.get_or_init(|| Regex::new(r"<\d+,\d+>").unwrap());
    result.lyric = word_re.replace_all(&lxlyric, "").to_string();
    result.lxlyric = lxlyric;

    result
}

fn kg_get_intv(interval: &str) -> u32 {
    if interval.is_empty() {
        return 0;
    }
    let mut intv: u32 = 0;
    let mut unit: u32 = 1;
    for part in interval.split(':').rev() {
        intv += part.parse::<u32>().unwrap_or(0) * unit;
        unit *= 60;
    }
    intv
}

pub(crate) async fn fetch_kg_lyric(song_info: &LyricSongInfo) -> Result<Option<LyricResult>, String> {
    let name = &song_info.name;
    let hash = song_info.hash.as_deref().unwrap_or(&song_info.songmid);
    let time = song_info
        .interval_ms
        .unwrap_or_else(|| kg_get_intv(song_info.interval.as_deref().unwrap_or("")) * 1000);

    let search_url = format!(
        "http://lyrics.kugou.com/search?ver=1&man=yes&client=pc&keyword={}&hash={}&timelength={}&lrctxt=1",
        urlencoding::encode(name),
        hash,
        time
    );

    let resp = http_fetch_text(
        &search_url,
        "GET",
        &[
            ("KG-RC", "1"),
            ("KG-THash", "expand_search_manager.cpp:852736169:451"),
            ("User-Agent", "KuGou2012-9020-ExpandSearchManager"),
        ],
        None,
    )
    .await?;

    if resp.status != 200 {
        return Ok(None);
    }

    let search_body: serde_json::Value =
        serde_json::from_str(&resp.body).map_err(|e| e.to_string())?;
    let candidates = search_body
        .get("candidates")
        .and_then(|v| v.as_array())
        .ok_or("No candidates")?;
    if candidates.is_empty() {
        return Ok(None);
    }

    async fn download_kg_lyric_content(
        id_value: &str,
        accesskey: &str,
        fmt: &str,
    ) -> Result<Option<(String, String)>, String> {
        let download_url = format!(
            "http://lyrics.kugou.com/download?ver=1&client=pc&id={}&accesskey={}&fmt={}&charset=utf8",
            id_value,
            accesskey,
            fmt
        );
        let resp = http_fetch_text(
            &download_url,
            "GET",
            &[
                ("KG-RC", "1"),
                ("KG-THash", "expand_search_manager.cpp:852736169:451"),
                ("User-Agent", "KuGou2012-9020-ExpandSearchManager"),
            ],
            None,
        )
        .await?;

        if resp.status != 200 {
            return Ok(None);
        }

        let download_body: serde_json::Value =
            serde_json::from_str(&resp.body).map_err(|e| e.to_string())?;
        let dl_fmt = download_body
            .get("fmt")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let content = download_body
            .get("content")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();

        if content.trim().is_empty() {
            return Ok(None);
        }
        Ok(Some((dl_fmt, content)))
    }

    fn parse_kg_lrc_content(content: &str) -> Result<LyricResult, String> {
        let b64 = pad_base64(content);
        let decoded = base64::engine::general_purpose::STANDARD
            .decode(&b64)
            .map_err(|e| e.to_string())?;
        let lyric = String::from_utf8_lossy(&decoded).into_owned();
        Ok(LyricResult {
            lyric: decode_html_entities(&lyric),
            ..Default::default()
        })
    }

    let mut last_error: Option<String> = None;
    for info in candidates {
        let krctype = info.get("krctype").and_then(|v| v.as_i64()).unwrap_or(0);
        let contenttype = info
            .get("contenttype")
            .and_then(|v| v.as_i64())
            .unwrap_or(0);
        let fmt = if krctype == 1 && contenttype != 1 {
            "krc"
        } else {
            "lrc"
        };

        let id_value = info
            .get("id")
            .and_then(|v| {
                if let Some(s) = v.as_str() {
                    Some(s.to_string())
                } else {
                    v.as_i64().map(|n| n.to_string())
                }
            })
            .unwrap_or_default();
        let accesskey = info.get("accesskey").and_then(|v| v.as_str()).unwrap_or("");
        if id_value.is_empty() || accesskey.is_empty() {
            continue;
        }

        let downloaded = match download_kg_lyric_content(&id_value, accesskey, fmt).await {
            Ok(value) => value,
            Err(error) => {
                last_error = Some(error);
                continue;
            }
        };
        let Some((dl_fmt, content)) = downloaded else {
            continue;
        };

        if dl_fmt == "krc" {
            match decode_kg_krc(&content) {
                Ok(decoded) => return Ok(Some(kg_parse_lyric(&decoded))),
                Err(error) => {
                    last_error = Some(error);
                    if let Some((fallback_fmt, fallback_content)) =
                        download_kg_lyric_content(&id_value, accesskey, "lrc").await?
                    {
                        if fallback_fmt == "lrc" {
                            match parse_kg_lrc_content(&fallback_content) {
                                Ok(result) => return Ok(Some(result)),
                                Err(error) => {
                                    last_error = Some(error);
                                }
                            }
                        }
                    }
                }
            }
        } else if dl_fmt == "lrc" {
            match parse_kg_lrc_content(&content) {
                Ok(result) => return Ok(Some(result)),
                Err(error) => {
                    last_error = Some(error);
                }
            }
        }
    }

    if let Some(_error) = last_error {}
    Ok(None)
}
