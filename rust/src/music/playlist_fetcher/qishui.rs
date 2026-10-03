// 歌单导入汽水音乐平台实现：自前端 playlistImportQishui.ts 移植（内置主链路）。

use std::collections::HashSet;
use std::sync::OnceLock;

use regex::Regex;
use serde_json::{json, Value};

use super::common::{
    http_fetch_json, percent_encode_component, PlaylistImportResult, PlaylistInfo, PlaylistSong,
};

// ==================== 常量（与移动端 qishui_sheet_import.dart 对齐） ====================

const PC_BASE: &str = "https://api.qishui.com/luna/pc";
const PC_QUERY: &str = "aid=386088&app_name=luna_pc&region=cn&geo_region=cn&os_region=cn&sim_region=&device_id=2081836196178571&cdid=&iid=2081836196182667&version_name=3.8.0&version_code=30080000&channel=official&build_mode=master&network_carrier=&ac=wifi&tz_name=Asia/Shanghai&resolution=&device_platform=windows&device_type=Windows&os_version=Windows%2011%20Pro%20for%20Workstations&fp=2081836196178571";
const PC_HEADERS: &[(&str, &str)] = &[
    ("Accept", "*/*"),
    ("Content-Type", "application/json; charset=utf-8"),
    ("Accept-Encoding", "gzip, deflate"),
    ("User-Agent", "LunaPC/3.8.0(467160162)"),
    ("x-luna-background-type", "foreground"),
    ("x-luna-is-background-req", "0"),
    ("x-luna-is-local-user", "0"),
];
const WEB_SHARE_URL: &str = "https://music.douyin.com/qishui/share/playlist";
const WEB_SHARE_HEADERS: &[(&str, &str)] = &[
    (
        "Accept",
        "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    ),
    (
        "User-Agent",
        "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)",
    ),
];
const DOUYIN_IMAGE_BASE: &str = "https://p3-luna.douyinpic.com/img/";
/// build_image_url_from_cover 的默认尺寸（对齐 TS 默认参数）
const DEFAULT_COVER_SIZE: &str = "960:960";

const QUALITY_TO_BAKA: &[(&str, &str)] = &[
    ("medium", "128k"),
    ("higher", "192k"),
    ("highest", "320k"),
    ("lossless", "flac"),
    ("hi_res", "hires"),
    ("spatial", "atmos"),
];
const FALLBACK_BITRATE: &[(&str, i64)] = &[
    ("medium", 128000),
    ("higher", 192000),
    ("highest", 320000),
    ("lossless", 1411000),
    ("hi_res", 2304000),
    ("spatial", 324000),
];

// 关键词/来源判定（isQishuiKeyword / isQishuiSource）留在 TS，不移植。

// ==================== 正则（统一惰性初始化） ====================

struct Patterns {
    /// 纯数字 ID：^(\d+)$
    plain_id: Regex,
    /// 长数字串：\b\d{10,}\b
    long_id: Regex,
    /// 文本中的 URL：https?://[^\s@]+
    url: Regex,
    /// URL 路径 playlist/<id>
    playlist_path: Regex,
    /// URL 参数 playlist_id
    playlist_id: Regex,
    /// URL 参数 ugc_video_id
    ugc_video_id: Regex,
    /// URL 参数 id
    id_param: Regex,
    /// 落地页正文 playlist/<id>
    body_playlist_path: Regex,
    /// 落地页正文 playlist_id
    body_playlist_id: Regex,
    /// 落地页正文 id
    body_id_param: Regex,
}

fn patterns() -> &'static Patterns {
    static PATTERNS: OnceLock<Patterns> = OnceLock::new();
    PATTERNS.get_or_init(|| Patterns {
        plain_id: Regex::new(r"^(\d+)$").unwrap(),
        long_id: Regex::new(r"\b\d{10,}\b").unwrap(),
        url: Regex::new(r"https?://[^\s@]+").unwrap(),
        playlist_path: Regex::new(r"playlist/([\d]+)").unwrap(),
        playlist_id: Regex::new(r"[?&]playlist_id=([\d]+)").unwrap(),
        ugc_video_id: Regex::new(r"[?&]ugc_video_id=([\d]+)").unwrap(),
        id_param: Regex::new(r"[?&]id=([\d]+)").unwrap(),
        body_playlist_path: Regex::new(r"playlist/(\d+)").unwrap(),
        body_playlist_id: Regex::new(r"[?&]playlist_id=(\d+)").unwrap(),
        body_id_param: Regex::new(r"[?&]id=(\d+)").unwrap(),
    })
}

// ==================== 对齐 JS 语义的取值工具 ====================

/// 对齐 JS `typeof v === 'object' && v !== null`（JS 中数组也算 object）
fn is_object_like(v: &Value) -> bool {
    v.is_object() || v.is_array()
}

