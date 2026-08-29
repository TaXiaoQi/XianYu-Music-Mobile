// lx_catalog.rs - LX 音源目录搜索（歌单）+ 歌单曲目（Rust 实现）
//
// 移植自桌面端 lxMusicSdkCatalog.ts（searchLxPlaylists / normalizeLxPlaylistResults）
// 与 lxMusicSdkTracks.ts（lxGetPlaylistTracks / txSheetTracksWebFallback /
// txSheetSearchDesktopFallback），支持 kw / kg / tx / wy / mg 五个音源。
//
// 歌单搜索返回归一化条目（id/title/cover/artist/计数 + 原始 raw），
// 歌单曲目复用 lx_search.rs 的 LxSearchItem（types 留空，播放时统一由
// url_resolver 按音源解析），与桌面端行为一致。

use crate::music::lx_search::{
    decode_name, format_play_time, format_singer_name, http_get_json, http_post_json,
    kg_filter_data, mg_create_signature, random_5_digits, random_tx_guid, tx_handle_result,
    zzc_sign, LxSearchItem,
};
use serde::Serialize;
use serde_json::Value;
use std::time::{SystemTime, UNIX_EPOCH};

/// 归一化歌单条目（对应桌面 LxPlaylistSearchResult）。
#[derive(Serialize, Clone, Debug)]
pub struct LxPlaylistItem {
    /// `{source}:playlist:{id}` 复合 ID
    pub id: String,
    /// 平台原生歌单 ID（拉取曲目用）
    pub playlist_id: String,
    pub title: String,
    pub cover_url: Option<String>,
    pub artist: String,
    pub track_count: Option<u64>,
    pub play_count: Option<u64>,
    /// 原始 API 响应条目
    pub raw: Value,
}

/// 歌单曲目拉取结果（对应桌面 { list, isEnd }）。
#[derive(Serialize, Clone, Debug)]
pub struct LxPlaylistTracksResult {
    pub list: Vec<LxSearchItem>,
    pub is_end: bool,
}

const PLAYLIST_ID_KEYS: &[&str] = &[
    "id", "ID", "playlistId", "playlistid", "specialid", "dissid", "disstid",
    "songListId", "songlistId", "musicListId", "rid",
];
const PLAYLIST_TITLE_KEYS: &[&str] = &[
    "title", "name", "playlistName", "specialname", "dissname",
    "songListName", "songlistName", "NAME",
];
const PLAYLIST_ARTIST_KEYS: &[&str] = &[
    "artist", "author", "nickname", "uname", "UNAME",
];
const PLAYLIST_COVER_KEYS: &[&str] = &[
    "coverUrl", "coverImgUrl", "img", "imgurl", "pic", "picUrl", "pic_url",
    "PIC", "album_pic_url", "hts_pic",
];
const PLAYLIST_TRACK_COUNT_KEYS: &[&str] = &[
    "trackCount", "trackcount", "songCount", "song_count", "songnum", "SONGNUM",
];
const PLAYLIST_PLAY_COUNT_KEYS: &[&str] = &[
    "playCount", "playcount", "play_count", "playcnt", "listennum", "LISTENNUM",
];

/// 顺序取多个候选键里的首个非 null/非空串值（对齐桌面 firstValue）。
fn first_value<'a>(item: &'a Value, keys: &[&str]) -> Option<&'a Value> {
    for key in keys {
        if let Some(v) = item.get(*key) {
            let empty_str = v.as_str().map(|s| s.is_empty()).unwrap_or(false);
            if !v.is_null() && !empty_str {
                return Some(v);
            }
        }
    }
    None
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// 归一化封面 URL：协议相对补 https、http 升级 https。
fn normalize_cover(v: &Value) -> Option<String> {
    let s = v.as_str()?;
    if s.is_empty() {
        return None;
    }
    let url = if let Some(rest) = s.strip_prefix("//") {
        format!("https://{}", rest)
    } else {
        s.replace("http://", "https://")
    };
    Some(url)
}

