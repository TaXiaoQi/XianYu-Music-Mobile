// url_resolver.rs - LX 音源封面获取与 URL 缓存
//
// 播放直链解析由 Dart 编排层直接驱动插件引擎（对齐桌面端 lxUrlResolver 架构），
// 本模块不再承担 URL 解析（原公共 API 代理已失效，2026-09-04 移除）。
//
// 支持的音源：kw / kg / tx / wy / mg

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

// ==================== URL Cache ====================

/// URL 缓存条目：存储解析后的 URL 和过期时间
struct CacheEntry {
    url: String,
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
            // SSRF 防护：每个跳转目标都需通过公网校验
            .redirect(crate::security::ssrf::ssrf_redirect_policy())
            // DNS pinning：连接复用校验时刻已钉住的公网 IP，杜绝 rebinding TOCTOU
            .dns_resolver(crate::security::ssrf::pinned_dns_resolver())
            .build()
            .expect("failed to build url_resolver reqwest client")
    })
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
    // img1.kwcdn 部分网络不可达/证书异常，统一改写到 img3.kuwo.cn
    // 注意替换整段域名，否则 img1.kwcdn.kuwo.cn 会被替换成 img3.kuwo.kuwo.cn（无效域名）
    let url = url
        .replace("https://img1.kwcdn.kuwo.cn", "https://img3.kuwo.cn")
        .replace("https://img.kuwo.cn", "https://img3.kuwo.cn");
    Some(url)
}

/// 网易云专辑封面缓存 key 前缀（复用 URL_CACHE，与播放 URL 隔离避免碰撞）
const WY_ALBUM_COVER_PREFIX: &str = "wy_album_cover";
/// 网易云专辑接口对并发请求风控严格（code:-462），两次专辑请求至少间隔的时长
const WY_ALBUM_FETCH_INTERVAL: Duration = Duration::from_millis(250);
/// 全局串行锁：并发补封面时逐个请求专辑接口，避免集群突发触发 -462 风控
static WY_ALBUM_FETCH_LOCK: OnceLock<tokio::sync::Mutex<()>> = OnceLock::new();

async fn get_cached_wy_album_cover(album_id: &str) -> Option<String> {
    let key = format!("{}/{}/{}", WY_ALBUM_COVER_PREFIX, "wy", album_id);
    let mut cache = url_cache().write().await;
    let now = Instant::now();
    let entry = cache.get_mut(&key)?;
    if entry.expires_at <= now {
        cache.remove(&key);
        return None;
    }
    entry.last_access = now;
    Some(entry.url.clone())
}