/// 对齐 JS `String(v ?? '')`：null/undefined → ''，标量按 JS 规则字符串化
fn js_string(v: Option<&Value>) -> String {
    match v {
        None | Some(Value::Null) => String::new(),
        Some(Value::String(s)) => s.clone(),
        // 容器类型在 JS 中 String() 退化为 "[object Object]"，真实数据不会走到这里
        Some(Value::Array(_) | Value::Object(_)) => "[object Object]".to_string(),
        Some(other) => other.to_string(),
    }
}

/// 对齐 TS firstText：第一个字符串化后非空且不等于 "null" 的值
fn first_text(vals: &[Option<&Value>]) -> String {
    for v in vals {
        let s = js_string(*v);
        if !s.is_empty() && s != "null" {
            return s;
        }
    }
    String::new()
}

/// 对齐 TS firstNotEmpty：第一个非空字符串
fn first_not_empty(candidates: &[String]) -> String {
    candidates
        .iter()
        .find(|s| !s.is_empty())
        .cloned()
        .unwrap_or_default()
}

/// 对齐 TS asInt：有限数字截断为 i64，其余为 None
fn as_int(v: Option<&Value>) -> Option<i64> {
    v.and_then(Value::as_f64)
        .filter(|n| n.is_finite())
        .map(|n| n.trunc() as i64)
}

/// 对齐 TS normalizeDurationSeconds：正整数秒；> 10000 视为毫秒入参除以 1000
fn normalize_duration_seconds(v: Option<&Value>) -> Option<i64> {
    let n = as_int(v)?;
    if n <= 0 {
        return None;
    }
    Some(if n > 10000 { n / 1000 } else { n })
}

/// 对齐 TS asMapList：数组过滤出对象元素（显式排除数组）
fn as_map_list(v: Option<&Value>) -> Vec<Value> {
    match v {
        Some(Value::Array(arr)) => arr.iter().filter(|e| e.is_object()).cloned().collect(),
        _ => Vec::new(),
    }
}

/// 对齐 TS buildImageUrlFromCover：uri+template_prefix 拼静态图 URL，否则取 urls 首个
fn build_image_url_from_cover(url_cover: Option<&Value>, size: &str) -> String {
    let Some(v) = url_cover else {
        return String::new();
    };
    match v {
        Value::Null => String::new(),
        Value::String(s) => s.clone(),
        Value::Object(obj) => {
            let uri = js_string(obj.get("uri"));
            let template_prefix = js_string(obj.get("template_prefix"));
            if !uri.is_empty() && !template_prefix.is_empty() {
                return format!(
                    "{}{}~{}-resize:{}.png",
                    DOUYIN_IMAGE_BASE, uri, template_prefix, size
                );
            }
            if let Some(Value::Array(raw_urls)) = obj.get("urls") {
                let urls: Vec<String> = raw_urls
                    .iter()
                    .map(|e| js_string(Some(e)))
                    .filter(|e| !e.is_empty())
                    .collect();
                if let Some(first) = urls.first() {
                    if uri.is_empty() || first.contains(&uri) {
                        return first.clone();
                    }
                    return format!("{}{}", first, uri);
                }
            }
            String::new()
        }
        _ => String::new(),
    }
}

/// 对齐 TS firstUrlList：cover.urls 数组里第一个非空字符串
fn first_url_list(cover: Option<&Value>) -> String {
    if let Some(Value::Array(urls)) = cover.and_then(|v| v.get("urls")) {
        for u in urls {
            let s = js_string(Some(u));
            if !s.is_empty() {
                return s;
            }
        }
    }
    String::new()
}

// ==================== 歌单详情主入口 ====================

pub(super) async fn get_list_detail_qishui(raw_id: &str) -> Result<PlaylistImportResult, String> {
    let Some(id) = extract_qishui_id(raw_id).await else {
        return Ok(PlaylistImportResult::empty("qishui"));
    };

    let detail = match fetch_playlist_detail(&id).await? {
        Some(detail) => detail,
        None => return Ok(PlaylistImportResult::empty("qishui")),
    };
    if detail.media_resources.is_empty() {
        return Ok(PlaylistImportResult::empty("qishui"));
    }

    let mut songs: Vec<PlaylistSong> = Vec::new();
    for raw in &detail.media_resources {
        if let Some(parsed) = format_track(raw) {
            songs.push(parsed);
        }
    }
    if songs.is_empty() {
        return Ok(PlaylistImportResult::empty("qishui"));
    }

    let sheet = parse_playlist_item(detail.playlist_info.as_ref());
    let info = PlaylistInfo {
        name: sheet.title,
        img: sheet.artwork,
        desc: sheet.description,
        author: sheet.artist,
        play_count: (if sheet.works_num != 0 {
            sheet.works_num
        } else {
            songs.len() as i64
        })
        .to_string(),
    };
    let total = if sheet.works_num > 0 {
        sheet.works_num
    } else {
        songs.len() as i64
    };

    Ok(PlaylistImportResult {
        source: "qishui".to_string(),
        songs,
        total,
        info,
    })
}

