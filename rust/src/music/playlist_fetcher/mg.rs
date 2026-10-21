// 歌单导入咪咕平台实现：对齐咪咕 mf 插件 getMusicSheetInfo 的歌单接口
// （app.c.nf.migu.cn MIGUM2.0 queryMusicListSongs.do，30 条/页翻页取全）。
// 条目解析对齐插件 formatMusicSheetItem：artists 拼接、albumImgs 封面、
// pickDurationSeconds 时长（"mm:ss" 字符串 / 秒 / 旧字段毫秒）；
// rawData 保留插件原条目（copyrightId/songId/newRateFormats/lrcUrl），
// 供 mf 播放链路 requestMusicUrl('mg', musicItem) 直接消费。

use std::sync::OnceLock;

use regex::Regex;
use serde_json::Value;

use super::common::{
    decode_name, http_fetch_json, PlaylistImportResult, PlaylistInfo, PlaylistSong,
};

const SHEET_PAGE_SIZE: i64 = 30;
const SHEET_MAX_PAGES: i64 = 100;

// ==================== ID 提取（对齐插件 importMusicSheet 的正则序） ====================

/// music.migu.cn/v3/{my|music}/playlist/数字
fn mg_regex_site() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"https?://music\.migu\.cn/v3/(?:my|music)/playlist/(\d+)").unwrap()
    })
}

/// h5.nf.migu.cn 分享链接 query 参数 id=数字
fn mg_regex_share() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"https?://h5\.nf\.migu\.cn/app/v4/p/share/playlist/index\.html\?.*id=(\d+)")
            .unwrap()
    })
}

/// 纯数字串
fn mg_regex_digits() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"^\s*(\d+)\s*$").unwrap())
}

fn get_mg_list_id(raw_id: &str) -> Option<String> {
    if let Some(caps) = mg_regex_site().captures(raw_id) {
        return Some(caps[1].to_string());
    }
    if let Some(caps) = mg_regex_share().captures(raw_id) {
        return Some(caps[1].to_string());
    }
    if let Some(caps) = mg_regex_digits().captures(raw_id) {
        return Some(caps[1].to_string());
    }
    None
}

// ==================== 主流程 ====================

pub(super) async fn get_list_detail_mg(raw_id: &str) -> Result<PlaylistImportResult, String> {
    let id = match get_mg_list_id(raw_id) {
        Some(id) if !id.is_empty() => id,
        _ => return Ok(PlaylistImportResult::empty("mg")),
    };

    // 歌单名等元信息该接口不返回（插件同样只用列表），info 留空
    let info = PlaylistInfo::default();
    let mut songs: Vec<PlaylistSong> = Vec::new();

    for page in 1..=SHEET_MAX_PAGES {
        let url = format!(
            "https://app.c.nf.migu.cn/MIGUM2.0/v1.0/user/queryMusicListSongs.do?musicListId={id}&pageNo={page}&pageSize={SHEET_PAGE_SIZE}"
        );
        let resp = http_fetch_json(
            &url,
            "GET",
            &[
                (
                    "User-Agent",
                    "Mozilla/5.0 (iPhone; CPU iPhone OS 13_2_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/13.0.3 Mobile/15E148 Safari/604.1",
                ),
                ("Referer", "https://m.music.migu.cn/"),
            ],
            None,
            None,
        )
        .await?;

        let body = &resp.body;
        if body.get("code").and_then(|v| v.as_str()) != Some("000000") {
            let code = body
                .get("code")
                .map(|v| match v {
                    Value::String(s) => s.clone(),
                    other => other.to_string(),
                })
                .unwrap_or_else(|| "unknown".to_string());
            if page == 1 {
                return Err(format!("咪咕歌单获取失败: code={code}"));
            }
            // 首页成功后的异常页按结尾处理，保留已取曲目
            break;
        }

        let empty_list: Vec<Value> = Vec::new();
        let list = body
            .get("list")
            .and_then(|v| v.as_array())
            .unwrap_or(&empty_list);
        if list.is_empty() {
            break;
        }

        for item in list {
            if let Some(song) = parse_mg_song(item) {
                songs.push(song);
            }
        }

        // 不足一页 → 已到结尾
        if (list.len() as i64) < SHEET_PAGE_SIZE {
            break;
        }
    }

    let total = songs.len() as i64;
    Ok(PlaylistImportResult {
        source: "mg".to_string(),
        songs,
        total,
        info,
    })
}

// ==================== 条目解析（对齐插件 formatMusicSheetItem） ====================