/// 扁平化两层嵌套数组（对齐桌面 rawItems.flat(2)），过滤非对象项。
fn flatten_items(raw: &Value) -> Vec<Value> {
    let mut out = Vec::new();
    let mut push_value = |v: &Value| {
        if v.is_object() {
            out.push(v.clone());
        }
    };
    match raw {
        Value::Array(top) => {
            for item in top {
                if item.is_array() {
                    if let Some(inner) = item.as_array() {
                        for v in inner {
                            push_value(v);
                        }
                    }
                } else {
                    push_value(item);
                }
            }
        }
        v => push_value(v),
    }
    out
}

/// 归一化歌单搜索结果（对齐桌面 normalizeLxPlaylistResults）。
fn normalize_playlists(source: &str, raw_items: &Value) -> Vec<LxPlaylistItem> {
    let mut results = Vec::new();
    let mut seen = std::collections::HashSet::new();

    for raw in flatten_items(raw_items) {
        let id_value = match first_value(&raw, PLAYLIST_ID_KEYS) {
            Some(v) => v,
            None => continue,
        };
        let title_value = match first_value(&raw, PLAYLIST_TITLE_KEYS) {
            Some(v) => v,
            None => continue,
        };
        let playlist_id = match id_value {
            Value::Number(n) => n.to_string(),
            Value::String(s) => s.clone(),
            _ => continue,
        };
        let dedupe_key = format!("{}:{}", source, playlist_id);
        if !seen.insert(dedupe_key) {
            continue;
        }

        let title_text = title_value.as_str().unwrap_or("");
        let title = decode_name(&strip_html_tags(title_text));
        let cover_url = first_value(&raw, PLAYLIST_COVER_KEYS).and_then(normalize_cover);
        let artist = first_value(&raw, PLAYLIST_ARTIST_KEYS)
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
            .or_else(|| {
                raw.get("creator").and_then(|c| {
                    c.get("name")
                        .or_else(|| c.get("nickname"))
                        .and_then(|v| v.as_str())
                        .map(|s| s.to_string())
                })
            })
            .unwrap_or_default();
        let track_count = first_value(&raw, PLAYLIST_TRACK_COUNT_KEYS)
            .and_then(|v| v.as_u64().or_else(|| v.as_str().and_then(|s| s.parse().ok())));
        let play_count = first_value(&raw, PLAYLIST_PLAY_COUNT_KEYS)
            .and_then(|v| v.as_u64().or_else(|| v.as_str().and_then(|s| s.parse().ok())));

        results.push(LxPlaylistItem {
            id: format!("{}:playlist:{}", source, playlist_id),
            playlist_id,
            title,
            cover_url,
            artist,
            track_count,
            play_count,
            raw,
        });
    }
    results
}

fn strip_html_tags(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut in_tag = false;
    for ch in s.chars() {
        match ch {
            '<' => in_tag = true,
            '>' => in_tag = false,
            c if !in_tag => out.push(c),
            _ => {}
        }
    }
    out
}

/// 酷我旧搜索接口（search.kuwo.cn/r.s）返回 Python 风格单引号 JSON，
/// 标准解析必然失败。状态机转换（对齐桌面 parseLooseJson）：
/// 字符串定界符 ' → "，字符串内的 " 转义，保留原有反斜杠转义。
fn parse_loose_json(text: &str) -> Result<Value, String> {
    let mut out = String::with_capacity(text.len());
    let mut in_str = false;
    let chars: Vec<char> = text.chars().collect();
    let mut i = 0;
    while i < chars.len() {
        let ch = chars[i];
        if !in_str {
            if ch == '\'' {
                in_str = true;
                out.push('"');
            } else {
                out.push(ch);
            }
        } else if ch == '\\' {
            out.push(ch);
            if i + 1 < chars.len() {
                out.push(chars[i + 1]);
                i += 1;
            }
        } else if ch == '\'' {
            in_str = false;
            out.push('"');
        } else {
            if ch == '"' {
                out.push('\\');
            }
            out.push(ch);
        }
        i += 1;
    }
    serde_json::from_str(&out).map_err(|e| format!("loose JSON: {}", e))
}