// ==================== ID 提取（抄 extractQishuiId） ====================

async fn extract_qishui_id(input: &str) -> Option<String> {
    let trimmed = input.trim();
    if trimmed.is_empty() {
        return None;
    }
    let p = patterns();

    // 纯数字 ID
    if let Some(caps) = p.plain_id.captures(trimmed) {
        return Some(caps[1].to_string());
    }

    if let Some(id) = extract_id_from_url(trimmed) {
        return Some(id);
    }

    // 长数字串兜底
    if let Some(m) = p.long_id.find(trimmed) {
        return Some(m.as_str().to_string());
    }

    // 遍历文本中的所有链接；短链需要请求解析
    for m in p.url.find_iter(trimmed) {
        let url = m.as_str();
        if let Some(id) = extract_id_from_url(url) {
            return Some(id);
        }
        let lower = url.to_lowercase();
        if lower.contains("douyin.com/s/") || lower.contains("qishui.douyin.com") {
            if let Some(id) = resolve_redirect_id(url).await {
                return Some(id);
            }
        }
    }
    None
}

fn extract_id_from_url(url: &str) -> Option<String> {
    let p = patterns();
    if let Some(caps) = p.playlist_path.captures(url) {
        return Some(caps[1].to_string());
    }
    if let Some(caps) = p.playlist_id.captures(url) {
        return Some(caps[1].to_string());
    }
    if let Some(caps) = p.ugc_video_id.captures(url) {
        return Some(caps[1].to_string());
    }
    if let Some(caps) = p.id_param.captures(url) {
        return Some(caps[1].to_string());
    }
    None
}

/// 短链解析：读 location 逐跳跟随；落地页直接正则提取
async fn resolve_redirect_id(url: &str) -> Option<String> {
    let resp = match http_fetch_json(url, "GET", WEB_SHARE_HEADERS, None, None).await {
        Ok(resp) => resp,
        Err(e) => {
            eprintln!("[playlist_fetcher] [qs-import] 短链解析失败: {}", e);
            return None;
        }
    };

    if let Some(location) = resp.header("location") {
        if !location.is_empty() {
            if let Some(id) = extract_id_from_url(location) {
                return Some(id);
            }
            let lower = location.to_lowercase();
            if lower.contains("douyin.com/s/") || lower.contains("qishui.douyin.com") {
                return Box::pin(resolve_redirect_id(location)).await;
            }
        }
    }

    // httpFetch 可能已自动跟随重定向：从落地页内容提取
    let body = resp.text.as_str();
    if !body.is_empty() {
        if let Some(caps) = patterns().body_playlist_path.captures(body) {
            return Some(caps[1].to_string());
        }
        if let Some(caps) = patterns().body_playlist_id.captures(body) {
            return Some(caps[1].to_string());
        }
        if let Some(caps) = patterns().body_id_param.captures(body) {
            return Some(caps[1].to_string());
        }
    }
    None
}

// ==================== 歌单详情（PC API → web 兜底） ====================

struct QishuiPlaylistDetail {
    playlist_info: Option<Value>,
    media_resources: Vec<Value>,
}

async fn fetch_playlist_detail(id: &str) -> Result<Option<QishuiPlaylistDetail>, String> {
    let api_detail = fetch_from_api(id).await?;
    if let Some(api) = &api_detail {
        if !api.media_resources.is_empty() {
            return Ok(api_detail);
        }
    }

    if let Some(web_detail) = fetch_from_web(id).await {
        if !web_detail.media_resources.is_empty() {
            let info_id = web_detail
                .playlist_info
                .as_ref()
                .and_then(|info| info.get("id"))
                .map(|v| js_string(Some(v)))
                .unwrap_or_default();
            if info_id == id {
                return Ok(Some(web_detail));
            }
        }
    }
    Ok(None)
}

