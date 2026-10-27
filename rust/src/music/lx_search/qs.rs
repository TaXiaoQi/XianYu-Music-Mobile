use super::*;

// 汽水音乐（抖音旗下）PC 客户端搜索：免签名，与歌单导入（playlist_fetcher/qishui.rs）同一 API 族。
// 端点为综合搜索（歌曲/歌单/歌手/专辑混排），此处取 tracks 分组，cursor 为全局流偏移。
// 以下参数组合已实测验证：UA 或 device_* 参数缺失时上游返回 ERR_INVALID_PARAM。
const QS_PC_QUERY: &str = "aid=386088&app_name=luna_pc&region=cn&geo_region=cn&os_region=cn&sim_region=&device_id=3753066532709850&cdid=&iid=3753066532713946&version_name=3.5.2&version_code=30050200&channel=official&build_mode=master&network_carrier=&ac=wifi&tz_name=Asia/Shanghai&resolution=&device_platform=windows&device_type=Windows&os_version=Windows%2010&fp=3753066532709850";
pub(crate) const QS_UA: &str = "LunaPC/3.5.2(412998333)";
/// 单次取数的全局流窗口
const QS_CURSOR_STEP: u32 = 20;
/// 最多取数轮数（综合搜索的全局流通常 3~4 窗即耗尽）
const QS_MAX_FETCHES: u32 = 5;
/// 搜索封面尺寸
const QS_COVER_SIZE: &str = "500:500";

/// 汽水内部品质 → LX 品质（映射后保持上游顺序：128k/320k/flac/spatial/hires）。
/// higher(192k) 在 LX 品质体系无对应，跳过。
fn qs_quality_type(quality: &str) -> Option<&'static str> {
    match quality {
        "medium" => Some("128k"),
        "highest" => Some("320k"),
        "lossless" => Some("flac"),
        "spatial" => Some("spatial"),
        "hi_res" => Some("hires"),
        _ => None,
    }
}

/// 单首曲目 → LxSearchItem
fn qs_item_from_track(track: &serde_json::Value) -> Option<LxSearchItem> {
    let songmid = track.get("id")?.as_str()?.to_string();
    if songmid.is_empty() {
        return None;
    }
    let album = track.get("album").unwrap_or(&serde_json::Value::Null);
    let img = crate::music::playlist_fetcher::qishui::build_image_url_from_cover(
        album.get("url_cover"),
        QS_COVER_SIZE,
    );

    // 音质：bit_rates 顺序即低→高，映射后保持顺序（spatial/hires 为汽水特有品质）
    let mut types = Vec::new();
    let mut lx_types = HashMap::new();
    if let Some(brs) = track.get("bit_rates").and_then(|v| v.as_array()) {
        for br in brs {
            let quality = br.get("quality").and_then(|v| v.as_str()).unwrap_or("");
            let Some(lx_q) = qs_quality_type(quality) else {
                continue;
            };
            let size = br.get("size").and_then(|v| v.as_f64()).map(size_formate);
            types.push(LxTypeTuple {
                quality_type: lx_q.into(),
                size: size.clone(),
                hash: None,
            });
            lx_types.insert(lx_q.into(), LxTypeEntry { size, hash: None });
        }
    }

    let duration_ms = track.get("duration").and_then(|v| v.as_f64()).unwrap_or(0.0);
    Some(LxSearchItem {
        name: track
            .get("name")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string(),
        singer: format_singer_name(
            track.get("artists").unwrap_or(&serde_json::Value::Null),
            "name",
        ),
        album_name: album
            .get("name")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string(),
        album_id: album.get("id").cloned().unwrap_or(serde_json::Value::Null),
        songmid,
        source: "qs".into(),
        interval: format_play_time(duration_ms / 1000.0),
        img: if img.is_empty() { None } else { Some(img) },
        hash: None,
        str_media_mid: None,
        song_id: None,
        album_mid: None,
        copyright_id: None,
        types,
        lx_types: Some(lx_types),
    })
}

