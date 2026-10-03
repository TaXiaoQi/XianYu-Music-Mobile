// 歌单导入网易云平台实现：自前端 playlistImportWy.ts 移植（内置主链路）。

use std::collections::HashSet;
use std::sync::OnceLock;
use std::time::Duration;

use regex::Regex;
use serde_json::{json, Value};

use super::common::{
    decode_name, format_play_time, format_singer_name, http_fetch_json, percent_encode_component,
    PlaylistImportResult, PlaylistSong,
};

// 对齐 TS：linux/forward 与 weapi 接口使用的 Linux 端 UA
const WY_LINUX_UA: &str = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/60.0.3112.90 Safari/537.36";

// 对齐 TS wyRegex1 / wyRegex2（playlistImportBase.ts）：注意 `^.+` 锚定前缀；
// `\d` 用 [0-9] 等价替换（JS 的 \d 仅匹配 ASCII 数字，regex crate 默认匹配 Unicode 数字）
const WY_REGEX1: &str = r"^.+[?&]id=([0-9]+)(?:&.*$|#.*$|$)";
const WY_REGEX2: &str = r"^.+/playlist/([0-9]+)/[0-9]+/.+$";

fn wy_regex1() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(WY_REGEX1).expect("wyRegex1 编译失败"))
}

fn wy_regex2() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(WY_REGEX2).expect("wyRegex2 编译失败"))
}

// ==================== JS/TS 语义工具 ====================

/// 对齐 JS 真值判断：null/false/0/空串为假；数组与对象（含空）恒为真
fn is_truthy(value: &Value) -> bool {
    match value {
        Value::Null => false,
        Value::Bool(b) => *b,
        Value::Number(n) => n.as_f64().map(|f| f != 0.0).unwrap_or(false),
        Value::String(s) => !s.is_empty(),
        // Array / Object
        _ => true,
    }
}

/// 对齐 TS `a || b`：主值为真值取主值，否则取兜底
fn or_truthy<'a>(primary: Option<&'a Value>, fallback: &'a Value) -> &'a Value {
    match primary {
        Some(v) if is_truthy(v) => v,
        _ => fallback,
    }
}

/// 对齐 TS `value || ''` 且按字符串取用：真值字符串原样返回，其余为空串
fn truthy_string(value: Option<&Value>) -> String {
    match value {
        Some(Value::String(s)) if !s.is_empty() => s.clone(),
        _ => String::new(),
    }
}

/// 对齐 TS `String(value ?? '')`：缺失/null → 空串；字符串原样；数字/布尔按 JS 语义字符串化
fn js_string(value: Option<&Value>) -> String {
    match value {
        None | Some(Value::Null) => String::new(),
        Some(Value::String(s)) => s.clone(),
        // Number/Bool 的 serde to_string 与 JS String() 一致（123 → "123"、true → "true"）
        Some(other) => other.to_string(),
    }
}

// ==================== 歌单 ID 提取（对齐 playlistImportBase.ts getWyListId） ====================

fn get_wy_list_id(raw_id: &str) -> Option<String> {
    // TS: if (id.includes('###')) id = id.split('###')[0]
    let id = match raw_id.find("###") {
        Some(pos) => &raw_id[..pos],
        None => raw_id,
    };
    // TS: /[?&:/]/.test(id)
    if id.chars().any(|c| matches!(c, '?' | '&' | ':' | '/')) {
        if let Some(caps) = wy_regex1().captures(id) {
            return Some(caps[1].to_string());
        }
        if let Some(caps) = wy_regex2().captures(id) {
            return Some(caps[1].to_string());
        }
        return None;
    }
    Some(id.to_string())
}

// ==================== 歌单详情主流程（对齐 getListDetailWy） ====================