async fn fetch_from_api(id: &str) -> Result<Option<QishuiPlaylistDetail>, String> {
    let mut cursor = String::new();
    let mut playlist_info: Option<Value> = None;
    let mut resources: Vec<Value> = Vec::new();
    let mut seen_cursors: HashSet<String> = HashSet::new();
    for page in 0..10000 {
        let url = format!(
            "{}/playlist/detail?{}&playlist_id={}&cursor={}&count=100",
            PC_BASE,
            PC_QUERY,
            id,
            percent_encode_component(&cursor)
        );
        let resp = http_fetch_json(&url, "GET", PC_HEADERS, None, None).await?;
        let data = &resp.body;
        let media_resources = data.get("media_resources");
        if !is_object_like(data) || !media_resources.is_some_and(Value::is_array) {
            if page == 0 {
                return Ok(None);
            }
            return Err("[汽水音乐] 歌单分页数据异常".to_string());
        }
        if playlist_info.is_none() {
            if let Some(playlist) = data.get("playlist").filter(|v| is_object_like(v)) {
                playlist_info = Some(playlist.clone());
            }
        }
        if let Some(items) = media_resources.and_then(Value::as_array) {
            for item in items {
                if is_object_like(item) {
                    resources.push(item.clone());
                }
            }
        }
        // has_more === true | 1 | "1"
        let has_more = match data.get("has_more") {
            Some(v) => {
                v.as_bool() == Some(true) || v.as_i64() == Some(1) || v.as_str() == Some("1")
            }
            None => false,
        };
        if !has_more {
            return Ok(Some(QishuiPlaylistDetail {
                playlist_info,
                media_resources: resources,
            }));
        }
        let next = js_string(data.get("next_cursor"));
        if resources.is_empty() || next.is_empty() || next == cursor || seen_cursors.contains(&next)
        {
            return Err("[汽水音乐] 歌单分页游标未推进".to_string());
        }
        seen_cursors.insert(next.clone());
        cursor = next;
    }
    Ok(None)
}

async fn fetch_from_web(id: &str) -> Option<QishuiPlaylistDetail> {
    let url = format!("{}?playlist_id={}", WEB_SHARE_URL, id);
    let resp = match http_fetch_json(&url, "GET", WEB_SHARE_HEADERS, None, None).await {
        Ok(resp) => resp,
        Err(e) => {
            eprintln!("[playlist_fetcher] [qs-import] web 分享页解析失败: {}", e);
            return None;
        }
    };
    let html = resp.text;
    if html.is_empty() {
        return None;
    }
    let router_data = extract_router_data(&html)?;
    let playlist_page = router_data
        .get("loaderData")
        .and_then(|loader| loader.get("playlist_page"))
        .filter(|v| is_object_like(v))?;
    let playlist_info = playlist_page
        .get("playlistInfo")
        .filter(|v| is_object_like(v))
        .cloned();
    let media_resources = playlist_page
        .get("medias")
        .and_then(Value::as_array)
        .map(|arr| arr.iter().filter(|e| is_object_like(e)).cloned().collect())
        .unwrap_or_default();
    Some(QishuiPlaylistDetail {
        playlist_info,
        media_resources,
    })
}

fn extract_router_data(html: &str) -> Option<Value> {
    const ASSIGNMENT: &str = "_ROUTER_DATA = ";
    let start = html.find(ASSIGNMENT)?;
    let json_start = start + ASSIGNMENT.len();
    let rest = &html[json_start..];
    let end_rel = rest
        .find(";\nfunction runWindowFn")
        .or_else(|| rest.find(";</script>"))?;
    let decoded: Value = serde_json::from_str(&rest[..end_rel]).ok()?;
    if is_object_like(&decoded) {
        Some(decoded)
    } else {
        None
    }
}

// ==================== 条目格式化（抄 parseTrackItem） ====================

fn normalize_track(raw: &Value) -> Value {
    if let Some(entity) = raw.get("entity") {
        if is_object_like(entity) {
            if let Some(tw) = entity.get("track_wrapper") {
                if is_object_like(tw) {
                    if let Some(track) = tw.get("track") {
                        if is_object_like(track) {
                            return track.clone();
                        }
                    }
                }
            }
            if let Some(track) = entity.get("track") {
                if is_object_like(track) {
                    return track.clone();
                }
            }
            if let Some(video) = entity.get("video") {
                if is_object_like(video) {
                    return video.clone();
                }
            }
            if let Some(video) = entity.get("ugc_video") {
                if is_object_like(video) {
                    return video.clone();
                }
            }
        }
    }
    if let Some(track) = raw.get("track") {
        if is_object_like(track) {
            return track.clone();
        }
    }
    raw.clone()
}