/// 宽松 GET：标准 JSON 失败时尝试单引号状态机转换（对齐桌面 httpGetLooseJson）。
async fn http_get_loose_json(
    url: &str,
    headers: &[(&str, &str)],
) -> Result<Value, String> {
    // 复用 lx_search 的严格 GET；失败时再拉一次文本做宽松解析。
    // 这里直接调用严格版：其错误信息含 HTTP 状态，无法区分解析失败，
    // 因此宽松版仅在严格版返回「Invalid JSON」时用独立请求兜底。
    match http_get_json(url, headers).await {
        Ok(v) => Ok(v),
        Err(e) if e.starts_with("Invalid JSON") => {
            // 重新请求一次拿原始文本做状态机转换（低频兜底路径，可接受）。
            let body = http_get_text(url, headers).await?;
            parse_loose_json(&body).map_err(|_| e)
        }
        Err(e) => Err(e),
    }
}

/// GET 原始文本（仅宽松解析兜底用）。
async fn http_get_text(url: &str, headers: &[(&str, &str)]) -> Result<String, String> {
    use std::sync::OnceLock;
    static CLIENT: OnceLock<Result<reqwest::Client, String>> = OnceLock::new();
    let client = CLIENT
        .get_or_init(|| {
            reqwest::Client::builder()
                .timeout(std::time::Duration::from_secs(15))
                .build()
                .map_err(|e| e.to_string())
        })
        .as_ref()
        .map_err(|e| e.clone())?;
    let mut req = client.get(url);
    for (k, v) in headers {
        req = req.header(*k, *v);
    }
    let resp = req.send().await.map_err(|e| e.to_string())?;
    let status = resp.status().as_u16();
    let body = resp.text().await.map_err(|e| e.to_string())?;
    if status != 200 {
        return Err(format!("HTTP {} for {}", status, url));
    }
    Ok(body)
}

// ==================== 歌单搜索 ====================

