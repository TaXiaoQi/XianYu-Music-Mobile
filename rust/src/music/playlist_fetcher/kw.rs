// 歌单导入酷我平台实现：自前端 playlistImportKw.ts 移植（内置主链路）。
// 对齐 getListDetailKw / parseKwSong（playlistImportKw.ts）与
// getKwListId / kwRegex1/2（playlistImportBase.ts）；
// buildKwSheetIndex / buildKwArtistIndex / fetchKwTrackMetaByIds 属 TrackMeta 链路，不移植。

use std::sync::OnceLock;

use regex::Regex;
use serde_json::Value;

use super::common::{
    decode_name, format_play_time, http_fetch_json, PlaylistImportResult, PlaylistInfo,
    PlaylistSong,
};

// ==================== ID 提取（对齐 playlistImportBase.ts getKwListId） ====================

/// kwRegex1：/playlist、/playlists、/playlist_detail、/playlists_detail + 数字
fn kw_regex1() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"/playlists?(?:_detail)?/(\d+)").unwrap())
}

/// kwRegex2：playlistId=数字
fn kw_regex2() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"playlistId=(\d+)").unwrap())
}

/// 对齐 TS getKwListId：链接形态（含 ?&:/）走正则提取，digest- 前缀按 __ 分段取第 2 段，其余原样返回
fn get_kw_list_id(raw_id: &str) -> Option<String> {
    if raw_id.contains(['?', '&', ':', '/']) {
        if let Some(caps) = kw_regex1().captures(raw_id) {
            return Some(caps[1].to_string());
        }
        if let Some(caps) = kw_regex2().captures(raw_id) {
            return Some(caps[1].to_string());
        }
        return None;
    }
    if raw_id.starts_with("digest-") {
        let parts: Vec<&str> = raw_id.split("__").collect();
        if parts.len() >= 2 {
            return Some(parts[1].to_string());
        }
    }
    Some(raw_id.to_string())
}

// ==================== 主流程（对齐 playlistImportKw.ts getListDetailKw） ====================

pub(super) async fn get_list_detail_kw(raw_id: &str) -> Result<PlaylistImportResult, String> {
    // TS：const id = getKwListId(rawId); if (!id) return 空结果
    let id = match get_kw_list_id(raw_id) {
        Some(id) if !id.is_empty() => id,
        _ => return Ok(PlaylistImportResult::empty("kw")),
    };

    let url = format!(
        "http://nplserver.kuwo.cn/pl.svc?op=getlistinfo&pid={id}&pn=0&rn=1000&encode=utf8&keyset=pl2012&identity=kuwo&pcmp4=1&vipver=MUSIC_9.0.5.0_W1&newver=1"
    );

    let resp = http_fetch_json(
        &url,
        "GET",
        &[("User-Agent", "Dalvik/2.1.0 (Linux; U; Android 9;)")],
        None,
        None,
    )
    .await?;

    let body = &resp.body;
    // TS：typeof body !== 'object' || body === null || body.result !== 'ok' → throw
    if body.get("result").and_then(|v| v.as_str()) != Some("ok") {
        let shown = body
            .get("result")
            .map(json_value_display)
            .unwrap_or_else(|| "unknown".to_string());
        return Err(format!("酷我歌单获取失败: result={}", shown));
    }

    // TS：const musiclist = body.musiclist || []
    let empty_list: Vec<Value> = Vec::new();
    let musiclist = body
        .get("musiclist")
        .and_then(|v| v.as_array())
        .unwrap_or(&empty_list);

    let mut songs: Vec<PlaylistSong> = Vec::new();
    for item in musiclist {
        if let Some(song) = parse_kw_song(item) {
            songs.push(song);
        }
    }

    let info = PlaylistInfo {
        name: decode_name(json_str_or_empty(body, "title")),
        img: json_str_or_empty(body, "pic").to_string(),
        desc: decode_name(json_str_or_empty(body, "info")),
        author: decode_name(json_str_or_empty(body, "uname")),
        play_count: play_count_string(body),
    };

    // TS：total = body.total || songs.length（数字 total，0 时回落歌曲数）
    let total = body
        .get("total")
        .and_then(|v| v.as_i64())
        .filter(|n| *n != 0)
        .unwrap_or(songs.len() as i64);

    Ok(PlaylistImportResult {
        source: "kw".to_string(),
        songs,
        total,
        info,
    })
}

// ==================== 解析工具 ====================

/// TS `body?.result ?? 'unknown'` 的展示化：字符串原样，其余 JSON 序列化
fn json_value_display(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        other => other.to_string(),
    }
}

/// TS `body.xxx || ''` 的字符串字段读取：缺失/非字符串一律按空串
fn json_str_or_empty<'a>(body: &'a Value, key: &str) -> &'a str {
    body.get(key).and_then(|v| v.as_str()).unwrap_or("")
}

/// TS `String(body.playnum || 0)`：非空字符串原样，数字转字符串，其余按 0
fn play_count_string(body: &Value) -> String {
    match body.get("playnum") {
        Some(Value::String(s)) if !s.is_empty() => s.clone(),
        Some(Value::Number(n)) => n.to_string(),
        _ => "0".to_string(),
    }
}

// ==================== 歌曲解析（对齐 playlistImportKw.ts parseKwSong） ====================