fn format_track(raw: &Value) -> Option<PlaylistSong> {
    let track = normalize_track(raw);
    let is_video = is_video_track(raw, &track);
    let album = track.get("album").filter(|v| is_object_like(v));
    let video_id = first_text(&[
        track.get("video_id"),
        track.get("ugc_video_id"),
        track.get("id"),
        track.get("vid"),
    ]);
    let artwork = first_not_empty(&[
        build_image_url_from_cover(album.and_then(|a| a.get("url_cover")), DEFAULT_COVER_SIZE),
        build_image_url_from_cover(track.get("cover_url"), DEFAULT_COVER_SIZE),
        first_url_list(track.get("image_url")),
        first_url_list(track.get("share_cover_url")),
        js_string(track.get("coverURL")),
        js_string(track.get("firstFrameURL")),
    ]);
    let mut artist_entries = as_map_list(track.get("artists"));
    if artist_entries.is_empty() {
        if let Some(author_info) = track.get("author_info").filter(|v| is_object_like(v)) {
            artist_entries.push(author_info.clone());
        }
    }
    let singer_list = build_singer_list(&artist_entries);
    let primary_name = singer_list
        .first()
        .and_then(|primary| primary.get("name"))
        .map(|v| js_string(Some(v)))
        .unwrap_or_default();
    let fee = i64::from(
        track
            .get("label_info")
            .filter(|v| is_object_like(v))
            .and_then(|v| v.get("only_vip_playable"))
            .and_then(Value::as_bool)
            == Some(true),
    );
    let id = js_string(track.get("id"));
    let final_id = if id.is_empty() { video_id.clone() } else { id };
    if final_id.is_empty() {
        return None;
    }
    let title = first_not_empty(&[
        js_string(track.get("name")),
        js_string(track.get("title")),
        js_string(track.get("videoName")),
        js_string(track.get("desc")),
        String::new(),
    ]);
    let artist = first_not_empty(&[
        primary_name,
        js_string(track.get("artistName")),
        js_string(track.get("author")),
        String::new(),
    ]);
    // track.duration ?? track.duration_ms：仅 null/undefined 时回退
    let duration_raw = match track.get("duration") {
        Some(Value::Null) | None => track.get("duration_ms"),
        other => other,
    };
    let duration_sec = normalize_duration_seconds(duration_raw);
    let album_name = album
        .and_then(|a| a.get("name"))
        .map(|v| js_string(Some(v)))
        .unwrap_or_default();
    let album_id = album
        .and_then(|a| a.get("id"))
        .map(|v| js_string(Some(v)))
        .unwrap_or_default();
    let qualities = qualities_from_bit_rates(track.get("bit_rates"));

    let is_video_json = if is_video {
        Value::Bool(true)
    } else {
        Value::Null
    };
    let video_id_json = if is_video {
        Value::String(video_id.clone())
    } else {
        Value::Null
    };
    let vid_json = if is_video {
        Value::String(video_id.clone())
    } else {
        Value::String(first_text(&[track.get("vid"), track.get("video_id")]))
    };

    // 宿主补充键 songmid/name/singer/source：兼容播放链
    let raw_data = json!({
        "id": final_id.clone(),
        "title": title.clone(),
        "artist": artist.clone(),
        "singerList": singer_list,
        "album": album_name.clone(),
        "albumId": album_id,
        "artwork": artwork,
        "duration": duration_sec,
        "qualities": qualities,
        "fee": fee,
        "is_video": is_video_json,
        "videoId": video_id_json,
        "vid": vid_json,
        "songmid": final_id,
        "name": title,
        "singer": artist,
        "source": "qishui",
    });

    Some(PlaylistSong::new(
        &final_id,
        &title,
        &artist,
        &album_name,
        &artwork,
        duration_sec.unwrap_or(0) * 1000,
        "汽水音乐",
        "qishui",
        raw_data,
    ))
}

fn is_video_track(raw: &Value, track: &Value) -> bool {
    if let Some(entity) = raw.get("entity") {
        if is_object_like(entity)
            && (entity.get("video").is_some_and(|v| !v.is_null())
                || entity.get("ugc_video").is_some_and(|v| !v.is_null()))
        {
            return true;
        }
    }
    if raw.get("type").and_then(Value::as_str) == Some("video") {
        return true;
    }
    if raw.get("media_type").and_then(Value::as_str) == Some("video") {
        return true;
    }
    if track.get("video_id").is_some_and(|v| !v.is_null()) {
        return true;
    }
    if track.get("ugc_video_id").is_some_and(|v| !v.is_null()) {
        return true;
    }
    if track.get("type").and_then(Value::as_str) == Some("ugc_video") {
        return true;
    }
    if track.get("video_type").and_then(Value::as_str) == Some("ugc_video") {
        return true;
    }
    if track.get("media_type").and_then(Value::as_str) == Some("ugc_video") {
        return true;
    }
    if track.get("videoName").is_some_and(|v| !v.is_null()) {
        return true;
    }
    false
}

fn build_singer_list(artists: &[Value]) -> Vec<Value> {
    let mut out: Vec<Value> = Vec::new();
    for artist in artists {
        let user_info = match artist.get("user_info") {
            Some(v) if is_object_like(v) => v,
            _ => match artist.get("author_info") {
                Some(v) if is_object_like(v) => v,
                _ => artist,
            },
        };
        let avatar = first_not_empty(&[
            js_string(user_info.get("avatar")),
            build_image_url_from_cover(user_info.get("url_avatar"), "100:100"),
            build_image_url_from_cover(user_info.get("medium_avatar_url"), "100:100"),
            build_image_url_from_cover(user_info.get("thumb_avatar_url"), "100:100"),
            String::new(),
        ]);
        let id = match user_info.get("id") {
            Some(v) if !v.is_null() => js_string(Some(v)),
            _ => match artist.get("id") {
                Some(v) if !v.is_null() => js_string(Some(v)),
                _ => String::new(),
            },
        };
        let name = first_not_empty(&[
            js_string(user_info.get("name")),
            js_string(user_info.get("nickname")),
            js_string(artist.get("name")),
            String::new(),
        ]);
        if !id.is_empty() || !name.is_empty() {
            out.push(json!({ "id": id, "name": name, "avatar": avatar }));
        }
    }
    out
}