/// 单次综合搜索（cursor 为全局流偏移，返回值仅含 tracks 分组）
async fn qs_fetch_tracks(keyword: &str, cursor: u32) -> Result<Vec<LxSearchItem>, String> {
    let url = format!(
        "https://api.qishui.com/luna/pc/search/all?q={}&cursor={}&search_id={}&search_method=input&{}",
        urlencoding::encode(keyword),
        cursor,
        uuid::Uuid::new_v4(),
        QS_PC_QUERY,
    );
    let result = http_get_json(&url, &[("User-Agent", QS_UA)]).await?;

    let mut out = Vec::new();
    if let Some(groups) = result.get("result_groups").and_then(|v| v.as_array()) {
        for group in groups {
            if group.get("id").and_then(|v| v.as_str()) != Some("tracks") {
                continue;
            }
            let Some(items) = group.get("data").and_then(|v| v.as_array()) else {
                continue;
            };
            for item in items {
                if item.pointer("/meta/item_type").and_then(|v| v.as_str()) != Some("track") {
                    continue;
                }
                if let Some(track) = item.pointer("/entity/track") {
                    if let Some(it) = qs_item_from_track(track) {
                        out.push(it);
                    }
                }
            }
        }
    }
    Ok(out)
}

// ==================== 原生播放取流（track_v2 + PlayAuth→CEK） ====================

/// track_v2 / GetPlayInfo 归一化后的单档播放信息
#[derive(Debug, Clone)]
pub(crate) struct QsPlayEntry {
    pub url: String,
    pub quality: String,
    pub bitrate: u64,
    pub size: u64,
    pub play_auth: String,
}

/// 品质选择结果（quality 为 LX 档位）
#[derive(Debug, Clone)]
pub(crate) struct QsPlayPayload {
    pub url: String,
    pub quality: String,
    pub bitrate: u64,
    pub size: u64,
    pub play_auth: String,
}

fn qs_v_str(v: &serde_json::Value, keys: &[&str]) -> String {
    for k in keys {
        if let Some(s) = v.get(k).and_then(|x| x.as_str()) {
            if !s.is_empty() {
                return s.to_string();
            }
        }
    }
    String::new()
}

fn qs_v_u64(v: &serde_json::Value, keys: &[&str]) -> u64 {
    for k in keys {
        if let Some(n) = v.get(k) {
            if let Some(x) = n.as_u64() {
                return x;
            }
            if let Some(s) = n.as_str() {
                if let Ok(x) = s.parse::<u64>() {
                    return x;
                }
            }
        }
    }
    0
}

/// video_list 条目字段大小写两套归一化（video_model 为 snake_case，GetPlayInfo 为 PascalCase）
fn qs_normalize_play_entry(x: &serde_json::Value) -> Option<QsPlayEntry> {
    if !x.is_object() {
        return None;
    }
    let url = qs_v_str(x, &["main_play_url", "main_url", "MainPlayUrl", "MainUrl"]);
    let backup = qs_v_str(x, &["backup_play_url", "backup_url", "BackupPlayUrl"]);
    let url = if url.is_empty() { backup } else { url };
    if url.is_empty() {
        return None;
    }
    let meta = x
        .get("video_meta")
        .or_else(|| x.get("VideoMeta"))
        .cloned()
        .unwrap_or(serde_json::Value::Null);
    let enc = x
        .get("encrypt_info")
        .or_else(|| x.get("EncryptInfo"))
        .cloned()
        .unwrap_or(serde_json::Value::Null);
    Some(QsPlayEntry {
        quality: qs_v_str(&meta, &["quality", "Quality"]),
        bitrate: qs_v_u64(&meta, &["bitrate", "real_bitrate", "Bitrate"]),
        size: qs_v_u64(&meta, &["size", "Size"]),
        play_auth: qs_v_str(&enc, &["spade_a", "PlayAuth", "play_auth", "PlayAuthToken"]),
        url,
    })
}