pub(super) async fn get_list_detail_wy(raw_id: &str) -> Result<PlaylistImportResult, String> {
    // TS: const id = getWyListId(rawId); if (!id) return 空结果（null 与空串均为假值）
    let id = match get_wy_list_id(raw_id) {
        Some(id) if !id.is_empty() => id,
        _ => return Ok(PlaylistImportResult::empty("wy")),
    };

    // linuxapi 加密：v3 歌单详情的 method/url/params 包装体（id 为字符串、n/s 为数字）
    let params = json!({
        "method": "POST",
        "url": "https://music.163.com/api/v3/playlist/detail",
        "params": { "id": id, "n": 100000, "s": 8 },
    });
    let params_str = serde_json::to_string(&params).map_err(|e| e.to_string())?;
    let eparams = crate::host_crypto::linuxapi_encrypt(&params_str);

    let resp = http_fetch_json(
        "https://music.163.com/api/linux/forward",
        "POST",
        &[("User-Agent", WY_LINUX_UA), ("Cookie", "MUSIC_U=")],
        None,
        Some(&[("eparams", eparams.as_str())]),
    )
    .await?;

    // TS: typeof body !== 'object' || body === null || body.code !== 200 → throw
    let body = resp.body;
    if !body.is_object() || body.get("code").and_then(Value::as_i64) != Some(200) {
        let code_display = match body.get("code") {
            // TS: body?.code ?? 'unknown'（仅 null/undefined 回退）
            Some(v) if !v.is_null() => js_string(Some(v)),
            _ => "unknown".to_string(),
        };
        return Err(format!("网易云歌单获取失败: code={}", code_display));
    }

    // TS: if (!playlist) return 空结果
    let playlist = match body.get("playlist") {
        Some(p) if !p.is_null() => p,
        _ => return Ok(PlaylistImportResult::empty("wy")),
    };

    let empty_arr = Vec::new();
    // TS: playlist.trackIds || [] / playlist.tracks || []
    let track_ids = playlist
        .get("trackIds")
        .and_then(Value::as_array)
        .unwrap_or(&empty_arr);
    let tracks = playlist
        .get("tracks")
        .and_then(Value::as_array)
        .unwrap_or(&empty_arr);
    let total = track_ids.len() as i64;

    eprintln!(
        "[playlist_fetcher] getListDetailWy: trackIds={}, tracks={}",
        total,
        tracks.len()
    );

    let mut songs: Vec<PlaylistSong> = Vec::new();
    let mut fetched_ids: HashSet<String> = HashSet::new();
    for track in tracks {
        if let Some(parsed) = parse_wy_track(track) {
            fetched_ids.insert(parsed.id.clone());
            songs.push(parsed);
        }
    }

    // trackIds 中未随 tracks 返回的剩余 id，按 1000/批补拉详情
    let mut remaining_ids: Vec<String> = Vec::new();
    for tid in track_ids {
        // TS: String(tid.id ?? '')
        let song_id = js_string(tid.get("id"));
        if !song_id.is_empty() && !fetched_ids.contains(&song_id) {
            remaining_ids.push(song_id);
        }
    }

    eprintln!(
        "[playlist_fetcher] getListDetailWy: already fetched={}, remaining={}",
        fetched_ids.len(),
        remaining_ids.len()
    );

    if !remaining_ids.is_empty() {
        let batch_size = 1000;
        let mut processed = 0;
        while processed < remaining_ids.len() {
            let end = (processed + batch_size).min(remaining_ids.len());
            let batch_result = fetch_wy_music_detail_list(&remaining_ids[processed..end]).await?;
            songs.extend(batch_result);
            processed = end;
        }
    }

    // TS: playlist.name || '' / coverImgUrl || '' / description || '' /
    //     creator?.nickname || '' / String(playCount || 0)
    let play_count = match playlist.get("playCount") {
        Some(v) if is_truthy(v) => js_string(Some(v)),
        _ => "0".to_string(),
    };
    let info = super::common::PlaylistInfo {
        name: decode_name(&truthy_string(playlist.get("name"))),
        img: truthy_string(playlist.get("coverImgUrl")),
        desc: decode_name(&truthy_string(playlist.get("description"))),
        author: decode_name(&truthy_string(
            playlist
                .get("creator")
                .and_then(|creator| creator.get("nickname")),
        )),
        play_count,
    };

    Ok(PlaylistImportResult {
        source: "wy".to_string(),
        songs,
        total,
        info,
    })
}

// ==================== 歌曲详情批量补拉（对齐 fetchWyMusicDetailList） ====================