fn qualities_from_bit_rates(bit_rates: Option<&Value>) -> Value {
    let mut qualities = serde_json::Map::new();
    let mut spatial_entries: Vec<Value> = Vec::new();
    for item in as_map_list(bit_rates) {
        let qishui_quality = js_string(item.get("quality"));
        let bitrate = match item.get("br") {
            Some(br) if br.is_number() => br.clone(),
            _ => FALLBACK_BITRATE
                .iter()
                .find(|entry| qishui_quality == entry.0)
                .map(|entry| json!(entry.1))
                .unwrap_or(Value::Null),
        };
        if qishui_quality == "spatial" {
            spatial_entries.push(json!({
                "size": item.get("size").cloned().unwrap_or(Value::Null),
                "bitrate": bitrate,
                "qishuiQuality": qishui_quality,
            }));
            continue;
        }
        let quality_key = QUALITY_TO_BAKA
            .iter()
            .find(|entry| qishui_quality == entry.0)
            .map(|entry| entry.1);
        let Some(quality_key) = quality_key else {
            continue;
        };
        // 同键首个保留
        if !qualities.contains_key(quality_key) {
            qualities.insert(
                quality_key.to_string(),
                json!({
                    "size": item.get("size").cloned().unwrap_or(Value::Null),
                    "bitrate": bitrate,
                    "qishuiQuality": qishui_quality,
                }),
            );
        }
    }
    // spatial（全景声）在导入场景取首个条目映射为 atmos
    if !spatial_entries.is_empty() && !qualities.contains_key("atmos") {
        if let Some(first) = spatial_entries.first() {
            qualities.insert("atmos".to_string(), first.clone());
        }
    }
    Value::Object(qualities)
}

// ==================== 歌单信息（抄 parsePlaylistItem） ====================

struct ParsedPlaylistItem {
    title: String,
    artist: String,
    artwork: String,
    description: String,
    works_num: i64,
}

fn parse_playlist_item(raw: Option<&Value>) -> ParsedPlaylistItem {
    let Some(raw) = raw else {
        return ParsedPlaylistItem {
            title: String::new(),
            artist: String::new(),
            artwork: String::new(),
            description: String::new(),
            works_num: 0,
        };
    };
    let owner = raw.get("owner").filter(|v| is_object_like(v));
    let user_brief = raw
        .get("user_artist_info")
        .filter(|v| is_object_like(v))
        .and_then(|info| info.get("user_brief"));
    let works_num = as_int(raw.get("count_tracks"))
        .or_else(|| {
            raw.get("resource_cnt")
                .filter(|v| is_object_like(v))
                .and_then(|cnt| as_int(cnt.get("track_cnt")))
        })
        .unwrap_or(0);
    ParsedPlaylistItem {
        title: first_not_empty(&[
            js_string(raw.get("title")),
            js_string(raw.get("public_title")),
            js_string(raw.get("name")),
            String::new(),
        ]),
        artist: first_not_empty(&[
            js_string(owner.and_then(|o| o.get("nickname"))),
            js_string(user_brief),
            String::new(),
        ]),
        artwork: build_image_url_from_cover(raw.get("url_cover"), DEFAULT_COVER_SIZE),
        description: js_string(raw.get("desc")),
        works_num,
    }
}

// ==================== 单测（仅纯函数，网络相关不测） ====================

#[cfg(test)]
mod tests {
    use super::*;

    const API_FIXTURE: &str = include_str!("../fixtures/playlist/qishui_api.json");
    const WEB_FIXTURE: &str = include_str!("../fixtures/playlist/qishui_web.html");

    #[test]
    fn test_extract_router_data() {
        let data = extract_router_data(WEB_FIXTURE).expect("应能提取 _ROUTER_DATA");
        let page = &data["loaderData"]["playlist_page"];
        assert_eq!(page["playlistInfo"]["title"], "网页歌单");
        assert_eq!(page["playlistInfo"]["id"], "1234567890");
        assert_eq!(page["playlistInfo"]["owner"]["nickname"], "网页作者");
        let medias = page["medias"].as_array().expect("medias 应为数组");
        assert_eq!(medias.len(), 1);
        assert_eq!(medias[0]["id"], 9001);
        assert_eq!(medias[0]["name"], "网页歌曲");
    }