/// video_model（JSON 字符串或对象）→ video_list 原始数组
fn qs_list_from_video_model(vm_val: &serde_json::Value) -> Vec<serde_json::Value> {
    for pointer in ["/video_list", "/VideoList", "/data/play_info_list", "/PlayInfoList"] {
        if let Some(list) = vm_val.pointer(pointer).and_then(|v| v.as_array()) {
            return list.clone();
        }
    }
    Vec::new()
}

/// 从 track_v2 响应提取播放档列表（video_model 主路径）
fn qs_extract_play_list(payload: &serde_json::Value) -> Vec<QsPlayEntry> {
    let vm = payload
        .pointer("/track_player/video_model")
        .or_else(|| payload.pointer("/trackPlayer/videoModel"))
        .or_else(|| payload.pointer("/data/track_player/video_model"));
    let Some(vm) = vm else {
        return Vec::new();
    };
    let vm_val: serde_json::Value = match vm {
        serde_json::Value::String(s) if !s.trim().is_empty() => match serde_json::from_str(s) {
            Ok(v) => v,
            Err(_) => return Vec::new(),
        },
        other => other.clone(),
    };
    qs_list_from_video_model(&vm_val)
        .iter()
        .filter_map(qs_normalize_play_entry)
        .collect()
}

/// 兜底：url_player_info（Vod GetPlayInfo）拉取播放档列表
async fn qs_fetch_play_list_via_player_info(url_player_info: &str) -> Vec<QsPlayEntry> {
    let Ok(result) = http_get_json(url_player_info, &[("User-Agent", QS_UA)]).await else {
        return Vec::new();
    };
    for pointer in [
        "/Result/Data/PlayInfoList",
        "/result/data/play_info_list",
        "/PlayInfoList",
    ] {
        if let Some(list) = result.pointer(pointer).and_then(|v| v.as_array()) {
            let out: Vec<QsPlayEntry> =
                list.iter().filter_map(qs_normalize_play_entry).collect();
            if !out.is_empty() {
                return out;
            }
        }
    }
    Vec::new()
}

/// 汽水品质 → pickPlayInfo 同款 rank（flac/hires=100，spatial/highest=90，higher/320=80，medium=40）
fn qs_quality_rank(q: &str) -> u32 {
    let s = q.to_lowercase();
    if s.contains("lossless") || s.contains("flac") || s.contains("hi_res") || s.contains("hires") {
        100
    } else if s.contains("spatial") || s.contains("highest") || s.contains("atmos") {
        90
    } else if s.contains("higher") || s.contains("exhigh") || s == "320" {
        80
    } else if s.contains("medium") || s.contains("standard") || s == "128" {
        40
    } else {
        20
    }
}

fn lx_quality_rank(q: &str) -> u32 {
    match q {
        "flac" | "hires" => 100,
        "spatial" => 90,
        "320k" => 80,
        "192k" => 60,
        "128k" => 40,
        _ => 40,
    }
}

fn qs_payload_from(e: &QsPlayEntry, quality: &str) -> QsPlayPayload {
    QsPlayPayload {
        url: e.url.clone(),
        quality: quality.to_string(),
        bitrate: e.bitrate,
        size: e.size,
        play_auth: e.play_auth.clone(),
    }
}