/// LX 歌单搜索（对齐桌面 searchLxPlaylists）。
pub async fn lx_search_playlists(
    source: &str,
    keyword: &str,
    page: u32,
    limit: u32,
) -> Result<Vec<LxPlaylistItem>, String> {
    match source {
        "kw" => {
            // 优先新 API，被风控/空结果时回退旧 r.s 接口（单引号 JSON）。
            let new_url = format!(
                "https://www.kuwo.cn/api/www/search/searchPlayListBykeyWord?key={}&pn={}&rn={}",
                urlencode(keyword),
                page,
                limit
            );
            if let Ok(data) = http_get_json(
                &new_url,
                &[
                    ("csrf", "ABCDEF"),
                    ("Cookie", "kw_token=ABCDEF"),
                    ("Referer", "https://www.kuwo.cn/"),
                ],
            )
            .await
            {
                let list = data
                    .pointer("/data/list")
                    .or_else(|| data.get("data"))
                    .cloned()
                    .unwrap_or(Value::Null);
                if list.as_array().map(|a| !a.is_empty()).unwrap_or(false) {
                    return Ok(normalize_playlists(source, &list));
                }
            }
            let old_url = format!(
                "https://search.kuwo.cn/r.s?client=kt&all={}&pn={}&rn={}&ft=playlist&encoding=utf8&rformat=json",
                urlencode(keyword),
                page - 1,
                limit
            );
            let data = http_get_loose_json(
                &old_url,
                &[("Referer", "https://www.kuwo.cn/")],
            )
            .await?;
            let list = data
                .get("abslist")
                .or_else(|| data.get("data"))
                .cloned()
                .unwrap_or(Value::Array(Vec::new()));
            Ok(normalize_playlists(source, &list))
        }
        "kg" => {
            let url = format!(
                "https://songsearch.kugou.com/special_search?keyword={}&page={}&pagesize={}&userid=-1&clientver=&platform=WebFilter&filter=0&iscorrection=1&privilege_filter=0",
                urlencode(keyword),
                page,
                limit
            );
            let data = http_get_json(&url, &[]).await?;
            let list = data
                .pointer("/data/lists")
                .or_else(|| data.pointer("/data/list"))
                .cloned()
                .unwrap_or(Value::Array(Vec::new()));
            Ok(normalize_playlists(source, &list))
        }
        "wy" => {
            let offset = limit * (page - 1);
            let url = format!(
                "https://music.163.com/api/search/get/web?s={}&type=1000&offset={}&limit={}",
                urlencode(keyword),
                offset,
                limit
            );
            let data = http_get_json(
                &url,
                &[
                    ("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"),
                    ("Referer", "https://music.163.com"),
                    ("Cookie", "MUSIC_A=1"),
                ],
            )
            .await?;
            let list = data
                .pointer("/result/playlists")
                .cloned()
                .unwrap_or(Value::Array(Vec::new()));
            Ok(normalize_playlists(source, &list))
        }
        "tx" => {
            // 新签名(Mobile)通道，被风控/降级时回退无签名 Desktop 通道（实测稳定）。
            let request_data = serde_json::json!({
                "comm": {
                    "ct": "24", "cv": "4747474", "v": "4747474",
                    "tmeAppID": "qqmusic", "format": "json",
                    "inCharset": "utf-8", "outCharset": "utf-8",
                    "platform": "yqq.json", "needNewCode": 0,
                    "uin": "0", "guid": "0",
                },
                "req": {
                    "module": "music.search.SearchCgiService",
                    "method": "DoSearchForQQMusicMobile",
                    "param": {
                        "search_type": 3,
                        "searchid": format!("{}{:05}", random_tx_guid(), random_5_digits()),
                        "query": keyword,
                        "page_num": page,
                        "num_per_page": limit,
                        "highlight": 0, "nqc_flag": 0, "multi_zhida": 0,
                        "cat": 2, "grp": 1, "sin": 0, "sem": 0,
                    },
                },
            });
            let request_str = serde_json::to_string(&request_data).map_err(|e| e.to_string())?;
            let mut list: Vec<Value> = Vec::new();
            let sign = zzc_sign(&request_str);
            let url = format!("https://u.y.qq.com/cgi-bin/musics.fcg?sign={}", sign);
            if let Ok(data) = http_post_json(
                &url,
                &request_str,
                &[
                    ("User-Agent", "Mozilla/5.0 (Linux; Android 12; EBG-AN10) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/107.0.5304.141 Mobile Safari/537.36"),
                    ("Content-Type", "application/json"),
                    ("Referer", "https://y.qq.com/"),
                ],
            )
            .await
            {
                let body = data.pointer("/req/data/body").cloned().unwrap_or(Value::Null);
                let picked = body
                    .pointer("/item_songlist")
                    .or_else(|| body.pointer("/songlist/list"))
                    .cloned()
                    .unwrap_or(Value::Array(Vec::new()));
                if picked.as_array().map(|a| !a.is_empty()).unwrap_or(false) {
                    list = picked.as_array().cloned().unwrap_or_default();
                }
            }
            if list.is_empty() {
                list = tx_sheet_search_desktop_fallback(keyword, page, limit).await?;
            }
            Ok(normalize_playlists(source, &Value::Array(list)))
        }
        "mg" => {
            let time = now_ms().to_string();
            let (sign, device_id) = mg_create_signature(&time, keyword);
            let search_switch = urlencode(
                r#"{"song":0,"album":0,"singer":0,"tagSong":0,"mvSong":0,"bestShow":0,"songlist":1,"lyricSong":0}"#,
            );
            let url = format!(
                "https://jadeite.migu.cn/music_search/v3/search/searchAll?isCorrect=0&isCopyright=1&searchSwitch={}&pageSize={}&text={}&pageNo={}&sort=0&sid=USS",
                search_switch,
                limit,
                urlencode(keyword),
                page
            );
            let data = http_get_json(
                &url,
                &[
                    ("uiVersion", "A_music_3.6.1"),
                    ("deviceId", device_id.as_str()),
                    ("timestamp", time.as_str()),
                    ("sign", sign.as_str()),
                    ("channel", "0146921"),
                    ("User-Agent", "Mozilla/5.0 (Linux; Android 11)"),
                ],
            )
            .await?;
            let result_data = data
                .get("songListResultData")
                .or_else(|| data.get("songlistResultData"))
                .cloned()
                .unwrap_or(Value::Null);
            let list = result_data
                .get("resultList")
                .or_else(|| result_data.get("list"))
                .cloned()
                .unwrap_or(Value::Array(Vec::new()));
            Ok(normalize_playlists(source, &list))
        }
        _ => Err(format!("Unknown lx source: {}", source)),
    }
}