    #[test]
    fn test_extract_router_data_missing_marker() {
        assert!(extract_router_data("<html><body>没有标记</body></html>").is_none());
        assert!(extract_router_data("").is_none());
    }

    #[test]
    fn test_format_track_music() {
        let page: Value = serde_json::from_str(API_FIXTURE).unwrap();
        let song = format_track(&page["media_resources"][0]).expect("音乐条目应可格式化");
        assert_eq!(song.id, "7001");
        assert_eq!(song.title, "晴天");
        assert_eq!(song.artist, "周杰伦");
        assert_eq!(song.album, "叶惠美");
        assert_eq!(song.platform, "汽水音乐");
        assert_eq!(song.platform_id, "7001");
        assert_eq!(song.plugin_id, "qishui");
        // 封面优先取 album.url_cover（uri + template_prefix）
        assert_eq!(
            song.cover_url,
            "https://p3-luna.douyinpic.com/img/album/yeuimei~tpl960-resize:960:960.png"
        );
        // 269000ms → 269s → 回填毫秒 269000
        assert_eq!(song.duration, 269000);

        let rd = &song.raw_data;
        assert_eq!(rd["songmid"], "7001");
        assert_eq!(rd["source"], "qishui");
        assert_eq!(rd["name"], "晴天");
        assert_eq!(rd["singer"], "周杰伦");
        assert_eq!(rd["albumId"], "alb_1");
        assert_eq!(rd["fee"], 0);
        assert_eq!(rd["is_video"], Value::Null);
        assert_eq!(rd["videoId"], Value::Null);
        assert_eq!(rd["vid"], "");
        assert_eq!(rd["duration"], 269);
        assert_eq!(rd["singerList"][0]["id"], "101");
        assert_eq!(rd["singerList"][0]["name"], "周杰伦");
        assert_eq!(rd["singerList"][0]["avatar"], "https://example.com/jay.png");
        // 第二位歌手：nickname 兜底 name，url_avatar 拼 100:100 尺寸
        assert_eq!(rd["singerList"][1]["name"], "合作歌手");
        assert_eq!(
            rd["singerList"][1]["avatar"],
            "https://p3-luna.douyinpic.com/img/feat/ava~tpl100-resize:100:100.png"
        );
        // 音质映射 + 同键首个保留 + 未知音质跳过 + spatial → atmos
        assert_eq!(rd["qualities"]["128k"]["bitrate"], 128000);
        assert_eq!(rd["qualities"]["128k"]["size"], 4300000);
        assert_eq!(rd["qualities"]["320k"]["bitrate"], 320000);
        assert_eq!(rd["qualities"]["atmos"]["bitrate"], 324000);
        assert_eq!(rd["qualities"]["atmos"]["qishuiQuality"], "spatial");
        assert!(rd["qualities"].get("hires").is_none());
    }

    #[test]
    fn test_format_track_video() {
        let page: Value = serde_json::from_str(API_FIXTURE).unwrap();
        let song = format_track(&page["media_resources"][1]).expect("视频条目应可格式化");
        assert_eq!(song.id, "8002");
        assert_eq!(song.title, "某个视频");
        // artists 为空 → 回退 author_info
        assert_eq!(song.artist, "视频作者");
        assert_eq!(song.album, "");
        assert_eq!(song.cover_url, "https://example.com/frame.jpg");
        assert_eq!(song.duration, 45000);

        let rd = &song.raw_data;
        assert_eq!(rd["is_video"], true);
        assert_eq!(rd["videoId"], "v_999");
        assert_eq!(rd["vid"], "v_999");
        assert_eq!(rd["singerList"][0]["id"], "202");
        assert_eq!(rd["singerList"][0]["name"], "视频作者");
    }

    #[test]
    fn test_format_track_empty_id() {
        let raw = json!({ "name": "无 ID 条目" });
        assert!(format_track(&raw).is_none());
    }

    #[test]
    fn test_qualities_from_bit_rates() {
        let bit_rates = json!([
            { "quality": "lossless", "size": 30000000 },
            { "quality": "medium", "br": "128000" },
            { "quality": "spatial", "br": 500000, "size": 1 },
            { "quality": "spatial", "br": 600000, "size": 2 },
            { "quality": "hi_res", "br": 2304000 },
            { "quality": "mystery", "br": 123456 }
        ]);
        let q = qualities_from_bit_rates(Some(&bit_rates));
        // br 非数字 → 回退码率（键为 QUALITY_TO_BAKA 映射名）
        assert_eq!(q["flac"]["bitrate"], 1411000);
        assert_eq!(q["128k"]["bitrate"], 128000);
        assert_eq!(q["hires"]["bitrate"], 2304000);
        // spatial 取首个映射为 atmos
        assert_eq!(q["atmos"]["bitrate"], 500000);
        assert_eq!(q["atmos"]["qishuiQuality"], "spatial");
        // 未映射音质跳过
        assert!(q.get("mystery").is_none());
    }

