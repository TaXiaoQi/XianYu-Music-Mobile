// url_resolver.rs - LX 音源 URL 解析与封面获取
//
// 将前端 lxMusicSdk.ts 中的 lxGetMusicUrl / lxGetPic 迁移到 Rust。
// 通过公共 API 代理服务解析音频链接，与 lx-music-desktop 的 api-test.js 一致。
//
// 支持的音源：kw / kg / tx / wy / mg
// 主 API: https://lxmusicapi.onrender.com
// 备用 API: http://ts.tempmusics.tk

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};
use tokio::sync::RwLock;

// ==================== Types ====================

#[derive(Deserialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct LxUrlSongInfo {
    pub songmid: String,
    pub source: String,
    pub hash: Option<String>,
    pub name: Option<String>,
    // 保留字段：仅随源插件 payload 解析，暂未消费
    #[allow(dead_code)]
    pub singer: Option<String>,
    #[allow(dead_code)]
    pub album_name: Option<String>,
    pub album_id: Option<serde_json::Value>,
    pub album_mid: Option<String>,
    pub copyright_id: Option<String>,
    #[allow(dead_code)]
    pub str_media_mid: Option<String>,
    #[allow(dead_code)]
    pub song_id: Option<serde_json::Value>,
    /// 音质 → { size, hash } 映射（KG 使用 hash 而非 songmid 解析 URL）
    #[serde(rename = "_types", default)]
    pub types: Option<HashMap<String, LxTypeEntry>>,
}

#[derive(Deserialize, Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct LxTypeEntry {
    pub size: Option<String>,
    pub hash: Option<String>,
}

#[derive(Serialize, Clone, Debug)]
pub struct ResolvedUrl {
    pub url: String,
    pub quality: String,
}

// ==================== URL Cache ====================

/// URL 缓存条目：存储解析后的 URL 和过期时间
struct CacheEntry {
    url: String,
    quality: String,
    expires_at: Instant,
    last_access: Instant,
}

/// 全局 URL 缓存，TTL 10 分钟
static URL_CACHE: OnceLock<Arc<RwLock<HashMap<String, CacheEntry>>>> = OnceLock::new();

fn url_cache() -> &'static Arc<RwLock<HashMap<String, CacheEntry>>> {
    URL_CACHE.get_or_init(|| Arc::new(RwLock::new(HashMap::new())))
}

const URL_CACHE_TTL_SECS: u64 = 600; // 10 分钟
/// 缓存硬上限：过期清理后仍超容量时，按 LRU（最久未访问）淘汰
const URL_CACHE_MAX_ENTRIES: usize = 500;

fn make_cache_key(source: &str, id: &str, quality: &str) -> String {
    format!("{}/{}/{}", source, id, quality)
}

/// 查询 URL 缓存
///
/// 命中且未过期时返回拷贝并刷新 `last_access`（LRU）；过期则惰性删除该条目，
/// 避免过期项长期占内存。使用写锁以更新访问时间，缓存操作极轻量可接受。
async fn get_cached_url(source: &str, id: &str, quality: &str) -> Option<ResolvedUrl> {
    let key = make_cache_key(source, id, quality);
    let mut cache = url_cache().write().await;
    let now = Instant::now();
    let entry = cache.get_mut(&key)?;
    if entry.expires_at <= now {
        cache.remove(&key);
        return None;
    }
    entry.last_access = now;
    Some(ResolvedUrl {
        url: entry.url.clone(),
        quality: entry.quality.clone(),
    })
}

/// 写入 URL 缓存
async fn set_cached_url(source: &str, id: &str, quality: &str, url: String) {
    let mut cache = url_cache().write().await;
    let key = make_cache_key(source, id, quality);
    let now = Instant::now();
    cache.insert(
        key,
        CacheEntry {
            url,
            quality: quality.to_string(),
            expires_at: now + Duration::from_secs(URL_CACHE_TTL_SECS),
            last_access: now,
        },
    );

    // 先清过期项；若仍超容量，按 last_access 最早淘汰（LRU）
    evict_url_cache(&mut cache, now);
}