/// 品质选择：请求档精确命中 → rank 不高于请求档的最高者（并列取大 size）→ 全高于则取最低档
pub(crate) fn qs_pick_play_info(list: &[QsPlayEntry], want_lx: &str) -> Option<QsPlayPayload> {
    if list.is_empty() {
        return None;
    }
    if let Some(e) = list
        .iter()
        .find(|e| qs_quality_type(&e.quality) == Some(want_lx))
    {
        return Some(qs_payload_from(e, want_lx));
    }
    let want_rank = lx_quality_rank(want_lx);
    let mut candidates: Vec<&QsPlayEntry> = list
        .iter()
        .filter(|e| qs_quality_rank(&e.quality) <= want_rank)
        .collect();
    if !candidates.is_empty() {
        candidates.sort_by(|a, b| {
            qs_quality_rank(&b.quality)
                .cmp(&qs_quality_rank(&a.quality))
                .then(b.size.cmp(&a.size))
        });
        let e = candidates[0];
        return Some(qs_payload_from(
            e,
            qs_quality_type(&e.quality).unwrap_or(want_lx),
        ));
    }
    let mut all: Vec<&QsPlayEntry> = list.iter().collect();
    all.sort_by(|a, b| {
        qs_quality_rank(&a.quality)
            .cmp(&qs_quality_rank(&b.quality))
            .then(a.size.cmp(&b.size))
    });
    let e = all[0];
    Some(qs_payload_from(
        e,
        qs_quality_type(&e.quality).unwrap_or(want_lx),
    ))
}

// ==================== PlayAuth → CEK（spade 算法） ====================

fn spade_decode_base36(c: u8) -> Option<u8> {
    match c {
        b'0'..=b'9' => Some(c - b'0'),
        b'a'..=b'z' => Some(c - b'a' + 10),
        _ => None,
    }
}

/// spade 内层变换（lyms decryptSpadeInner 逐行对齐）：
/// buff = [0xfa,0x55] ++ inner；tmp[i] = wrap255((inner[i] ^ buff[i]) - popcount(i) - 21)
fn spade_inner_transform(inner: &[u8]) -> Vec<u8> {
    let mut out = vec![0u8; inner.len()];
    for (i, slot) in out.iter_mut().enumerate() {
        let buff_i = match i {
            0 => 0xfa,
            1 => 0x55,
            _ => inner[i - 2],
        };
        let mut v = (inner[i] ^ buff_i) as i32 - (i as u32).count_ones() as i32 - 21;
        while v < 0 {
            v += 255;
        }
        *slot = (v & 0xff) as u8;
    }
    out
}

/// PlayAuth（base64，来自 encrypt_info.spade_a）→ CENC 内容密钥（32 位 hex 字符串）。
/// 解出失败返回 Err，调用方应丢弃 cek 走换源，不影响其他源。
pub(crate) fn qs_play_auth_to_cek(play_auth: &str) -> Result<String, String> {
    use base64::Engine;
    let bin = base64::engine::general_purpose::STANDARD
        .decode(play_auth.trim())
        .map_err(|e| format!("QS playAuth base64 解码失败: {}", e))?;
    if bin.len() < 3 {
        return Err("QS playAuth 过短".into());
    }
    let padding = ((bin[0] ^ bin[1] ^ bin[2]) as i32) - 48;
    if padding < 0 || bin.len() < padding as usize + 2 {
        return Err("QS playAuth padding 非法".into());
    }
    let inner = &bin[1..bin.len() - padding as usize];
    let tmp = spade_inner_transform(inner);
    if tmp.is_empty() {
        return Err("QS spade 变换输出为空".into());
    }
    let skip = spade_decode_base36(tmp[0])
        .ok_or_else(|| "QS playAuth 头部非法".to_string())? as i64;
    // lyms: endIndex = 1 + (binary.length - paddingLen - 2) - skipBytes，
    // 其中 binary.length - paddingLen = 1 + inner.len，故 end = inner.len - skip
    let end = inner.len() as i64 - skip;
    if end < 1 || end as usize > tmp.len() {
        return Err("QS playAuth 密钥区间越界".into());
    }
    String::from_utf8(tmp[1..end as usize].to_vec())
        .map_err(|e| format!("QS CEK 非法 UTF-8: {}", e))
}