async fn set_cached_wy_album_cover(album_id: &str, cover: String) {
    let key = format!("{}/{}/{}", WY_ALBUM_COVER_PREFIX, "wy", album_id);
    let mut cache = url_cache().write().await;
    let now = Instant::now();
    cache.insert(
        key,
        CacheEntry {
            url: cover,
            expires_at: now + Duration::from_secs(URL_CACHE_TTL_SECS),
            last_access: now,
        },
    );
    evict_url_cache(&mut cache, now);
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
            // 网易云搜索接口已不再返回 album.picUrl（只给超大整数 picId，JSON 解析后丢精度），
            // song/detail 接口现被限流返回 405。专辑接口 /api/album/{id}?ext=true 稳定返回 picUrl，
            // 且搜索结果中的 album.id 是可靠的安全整数，故优先走专辑接口。
            let album_id: String = song_info
                .album_id
                .as_ref()
                .and_then(|v| v.as_str().map(|s| s.to_string()))
                .or_else(|| {
                    song_info
                        .album_id
                        .as_ref()
                        .and_then(|v| v.as_i64().map(|n| n.to_string()))
                })
                .unwrap_or_default();

            let headers: &[(&str, &str)] = &[
                ("Referer", "https://music.163.com"),
                ("Cookie", "MUSIC_A=1"),
            ];

            // 优先专辑接口（稳定）。先查同专辑缓存，避免同一张专辑被重复请求；
            // 缓存未命中时通过全局串行锁逐个请求，并保证两次请求留有间隔，
            // 规避网易云对并发请求的风控（code:-462）。
            if !album_id.is_empty() {
                if let Some(cached) = get_cached_wy_album_cover(&album_id).await {
                    if !cached.is_empty() {
                        return Some(cached);
                    }
                }
                let _guard = WY_ALBUM_FETCH_LOCK
                    .get_or_init(|| tokio::sync::Mutex::new(()))
                    .lock()
                    .await;
                // 拿到锁后再查一次缓存（前一个持锁者可能已填充）
                if let Some(cached) = get_cached_wy_album_cover(&album_id).await {
                    if !cached.is_empty() {
                        return Some(cached);
                    }
                }
                tokio::time::sleep(WY_ALBUM_FETCH_INTERVAL).await;
                let album_url = format!("https://music.163.com/api/album/{}?ext=true", album_id);
                if let Ok((status, body)) = http_get_text(&album_url, headers).await {
                    if status == 200 {
                        if let Ok(body_json) = serde_json::from_str::<serde_json::Value>(&body) {
                            if let Some(pic_url) = body_json
                                .pointer("/album/picUrl")
                                .and_then(|v| v.as_str())
                            {
                                if !pic_url.is_empty() {
                                    set_cached_wy_album_cover(&album_id, pic_url.to_string()).await;
                                    return Some(pic_url.to_string());
                                }
                            }
                        }
                    }
                }
            }

            // 专辑接口失败时回退 song/detail（可能被限流）
            let url = format!(
                "https://music.163.com/api/song/detail/?id={}&ids=%5B{}%5D",
                song_info.songmid, song_info.songmid
            );
            match http_get_text(&url, headers).await {
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

// ==================== FRB 包装层调用的辅助命令 ====================

/// 获取 LX 音源封面 URL（由 api 层包装后暴露给 Dart）
#[allow(dead_code)]
pub async fn get_lx_cover(song_info: LxUrlSongInfo) -> Result<Option<String>, String> {
    Ok(get_lx_cover_url(&song_info).await)
}

/// 清除 URL 缓存（由 api 层包装后暴露给 Dart）
#[allow(dead_code)]
pub async fn clear_lx_url_cache() -> Result<(), String> {
    let mut cache = url_cache().write().await;
    cache.clear();
    Ok(())
}

// ==================== Source Fallback（对齐桌面端换源命令） ====================

/// 换源结果：匹配到的歌曲信息（URL 由 Dart 插件编排层解析）
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
}

/// 平台尝试优先级（kw 优先，与落雪默认顺序一致）
const SOURCE_PRIORITY: &[&str] = &["kw", "tx", "wy", "kg", "mg"];

/// 时长匹配容差（秒）
const DURATION_TOLERANCE_SEC: f64 = 5.0;

/// 归一化歌名：trim + toLowerCase + 移除全部空白/标点
fn normalize_name(name: &str) -> String {
    name.trim()
        .to_lowercase()
        .chars()
        .filter(|c| {
            !c.is_whitespace()
                && !c.is_ascii_punctuation()
                && !matches!(c, '（' | '）' | '【' | '】' | '、' | '，' | '·')
        })
        .collect()
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
///
/// 标题：归一化相等，或双方长度 ≥3 时互相包含（feat./混音版等带后缀场景）；
/// 歌手：有交集（避免同名异唱误命中）；
/// 时长：±5s 辅助校验（未知则跳过）。
fn is_match(
    item: &crate::music::lx_search::LxSearchItem,
    target_name: &str,
    target_artists: &[String],
    target_duration: f64,
) -> bool {
    let item_name = normalize_name(&item.name);
    let title_matched = item_name == target_name
        || (item_name.chars().count() >= 3
            && target_name.chars().count() >= 3
            && (item_name.contains(target_name) || target_name.contains(&item_name)));
    if !title_matched {
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

/// [项4 源回退集中 · 双端通用] 查找替代落雪音源
///
/// 当 lx:// 歌曲在某个音源起播失败时，在其余落雪平台搜索同名同歌手的歌曲。
/// 匹配规则：标题归一化相等/互相包含 + 歌手有交集 + 时长接近（±5s 辅助）。
/// 搜索策略：串行（按平台优先级 kw > tx > wy > kg > mg），每平台取前 10 条
/// 逐一匹配，找到即返回。
///
/// 直链解析不在本函数内完成：URL 由 Dart 插件编排层（plugin_engine.dart）
/// 按其缓存与回退策略解析。
pub async fn find_alternative_lx_source(
    song_name: String,
    song_artist: String,
    song_duration: f64,
    failed_sources: Vec<String>,
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

        let items = match crate::music::lx_search::lx_search(source, &keyword, 10).await {
            Ok(items) => items,
            Err(_) => {
                continue; // 单个平台失败不中断整体流程
            }
        };

        // 在搜索结果中查找首个匹配项
        for item in &items {
            if item.source != source {
                continue;
            }
            if !is_match(item, &target_name, &target_artists, song_duration) {
                continue;
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
            }));
        }
    }

    Ok(None)
}
