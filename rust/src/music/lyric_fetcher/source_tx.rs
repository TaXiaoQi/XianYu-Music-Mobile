//! QQ 音乐（tx）歌词抓取：QRC 解密与逐字歌词解析。

use super::*;
use base64::Engine;
use regex::Regex;
use std::sync::OnceLock;

static TX_LYRIC_CONTENT_OPEN_RE: OnceLock<Regex> = OnceLock::new();
static TX_LYRIC_CONTENT_CLOSE_RE: OnceLock<Regex> = OnceLock::new();
static TX_LINE_TIME_RE: OnceLock<Regex> = OnceLock::new();
static TX_LINE_TIME2_RE: OnceLock<Regex> = OnceLock::new();
static TX_WORD_TIME_GROUP_RE: OnceLock<Regex> = OnceLock::new();
static TX_WORD_TIME_RE: OnceLock<Regex> = OnceLock::new();
static TX_WORD_EXTRACT_RE: OnceLock<Regex> = OnceLock::new();

// ==================== TX (QQ Music) Lyric Fetching ====================

fn tx_remove_tag(s: &str) -> String {
    let re1 = TX_LYRIC_CONTENT_OPEN_RE.get_or_init(|| Regex::new(r#"^[\S\s]*?LyricContent=""#).unwrap());
    let re2 = TX_LYRIC_CONTENT_CLOSE_RE.get_or_init(|| Regex::new(r#""/>[\S\s]*$"#).unwrap());
    re2.replace_all(&re1.replace_all(s, ""), "").to_string()
}

fn tx_parse_lyric(lrc: &str) -> (String, String) {
    let lrc = lrc.trim().replace('\r', "");
    if lrc.is_empty() {
        return (String::new(), String::new());
    }

    let line_time_re = TX_LINE_TIME_RE.get_or_init(|| Regex::new(r"^\[(\d+),\d+]").unwrap());
    let line_time2_re = TX_LINE_TIME2_RE.get_or_init(|| Regex::new(r"^\[([\d:.]+)]").unwrap());
    let word_time_all_re = TX_WORD_TIME_GROUP_RE.get_or_init(|| Regex::new(r"(\(\d+,\d+\))").unwrap());
    let word_time_re = TX_WORD_TIME_RE.get_or_init(|| Regex::new(r"\(\d+,\d+\)").unwrap());
    let word_extract_re = TX_WORD_EXTRACT_RE.get_or_init(|| Regex::new(r"\((\d+),(\d+)\)").unwrap());

    let mut lxlrc_lines: Vec<String> = Vec::new();
    let mut lrc_lines: Vec<String> = Vec::new();

    for raw_line in lrc.split('\n') {
        let line = raw_line.trim();
        if let Some(caps) = line_time_re.captures(line) {
            let start_ms: u64 = caps[1].parse().unwrap_or(0);
            let start_str = ms_format(start_ms);
            if start_str.is_empty() {
                continue;
            }
            let words = line_time_re.replace(line, "");
            lrc_lines.push(format!(
                "{}{}",
                start_str,
                word_time_all_re.replace_all(&words, "")
            ));

            let times: Vec<String> = word_time_all_re
                .captures_iter(&words)
                .filter_map(|c| {
                    let inner = &c[0];
                    if let Some(m) = word_extract_re.captures(inner) {
                        let t1: u64 = m[1].parse().unwrap_or(0);
                        let t2: u64 = m[2].parse().unwrap_or(0);
                        Some(format!(
                            "<{},{}>",
                            std::cmp::max(t1 as i64 - start_ms as i64, 0) as u64,
                            t2
                        ))
                    } else {
                        None
                    }
                })
                .collect();

            if times.is_empty() {
                continue;
            }

            let word_arr: Vec<&str> = word_time_re.split(&words).collect();
            let mut new_words = String::new();
            for (i, time) in times.iter().enumerate() {
                new_words.push_str(time);
                if i < word_arr.len() {
                    new_words.push_str(word_arr[i]);
                }
            }
            lxlrc_lines.push(format!("{}{}", start_str, new_words));
        } else {
            if line.starts_with("[offset") {
                lxlrc_lines.push(line.to_string());
                lrc_lines.push(line.to_string());
            }
            if line_time2_re.is_match(line) {
                lrc_lines.push(line.to_string());
            }
        }
    }

    (lrc_lines.join("\n"), lxlrc_lines.join("\n"))
}

fn tx_parse_rlyric(lrc: &str) -> String {
    let lrc = lrc.trim().replace('\r', "");
    if lrc.is_empty() {
        return String::new();
    }

    let line_time_re = TX_LINE_TIME_RE.get_or_init(|| Regex::new(r"^\[(\d+),\d+]").unwrap());
    let word_time_all_re = TX_WORD_TIME_RE.get_or_init(|| Regex::new(r"\(\d+,\d+\)").unwrap());
    let mut lrc_lines: Vec<String> = Vec::new();

    for raw_line in lrc.split('\n') {
        let line = raw_line.trim();
        if let Some(caps) = line_time_re.captures(line) {
            let start_ms: u64 = caps[1].parse().unwrap_or(0);
            let start_str = ms_format(start_ms);
            if start_str.is_empty() {
                continue;
            }
            let words = line_time_re.replace(line, "");
            lrc_lines.push(format!(
                "{}{}",
                start_str,
                word_time_all_re.replace_all(&words, "")
            ));
        }
    }

    lrc_lines.join("\n")
}

fn tx_get_intv(interval: &str) -> u64 {
    if interval.is_empty() {
        return 0;
    }
    let mut interval = interval.to_string();
    if !interval.contains('.') {
        interval.push_str(".0");
    }
    let arr: Vec<&str> = interval.split(|c| c == ':' || c == '.').collect();
    let mut arr = arr.to_vec();
    while arr.len() < 3 {
        arr.insert(0, "0");
    }
    let m: u64 = arr[0].parse().unwrap_or(0);
    let s: u64 = arr[1].parse().unwrap_or(0);
    let ms: u64 = arr[2].parse().unwrap_or(0);
    m * 3600000 + s * 1000 + ms
}

fn tx_fix_rlrc_time_tag(rlrc: &str, lrc: &str) -> String {
    let line_time2_re = TX_LINE_TIME2_RE.get_or_init(|| Regex::new(r"^\[([\d:.]+)]").unwrap());
    let rlrc_lines: Vec<&str> = rlrc.split('\n').collect();
    let mut lrc_lines: Vec<&str> = lrc.split('\n').collect();
    let mut new_lrc: Vec<String> = Vec::new();

    for line in &rlrc_lines {
        if let Some(caps) = line_time2_re.captures(line) {
            let words = line_time2_re.replace(line, "");
            if words.trim().is_empty() {
                continue;
            }
            let t1 = tx_get_intv(&caps[1]);
            while !lrc_lines.is_empty() {
                let lrc_line = lrc_lines.remove(0);
                if let Some(lrc_caps) = line_time2_re.captures(lrc_line) {
                    let t2 = tx_get_intv(&lrc_caps[1]);
                    if ((t1 as i64) - (t2 as i64)).unsigned_abs() < 100 {
                        new_lrc.push(line.replace(&caps[0], &lrc_caps[0]));
                        break;
                    }
                }
            }
        }
    }
    new_lrc.join("\n")
}

fn tx_fix_tlrc_time_tag(tlrc: &str, lrc: &str) -> String {
    let line_time2_re = TX_LINE_TIME2_RE.get_or_init(|| Regex::new(r"^\[([\d:.]+)]").unwrap());
    let tlrc_lines: Vec<&str> = tlrc.split('\n').collect();
    let mut lrc_lines: Vec<&str> = lrc.split('\n').collect();
    let mut new_lrc: Vec<String> = Vec::new();

    for line in &tlrc_lines {
        if let Some(caps) = line_time2_re.captures(line) {
            let words = line_time2_re.replace(line, "");
            if words.trim().is_empty() {
                continue;
            }
            let mut time = caps[1].to_string();
            if time.contains('.') {
                let parts: Vec<&str> = time.split('.').collect();
                if parts.len() == 2 {
                    let pad = 3usize.saturating_sub(parts[1].len());
                    time = format!("{}.{}{}", parts[0], parts[1], "0".repeat(pad));
                }
            }
            let t1 = tx_get_intv(&time);
            while !lrc_lines.is_empty() {
                let lrc_line = lrc_lines.remove(0);
                if let Some(lrc_caps) = line_time2_re.captures(lrc_line) {
                    let t2 = tx_get_intv(&lrc_caps[1]);
                    if ((t1 as i64) - (t2 as i64)).unsigned_abs() < 100 {
                        new_lrc.push(line.replace(&caps[0], &lrc_caps[0]));
                        break;
                    }
                }
            }
        }
    }
    new_lrc.join("\n")
}

fn tx_parse(lrc: &str, tlrc: &str, rlrc: &str) -> LyricResult {
    let mut info = LyricResult::default();
    if !lrc.is_empty() {
        let cleaned = tx_remove_tag(lrc);
        let (lyric, lxlyric) = tx_parse_lyric(&cleaned);
        info.lyric = lyric;
        info.lxlyric = lxlyric;
    }
    if !rlrc.is_empty() {
        let cleaned = tx_remove_tag(rlrc);
        let parsed = tx_parse_rlyric(&cleaned);
        info.rlyric = tx_fix_rlrc_time_tag(&parsed, &info.lyric);
    }
    if !tlrc.is_empty() {
        info.tlyric = tx_fix_tlrc_time_tag(tlrc, &info.lyric);
    }
    info
}

pub(crate) async fn fetch_tx_lyric(song_info: &LyricSongInfo) -> Result<Option<LyricResult>, String> {
    let song_id_num = song_info
        .song_id
        .as_ref()
        .and_then(|v| v.as_i64().or_else(|| v.as_str().and_then(|s| s.parse::<i64>().ok())))
        .unwrap_or(0);
    let songmid = &song_info.songmid;
    let interval_sec = song_info
        .interval_ms
        .map(|ms| (ms / 1000) as i64)
        .or_else(|| song_info.interval.as_ref().and_then(|s| s.parse::<i64>().ok()))
        .unwrap_or(0);
    let album_mid = song_info.album_mid.clone().unwrap_or_default();

    let mut lxlyric = String::new();
    let mut lyric = String::new();
    let mut tlyric = String::new();
    let mut rlyric = String::new();

    // 主接口：musicu.fcg + GetPlayLyricInfo，qrc=1&crypt=1 请求逐字 QRC（与桌面端对齐）。
    // lyric_download.fcg 会被 QQ 风控包装成 <command-lable-xwl78-qq-music> 且 content 为空，
    // 改用音乐统一接口，逐字数据在 data.lyric 字段（qrc_t 指示逐字）。crypt=1 必须带上，
    // 否则接口不返回带逐字时间戳的 QRC 加密歌词。
    let req_body = serde_json::json!({
        "comm": { "g_tk": 5381, "uin": 0, "format": "json", "ct": 24, "cv": 0, "platform": "yqq.json", "needNewCode": 1 },
        "req_0": {
            "module": "music.musichallSong.PlayLyricInfo",
            "method": "GetPlayLyricInfo",
            "param": {
                "songMID": songmid,
                "songID": song_id_num,
                "albumMID": album_mid,
                "trans": 1,
                "roma": 1,
                "platform": "yqq",
                "qrc": 1,
                "crypt": 1,
                "lrc_t": 0,
                "qrc_t": 0,
                "cv": 2111,
                "ct": 19,
                "interval": interval_sec
            }
        }
    });

    let resp = http_fetch_text(
        "https://u.y.qq.com/cgi-bin/musicu.fcg",
        "POST",
        &[
            ("User-Agent", "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/86.0.4240.198 Safari/537.36"),
            ("Referer", "https://y.qq.com/"),
            ("Origin", "https://y.qq.com"),
            ("Content-Type", "application/json"),
        ],
        Some(&req_body.to_string()),
    )
    .await?;

    if resp.status == 200 {
        if let Ok(body) = serde_json::from_str::<serde_json::Value>(&resp.body) {
            if let Some(data) = body.get("req_0").and_then(|v| v.get("data")) {
                let lyric_field = data
                    .get("lyric")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();
                let trans_field = data
                    .get("trans")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();
                let roma_field = data
                    .get("roma")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();
                if !lyric_field.trim().is_empty() {
                    if let Ok(decrypted) = qrc_decrypt(lyric_field.trim()) {
                        let parsed = tx_parse(&decrypted, "", "");
                        lyric = parsed.lyric;
                        lxlyric = parsed.lxlyric;
                    }
                }
                if !trans_field.trim().is_empty() {
                    if let Ok(decrypted) = qrc_decrypt(trans_field.trim()) {
                        let cleaned = tx_remove_tag(&decrypted);
                        tlyric = tx_fix_tlrc_time_tag(&cleaned, &lyric);
                    }
                }
                if !roma_field.trim().is_empty() {
                    if let Ok(decrypted) = qrc_decrypt(roma_field.trim()) {
                        let cleaned = tx_remove_tag(&decrypted);
                        let pr = tx_parse_rlyric(&cleaned);
                        rlyric = tx_fix_rlrc_time_tag(&pr, &lyric);
                    }
                }
            }
        }
    }

    // Fallback to old API
    if lyric.is_empty() && lxlyric.is_empty() {
        let old_url = format!(
            "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg?songmid={}&g_tk=5381&loginUin=0&hostUin=0&format=json&inCharset=utf8&outCharset=utf-8&platform=yqq",
            songmid
        );
        let old_resp = http_fetch_text(
            &old_url,
            "GET",
            &[
                ("User-Agent", "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/86.0.4240.198 Safari/537.36"),
                ("Referer", "https://y.qq.com/portal/player.html"),
            ],
            None,
        )
        .await?;

        if old_resp.status == 200 {
            if let Ok(body) = serde_json::from_str::<serde_json::Value>(&old_resp.body) {
                if body.get("retcode").and_then(|v| v.as_i64()) == Some(0) {
                    if let Some(lyric_b64) = body.get("lyric").and_then(|v| v.as_str()) {
                        if let Ok(decoded) =
                            base64::engine::general_purpose::STANDARD.decode(pad_base64(lyric_b64))
                        {
                            lyric = String::from_utf8_lossy(&decoded).into_owned();
                        }
                    }
                    if let Some(trans_b64) = body.get("trans").and_then(|v| v.as_str()) {
                        if let Ok(decoded) =
                            base64::engine::general_purpose::STANDARD.decode(pad_base64(trans_b64))
                        {
                            tlyric = String::from_utf8_lossy(&decoded).into_owned();
                        }
                    }
                }
            }
        }

        if lyric.is_empty() && lxlyric.is_empty() {
            // 诊断上抛：两条 QQ 接口都无歌词时，把响应摘要带给 Dart 侧日志，
            // 否则静默 Ok(None) 无法区分风控/参数/解析问题
            let truncate = |s: &str, n: usize| -> String {
                s.chars().take(n).collect::<String>().replace('\n', " ")
            };
            return Err(format!(
                "tx 无歌词 songmid={songmid} songID={song_id_num} main_status={} main_body={} legacy_status={} legacy_body={}",
                resp.status,
                truncate(&resp.body, 200),
                old_resp.status,
                truncate(&old_resp.body, 160),
            ));
        }
    }

    Ok(Some(LyricResult {
        lyric,
        tlyric,
        rlyric,
        lxlyric,
    }))
}