fn parse_kw_song(item: &Value) -> Option<PlaylistSong> {
    // TS String(item.id ?? '')：null/undefined → ''
    let id_str = match item.get("id") {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Number(n)) => n.to_string(),
        _ => String::new(),
    };
    if id_str.is_empty() {
        return None;
    }

    let name = decode_name(json_str_or_empty(item, "name"));
    let artist = decode_name(json_str_or_empty(item, "artist"));
    let album = decode_name(json_str_or_empty(item, "album"));
    let duration_sec = parse_duration_seconds(item.get("duration"));

    let raw_data = serde_json::json!({
        "songmid": id_str,
        "name": name,
        "singer": artist,
        "source": "kw",
        "interval": format_play_time(duration_sec as f64),
    });

    Some(PlaylistSong::new(
        &id_str,
        &name,
        &artist,
        &album,
        "",
        duration_sec * 1000,
        "酷我",
        "kw",
        raw_data,
    ))
}

/// TS `parseInt(item.duration || '0', 10) || 0`：字符串/数字均可能出现，取十进制前导整数，失败为 0
fn parse_duration_seconds(value: Option<&Value>) -> i64 {
    let raw = match value {
        Some(Value::String(s)) if !s.is_empty() => s.clone(),
        Some(Value::Number(n)) => n.to_string(),
        _ => "0".to_string(),
    };
    js_parse_int_10(&raw)
}

/// 对齐 JS parseInt(str, 10)：跳过前导空白与正负号后取连续十进制数字，无数字视为 NaN → 0
fn js_parse_int_10(input: &str) -> i64 {
    let bytes = input.trim_start().as_bytes();
    let mut idx = 0usize;
    let mut sign = 1i64;
    if idx < bytes.len() && (bytes[idx] == b'+' || bytes[idx] == b'-') {
        if bytes[idx] == b'-' {
            sign = -1;
        }
        idx += 1;
    }
    let start = idx;
    let mut val: i64 = 0;
    while idx < bytes.len() && bytes[idx].is_ascii_digit() {
        val = val
            .saturating_mul(10)
            .saturating_add((bytes[idx] - b'0') as i64);
        idx += 1;
    }
    if idx == start {
        return 0; // NaN → 0（TS `|| 0`）
    }
    sign * val
}

#[cfg(test)]
mod tests {
    use super::*;

    const FIXTURE: &str = include_str!("../fixtures/playlist/kw.json");

    fn fixture_body() -> Value {
        serde_json::from_str(FIXTURE).expect("fixture 应为合法 JSON")
    }

    #[test]
    fn parse_kw_song_maps_fields() {
        let body = fixture_body();
        let song = parse_kw_song(&body["musiclist"][0]).expect("应解析出歌曲");

        assert_eq!(song.id, "231057911");
        assert_eq!(song.platform_id, "231057911"); // platformId 自动 = id
        assert_eq!(song.title, "测试歌曲一");
        assert_eq!(song.artist, "测试歌手甲");
        assert_eq!(song.album, "测试专辑一");
        assert_eq!(song.cover_url, "");
        assert_eq!(song.platform, "酷我");
        assert_eq!(song.plugin_id, "kw");
        assert_eq!(song.duration, 245_000); // 秒 → 毫秒
    }

    #[test]
    fn parse_kw_song_raw_data_keys_and_values() {
        let body = fixture_body();
        let song = parse_kw_song(&body["musiclist"][1]).expect("应解析出歌曲");
        let raw = song.raw_data.as_object().expect("rawData 应为对象");

        // serde_json Object 为 BTreeMap（键按字母序），按键名存在性断言而非顺序
        assert_eq!(raw.len(), 5);
        for key in ["songmid", "name", "singer", "source", "interval"] {
            assert!(raw.contains_key(key), "rawData 缺少键: {}", key);
        }
        assert_eq!(raw["songmid"], "87654321");
        assert_eq!(raw["name"], "测试歌曲二");
        assert_eq!(raw["singer"], "测试歌手乙");
        assert_eq!(raw["source"], "kw");
        assert_eq!(raw["interval"], "03:03");
    }

    #[test]
    fn parse_kw_song_interval_format_and_duration_ms() {
        let body = fixture_body();
        let first = parse_kw_song(&body["musiclist"][0]).expect("应解析出歌曲");
        assert_eq!(first.duration, 245_000);
        assert_eq!(first.raw_data["interval"], "04:05");

        let second = parse_kw_song(&body["musiclist"][1]).expect("应解析出歌曲");
        assert_eq!(second.duration, 183_000);
        assert_eq!(second.raw_data["interval"], "03:03");
    }

    #[test]
    fn parse_kw_song_rejects_missing_or_empty_id() {
        let empty: Value = serde_json::json!({ "id": "", "name": "x" });
        assert!(parse_kw_song(&empty).is_none());
        let missing: Value = serde_json::json!({ "name": "x" });
        assert!(parse_kw_song(&missing).is_none());
        let null_id: Value = serde_json::json!({ "id": Value::Null });
        assert!(parse_kw_song(&null_id).is_none());
    }

    #[test]
    fn get_kw_list_id_plain_id() {
        assert_eq!(get_kw_list_id("2848439988"), Some("2848439988".to_string()));
    }

    #[test]
    fn get_kw_list_id_from_playlist_id_query_link() {
        assert_eq!(
            get_kw_list_id("https://m.kuwo.cn/newh5app/playlist?playlistId=2848439988"),
            Some("2848439988".to_string())
        );
    }

    #[test]
    fn get_kw_list_id_from_playlist_detail_path_link() {
        assert_eq!(
            get_kw_list_id("https://www.kuwo.cn/playlist_detail/2848439988?abc=1"),
            Some("2848439988".to_string())
        );
    }

    #[test]
    fn get_kw_list_id_digest_prefix() {
        assert_eq!(
            get_kw_list_id("digest-u7lm2cu__2848439988__mp3"),
            Some("2848439988".to_string())
        );
    }

    #[test]
    fn get_kw_list_id_unmatched_link_returns_none() {
        assert_eq!(get_kw_list_id("https://example.com/list/abc"), None);
    }
}