    #[test]
    fn test_build_image_url_from_cover() {
        // 字符串原样返回
        assert_eq!(
            build_image_url_from_cover(Some(&json!("https://a.com/x.png")), DEFAULT_COVER_SIZE),
            "https://a.com/x.png"
        );
        // null / 缺失 → ""
        assert_eq!(build_image_url_from_cover(Some(&Value::Null), DEFAULT_COVER_SIZE), "");
        assert_eq!(build_image_url_from_cover(None, DEFAULT_COVER_SIZE), "");
        // 非字符串非对象（数字）→ ""
        assert_eq!(build_image_url_from_cover(Some(&json!(123)), DEFAULT_COVER_SIZE), "");
        // uri + template_prefix
        assert_eq!(
            build_image_url_from_cover(
                Some(&json!({ "uri": "abc", "template_prefix": "tpl" })),
                DEFAULT_COVER_SIZE
            ),
            "https://p3-luna.douyinpic.com/img/abc~tpl-resize:960:960.png"
        );
        // 自定义尺寸
        assert_eq!(
            build_image_url_from_cover(
                Some(&json!({ "uri": "abc", "template_prefix": "tpl" })),
                "100:100"
            ),
            "https://p3-luna.douyinpic.com/img/abc~tpl-resize:100:100.png"
        );
        // urls 数组：uri 为空 → 取 urls[0]
        assert_eq!(
            build_image_url_from_cover(
                Some(&json!({ "urls": ["https://u/1", "https://u/2"] })),
                DEFAULT_COVER_SIZE
            ),
            "https://u/1"
        );
        // urls[0] 包含 uri → 取 urls[0]
        assert_eq!(
            build_image_url_from_cover(
                Some(&json!({ "uri": "u/1", "urls": ["https://x/u/1?k=1"] })),
                DEFAULT_COVER_SIZE
            ),
            "https://x/u/1?k=1"
        );
        // urls[0] 不含 uri → 拼接
        assert_eq!(
            build_image_url_from_cover(
                Some(&json!({ "uri": "img/9", "urls": ["https://p/"] })),
                DEFAULT_COVER_SIZE
            ),
            "https://p/img/9"
        );
        // template_prefix 为空 → 走 urls 分支；urls[0] 不含 uri 时追加 uri
        assert_eq!(
            build_image_url_from_cover(
                Some(&json!({ "uri": "z", "template_prefix": "", "urls": ["https://u/3"] })),
                DEFAULT_COVER_SIZE
            ),
            "https://u/3z"
        );
    }

    #[test]
    fn test_parse_playlist_item() {
        let page: Value = serde_json::from_str(API_FIXTURE).unwrap();
        let sheet = parse_playlist_item(page.get("playlist"));
        assert_eq!(sheet.title, "测试歌单");
        assert_eq!(sheet.artist, "作者");
        assert_eq!(
            sheet.artwork,
            "https://p3-luna.douyinpic.com/img/abc~tpl-resize:960:960.png"
        );
        assert_eq!(sheet.works_num, 2);

        // raw 缺失 → 全空
        let empty = parse_playlist_item(None);
        assert_eq!(empty.title, "");
        assert_eq!(empty.artist, "");
        assert_eq!(empty.artwork, "");
        assert_eq!(empty.description, "");
        assert_eq!(empty.works_num, 0);
    }

    #[test]
    fn test_extract_id_from_url() {
        assert_eq!(
            extract_id_from_url("https://qishui.douyin.com/playlist/7345678901234"),
            Some("7345678901234".to_string())
        );
        assert_eq!(
            extract_id_from_url("https://x.com/a?playlist_id=11122233344455"),
            Some("11122233344455".to_string())
        );
        assert_eq!(
            extract_id_from_url("https://x.com/a?ugc_video_id=9998887776665"),
            Some("9998887776665".to_string())
        );
        assert_eq!(
            extract_id_from_url("https://x.com/a?id=42"),
            Some("42".to_string())
        );
        assert_eq!(extract_id_from_url("https://x.com/nothing"), None);
    }

    #[test]
    fn test_normalize_duration_seconds() {
        assert_eq!(normalize_duration_seconds(Some(&json!(1000))), Some(1000));
        assert_eq!(normalize_duration_seconds(Some(&json!(20000))), Some(20));
        assert_eq!(normalize_duration_seconds(Some(&json!(269000))), Some(269));
        assert_eq!(normalize_duration_seconds(Some(&json!(0))), None);
        assert_eq!(normalize_duration_seconds(Some(&json!(-5))), None);
        assert_eq!(normalize_duration_seconds(Some(&Value::Null)), None);
        assert_eq!(normalize_duration_seconds(Some(&json!("300"))), None);
        assert_eq!(normalize_duration_seconds(None), None);
    }
}