/// weapi 加密的 v3 歌曲详情批量请求：MAX_RETRY=2（共 3 次尝试），间隔 300ms。
/// 全部尝试失败时抛错（对齐 TS throw）。
async fn fetch_wy_music_detail_list(ids: &[String]) -> Result<Vec<PlaylistSong>, String> {
    if ids.is_empty() {
        return Ok(Vec::new());
    }

    const MAX_RETRY: u32 = 2;
    let mut last_error = String::from("unknown");

    for attempt in 0..=MAX_RETRY {
        // c / ids 均为字符串化的 JSON 数组（id 不带引号，对齐 TS 模板串拼接）
        let c_value = format!(
            "[{}]",
            ids.iter()
                .map(|id| format!("{{\"id\":{}}}", id))
                .collect::<Vec<_>>()
                .join(",")
        );
        let ids_value = format!("[{}]", ids.join(","));
        let payload = json!({ "c": c_value, "ids": ids_value }).to_string();
        let (params, enc_sec_key) = crate::host_crypto::weapi_encrypt(&payload);

        let request_body = format!(
            "params={}&encSecKey={}",
            percent_encode_component(&params),
            percent_encode_component(&enc_sec_key)
        );

        match http_fetch_json(
            "https://music.163.com/weapi/v3/song/detail",
            "POST",
            &[
                ("Content-Type", "application/x-www-form-urlencoded"),
                ("User-Agent", WY_LINUX_UA),
                ("Origin", "https://music.163.com"),
                ("Referer", "https://music.163.com/"),
            ],
            Some(&request_body),
            None,
        )
        .await
        {
            Ok(resp) => {
                let body = resp.body;
                // TS: typeof body === 'object' && body !== null && body.code === 200
                if body.is_object() && body.get("code").and_then(Value::as_i64) == Some(200) {
                    let mut list: Vec<PlaylistSong> = Vec::new();
                    // TS: body.songs || []
                    if let Some(songs) = body.get("songs").and_then(Value::as_array) {
                        for track in songs {
                            if let Some(parsed) = parse_wy_track(track) {
                                list.push(parsed);
                            }
                        }
                    }
                    eprintln!(
                        "[playlist_fetcher] fetchWyMusicDetailList: requested={}, parsed={}, attempt={}",
                        ids.len(),
                        list.len(),
                        attempt + 1
                    );
                    return Ok(list);
                }

                let code_display = match body.get("code") {
                    Some(v) if !v.is_null() => js_string(Some(v)),
                    _ => "unknown".to_string(),
                };
                // TS: typeof body === 'string' ? body.substring(0, 200) : JSON.stringify(body).substring(0, 200)
                let body_preview = match &body {
                    Value::String(s) => s.chars().take(200).collect::<String>(),
                    other => serde_json::to_string(other)
                        .unwrap_or_default()
                        .chars()
                        .take(200)
                        .collect::<String>(),
                };
                eprintln!(
                    "[playlist_fetcher] fetchWyMusicDetailList: attempt={} code={}, body={}",
                    attempt + 1,
                    code_display,
                    body_preview
                );
                // TS: lastError = new Error(`code=${body?.code ?? 'unknown'}`)
                last_error = format!("code={}", code_display);
            }
            Err(e) => {
                eprintln!(
                    "[playlist_fetcher] fetchWyMusicDetailList: attempt={} exception: {}",
                    attempt + 1,
                    e
                );
                last_error = e;
            }
        }

        if attempt < MAX_RETRY {
            tokio::time::sleep(Duration::from_millis(300)).await;
        }
    }

    // TS: throw new Error(`网易云歌曲详情获取失败: ${lastError?.message || 'unknown'}`)
    Err(format!("网易云歌曲详情获取失败: {}", last_error))
}

// ==================== 单轨解析（对齐 parseWyTrack） ====================