/// 汽水原生取流：track_v2 → video_model 档列表（url_player_info 兜底）→ 按请求品质选档。
/// 返回的 play_auth 由调用方用 qs_play_auth_to_cek 解为 CEK 交给播放器 CENC 通道。
pub(crate) async fn qs_resolve_play(
    track_id: &str,
    quality: &str,
) -> Result<QsPlayPayload, String> {
    let track_id = track_id.trim();
    if track_id.is_empty() {
        return Err("QS play: track_id required".into());
    }
    let body = serde_json::json!({
        "media_type": "track",
        "queue_type": "search_one_track",
        "scene_name": "search",
        "track_id": track_id,
    });
    let url = format!("https://api.qishui.com/luna/pc/track_v2?{}", QS_PC_QUERY);
    let payload = http_post_json(
        &url,
        &body.to_string(),
        &[
            ("User-Agent", QS_UA),
            ("Content-Type", "application/json; charset=utf-8"),
        ],
    )
    .await?;

    let mut list = qs_extract_play_list(&payload);
    if list.is_empty() {
        if let Some(info) = payload
            .pointer("/track_player/url_player_info")
            .and_then(|v| v.as_str())
        {
            if !info.is_empty() {
                list = qs_fetch_play_list_via_player_info(info).await;
            }
        }
    }

    qs_pick_play_info(&list, quality)
        .ok_or_else(|| format!("QS play: no playable stream for track {}", track_id))
}