/// 淘汰过期与超容量条目：先 `retain` 未过期项，再按 `last_access` 升序移除最旧条目直至不超上限
fn evict_url_cache(cache: &mut HashMap<String, CacheEntry>, now: Instant) {
    cache.retain(|_, e| e.expires_at > now);
    let excess = cache.len().saturating_sub(URL_CACHE_MAX_ENTRIES);
    if excess == 0 {
        return;
    }
    // 收集并按访问时间排序，淘汰最久未访问的 excess 项
    let mut keys: Vec<(String, Instant)> =
        cache.iter().map(|(k, e)| (k.clone(), e.last_access)).collect();
    keys.sort_unstable_by_key(|(_, t)| *t);
    for (k, _) in keys.into_iter().take(excess) {
        cache.remove(&k);
    }
}

// ==================== HTTP ====================

static HTTP_CLIENT: OnceLock<reqwest::Client> = OnceLock::new();

fn http_client() -> &'static reqwest::Client {
    HTTP_CLIENT.get_or_init(|| {
        reqwest::Client::builder()
            .build()
            .expect("failed to build url_resolver reqwest client")
    })
}

async fn http_get_json(url: &str, headers: &[(&str, &str)]) -> Result<serde_json::Value, String> {
    let client = http_client();

    let mut req = client.get(url).timeout(Duration::from_secs(15));
    for (key, value) in headers {
        req = req.header(*key, *value);
    }

    let resp = req.send().await.map_err(|e| e.to_string())?;
    let status = resp.status().as_u16();
    let body = resp.text().await.map_err(|e| e.to_string())?;

    if status == 429 {
        return Err("请求过于频繁，请稍后再试".to_string());
    }
    if status != 200 {
        return Err(format!("HTTP {} for {}", status, url));
    }

    serde_json::from_str(&body).map_err(|e| format!("Invalid JSON: {}", e))
}

// ==================== URL Resolution ====================

/// 根据音源和歌曲信息解析出实际播放 URL
///
/// 各音源使用不同的标识符（与 lx-music-desktop api-test.js 一致）：
/// - kw/tx/wy: songmid
/// - kg: hash（从 _types[quality].hash 获取）
/// - mg: copyrightId
fn resolve_song_id(song_info: &LxUrlSongInfo, quality: &str) -> Result<String, String> {
    match song_info.source.as_str() {
        "kw" | "tx" | "wy" => Ok(song_info.songmid.clone()),
        "kg" => {
            // KG 优先使用 _types[quality].hash，其次 hash 字段，最后 songmid
            if let Some(types) = &song_info.types {
                if let Some(entry) = types.get(quality) {
                    if let Some(hash) = &entry.hash {
                        return Ok(hash.clone());
                    }
                }
            }
            Ok(song_info
                .hash
                .clone()
                .unwrap_or_else(|| song_info.songmid.clone()))
        }
        "mg" => Ok(song_info
            .copyright_id
            .clone()
            .unwrap_or_else(|| song_info.songmid.clone())),
        _ => Err(format!("Unsupported source: {}", song_info.source)),
    }
}

/// 通过公共 API 代理解析音频 URL（内部函数，供命令和换源共用）
///
/// 优先查询缓存，缓存未命中时通过公共 API 代理解析。
/// 解析成功后自动写入缓存。
pub async fn resolve_lx_music_url_inner(
    song_info: &LxUrlSongInfo,
    quality: &str,
) -> Option<ResolvedUrl> {
    let source = song_info.source.clone();

    let id = match resolve_song_id(song_info, quality) {
        Ok(id) => id,
        Err(_) => {
            return None;
        }
    };

    // 查询缓存
    if let Some(cached) = get_cached_url(&source, &id, quality).await {
        return Some(cached);
    }

    // 通过 API 解析
    match resolve_url_via_api(&source, &id, quality).await {
        Ok(url) => {
            set_cached_url(&source, &id, quality, url.clone()).await;
            Some(ResolvedUrl {
                url,
                quality: quality.to_string(),
            })
        }
        Err(_) => {
            None
        }
    }
}