/// TX 歌单搜索无签名 Desktop 兜底（对齐桌面 txSheetSearchDesktopFallback）：
/// musicu.fcg DoSearchForQQMusicDesktop search_type=3 → body.songlist.list。
async fn tx_sheet_search_desktop_fallback(
    keyword: &str,
    page: u32,
    limit: u32,
) -> Result<Vec<Value>, String> {
    let body = serde_json::json!({
        "comm": { "ct": 19, "cv": 1859, "uin": "0" },
        "req": {
            "module": "music.search.SearchCgiService",
            "method": "DoSearchForQQMusicDesktop",
            "param": {
                "search_type": 3,
                "query": keyword,
                "page_num": page,
                "num_per_page": limit,
            },
        },
    });
    let body_str = serde_json::to_string(&body).map_err(|e| e.to_string())?;
    let data = http_post_json(
        "https://u.y.qq.com/cgi-bin/musicu.fcg",
        &body_str,
        &[
            ("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"),
            ("Content-Type", "application/json"),
            ("Referer", "https://y.qq.com/"),
        ],
    )
    .await?;
    let list = data
        .pointer("/req/data/body/songlist/list")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    if list.is_empty() {
        return Err("TX sheet desktop fallback: 无有效歌单".to_string());
    }
    Ok(list)
}

// ==================== 歌单曲目 ====================

/// 构造简化 LxSearchItem（专辑/歌单接口不返回音质信息，types 留空，
/// 播放时由 url_resolver 统一解析）。
#[allow(clippy::too_many_arguments)]
fn simple_item(
    source: &str,
    songmid: String,
    name: &str,
    singer: &str,
    album_name: &str,
    album_id: Value,
    interval: String,
    img: Option<String>,
    copyright_id: Option<String>,
) -> LxSearchItem {
    LxSearchItem {
        name: decode_name(name),
        singer: decode_name(singer),
        album_name: decode_name(album_name),
        album_id,
        songmid,
        source: source.to_string(),
        interval,
        img,
        hash: None,
        str_media_mid: None,
        song_id: None,
        album_mid: None,
        copyright_id,
        types: Vec::new(),
        lx_types: None,
    }
}

/// TX 歌单详情经典 Web 兜底：不依赖新签名(musics.fcg)风控体系。
async fn tx_sheet_tracks_web_fallback(
    playlist_id: &str,
    page: u32,
    limit: u32,
) -> Result<Vec<LxSearchItem>, String> {
    let url = format!(
        "https://c.y.qq.com/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg?type=1&json=1&utf8=1&onlysong=0&new_format=1&disstid={}&format=json&g_tk=5381&loginUin=0&hostUin=0&inCharset=utf8&outCharset=utf-8&notice=0&platform=jq&needNewCode=0",
        urlencode(playlist_id)
    );
    let result = http_get_json(
        &url,
        &[
            ("User-Agent", "Mozilla/5.0 (iPhone; CPU iPhone OS 14_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/14.0 Mobile/15E148 Safari/604.1"),
            ("Referer", "https://y.qq.com/"),
        ],
    )
    .await?;
    let song_all = result
        .pointer("/data/cdlist/0/songlist")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    let start = ((page - 1) * limit) as usize;
    let songlist: Vec<Value> = song_all
        .into_iter()
        .skip(start)
        .take(limit as usize)
        .collect();
    Ok(tx_handle_result(&Value::Array(songlist)))
}