/// 汽水搜索：综合搜索每关键词仅少量歌曲，滚动全局流凑满 limit（不足即上游耗尽）
pub(crate) async fn search_qs(keyword: &str, limit: u32) -> Result<Vec<LxSearchItem>, String> {
    let want = limit.max(1);
    let mut collected: Vec<LxSearchItem> = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for round in 0..QS_MAX_FETCHES {
        let page = qs_fetch_tracks(keyword, round * QS_CURSOR_STEP).await?;
        if page.is_empty() {
            break;
        }
        for it in page {
            if seen.insert(it.songmid.clone()) {
                collected.push(it);
            }
        }
        if collected.len() as u32 >= want {
            break;
        }
    }
    if collected.is_empty() {
        return Err("QS search: no results".to_string());
    }
    Ok(collected)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_qs_quality_type() {
        assert_eq!(qs_quality_type("medium"), Some("128k"));
        assert_eq!(qs_quality_type("highest"), Some("320k"));
        assert_eq!(qs_quality_type("lossless"), Some("flac"));
        assert_eq!(qs_quality_type("spatial"), Some("spatial"));
        assert_eq!(qs_quality_type("hi_res"), Some("hires"));
        assert_eq!(qs_quality_type("higher"), None);
    }

    #[test]
    fn test_qs_item_from_track() {
        let raw = serde_json::json!({
            "id": "7157130433749059585",
            "name": "晴天",
            "duration": 238098,
            "artists": [{"name": "周杰伦"}],
            "album": {"id": "7157130433149274113", "name": "叶惠美", "url_cover": {
                "uri": "tos-cn-v-2774c002/abc",
                "urls": ["https://p3-luna.douyinpic.com/img/"],
                "template_prefix": "tplv-b829550vbb"
            }},
            "bit_rates": [
                {"br": 66135, "size": 1968355, "quality": "medium"},
                {"br": 132203, "size": 3934689, "quality": "higher"},
                {"br": 260239, "size": 7745354, "quality": "highest"},
                {"br": 971164, "size": 28904158, "quality": "lossless"},
                {"br": 324229, "size": 9650744, "quality": "spatial"},
                {"br": 283951, "size": 8451542, "quality": "hi_res"}
            ]
        });
        let it = qs_item_from_track(&raw).unwrap();
        assert_eq!(it.songmid, "7157130433749059585");
        assert_eq!(it.name, "晴天");
        assert_eq!(it.singer, "周杰伦");
        assert_eq!(it.album_name, "叶惠美");
        assert_eq!(it.source, "qs");
        assert_eq!(it.interval, "03:58");
        let types: Vec<&str> = it.types.iter().map(|t| t.quality_type.as_str()).collect();
        // higher(192k) 无 LX 对应被跳过，其余保持上游顺序
        assert_eq!(types, vec!["128k", "320k", "flac", "spatial", "hires"]);
        assert!(it.img.is_some());
    }

    #[test]
    fn test_qs_item_from_track_skips_empty_id() {
        let raw = serde_json::json!({"id": "", "name": "x"});
        assert!(qs_item_from_track(&raw).is_none());
    }

    // ===== spade PlayAuth → CEK =====

    /// 测试专用：由期望明文逆推 spade 内层（decode 的逆运算，选 x=(t+c) mod 255）
    #[cfg(test)]
    fn spade_encode_for_test(payload: &[u8]) -> Vec<u8> {
        let mut inner = vec![0u8; payload.len()];
        for i in 0..payload.len() {
            let c = (i as u32).count_ones() as i32 + 21;
            let buff_i = match i {
                0 => 0xfa,
                1 => 0x55,
                _ => inner[i - 2],
            };
            let x = ((payload[i] as i32 + c) % 255) as u8;
            inner[i] = x ^ buff_i;
        }
        inner
    }

    /// 构造合法 playAuth：bin = [b0] ++ spade(inner) ++ padding，其中
    /// b0^inner[0]^inner[1] = 48+padding，inner 解码后 = [skip_char] ++ key_hex ++ [冗余]
    #[cfg(test)]
    fn make_play_auth(key_hex: &str, skip_char: u8, padding: usize) -> String {
        use base64::Engine;
        let mut payload = vec![skip_char];
        payload.extend_from_slice(key_hex.as_bytes());
        payload.push(b'0');
        let inner = spade_encode_for_test(&payload);
        let b0 = ((48 + padding) as u8) ^ inner[0] ^ inner[1];
        let mut bin = vec![b0];
        bin.extend_from_slice(&inner);
        bin.extend(std::iter::repeat(0xAAu8).take(padding));
        base64::engine::general_purpose::STANDARD.encode(bin)
    }

    #[test]
    fn test_spade_roundtrip() {
        let key = "a1b2c3d4e5f60718293a4b5c6d7e8f90";
        let auth = make_play_auth(key, b'0', 0);
        // endIndex 公式会带上 payload 末尾 1 字节冗余（真实 playAuth 同构）
        assert_eq!(qs_play_auth_to_cek(&auth).unwrap(), format!("{}0", key));
    }

    #[test]
    fn test_spade_roundtrip_with_padding() {
        let key = "0123456789abcdef0123456789abcdef";
        let auth = make_play_auth(key, b'0', 5);
        assert_eq!(qs_play_auth_to_cek(&auth).unwrap(), format!("{}0", key));
    }

    #[test]
    fn test_spade_fixed_vector() {
        // 用 ly-music-source decrypt.js extractKeyFromPlayAuth 实际运行生成的固定向量
        assert_eq!(
            qs_play_auth_to_cek("rb8i+FuwIfpdsCH8X7EX/l2wFOBfmBPiXZgT5EOZEuZBoAY=").unwrap(),
            "a1b2c3d4e5f60718293a4b5c6d7e8f900"
        );
        assert_eq!(
            qs_play_auth_to_cek("mb8T+FqxEf1fsBDgaZkS5WyZK9Fhmy3WYpgyyUizNM5Lsgyqqqqqqg==")
                .unwrap(),
            "0123456789abcdef0123456789abcdef0"
        );
    }

    #[test]
    fn test_spade_invalid() {
        assert!(qs_play_auth_to_cek("").is_err());
        assert!(qs_play_auth_to_cek("!!!").is_err());
        assert!(qs_play_auth_to_cek(&base64_encode_raw(&[0x00, 0x01])).is_err());
    }

    fn base64_encode_raw(data: &[u8]) -> String {
        use base64::Engine;
        base64::engine::general_purpose::STANDARD.encode(data)
    }

    // ===== 品质选择 =====

    fn entry(quality: &str, size: u64, auth: &str) -> QsPlayEntry {
        QsPlayEntry {
            url: format!("https://stream/{}", quality),
            quality: quality.into(),
            bitrate: 0,
            size,
            play_auth: auth.into(),
        }
    }

    #[test]
    fn test_pick_exact_match() {
        let list = vec![
            entry("medium", 100, ""),
            entry("lossless", 400, "AUTH"),
            entry("highest", 200, ""),
        ];
        let p = qs_pick_play_info(&list, "flac").unwrap();
        assert_eq!(p.quality, "flac");
        assert_eq!(p.play_auth, "AUTH");
    }

    #[test]
    fn test_pick_lower_fallback() {
        // 请求 flac 无 lossless → spatial(90)/highest(90) 并列取大 size
        let list = vec![
            entry("medium", 100, ""),
            entry("spatial", 300, "SPATIAL"),
            entry("highest", 350, "HIGHEST"),
        ];
        let p = qs_pick_play_info(&list, "flac").unwrap();
        assert_eq!(p.quality, "320k");
        assert_eq!(p.play_auth, "HIGHEST");
    }

    #[test]
    fn test_pick_all_above_takes_lowest() {
        let list = vec![entry("hi_res", 500, "HIRES"), entry("lossless", 400, "LL")];
        let p = qs_pick_play_info(&list, "128k").unwrap();
        assert_eq!(p.quality, "flac");
        assert_eq!(p.play_auth, "LL");
    }

    #[test]
    fn test_pick_empty() {
        assert!(qs_pick_play_info(&[], "320k").is_none());
    }

    // ===== track_v2 响应解析 =====

    #[test]
    fn test_extract_play_list_from_video_model_string() {
        let vm = serde_json::json!({
            "video_list": [
                {
                    "main_url": "https://s/hi",
                    "video_meta": {"quality": "hi_res", "bitrate": 283951, "size": 8451542},
                    "encrypt_info": {"spade_a": "SPADE_A"}
                },
                {"main_url": "https://s/med", "video_meta": {"quality": "medium"}},
                {"main_url": "", "video_meta": {"quality": "higher"}}
            ]
        });
        let payload = serde_json::json!({ "track_player": { "video_model": vm.to_string() } });
        let list = qs_extract_play_list(&payload);
        assert_eq!(list.len(), 2);
        assert_eq!(list[0].url, "https://s/hi");
        assert_eq!(list[0].quality, "hi_res");
        assert_eq!(list[0].play_auth, "SPADE_A");
        assert_eq!(list[1].bitrate, 0);
    }

    #[test]
    fn test_extract_play_list_pascal_case_and_object() {
        let payload = serde_json::json!({
            "trackPlayer": {
                "videoModel": {
                    "VideoList": [
                        {
                            "MainPlayUrl": "https://s/pascal",
                            "VideoMeta": {"Quality": "lossless", "Size": 123},
                            "EncryptInfo": {"PlayAuth": "PA"}
                        }
                    ]
                }
            }
        });
        let list = qs_extract_play_list(&payload);
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].url, "https://s/pascal");
        assert_eq!(list[0].quality, "lossless");
        assert_eq!(list[0].play_auth, "PA");
        // 请求 hires 无精确档 → 选 rank≤100 的最高档 lossless，品质报实际档位
        let p = qs_pick_play_info(&list, "hires").unwrap();
        assert_eq!(p.quality, "flac");
    }

    #[test]
    fn test_normalize_backup_url() {
        let list = qs_extract_play_list(&serde_json::json!({
            "track_player": { "video_model": serde_json::json!({
                "video_list": [{ "backup_url": "https://s/bk", "video_meta": {"quality": "medium"} }]
            }).to_string() }
        }));
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].url, "https://s/bk");
    }
}