/// 通过公共 API 代理解析音频 URL
///
/// 主 API: https://lxmusicapi.onrender.com/url/{source}/{id}/{type}
/// 备用 API: http://ts.tempmusics.tk/url/{source}/{id}/{type}
async fn resolve_url_via_api(source: &str, id: &str, quality: &str) -> Result<String, String> {
    let headers = [("User-Agent", "lx-music request")];

    // 主 API
    let primary_url = format!(
        "https://lxmusicapi.onrender.com/url/{}/{}/{}",
        source, id, quality
    );
    match http_get_json(&primary_url, &headers).await {
        Ok(body) => {
            if let Some(data) = body.get("data").and_then(|d| d.as_str()) {
                if !data.is_empty() {
                    return Ok(data.to_string());
                }
            }
        }
        Err(_) => {}
    }

    // 备用 API
    let fallback_url = format!("http://ts.tempmusics.tk/url/{}/{}/{}", source, id, quality);
    match http_get_json(&fallback_url, &headers).await {
        Ok(body) => {
            if let Some(data) = body.get("data").and_then(|d| d.as_str()) {
                if !data.is_empty() {
                    return Ok(data.to_string());
                }
            }
            let msg = body
                .get("msg")
                .and_then(|m| m.as_str())
                .unwrap_or("未知错误");
            Err(format!("获取播放链接失败: {}", msg))
        }
        Err(e) => Err(format!("获取播放链接失败: {}", e)),
    }
}

// ==================== Cover URL Resolution ====================

/// 通过 HTTP 请求获取文本响应（用于 KW 封面 URL）
async fn http_get_text(url: &str, headers: &[(&str, &str)]) -> Result<(u16, String), String> {
    let client = http_client();

    let mut req = client.get(url).timeout(Duration::from_secs(10));
    for (key, value) in headers {
        req = req.header(*key, *value);
    }

    let resp = req.send().await.map_err(|e| e.to_string())?;
    let status = resp.status().as_u16();
    let body = resp.text().await.map_err(|e| e.to_string())?;
    Ok((status, body))
}

async fn http_post_json(
    url: &str,
    body: &str,
    headers: &[(&str, &str)],
) -> Result<serde_json::Value, String> {
    let client = http_client();

    let mut req = client
        .post(url)
        .timeout(Duration::from_secs(10))
        .body(body.to_string());
    for (key, value) in headers {
        req = req.header(*key, *value);
    }

    let resp = req.send().await.map_err(|e| e.to_string())?;
    let status = resp.status().as_u16();
    let body_text = resp.text().await.map_err(|e| e.to_string())?;

    if status != 200 {
        return Err(format!("HTTP {} for {}", status, url));
    }

    serde_json::from_str(&body_text).map_err(|e| format!("Invalid JSON: {}", e))
}

/// 将 kuwo 封面 URL 归一化为 https + img3.kuwo.cn 域名
fn normalize_kuwo_cover_url(url: &str) -> Option<String> {
    let url = url.trim();
    if url.is_empty() || !url.starts_with("http") {
        return None;
    }
    let url = url.replace("http://", "https://");
    // img1.kwcdn 部分网络不可达，统一改写到 img3.kuwo.cn
    let url = url
        .replace("https://img1.kwcdn", "https://img3.kuwo")
        .replace("https://img.kuwo", "https://img3.kuwo");
    Some(url)
}