fn parse_mg_song(item: &Value) -> Option<PlaylistSong> {
    // id：songId || id（数字/字符串均可）
    let id_str = first_non_empty_str(item, &["songId", "id"])?;
    // 标题：songName || name
    let title_raw = first_non_empty_str(item, &["songName", "name"]).unwrap_or_default();
    let name = decode_name(&title_raw);

    // 歌手：artists[].name 拼接 → singer → singerName（数组或字符串）
    let artist = match item.get("artists") {
        Some(Value::Array(arr)) => {
            let names: Vec<String> = arr
                .iter()
                .filter_map(|a| {
                    a.get("name")
                        .or_else(|| a.get("artistName"))
                        .and_then(|v| v.as_str())
                        .filter(|s| !s.is_empty())
                        .map(|s| s.to_string())
                })
                .collect();
            if names.is_empty() {
                fallback_artist(item)
            } else {
                names.join(", ")
            }
        }
        _ => fallback_artist(item),
    };
    let artist = decode_name(&artist);

    // 专辑：album || albumName
    let album_raw = first_non_empty_str(item, &["album", "albumName"]).unwrap_or_default();
    let album = decode_name(&album_raw);

    let duration_sec = pick_duration_seconds(item);
    let cover_url = pick_cover_url(item);

    // rawData 保留插件原条目 + source 标记：播放链路 requestMusicUrl('mg', musicItem)
    // 依赖 copyrightId/songId，歌词链路依赖 lrcUrl，音质展示依赖 newRateFormats
    let mut raw_data = item.clone();
    if let Some(obj) = raw_data.as_object_mut() {
        obj.insert("source".to_string(), Value::String("mg".to_string()));
    }

    Some(PlaylistSong::new(
        &id_str,
        &name,
        &artist,
        &album,
        &cover_url,
        duration_sec * 1000,
        "咪咕",
        "mg",
        raw_data,
    ))
}

fn fallback_artist(item: &Value) -> String {
    if let Some(s) = item.get("singer").and_then(|v| v.as_str()) {
        if !s.is_empty() {
            return s.to_string();
        }
    }
    match item.get("singerName") {
        Some(Value::Array(arr)) => arr
            .iter()
            .filter_map(|v| v.as_str())
            .filter(|s| !s.is_empty())
            .collect::<Vec<_>>()
            .join(", "),
        Some(Value::String(s)) if !s.is_empty() => s.clone(),
        _ => String::new(),
    }
}

/// 顺序取首个非空字符串字段（数字按原样转字符串）
fn first_non_empty_str<'a>(item: &'a Value, keys: &[&str]) -> Option<String> {
    for key in keys {
        match item.get(*key) {
            Some(Value::String(s)) if !s.is_empty() => return Some(s.clone()),
            Some(Value::Number(n)) => return Some(n.to_string()),
            _ => {}
        }
    }
    None
}

/// 对齐插件 formatImgUrl：http(s) 原样、// 补 http:、裸路径补咪咕图床域名
fn pick_cover_url(item: &Value) -> String {
    let raw = item
        .get("albumImgs")
        .and_then(|v| v.as_array())
        .and_then(|arr| arr.first())
        .and_then(|img| img.get("img"))
        .and_then(|v| v.as_str())
        .map(|s| s.to_string())
        .or_else(|| {
            first_non_empty_str(item, &["albumPic", "img3", "img2", "img1"])
        })
        .unwrap_or_default();
    if raw.is_empty() {
        return String::new();
    }
    if raw.starts_with("http:") || raw.starts_with("https:") {
        return raw;
    }
    if let Some(rest) = raw.strip_prefix("//") {
        return format!("http://{rest}");
    }
    format!("http://d.musicapp.migu.cn{raw}")
}

/// 对齐插件 pickDurationSeconds：候选字段顺序取第一个有效秒数
fn pick_duration_seconds(item: &Value) -> i64 {
    const CANDIDATES: &[&str] = &[
        "duration",
        "length",
        "songTime",
        "playTime",
        "timeLength",
        "songLength",
        "lengthOfTrack",
    ];
    for key in CANDIDATES {
        if let Some(seconds) = normalize_duration_seconds(item.get(*key)) {
            return seconds;
        }
    }
    0
}

/// 对齐插件 normalizeDurationSeconds：
/// "mm:ss"/"hh:mm:ss" 字符串逐段累加；数字 ≥1000 按毫秒折算，否则按秒；无效为 None
fn normalize_duration_seconds(value: Option<&Value>) -> Option<i64> {
    match value? {
        Value::Null => None,
        Value::String(s) if s.is_empty() => None,
        Value::String(s) if s.contains(':') => {
            let mut total: i64 = 0;
            for part in s.split(':') {
                let n = js_parse_int_10(part)?;
                total = total.checked_mul(60)?.checked_add(n)?;
            }
            (total > 0).then_some(total)
        }
        Value::String(s) => {
            let n = js_parse_int_10(s)?;
            normalize_numeric_seconds(n)
        }
        Value::Number(n) => {
            let f = n.as_f64()?;
            if !f.is_finite() || f <= 0.0 {
                return None;
            }
            let secs = if f >= 1000.0 { (f / 1000.0).floor() } else { f.floor() };
            (secs > 0.0).then_some(secs as i64)
        }
        _ => None,
    }
}