/// LX 歌单曲目拉取（对齐桌面 lxGetPlaylistTracks）。
pub async fn lx_playlist_tracks(
    source: &str,
    playlist_id: &str,
    page: u32,
    limit: u32,
) -> Result<LxPlaylistTracksResult, String> {
    if playlist_id.is_empty() {
        return Ok(LxPlaylistTracksResult {
            list: Vec::new(),
            is_end: true,
        });
    }
    let result = match source {
        "kw" => {
            // www.kuwo.cn/api/www/playlist/playListInfo 已被风控，
            // 改用 nplserver 无风控接口，一次 rn=1000 拉全部曲目。
            let url = format!(
                "http://nplserver.kuwo.cn/pl.svc?op=getlistinfo&pid={}&pn=0&rn=1000&encode=utf8&keyset=pl2012&vipver=MUSIC_9.1.1.2_BCS2&newver=1",
                urlencode(playlist_id)
            );
            let body = match http_get_json(&url, &[("Referer", "https://www.kuwo.cn/")]).await {
                Ok(b) => b,
                Err(e) => return Err(e),
            };
            if body.get("result").and_then(|v| v.as_str()) != Some("ok") {
                return Ok(LxPlaylistTracksResult {
                    list: Vec::new(),
                    is_end: true,
                });
            }
            let musiclist = body
                .get("musiclist")
                .and_then(|v| v.as_array())
                .cloned()
                .unwrap_or_default();
            let list = musiclist
                .iter()
                .map(|m| {
                    // id 可能是数字或 "MUSIC_xxx" 形式的字符串
                    let rid = match m.get("id") {
                        Some(Value::Number(n)) => n.to_string(),
                        Some(Value::String(s)) => s.clone(),
                        _ => String::new(),
                    };
                    let rid = rid.strip_prefix("MUSIC_").unwrap_or(&rid).to_string();
                    let duration = m
                        .get("duration")
                        .and_then(|v| v.as_str().and_then(|s| s.parse::<f64>().ok()))
                        .unwrap_or(0.0);
                    let img = m
                        .get("albumpic")
                        .or_else(|| m.get("pic"))
                        .and_then(|v| v.as_str())
                        .map(|s| s.to_string());
                    simple_item(
                        source,
                        rid,
                        m.get("name").and_then(|v| v.as_str()).unwrap_or(""),
                        m.get("artist").and_then(|v| v.as_str()).unwrap_or(""),
                        m.get("album").and_then(|v| v.as_str()).unwrap_or(""),
                        m.get("albumid").cloned().unwrap_or(Value::String(String::new())),
                        format_play_time(duration),
                        img,
                        None,
                    )
                })
                .collect();
            // nplserver 一次返回全部，isEnd 始终为 true
            LxPlaylistTracksResult {
                list,
                is_end: true,
            }
        }
        "kg" => {
            let url = format!(
                "http://mobilecdn.kugou.com/api/v3/song/special/getSongList?specialid={}&page={}&pagesize={}",
                urlencode(playlist_id),
                page,
                limit
            );
            let data = http_get_json(&url, &[]).await?;
            let info_list = data
                .pointer("/data/info")
                .and_then(|v| v.as_array())
                .cloned()
                .unwrap_or_default();
            let list: Vec<LxSearchItem> = info_list.iter().map(kg_filter_data).collect();
            LxPlaylistTracksResult {
                is_end: (list.len() as u32) < limit,
                list,
            }
        }
        "tx" => {
            // 新签名(Mobile)通道被风控(reqCode 2001)或降级时 songlist 为空，
            // 回退经典 Web 接口兜底。
            let request_data = serde_json::json!({
                "comm": { "ct": "24", "cv": "0" },
                "req": {
                    "module": "music.srfDissInfo.aiDissInfo",
                    "method": "uniform_get_Dissinfo",
                    "param": {
                        "disstid": playlist_id,
                        "song_num": limit,
                        "song_begin": (page - 1) * limit,
                        "userinfo": 0, "tag": 1, "is_pull_album_info": 1,
                    },
                },
            });
            let request_str = serde_json::to_string(&request_data).map_err(|e| e.to_string())?;
            let sign = zzc_sign(&request_str);
            let url = format!("https://u.y.qq.com/cgi-bin/musics.fcg?sign={}", sign);
            let songlist = match http_post_json(
                &url,
                &request_str,
                &[
                    ("User-Agent", "Mozilla/5.0 (Linux; Android 12; EBG-AN10) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/107.0.5304.141 Mobile Safari/537.36"),
                    ("Content-Type", "application/json"),
                    ("Referer", "https://y.qq.com/"),
                ],
            )
            .await
            {
                Ok(resp) => resp
                    .pointer("/req/data/songlist")
                    .and_then(|v| v.as_array())
                    .cloned()
                    .unwrap_or_default(),
                Err(_) => Vec::new(),
            };
            let (list, is_end) = if songlist.is_empty() {
                let list = tx_sheet_tracks_web_fallback(playlist_id, page, limit).await?;
                let is_end = (list.len() as u32) < limit;
                (list, is_end)
            } else {
                let list = tx_handle_result(&Value::Array(songlist));
                let is_end = (list.len() as u32) < limit;
                (list, is_end)
            };
            LxPlaylistTracksResult { list, is_end }
        }
        "wy" => {
            let offset = (page - 1) * limit;
            let url = format!(
                "https://music.163.com/api/v6/playlist/detail?id={}&n={}&offset={}",
                urlencode(playlist_id),
                limit,
                offset
            );
            let data = http_get_json(
                &url,
                &[
                    ("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"),
                    ("Referer", "https://music.163.com"),
                    ("Cookie", "MUSIC_A=1"),
                ],
            )
            .await?;
            let tracks = data
                .pointer("/playlist/tracks")
                .and_then(|v| v.as_array())
                .cloned()
                .unwrap_or_default();
            let list: Vec<LxSearchItem> = tracks
                .iter()
                .map(|song| {
                    let al = song.get("album").or_else(|| song.get("al"));
                    let ar = song
                        .get("artists")
                        .or_else(|| song.get("ar"))
                        .and_then(|v| v.as_array())
                        .cloned()
                        .unwrap_or_default();
                    let singer = ar
                        .iter()
                        .filter_map(|s| s.get("name").and_then(|n| n.as_str()))
                        .collect::<Vec<&str>>()
                        .join("、");
                    let duration = song
                        .get("duration")
                        .or_else(|| song.get("dt"))
                        .and_then(|v| v.as_f64())
                        .unwrap_or(0.0)
                        / 1000.0;
                    let img = al
                        .and_then(|a| a.get("picUrl"))
                        .and_then(|v| v.as_str())
                        .map(|s| s.replace("http://", "https://"));
                    simple_item(
                        source,
                        song.get("id").map(|v| v.to_string()).unwrap_or_default(),
                        song.get("name").and_then(|v| v.as_str()).unwrap_or(""),
                        &singer,
                        al.and_then(|a| a.get("name"))
                            .and_then(|v| v.as_str())
                            .unwrap_or(""),
                        al.and_then(|a| a.get("id"))
                            .cloned()
                            .unwrap_or(Value::String(String::new())),
                        format_play_time(duration),
                        img,
                        None,
                    )
                })
                .collect();
            LxPlaylistTracksResult {
                is_end: (list.len() as u32) < limit,
                list,
            }
        }
        "mg" => {
            let url = format!(
                "https://m.music.migu.cn/migu/remoting/playlist_callback?playlistId={}&pageNo={}&pageSize={}",
                urlencode(playlist_id),
                page,
                limit
            );
            let data = http_get_json(&url, &[]).await?;
            let raw_list = data
                .get("list")
                .or_else(|| data.get("resultList"))
                .and_then(|v| v.as_array())
                .cloned()
                .unwrap_or_default();
            let list: Vec<LxSearchItem> = raw_list
                .iter()
                .map(|item| {
                    let singers = item
                        .get("singerList")
                        .or_else(|| item.get("singers"))
                        .cloned()
                        .unwrap_or(Value::Null);
                    let singer = format_singer_name(&singers, "name");
                    let img = item
                        .get("img3")
                        .or_else(|| item.get("img2"))
                        .or_else(|| item.get("img1"))
                        .and_then(|v| v.as_str())
                        .map(|s| s.to_string());
                    let duration = item
                        .get("duration")
                        .and_then(|v| v.as_f64())
                        .unwrap_or(0.0);
                    simple_item(
                        source,
                        item.get("songId")
                            .or_else(|| item.get("id"))
                            .map(|v| v.to_string())
                            .unwrap_or_default(),
                        item.get("name")
                            .or_else(|| item.get("songName"))
                            .and_then(|v| v.as_str())
                            .unwrap_or(""),
                        &singer,
                        item.get("album")
                            .or_else(|| item.get("albumName"))
                            .and_then(|v| v.as_str())
                            .unwrap_or(""),
                        item.get("albumId")
                            .cloned()
                            .unwrap_or(Value::String(String::new())),
                        format_play_time(duration),
                        img,
                        item.get("copyrightId")
                            .and_then(|v| v.as_str())
                            .map(|s| s.to_string()),
                    )
                })
                .collect();
            LxPlaylistTracksResult {
                is_end: (list.len() as u32) < limit,
                list,
            }
        }
        _ => return Err(format!("Unknown lx source: {}", source)),
    };
    Ok(result)
}

fn urlencode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{:02X}", b)),
        }
    }
    out
}