/// 获取落雪 LX 音源的封面图片 URL
///
/// - kw: 通过 artistpicserver 获取
/// - kg: 通过 media.store.kugou.com 获取
/// - tx: 直接构造 URL
/// - wy: 通过 music.163.com API 获取
/// - mg: 不支持（返回 None）
pub async fn get_lx_cover_url(song_info: &LxUrlSongInfo) -> Option<String> {
    let source = song_info.source.as_str();

    match source {
        "kw" => {
            let url = format!(
                "http://artistpicserver.kuwo.cn/pic.web?corp=kuwo&type=rid_pic&pictype=500&size=500&rid={}",
                song_info.songmid
            );
            match http_get_text(&url, &[]).await {
                Ok((status, body)) if status == 200 => {
                    let trimmed = body.trim();
                    if trimmed.starts_with("http") {
                        return normalize_kuwo_cover_url(trimmed);
                    }
                }
                _ => {}
            }
            None
        }

        "kg" => {
            let hash = song_info
                .types
                .as_ref()
                .and_then(|t| t.get("128k"))
                .and_then(|e| e.hash.as_deref())
                .or(song_info.hash.as_deref())
                .unwrap_or("");

            let album_id_owned: String = song_info
                .album_id
                .as_ref()
                .and_then(|v| v.as_str().map(|s| s.to_string()))
                .or_else(|| {
                    song_info
                        .album_id
                        .as_ref()
                        .and_then(|v| v.as_i64().map(|n| n.to_string()))
                })
                .unwrap_or_else(|| "0".to_string());
            let album_id = album_id_owned.as_str();

            let body = serde_json::json!({
                "appid": 1001,
                "area_code": "1",
                "behavior": "play",
                "clientver": "9020",
                "need_hash_offset": 1,
                "relate": 1,
                "resource": [{
                    "album_audio_id": 0,
                    "album_id": album_id,
                    "hash": hash,
                    "id": 0,
                    "name": song_info.name.as_deref().unwrap_or(""),
                    "type": "audio"
                }],
                "token": "",
                "userid": 2626431536u32,
                "vip": 1
            });
            let body_str = serde_json::to_string(&body).unwrap_or_default();

            match http_post_json(
                "http://media.store.kugou.com/v1/get_res_privilege",
                &body_str,
                &[
                    ("KG-RC", "1"),
                    ("KG-THash", "expand_search_manager.cpp:852736169:451"),
                    ("User-Agent", "KuGou2012-9020-ExpandSearchManager"),
                    ("Content-Type", "application/json"),
                ],
            )
            .await
            {
                Ok(resp) => {
                    if resp.get("error_code").and_then(|c| c.as_i64()) == Some(0) {
                        if let Some(info) = resp.pointer("/data/0/info") {
                            if let Some(imgsize) = info.get("imgsize").and_then(|v| v.as_array()) {
                                if let (Some(image), Some(first_size)) = (
                                    info.get("image").and_then(|v| v.as_str()),
                                    imgsize.first().and_then(|s| s.as_u64()),
                                ) {
                                    return Some(image.replace("{size}", &first_size.to_string()));
                                }
                            }
                            if let Some(image) = info.get("image").and_then(|v| v.as_str()) {
                                if !image.is_empty() {
                                    return Some(image.to_string());
                                }
                            }
                        }
                    }
                }
                Err(_) => {}
            }
            None
        }

        "tx" => {
            let album_id = song_info
                .album_mid
                .as_deref()
                .or(song_info.album_id.as_ref().and_then(|v| v.as_str()))
                .unwrap_or("");
            if !album_id.is_empty() {
                return Some(format!(
                    "https://y.gtimg.cn/music/photo_new/T002R500x500M000{}.jpg",
                    album_id
                ));
            }
            None
        }

        "wy" => {
            let url = format!(
                "https://music.163.com/api/song/detail/?id={}&ids=%5B{}%5D",
                song_info.songmid, song_info.songmid
            );
            match http_get_text(
                &url,
                &[
                    ("Referer", "https://music.163.com"),
                    ("Cookie", "MUSIC_A=1"),
                ],
            )
            .await
            {
                Ok((status, body)) if status == 200 => {
                    if let Ok(body_json) = serde_json::from_str::<serde_json::Value>(&body) {
                        if let Some(pic_url) = body_json
                            .pointer("/songs/0/album/picUrl")
                            .and_then(|v| v.as_str())
                        {
                            if !pic_url.is_empty() {
                                return Some(pic_url.to_string());
                            }
                        }
                    }
                }
                _ => {}
            }
            None
        }

        _ => None,
    }
}

// ==================== Tauri Commands ====================

/// 解析 LX 音源播放 URL
///
/// 优先查询缓存，缓存未命中时通过公共 API 代理解析。
/// 解析成功后自动写入缓存。
#[allow(dead_code)] // 桌面端 Tauri command，移动端核心以下层函数复用
pub async fn resolve_lx_music_url(
    song_info: LxUrlSongInfo,
    quality: String,
) -> Result<Option<ResolvedUrl>, String> {
    Ok(resolve_lx_music_url_inner(&song_info, &quality).await)
}

/// 获取 LX 音源封面 URL
#[allow(dead_code)] // 桌面端 Tauri command，移动端核心以下层函数复用
pub async fn get_lx_cover(song_info: LxUrlSongInfo) -> Result<Option<String>, String> {
    Ok(get_lx_cover_url(&song_info).await)
}

/// 清除 URL 缓存
#[allow(dead_code)] // 桌面端 Tauri command，移动端核心以下层函数复用
pub async fn clear_lx_url_cache() -> Result<(), String> {
    let mut cache = url_cache().write().await;
    cache.clear();
    Ok(())
}

// ==================== Source Fallback ====================