fn normalize_numeric_seconds(n: i64) -> Option<i64> {
    if n <= 0 {
        return None;
    }
    let secs = if n >= 1000 { n / 1000 } else { n };
    (secs > 0).then_some(secs)
}

/// 对齐 JS parseInt(part, 10)：前导空白/正负号 + 连续十进制数字，无数字为 None
fn js_parse_int_10(input: &str) -> Option<i64> {
    let bytes = input.trim_start().as_bytes();
    let mut idx = 0usize;
    let mut sign: i64 = 1;
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
        return None;
    }
    Some(sign * val)
}

#[cfg(test)]
mod tests {
    use super::*;

    const FIXTURE: &str = include_str!("../fixtures/playlist/mg.json");

    fn fixture_body() -> Value {
        serde_json::from_str(FIXTURE).expect("fixture 应为合法 JSON")
    }

    #[test]
    fn parse_mg_song_maps_fields() {
        let body = fixture_body();
        let song = parse_mg_song(&body["list"][0]).expect("应解析出歌曲");

        assert_eq!(song.id, "6005987HG0001");
        assert_eq!(song.platform_id, "6005987HG0001");
        assert_eq!(song.title, "测试歌曲一");
        assert_eq!(song.artist, "测试歌手甲, 测试歌手乙");
        assert_eq!(song.album, "测试专辑一");
        assert_eq!(song.cover_url, "http://d.musicapp.migu.cn/p/album001.jpg");
        assert_eq!(song.duration, 245_000); // 245 秒 → 毫秒
        assert_eq!(song.platform, "咪咕");
        assert_eq!(song.plugin_id, "mg");
        // rawData 保留原条目并打 source 标记（播放链路依赖 copyrightId）
        assert_eq!(song.raw_data["copyrightId"], "6005987HG0001");
        assert_eq!(song.raw_data["source"], "mg");
        assert_eq!(song.raw_data["newRateFormats"][0]["formatType"], "PQ");
    }

    #[test]
    fn parse_mg_song_duration_variants() {
        let body = fixture_body();
        // 第二条：length 为 "04:05" 字符串
        let second = parse_mg_song(&body["list"][1]).expect("应解析出歌曲");
        assert_eq!(second.duration, 245_000);
        assert_eq!(second.raw_data["songId"], serde_json::json!(8887776));
        // 第三条：duration 为毫秒数字（旧字段）
        let third = parse_mg_song(&body["list"][2]).expect("应解析出歌曲");
        assert_eq!(third.duration, 183_000);
        // 第四条：songTime 缺失、cover 走 // 相对协议
        let fourth = parse_mg_song(&body["list"][3]).expect("应解析出歌曲");
        assert_eq!(fourth.duration, 0);
        assert_eq!(fourth.cover_url, "http://d.musicapp.migu.cn/p/cover004.jpg");
        assert_eq!(fourth.artist, "测试歌手丙");
    }

    #[test]
    fn parse_mg_song_rejects_missing_id() {
        let empty: Value = serde_json::json!({ "songName": "x" });
        assert!(parse_mg_song(&empty).is_none());
    }

    #[test]
    fn get_mg_list_id_plain_and_links() {
        assert_eq!(get_mg_list_id("179872678"), Some("179872678".to_string()));
        assert_eq!(
            get_mg_list_id("https://music.migu.cn/v3/music/playlist/179872678"),
            Some("179872678".to_string())
        );
        assert_eq!(
            get_mg_list_id("https://music.migu.cn/v3/my/playlist/179872678"),
            Some("179872678".to_string())
        );
        assert_eq!(
            get_mg_list_id(
                "https://h5.nf.migu.cn/app/v4/p/share/playlist/index.html?id=179872678&channel=xxx"
            ),
            Some("179872678".to_string())
        );
        assert_eq!(get_mg_list_id("https://example.com/abc"), None);
    }

    #[test]
    fn normalize_duration_seconds_variants() {
        assert_eq!(
            normalize_duration_seconds(Some(&Value::String("03:02".into()))),
            Some(182)
        );
        assert_eq!(
            normalize_duration_seconds(Some(&Value::String("00:03:02".into()))),
            Some(182)
        );
        assert_eq!(
            normalize_duration_seconds(Some(&serde_json::json!(183000))),
            Some(183)
        );
        assert_eq!(normalize_duration_seconds(Some(&serde_json::json!(183))), Some(183));
        assert_eq!(normalize_duration_seconds(Some(&serde_json::json!(0))), None);
        assert_eq!(
            normalize_duration_seconds(Some(&Value::String("abc".into()))),
            None
        );
        assert_eq!(normalize_duration_seconds(None), None);
    }
}