/// 单轨 → PlaylistSong；id 缺失或为 "0" 时丢弃（对齐 TS null）。
fn parse_wy_track(track: &Value) -> Option<PlaylistSong> {
    // TS: const id = String(track.id ?? ''); if (!id || id === '0') return null
    let id = js_string(track.get("id"));
    if id.is_empty() || id == "0" {
        return None;
    }

    let name = decode_name(&truthy_string(track.get("name")));

    // TS: track.ar || track.artists || [] / track.al || track.album || {}（假值穿透）
    let empty_arr = Value::Array(Vec::new());
    let empty_obj = Value::Object(serde_json::Map::new());
    let zero = Value::from(0);
    let ar = or_truthy(track.get("ar"), or_truthy(track.get("artists"), &empty_arr));
    let al = or_truthy(track.get("al"), or_truthy(track.get("album"), &empty_obj));

    // duration 为毫秒（dt 新版 / duration 旧版）
    let duration_value = or_truthy(track.get("dt"), or_truthy(track.get("duration"), &zero));
    let duration_f = duration_value.as_f64().unwrap_or(0.0);
    let duration_ms = duration_f as i64;

    // TS: al.picUrl || track.album?.picUrl || ''
    let img = match truthy_string(al.get("picUrl")) {
        img if !img.is_empty() => img,
        _ => truthy_string(track.get("album").and_then(|album| album.get("picUrl"))),
    };

    let singer_name = format_singer_name(ar);
    let album = decode_name(&truthy_string(al.get("name")));

    // rawData 键集合冻结：songmid / name / singer / source / interval
    let raw_data = json!({
        "songmid": id.as_str(),
        "name": name.as_str(),
        "singer": singer_name.as_str(),
        "source": "wy",
        "interval": format_play_time((duration_f / 1000.0).floor()).as_str(),
    });

    Some(PlaylistSong::new(
        &id,
        &name,
        &singer_name,
        &album,
        &img,
        duration_ms,
        "网易云",
        "wy",
        raw_data,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    const FIXTURE: &str = include_str!("../fixtures/playlist/wy.json");

    fn fixture_body() -> Value {
        serde_json::from_str(FIXTURE).expect("fixture 应为合法 JSON")
    }

    // parse_wy_track：新版 ar/al/dt 字段映射 + rawData 键集合 + 毫秒时长 + platformId == id
    #[test]
    fn parse_wy_track_maps_new_shape() {
        let body = fixture_body();
        let track = &body["playlist"]["tracks"][0];
        let song = parse_wy_track(track).expect("有效 track 应解析成功");

        assert_eq!(song.id, "101");
        // platformId 自动等于 id
        assert_eq!(song.platform_id, "101");
        assert_eq!(song.plugin_id, "wy");
        assert_eq!(song.platform, "网易云");
        // name 经 HTML 实体解码（&amp; → &）
        assert_eq!(song.title, "晴天 & 彩虹");
        assert_eq!(song.artist, "周杰伦、费玉清");
        assert_eq!(song.album, "叶惠美");
        assert_eq!(song.cover_url, "https://p1.example/101.jpg");
        // duration 保持毫秒单位
        assert_eq!(song.duration, 269_000);

        // rawData 键集合断言（serde Object 为 BTreeMap，按键名存在性而非顺序）
        let raw = song.raw_data.as_object().expect("rawData 应为对象");
        assert_eq!(raw.len(), 5);
        for key in ["songmid", "name", "singer", "source", "interval"] {
            assert!(raw.contains_key(key), "rawData 缺少键 {}", key);
        }
        assert_eq!(raw["songmid"], "101");
        assert_eq!(raw["name"], "晴天 & 彩虹");
        assert_eq!(raw["singer"], "周杰伦、费玉清");
        assert_eq!(raw["source"], "wy");
        // 269000ms → 269s → "04:29"
        assert_eq!(raw["interval"], "04:29");
    }

    // parse_wy_track：旧版 artists/album/duration 字段映射
    #[test]
    fn parse_wy_track_maps_legacy_shape() {
        let body = fixture_body();
        let track = &body["playlist"]["tracks"][1];
        let song = parse_wy_track(track).expect("有效 track 应解析成功");

        assert_eq!(song.id, "102");
        assert_eq!(song.platform_id, "102");
        assert_eq!(song.title, "吻别");
        assert_eq!(song.artist, "张学友");
        assert_eq!(song.album, "吻别专辑");
        assert_eq!(song.cover_url, "https://p1.example/102.jpg");
        assert_eq!(song.duration, 253_000);
        // 253000ms → 253s → "04:13"
        assert_eq!(song.raw_data["interval"], "04:13");
        assert_eq!(song.raw_data["source"], "wy");
    }

    // TS: if (!id || id === '0') return null
    #[test]
    fn parse_wy_track_rejects_missing_or_zero_id() {
        assert!(parse_wy_track(&json!({ "id": 0, "name": "零 id" })).is_none());
        assert!(parse_wy_track(&json!({ "name": "缺 id" })).is_none());
    }

    // get_wy_list_id：纯 ID / ?id= 链接 / /playlist/ 链接（外加 ### 截断与正则无果分支）
    #[test]
    fn get_wy_list_id_handles_common_inputs() {
        // 纯 ID 原样返回
        assert_eq!(get_wy_list_id("123456789"), Some("123456789".to_string()));
        // ?id= 链接（wyRegex1）
        assert_eq!(
            get_wy_list_id("https://music.163.com/playlist?id=789456&userid=1"),
            Some("789456".to_string())
        );
        // /playlist/ 层级链接（wyRegex2）
        assert_eq!(
            get_wy_list_id("https://music.163.com/#/playlist/789456/10085/mymusic"),
            Some("789456".to_string())
        );
        // ### 锚点截断后为纯 ID
        assert_eq!(
            get_wy_list_id("123456###来自分享"),
            Some("123456".to_string())
        );
        // 含 URL 特征字符但正则无果 → None（对齐 TS null）
        assert_eq!(get_wy_list_id("https://music.163.com/playlist/789456"), None);
    }
}