/// 换源结果：包含匹配到的歌曲信息和已解析的播放 URL
#[derive(Serialize, Clone, Debug)]
pub struct AlternativeSourceResult {
    pub source: String,
    pub songmid: String,
    pub name: String,
    pub singer: String,
    pub album_name: String,
    pub album_id: serde_json::Value,
    pub album_mid: Option<String>,
    pub img: Option<String>,
    pub interval: String,
    pub hash: Option<String>,
    pub copyright_id: Option<String>,
    pub str_media_mid: Option<String>,
    pub song_id: Option<serde_json::Value>,
    pub lx_types: Option<HashMap<String, LxTypeEntry>>,
    /// 已解析的播放 URL（若 qualities 非空则尝试解析）
    pub resolved_url: Option<String>,
    pub resolved_quality: Option<String>,
}

/// 平台尝试优先级（kw 优先，与落雪默认顺序一致）
const SOURCE_PRIORITY: &[&str] = &["kw", "tx", "wy", "kg", "mg"];

/// 时长匹配容差（秒）
const DURATION_TOLERANCE_SEC: f64 = 5.0;

/// 归一化歌名：trim + toLowerCase + 去除首尾标点/空白
fn normalize_name(name: &str) -> String {
    let trimmed = name.trim().to_lowercase();
    // 去除首尾标点和空白（Unicode 标点）
    let chars: Vec<char> = trimmed.chars().collect();
    let mut start = 0;
    let mut end = chars.len();
    while start < end && (chars[start].is_whitespace() || chars[start].is_ascii_punctuation()) {
        start += 1;
    }
    while end > start && (chars[end - 1].is_whitespace() || chars[end - 1].is_ascii_punctuation()) {
        end -= 1;
    }
    chars[start..end].iter().collect()
}

/// 拆分歌手名：支持 、,/& 等分隔符，返回小写数组
fn split_artists(singer: &str) -> Vec<String> {
    singer
        .split(|c| matches!(c, '、' | ',' | '/' | '&'))
        .flat_map(|s| s.split("feat."))
        .map(|s| s.trim().to_lowercase())
        .filter(|s| !s.is_empty())
        .collect()
}

/// 判断两个歌手集合是否有交集
fn artists_intersect(a: &[String], b: &[String]) -> bool {
    if a.is_empty() || b.is_empty() {
        return false;
    }
    let set_b: std::collections::HashSet<&String> = b.iter().collect();
    a.iter().any(|x| set_b.contains(x))
}

/// 将 interval 字符串（"mm:ss" 或纯秒数）解析为秒数
fn parse_interval_to_seconds(interval: &str) -> f64 {
    if interval.is_empty() {
        return 0.0;
    }
    // 尝试纯数字
    if let Ok(secs) = interval.parse::<f64>() {
        return secs;
    }
    // mm:ss 或 hh:mm:ss
    let parts: Vec<f64> = interval
        .split(':')
        .filter_map(|p| p.trim().parse::<f64>().ok())
        .collect();
    if parts.is_empty() {
        return 0.0;
    }
    parts.iter().fold(0.0, |acc, n| acc * 60.0 + n)
}

/// 判断搜索结果是否匹配原歌曲
fn is_match(
    item: &crate::music::lx_search::LxSearchItem,
    target_name: &str,
    target_artists: &[String],
    target_duration: f64,
) -> bool {
    if normalize_name(&item.name) != target_name {
        return false;
    }
    // 原曲歌手已知时要求交集；未知时仅靠歌名+时长
    if !target_artists.is_empty() {
        let item_artists = split_artists(&item.singer);
        if !artists_intersect(target_artists, &item_artists) {
            return false;
        }
    }
    // 时长辅助校验
    if target_duration > 0.0 {
        let item_duration = parse_interval_to_seconds(&item.interval);
        if item_duration > 0.0 && (item_duration - target_duration).abs() > DURATION_TOLERANCE_SEC {
            return false;
        }
    }
    true
}

/// 将 LxSearchItem 转换为 LxUrlSongInfo（用于 URL 解析）
fn search_item_to_url_info(item: &crate::music::lx_search::LxSearchItem) -> LxUrlSongInfo {
    LxUrlSongInfo {
        songmid: item.songmid.clone(),
        source: item.source.clone(),
        hash: item.hash.clone(),
        name: Some(item.name.clone()),
        singer: Some(item.singer.clone()),
        album_name: Some(item.album_name.clone()),
        album_id: Some(item.album_id.clone()),
        album_mid: item.album_mid.clone(),
        copyright_id: item.copyright_id.clone(),
        str_media_mid: item.str_media_mid.clone(),
        song_id: item.song_id.clone(),
        types: item.lx_types.clone(),
    }
}

/// [项4 源回退集中] 查找替代落雪音源
///
/// 当 lx:// 歌曲在某个音源起播失败时，在其余落雪平台搜索同名同歌手的歌曲。
/// 匹配规则：歌名归一化相等 + 歌手有交集 + 时长接近（±5s 辅助）
/// 搜索策略：串行（按平台优先级 kw > tx > wy > kg > mg），找到即返回
///
/// 若 qualities 非空，同时尝试解析播放 URL（带缓存），减少前端 IPC 调用次数。
#[allow(dead_code)] // 桌面端 Tauri command，移动端核心以下层函数复用
pub async fn find_alternative_lx_source(
    song_name: String,
    song_artist: String,
    song_duration: f64,
    failed_sources: Vec<String>,
    qualities: Vec<String>,
) -> Result<Option<AlternativeSourceResult>, String> {
    let target_name = normalize_name(&song_name);
    if target_name.is_empty() {
        return Ok(None);
    }

    // 构造搜索关键词
    let primary_artist = extract_primary_artist(&song_artist);
    let keyword = if primary_artist.is_empty() {
        song_name.clone()
    } else {
        format!("{} {}", song_name, primary_artist)
    };

    let target_artists = split_artists(&song_artist);
    let failed_set: std::collections::HashSet<&str> =
        failed_sources.iter().map(|s| s.as_str()).collect();

    // 按优先级串行搜索剩余平台
    for &source in SOURCE_PRIORITY {
        if failed_set.contains(source) {
            continue;
        }

        let items = match crate::music::lx_search::lx_search(source, &keyword, 1).await {
            Ok(items) => items,
            Err(_) => {
                continue; // 单个平台失败不中断整体流程
            }
        };

        // 在搜索结果中查找匹配项
        for item in &items {
            if item.source != source {
                continue;
            }
            if !is_match(item, &target_name, &target_artists, song_duration) {
                continue;
            }

            // 找到匹配项，尝试解析 URL（若 qualities 非空）
            let mut resolved_url = None;
            let mut resolved_quality = None;

            if !qualities.is_empty() {
                let url_info = search_item_to_url_info(item);
                for quality in &qualities {
                    if let Some(result) = resolve_lx_music_url_inner(&url_info, quality).await {
                        if !result.url.is_empty() {
                            resolved_url = Some(result.url);
                            resolved_quality = Some(result.quality);
                            break;
                        }
                    }
                }
            }

            return Ok(Some(AlternativeSourceResult {
                source: item.source.clone(),
                songmid: item.songmid.clone(),
                name: item.name.clone(),
                singer: item.singer.clone(),
                album_name: item.album_name.clone(),
                album_id: item.album_id.clone(),
                album_mid: item.album_mid.clone(),
                img: item.img.clone(),
                interval: item.interval.clone(),
                hash: item.hash.clone(),
                copyright_id: item.copyright_id.clone(),
                str_media_mid: item.str_media_mid.clone(),
                song_id: item.song_id.clone(),
                lx_types: item.lx_types.clone(),
                resolved_url,
                resolved_quality,
            }));
        }
    }

    Ok(None)
}

/// [项4 音质回退集中] 批量音质解析（带缓存）
///
/// 按传入的音质顺序依次尝试解析播放 URL，返回第一个成功的结果。
/// 前端只需一次 IPC 调用即可完成多音质回退，避免循环调用。
#[allow(dead_code)] // 桌面端 Tauri command，移动端核心以下层函数复用
pub async fn resolve_lx_with_quality_fallback(
    song_info: LxUrlSongInfo,
    qualities: Vec<String>,
) -> Result<Option<ResolvedUrl>, String> {
    for quality in &qualities {
        if let Some(result) = resolve_lx_music_url_inner(&song_info, quality).await {
            if !result.url.is_empty() {
                return Ok(Some(result));
            }
        }
    }
    Ok(None)
}

/// 从歌手字段提取首个有效歌手名
fn extract_primary_artist(artist: &str) -> String {
    if artist.is_empty() || artist == "未知歌手" {
        return String::new();
    }
    // 取第一个歌手
    let first = artist
        .split(|c| matches!(c, '、' | ',' | '/' | '&'))
        .next()
        .unwrap_or("");
    let trimmed = first.trim();
    if trimmed.is_empty() || trimmed == "未知歌手" {
        return String::new();
    }
    trimmed.to_string()
}
