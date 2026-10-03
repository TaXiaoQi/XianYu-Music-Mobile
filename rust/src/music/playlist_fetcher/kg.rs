// 歌单导入酷狗平台实现：自前端 playlistImportKg.ts 移植（内置主链路）。

use std::collections::{HashMap, HashSet};
use std::sync::OnceLock;
use std::time::{SystemTime, UNIX_EPOCH};

use regex::Regex;
use serde_json::{json, Value};

use super::common::{
    decode_name, format_play_time, http_fetch_json, percent_encode_component, PlaylistInfo,
    PlaylistImportResult, PlaylistSong,
};

// ==================== 懒编译正则（对齐 TS 模块级字面量） ====================

/// 定义 `fn 名字() -> &'static Regex` 形式的懒编译正则访问器
macro_rules! lazy_re {
    ($getter:ident, $pattern:literal) => {
        fn $getter() -> &'static Regex {
            static RE: OnceLock<Regex> = OnceLock::new();
            RE.get_or_init(|| Regex::new($pattern).unwrap())
        }
    };
}

// kgGcidRegex / kgRegex1 / kgRegex2（playlistImportBase.ts 随迁）
lazy_re!(kg_gcid_re, r"gcid_(\w+)");
lazy_re!(kg_regex1_re, r"/(\d+)\.html(?:\?.*|&.*$|#.*$|$)");
lazy_re!(kg_regex2_re, r"/special/(?:single/)?(\d+)");
lazy_re!(kg_query_chars_re, r"[?&:/]");
lazy_re!(kg_pure_numeric_re, r"^\d+$");
lazy_re!(kg_numeric_1_32_re, r"^\d{1,32}$");
// global_collection_id=(\w+)（主流程分发）
lazy_re!(kg_global_collection_re, r"global_collection_id=(\w+)");
// v9 页面 global.data = [...] 与 global = {...} 提取（(?s) 跨行，对齐 [\s\S]）
lazy_re!(kg_global_data_re, r"(?s)global\.data\s*=\s*(\[.+]);");
lazy_re!(
    kg_list_info_re,
    r#"(?s)global\s*=\s*\{.+?name:\s*"(.+?)".+?pic:\s*"(.+?)".+?};"#
);
// 分享链接 gcid 提取（resolveKgShareUrl 依次匹配）
lazy_re!(
    kg_share_gcol_re,
    r#"global_collection_id["']?\s*[:=]\s*["']?(\w+)"#
);
lazy_re!(kg_encode_gic_quoted_re, r#""encode_gic"\s*:\s*"(\w+)""#);
lazy_re!(
    kg_encode_src_gid_quoted_re,
    r#""encode_src_gid"\s*:\s*"(\w+)""#
);
lazy_re!(kg_encode_gic_re, r#"encode_gic["']?\s*[:=]\s*["']?(\w+)"#);
lazy_re!(kg_encode_src_gid_re, r#"encode_src_gid["']?\s*[:=]\s*["']?(\w+)"#);

// ==================== 常量 ====================

/// v2/album_audio/audio 批量详情接口（enrich 封面 / getKgMusicInfos 共用）
const KG_AUDIO_GATEWAY_URL: &str = "http://gateway.kugou.com/v2/album_audio/audio";
const KG_AUDIO_HEADERS: [(&str, &str); 7] = [
    ("KG-THash", "13a3164"),
    ("KG-RC", "1"),
    ("KG-Fake", "0"),
    ("KG-RF", "00869891"),
    (
        "User-Agent",
        "Android712-AndroidPhone-11451-376-0-FeeCacheUpdate-wifi",
    ),
    ("x-router", "kmr.service.kugou.com"),
    ("Content-Type", "application/json"),
];

// ==================== TS 语义小工具 ====================

/// JS 真值判断：null/false/0/'' 为假，其余（含空数组/空对象）为真
fn js_truthy(v: &Value) -> bool {
    match v {
        Value::Null => false,
        Value::Bool(b) => *b,
        Value::Number(n) => n.as_f64().map(|f| f != 0.0).unwrap_or(false),
        Value::String(s) => !s.is_empty(),
        _ => true,
    }
}

/// TS `String(v ?? '')`：nullish → ''，其余按 JS String() 语义转字符串
fn ts_string(v: Option<&Value>) -> String {
    match v {
        None | Some(Value::Null) => String::new(),
        Some(Value::String(s)) => s.clone(),
        Some(Value::Number(n)) => n.to_string(),
        Some(Value::Bool(b)) => b.to_string(),
        Some(other) => other.to_string(),
    }
}

/// TS `v || ''`：falsy → ''，truthy 值按 String() 语义转字符串
fn truthy_str(v: Option<&Value>) -> String {
    match v {
        Some(x) if js_truthy(x) => ts_string(Some(x)),
        _ => String::new(),
    }
}

/// TS `Number(v)`：数字原样、字符串解析（空/空白串 → 0，非数字 → NaN）、布尔 0/1
fn ts_number(v: &Value) -> f64 {
    match v {
        Value::Number(n) => n.as_f64().unwrap_or(f64::NAN),
        Value::String(s) => {
            let t = s.trim();
            if t.is_empty() {
                0.0
            } else {
                t.parse::<f64>().unwrap_or(f64::NAN)
            }
        }
        Value::Bool(b) => {
            if *b {
                1.0
            } else {
                0.0
            }
        }
        Value::Null => 0.0,
        _ => f64::NAN,
    }
}

/// TS `a ?? b ?? c ?? -1`：返回第一个非 nullish 的值（全部缺失 → -1）
fn nullish_chain_value(body: &Value, keys: &[&str]) -> Value {
    for k in keys {
        if let Some(v) = body.get(k) {
            if !v.is_null() {
                return v.clone();
            }
        }
    }
    json!(-1)
}

/// TS 严格比较 `!== 0`：仅 JSON 数字 0 视为通过（字符串 "0" 不算）
fn is_strict_zero(v: &Value) -> bool {
    matches!(v, Value::Number(n) if n.as_f64() == Some(0.0))
}

/// TS 模板串插值 `${errCode}`：字符串原样，其余按 JSON 文本
fn js_display(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        other => other.to_string(),
    }
}

/// TS `a || b || c`（truthy 链）：返回第一个 truthy 的 JSON 值
fn first_truthy<'a>(vals: &[Option<&'a Value>]) -> Option<&'a Value> {
    for v in vals {
        if let Some(x) = v {
            if js_truthy(x) {
                return Some(x);
            }
        }
    }
    None
}

/// TS Date.now()：当前毫秒时间戳
fn now_millis() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64
}

// ==================== 主流程（对齐 getListDetailKg） ====================

/// 酷狗歌单导入入口
pub(super) async fn get_list_detail_kg(raw_id: &str) -> Result<PlaylistImportResult, String> {
    if raw_id.contains("gcid_") {
        return get_kg_list_detail_by_gcid(raw_id).await;
    }
    if raw_id.contains("global_collection_id") {
        if let Some(caps) = kg_global_collection_re().captures(raw_id) {
            if let Some(m) = caps.get(1) {
                if !m.as_str().is_empty() {
                    return get_kg_gcid_detail(m.as_str()).await;
                }
            }
        }
    }
    // 纯数字酷狗码：先 t.kugou.com/command 反查（gcid → gateway 全量，
    // 对齐移动端 kg_sheet_import），反查失败再当 specialid 走 v9 页面
    let trimmed = raw_id.trim();
    if kg_numeric_1_32_re().is_match(trimmed) {
        match get_kg_list_detail_by_code(trimmed).await {
            Ok(Some(by_code)) if !by_code.songs.is_empty() => return Ok(by_code),
            Ok(_) => {}
            Err(e) => eprintln!("[playlist_fetcher] getListDetailKg: command 反查失败: {}", e),
        }
    }
    let id = get_kg_list_id(raw_id);
    if id.is_none() && (raw_id.starts_with("http://") || raw_id.starts_with("https://")) {
        if let Some(gcid) = resolve_kg_share_url(raw_id).await {
            return get_kg_user_list_detail2(&gcid).await;
        }
    }
    let Some(id) = id else {
        return Ok(PlaylistImportResult::empty("kg"));
    };

    // v9 歌单页
    let url = format!(
        "https://www2.kugou.kugou.com/yueku/v9/special/single/{id}-5-9999.html"
    );
    let resp = http_fetch_json(&url, "GET", &[], None, None).await?;
    let body = resp.text.as_str();

    let Some(list_caps) = kg_global_data_re().captures(body) else {
        return Ok(PlaylistImportResult::empty("kg"));
    };
    let list_json = list_caps.get(1).map(|m| m.as_str()).unwrap_or("");
    let list_arr: Vec<Value> = match serde_json::from_str(list_json) {
        Ok(v) => v,
        Err(_) => return Ok(PlaylistImportResult::empty("kg")),
    };

    let mut songs: Vec<PlaylistSong> = Vec::new();
    for item in &list_arr {
        if let Some(parsed) = parse_kg_song(item) {
            songs.push(parsed);
        }
    }

    let info = match kg_list_info_re().captures(body) {
        Some(caps) => PlaylistInfo {
            name: decode_name(caps.get(1).map(|m| m.as_str()).unwrap_or("")),
            img: caps.get(2).map(|m| m.as_str()).unwrap_or("").to_string(),
            desc: String::new(),
            author: String::new(),
            play_count: String::new(),
        },
        None => PlaylistInfo::default(),
    };

    let total = songs.len() as i64;
    Ok(PlaylistImportResult {
        source: "kg".to_string(),
        songs,
        total,
        info,
    })
}

// ==================== ID 归一化（对齐 playlistImportBase.getKgListId） ====================

/// 酷狗歌单 ID 提取：.html 链接 / special 路径 / id_ 前缀 / 纯数字
fn get_kg_list_id(raw_id: &str) -> Option<String> {
    let id = raw_id;
    if id.contains(".html") {
        if let Some(caps) = kg_regex1_re().captures(id) {
            if let Some(m) = caps.get(1) {
                return Some(m.as_str().to_string());
            }
        }
    }
    if id.contains("special/") {
        if let Some(caps) = kg_regex2_re().captures(id) {
            if let Some(m) = caps.get(1) {
                return Some(m.as_str().to_string());
            }
        }
    }
    if kg_query_chars_re().is_match(id) {
        if let Some(caps) = kg_regex2_re().captures(id) {
            if let Some(m) = caps.get(1) {
                return Some(m.as_str().to_string());
            }
        }
        return None;
    }
    if id.starts_with("id_") {
        return Some(id[3..].to_string());
    }
    if kg_pure_numeric_re().is_match(id) {
        return Some(id.to_string());
    }
    None
}

/// v9/分页条目 → PlaylistSong（对齐 parseKgSong）
fn parse_kg_song(item: &Value) -> Option<PlaylistSong> {
    let hash = truthy_str(item.get("hash"));
    let audio_id = ts_string(item.get("audio_id").filter(|v| !v.is_null()));
    if hash.is_empty() && audio_id.is_empty() {
        return None;
    }

    let singer_name = decode_name(&truthy_str(item.get("singername")));
    let songname = decode_name(&truthy_str(item.get("songname")));
    let album_name = decode_name(&truthy_str(item.get("album_name")));
    let duration_f = match item.get("duration") {
        Some(v) if js_truthy(v) => ts_number(v),
        _ => 0.0,
    };
    let duration_ms = duration_f as i64;

    let song_id_str = if !audio_id.is_empty() {
        audio_id.clone()
    } else {
        hash.clone()
    };
    let mut raw = json!({
        "songmid": song_id_str,
        "name": songname,
        "singer": singer_name,
        "source": "kg",
        "interval": format_play_time((duration_f / 1000.0).floor()),
    });
    if !hash.is_empty() {
        raw["hash"] = json!(hash);
    }

    Some(PlaylistSong::new(
        &song_id_str,
        &songname,
        &singer_name,
        &album_name,
        "",
        duration_ms,
        "酷狗",
        "kg",
        raw,
    ))
}

// ==================== gcid 链路 ====================

/// 对齐 getKgListDetailByGcid
async fn get_kg_list_detail_by_gcid(raw_id: &str) -> Result<PlaylistImportResult, String> {
    let mut global_collection_id: Option<String> = None;

    if let Some(caps) = kg_gcid_re().captures(raw_id) {
        if let Some(m) = caps.get(1) {
            let gcid = format!("gcid_{}", m.as_str());
            match decode_gcid(&gcid).await {
                Ok(g) => global_collection_id = Some(g),
                Err(e) => eprintln!(
                    "[playlist_fetcher] getKgListDetailByGcid: decodeGcid failed: {}",
                    e
                ),
            }
        }
    }

    if global_collection_id.is_none()
        && (raw_id.starts_with("http://") || raw_id.starts_with("https://"))
    {
        global_collection_id = resolve_kg_share_url(raw_id).await;
    }

    match global_collection_id {
        Some(g) => get_kg_gcid_detail(&g).await,
        None => Ok(PlaylistImportResult::empty("kg")),
    }
}

/// 对齐 resolveKgShareUrl：分享链接 → global_collection_id
async fn resolve_kg_share_url(url: &str) -> Option<String> {
    let resp = match http_fetch_json(
        url,
        "GET",
        &[
            (
                "User-Agent",
                "Mozilla/5.0 (iPhone; CPU iPhone OS 9_1 like Mac OS X) AppleWebKit/601.1.46 (KHTML, like Gecko) Version/9.0 Mobile/13B143 Safari/601.1",
            ),
            ("Referer", url),
        ],
        None,
        None,
    )
    .await
    {
        Ok(r) => r,
        Err(e) => {
            eprintln!("[playlist_fetcher] resolveKgShareUrl failed: {}", e);
            return None;
        }
    };
    // TS：typeof resp.body === 'string' ? resp.body : JSON.stringify(resp.body)
    let body = match &resp.body {
        Value::String(s) => s.clone(),
        other => other.to_string(),
    };
    if body.is_empty() {
        return None;
    }

    if let Some(caps) = kg_share_gcol_re().captures(&body) {
        if let Some(m) = caps.get(1) {
            if !m.as_str().is_empty() {
                return Some(m.as_str().to_string());
            }
        }
    }

    let gcid = kg_encode_gic_quoted_re()
        .captures(&body)
        .or_else(|| kg_encode_src_gid_quoted_re().captures(&body))
        .or_else(|| kg_encode_gic_re().captures(&body))
        .or_else(|| kg_encode_src_gid_re().captures(&body))
        .and_then(|c| c.get(1).map(|m| m.as_str().to_string()));

    if let Some(g) = gcid {
        match decode_gcid(&format!("gcid_{g}")).await {
            Ok(v) => return Some(v),
            Err(e) => eprintln!(
                "[playlist_fetcher] resolveKgShareUrl: decodeGcid({}) failed: {}",
                g, e
            ),
        }
    }

    None
}

/// 对齐 decodeGcid：gcid 短码 → global_collection_id
async fn decode_gcid(gcid: &str) -> Result<String, String> {
    let params = "dfid=-&appid=1005&mid=0&clientver=20109&clienttime=640612895&uuid=-";
    let body_str = format!(r#"{{"ret_info":1,"data":[{{"id":"{gcid}","id_type":2}}]}}"#);
    let signature = crate::host_crypto::kugou_sign(params, "android", &body_str);
    let url = format!("https://t.kugou.com/v1/songlist/batch_decode?{params}&signature={signature}");

    let resp = http_fetch_json(
        &url,
        "POST",
        &[
            (
                "User-Agent",
                "Mozilla/5.0 (Linux; Android 10; HUAWEI HMA-AL00) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/83.0.4103.106 Mobile Safari/537.36",
            ),
            ("Referer", "https://m.kugou.com/"),
            ("Content-Type", "application/json"),
        ],
        Some(&body_str),
        None,
    )
    .await?;

    let body = resp.body;
    if !body.is_object() {
        return Err("decodeGcid: response not JSON".to_string());
    }

    let err_code = nullish_chain_value(&body, &["error_code", "errcode", "err_code"]);
    if !is_strict_zero(&err_code) {
        return Err(format!("decodeGcid failed: errcode={}", js_display(&err_code)));
    }

    // body.data?.list || body.list || body.info?.list || body.data?.info
    let list_v = body
        .pointer("/data/list")
        .filter(|v| js_truthy(v))
        .or_else(|| body.get("list").filter(|v| js_truthy(v)))
        .or_else(|| body.pointer("/info/list").filter(|v| js_truthy(v)))
        .or_else(|| body.pointer("/data/info").filter(|v| js_truthy(v)))
        .cloned()
        .unwrap_or(Value::Null);
    let Some(list) = list_v.as_array().filter(|a| !a.is_empty()) else {
        return Err("decodeGcid: missing or empty list".to_string());
    };

    let first = &list[0];
    let gcol = match first_truthy(&[first.get("global_collection_id")]) {
        Some(v) => ts_string(Some(v)),
        None => ts_string(first.get("global_specialid").filter(|v| js_truthy(v))),
    };
    if gcol.is_empty() {
        return Err("decodeGcid: missing global_collection_id".to_string());
    }

    Ok(gcol)
}

// ==================== song_v2 全量（对齐 getKgUserListDetail2） ====================

/// 对齐 getKgUserListDetail2：global_collection_id → info_v2 + song_v2 分页
async fn get_kg_user_list_detail2(
    global_collection_id: &str,
) -> Result<PlaylistImportResult, String> {
    if global_collection_id.len() > 1000 {
        return Ok(PlaylistImportResult::empty("kg"));
    }

    let id = global_collection_id;
    let common_headers: [(&str, &str); 5] = [
        ("mid", "1586163242519"),
        ("Referer", "https://m3ws.kugou.com/share/index.php"),
        (
            "User-Agent",
            "Mozilla/5.0 (iPhone; CPU iPhone OS 11_0 like Mac OS X) AppleWebKit/604.1.38 (KHTML, like Gecko) Version/11.0 Mobile/15A372 Safari/604.1",
        ),
        ("dfid", "-"),
        ("clienttime", "1586163242519"),
    ];

    let info_params = format!(
        "appid=1058&specialid=0&global_specialid={id}&format=jsonp&srcappid=2919&clientver=20000&clienttime=1586163242519&mid=1586163242519&uuid=1586163242519&dfid=-"
    );
    let info_sig = crate::host_crypto::kugou_sign(&info_params, "web", "");
    let info_url = format!(
        "https://mobiles.kugou.com/api/v5/special/info_v2?{info_params}&signature={info_sig}"
    );
    let info_resp = http_fetch_json(&info_url, "GET", &common_headers, None, None).await?;
    let info_body = info_resp.body;
    if !info_body.is_object() {
        return Err("kg info_v2: response not JSON".to_string());
    }

    let err_code = nullish_chain_value(&info_body, &["error_code", "errcode", "err_code"]);
    if !is_strict_zero(&err_code) {
        return Err(format!(
            "kg info_v2 failed: errcode={}",
            js_display(&err_code)
        ));
    }

    // infoBody.data || infoBody
    let info = match info_body.get("data") {
        Some(d) if js_truthy(d) => d,
        _ => &info_body,
    };
    let song_count = match info.get("songcount") {
        Some(v) if js_truthy(v) => ts_number(v) as i64,
        _ => 0,
    };
    let playlist_name = decode_name(&truthy_str(info.get("specialname")));
    let playlist_img = truthy_str(info.get("imgurl")).replacen("{size}", "240", 1);
    let playlist_desc = decode_name(&truthy_str(info.get("intro")));
    let playlist_author = decode_name(&truthy_str(info.get("nickname")));

    let mut hash_list: Vec<Value> = Vec::new();
    let mut total = song_count;
    let mut p = 0;
    while total > 0 {
        let limit = total.min(300);
        total -= limit;
        p += 1;
        let song_params = format!(
            "appid=1058&global_specialid={id}&specialid=0&plat=0&version=8000&page={p}&pagesize={limit}&srcappid=2919&clientver=20000&clienttime=1586163263991&mid=1586163263991&uuid=1586163263991&dfid=-"
        );
        let song_sig = crate::host_crypto::kugou_sign(&song_params, "web", "");
        let song_url = format!(
            "https://mobiles.kugou.com/api/v5/special/song_v2?{song_params}&signature={song_sig}"
        );
        let song_resp = http_fetch_json(&song_url, "GET", &common_headers, None, None).await?;
        let song_body = song_resp.body;
        if !song_body.is_object() {
            break;
        }

        let s_err = nullish_chain_value(&song_body, &["error_code", "errcode", "err_code"]);
        if !is_strict_zero(&s_err) {
            break;
        }

        // songBody.data?.info || songBody.info || []
        let info_arr = song_body
            .pointer("/data/info")
            .filter(|v| js_truthy(v))
            .or_else(|| song_body.get("info").filter(|v| js_truthy(v)))
            .cloned()
            .unwrap_or_else(|| Value::Array(Vec::new()));
        if let Some(items) = info_arr.as_array() {
            for item in items {
                hash_list.push(item.clone());
            }
        }
    }

    let songs = get_kg_music_infos(hash_list).await;

    let info_obj = PlaylistInfo {
        name: playlist_name,
        img: playlist_img,
        desc: playlist_desc,
        author: playlist_author,
        play_count: String::new(),
    };
    let total = songs.len() as i64;
    Ok(PlaylistImportResult {
        source: "kg".to_string(),
        songs,
        total,
        info: info_obj,
    })
}

// ==================== gcid 歌单 gateway 分页（对齐移动端 kg_sheet_import） ====================

/// gcid 歌单优先走 gateway get_other_list_file_nofilt 分页全量
/// （gcid 类型歌单用 song_v2 分页会报「歌单分页数据异常」），
/// 失败回落 get_kg_user_list_detail2（老歌单仍可用）。
async fn get_kg_gcid_detail(gcol: &str) -> Result<PlaylistImportResult, String> {
    match get_kg_gcid_detail_by_gateway(gcol).await {
        Ok(gw) if !gw.songs.is_empty() => return Ok(gw),
        Ok(_) => {}
        Err(e) => eprintln!("[playlist_fetcher] getKgGcidDetail: gateway 分页失败: {}", e),
    }
    get_kg_user_list_detail2(gcol).await
}

/// gateway get_other_list_file_nofilt 条目去重键：hash|audio_id(或 album_audio_id，缺省 0)|name
fn gateway_dedup_key(item: &Value) -> String {
    let hash = ts_string(item.get("hash"));
    let num_part = match item.get("audio_id") {
        Some(v) if !v.is_null() => ts_string(Some(v)),
        _ => match item.get("album_audio_id") {
            Some(v) if !v.is_null() => ts_string(Some(v)),
            _ => "0".to_string(),
        },
    };
    format!("{hash}|{num_part}|{}", ts_string(item.get("name")))
}

/// 对齐 getKgGcidDetailByGateway（TS 返回 null 的场景以 Err 表达，由调用方记日志回落）
async fn get_kg_gcid_detail_by_gateway(gcol: &str) -> Result<PlaylistImportResult, String> {
    if gcol.len() > 1000 {
        return Err("kg gateway: global_collection_id too long".to_string());
    }

    let headers: [(&str, &str); 5] = [
        (
            "User-Agent",
            "Android15-1070-11083-46-0-DiscoveryDRADProtocol-wifi",
        ),
        ("kg-rc", "1"),
        ("kg-thash", "5d816a0"),
        ("kg-rec", "1"),
        ("kg-rf", "B9EDA08A64250DEFFBCADDEE00F8F25F"),
    ];

    let mut songs: Vec<PlaylistSong> = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();
    let mut begin_idx: i64 = 0;
    let mut total_count: i64 = -1;
    let mut page = 0;
    let mut name = String::new();
    let mut img = String::new();
    let mut author = String::new();

    while total_count < 0 || begin_idx < total_count {
        page += 1;
        if page > 10000 {
            return Err("kg gateway: 歌单分页超出合理范围".to_string());
        }
        let clienttime_sec = (now_millis() / 1000).to_string();
        let params = format!(
            "area_code=1&appid=1005&begin_idx={begin_idx}&clienttime={clienttime_sec}&clientver=20489&extend_fields=abtags,hot_cmt,popularization&global_collection_id={}&mode=1&pagesize=300&personal_switch=1&plat=1&type=1&uuid=-",
            percent_encode_component(gcol)
        );
        let signature = crate::host_crypto::kugou_sign(&params, "android", "");
        let url = format!(
            "https://gateway.kugou.com/pubsongs/v2/get_other_list_file_nofilt?{params}&signature={signature}"
        );
        let resp = http_fetch_json(&url, "GET", &headers, None, None).await?;
        let body = resp.body;
        if !body.is_object() {
            return Err("kg gateway: response not JSON".to_string());
        }
        let status_v = nullish_chain_value(&body, &["status", "err_code", "error_code"]);
        let status = ts_number(&status_v);
        if status != 1.0 {
            return Err(format!("kg gateway: status={}", js_display(&status_v)));
        }
        let data = match body.get("data") {
            Some(d) if d.is_object() || d.is_array() => d,
            _ => return Err("kg gateway: missing data".to_string()),
        };

        if let Some(li) = data.get("list_info").filter(|v| v.is_object()) {
            if name.is_empty() {
                name = decode_name(&ts_string(li.get("name")));
            }
            if img.is_empty() {
                img = ts_string(li.get("pic")).replacen("{size}", "400", 1);
            }
            if author.is_empty() {
                author = decode_name(&ts_string(li.get("list_create_username")));
            }
        }

        let page_songs: Vec<Value> = data
            .get("songs")
            .and_then(|v| v.as_array())
            .cloned()
            .unwrap_or_default();
        if page_songs.is_empty() {
            if total_count > 0 && begin_idx < total_count {
                return Err("kg gateway: 分页提前结束".to_string());
            }
            break;
        }
        // Number(data.count ?? 0) || 0
        let reported = {
            let v = data
                .get("count")
                .filter(|x| !x.is_null())
                .cloned()
                .unwrap_or_else(|| json!(0));
            let n = ts_number(&v);
            if n.is_nan() {
                0.0
            } else {
                n
            }
        };
        if reported as i64 > total_count {
            total_count = reported as i64;
        }
        let mut added = 0;
        for item in &page_songs {
            if !item.is_object() {
                continue;
            }
            if ts_string(item.get("hash")).is_empty() {
                continue;
            }
            let key = gateway_dedup_key(item);
            if !seen.insert(key) {
                continue;
            }
            if let Some(parsed) = parse_gateway_song(item) {
                songs.push(parsed);
                added += 1;
            }
        }
        if added <= 0 {
            return Err("kg gateway: 分页重复".to_string());
        }
        begin_idx += page_songs.len() as i64;
        if total_count < 0 && (page_songs.len() as i64) < 300 {
            break;
        }
    }

    if songs.is_empty() {
        return Err("kg gateway: no songs".to_string());
    }
    enrich_kg_gateway_covers(&mut songs).await;
    let total = songs.len() as i64;
    Ok(PlaylistImportResult {
        source: "kg".to_string(),
        songs,
        total,
        info: PlaylistInfo {
            name,
            img,
            desc: String::new(),
            author,
            play_count: String::new(),
        },
    })
}

/// gateway get_other_list_file_nofilt 条目 → PlaylistSong。
/// 对齐移动端 _formatGatewayItem：name 为「歌手 - 歌名」合并格式需拆分。
fn parse_gateway_song(item: &Value) -> Option<PlaylistSong> {
    let hash = ts_string(item.get("hash"));
    if hash.is_empty() {
        return None;
    }

    let raw_name = ts_string(item.get("name"));
    let mut artist = ts_string(item.get("singername"));
    let mut title = raw_name.clone();
    if raw_name.contains(" - ") {
        let parts: Vec<&str> = raw_name.split(" - ").collect();
        if artist.is_empty() {
            artist = parts[0].trim().to_string();
        }
        title = parts[1..].join(" - ").trim().to_string();
    }
    if title.is_empty() {
        let songname = truthy_str(item.get("songname"));
        title = if songname.is_empty() {
            raw_name.clone()
        } else {
            songname
        };
    }

    // String(item.audio_id ?? item.album_audio_id ?? '')
    let audio_id = match item.get("audio_id") {
        Some(v) if !v.is_null() => ts_string(Some(v)),
        _ => match item.get("album_audio_id") {
            Some(v) if !v.is_null() => ts_string(Some(v)),
            _ => String::new(),
        },
    };
    // Number(item.timelen ?? 0) || 0
    let timelen_f = match item.get("timelen") {
        Some(v) if !v.is_null() => ts_number(v),
        _ => 0.0,
    };
    let timelen_f = if timelen_f.is_nan() { 0.0 } else { timelen_f };
    let timelen = timelen_f as i64;
    // String(trans.union_cover ?? item.cover ?? '')（?? 仅跳过 nullish，空串不回落）
    let cover_url = {
        let union = item
            .get("trans_param")
            .and_then(|t| t.get("union_cover"))
            .filter(|v| !v.is_null());
        let cover_val = match union {
            Some(u) => Some(u.clone()),
            None => item.get("cover").filter(|v| !v.is_null()).cloned(),
        };
        ts_string(cover_val.as_ref()).replacen("{size}", "400", 1)
    };
    // String(item.albuminfo?.name ?? item.remark ?? '')
    let album_src = item
        .get("albuminfo")
        .and_then(|a| a.get("name"))
        .filter(|v| !v.is_null())
        .or_else(|| item.get("remark").filter(|v| !v.is_null()));
    let album_name = decode_name(&ts_string(album_src));

    let song_id_str = if !audio_id.is_empty() {
        audio_id.clone()
    } else {
        hash.clone()
    };
    let singer_display = if artist.is_empty() {
        "未知歌手".to_string()
    } else {
        artist.clone()
    };
    let mut raw = json!({
        "songmid": song_id_str,
        "name": title,
        "singer": singer_display,
        "source": "kg",
        "interval": format_play_time((timelen_f / 1000.0).floor()),
    });
    if !hash.is_empty() {
        raw["hash"] = json!(hash);
    }
    if !audio_id.is_empty() {
        raw["audioId"] = json!(audio_id);
    }

    Some(PlaylistSong::new(
        &song_id_str,
        &title,
        &singer_display,
        &album_name,
        &cover_url,
        timelen,
        "酷狗",
        "kg",
        raw,
    ))
}

/// gateway get_other_list_file_nofilt 条目只带 albuminfo（专辑名），不带封面
/// （union_cover/cover 常为空）。移动端展示态按 hash 懒解析所以看起来正常，
/// 桌面端必须在导入期落库：按 hash 批量走 v2/album_audio/audio 取
/// album_info.sizable_cover（100 首/批，签名链路与 get_kg_music_infos 一致）。
async fn enrich_kg_gateway_covers(songs: &mut [PlaylistSong]) {
    // 缺封面且带 hash 的条目索引（先收集，避免与并行任务借用冲突）
    let missing: Vec<(usize, String, String)> = songs
        .iter()
        .enumerate()
        .filter(|(_, s)| {
            s.cover_url.is_empty() && s.raw_data.get("hash").map(js_truthy).unwrap_or(false)
        })
        .map(|(i, s)| (i, ts_string(s.raw_data.get("hash")), s.title.clone()))
        .collect();
    if missing.is_empty() {
        return;
    }

    let mut handles = Vec::new();
    for batch in missing.chunks(100) {
        let batch = batch.to_vec();
        handles.push(tokio::spawn(async move {
            match fetch_kg_cover_batch(batch).await {
                Ok(v) => v,
                Err(e) => {
                    eprintln!("[playlist_fetcher] enrichKgGatewayCovers batch failed: {}", e);
                    Vec::new()
                }
            }
        }));
    }
    let mut updates: Vec<(usize, String)> = Vec::new();
    for handle in handles {
        match handle.await {
            Ok(v) => updates.extend(v),
            Err(e) => eprintln!(
                "[playlist_fetcher] enrichKgGatewayCovers batch join failed: {}",
                e
            ),
        }
    }
    for (idx, cover) in updates {
        if let Some(song) = songs.get_mut(idx) {
            song.cover_url = cover.clone();
            song.raw_data["union_cover"] = json!(cover);
        }
    }
}

/// 封面补全单批请求：返回 (歌曲索引, 封面 URL) 列表
async fn fetch_kg_cover_batch(batch: Vec<(usize, String, String)>) -> Result<Vec<(usize, String)>, String> {
    let key = crate::host_crypto::host_kugou_request_key();
    let data_items: Vec<Value> = batch
        .iter()
        .map(|(_, hash, title)| {
            json!({
                "hash": hash,
                "name": title,
                "page_id": 0,
                "type": "audio",
                "id": 0,
                "album_audio_id": 0,
                "album_id": "0",
            })
        })
        .collect();
    let data_obj = json!({
        "area_code": "1",
        "show_privilege": 1,
        "show_album_info": 1,
        "is_publish": "",
        "appid": 1005,
        "clientver": 11451,
        "mid": "1",
        "dfid": "-",
        "clienttime": now_millis(),
        "key": key,
        "fields": "album_info,audio_info",
        "data": data_items,
    });

    let resp = http_fetch_json(
        KG_AUDIO_GATEWAY_URL,
        "POST",
        &KG_AUDIO_HEADERS,
        Some(&data_obj.to_string()),
        None,
    )
    .await?;

    let body = resp.body;
    if !body.is_object() {
        return Ok(Vec::new());
    }
    let err_code = nullish_chain_value(&body, &["error_code", "errcode", "err_code"]);
    if !is_strict_zero(&err_code) {
        return Ok(Vec::new());
    }

    let data_v = body
        .get("data")
        .filter(|v| js_truthy(v))
        .cloned()
        .unwrap_or_else(|| Value::Array(Vec::new()));
    let Some(data_arr) = data_v.as_array() else {
        return Err("enrichKgGatewayCovers: response data is not iterable".to_string());
    };

    let mut cover_by_hash: HashMap<String, String> = HashMap::new();
    for item in data_arr {
        // 元素可能本身是数组，取 first
        let first = if item.is_array() { item.get(0) } else { Some(item) };
        let Some(first) = first.filter(|v| js_truthy(v)) else {
            continue;
        };
        let hash = ts_string(first.pointer("/audio_info/hash")).to_lowercase();
        let album_info = first.get("album_info").filter(|v| js_truthy(v));
        let raw_cover = first_truthy(&[
            album_info.and_then(|a| a.get("sizable_cover")),
            album_info.and_then(|a| a.get("cover")),
            first.get("album_sizable_cover"),
            first.get("union_cover"),
        ]);
        if !hash.is_empty() {
            if let Some(rc) = raw_cover {
                cover_by_hash.insert(hash, ts_string(Some(rc)).replacen("{size}", "400", 1));
            }
        }
    }
    if cover_by_hash.is_empty() {
        return Ok(Vec::new());
    }

    Ok(batch
        .into_iter()
        .filter_map(|(idx, hash, _)| {
            let h = hash.to_lowercase();
            cover_by_hash.get(&h).map(|c| (idx, c.clone()))
        })
        .collect())
}

// ==================== 数字酷狗码 → t.kugou.com/command 反查 ====================

/// 对齐 getKgListDetailByCode（TS 返回 null 表示不可用，此处以 Ok(None) 表达）
async fn get_kg_list_detail_by_code(code: &str) -> Result<Option<PlaylistImportResult>, String> {
    let payload = json!({
        "appid": 1001,
        "clientver": 9020,
        "mid": "21511157a05844bd085308bc76ef3343",
        "clienttime": 640612895,
        "key": "36164c4015e704673c588ee202b9ecb8",
        "data": code,
    });
    let resp = http_fetch_json(
        "http://t.kugou.com/command/",
        "POST",
        &[("Content-Type", "application/json")],
        Some(&payload.to_string()),
        None,
    )
    .await?;
    let body = resp.body;
    if !body.is_object() {
        return Ok(None);
    }
    let status_v = nullish_chain_value(&body, &["status", "err_code", "error_code"]);
    if ts_number(&status_v) != 1.0 {
        return Ok(None);
    }
    let data = match body.get("data") {
        Some(d) if d.is_object() || d.is_array() => d,
        _ => return Ok(None),
    };
    let info = data.get("info").filter(|v| v.is_object());
    let name = decode_name(&truthy_str(info.and_then(|i| i.get("name"))));
    let gcol = ts_string(info.and_then(|i| i.get("global_collection_id")).filter(|v| !v.is_null()));
    if !gcol.is_empty() {
        let mut result = get_kg_gcid_detail(&gcol).await?;
        if result.info.name.is_empty() {
            result.info.name = name;
        }
        return Ok(Some(result));
    }
    // 老歌单：command 直出歌曲列表
    let list: Vec<Value> = data
        .get("list")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    let songs: Vec<PlaylistSong> = list.iter().filter_map(parse_kg_song).collect();
    if songs.is_empty() {
        return Ok(None);
    }
    let total = songs.len() as i64;
    Ok(Some(PlaylistImportResult {
        source: "kg".to_string(),
        songs,
        total,
        info: PlaylistInfo {
            name,
            img: String::new(),
            desc: String::new(),
            author: String::new(),
            play_count: String::new(),
        },
    }))
}

// ==================== v2/album_audio/audio 批量详情 ====================

/// 对齐 getKgMusicInfos：hash 列表 → 批量详情（100 首/批并行）
async fn get_kg_music_infos(list: Vec<Value>) -> Vec<PlaylistSong> {
    if list.is_empty() {
        return Vec::new();
    }

    let mut seen: HashSet<String> = HashSet::new();
    let mut deduped: Vec<Value> = Vec::new();
    for item in &list {
        let hash = truthy_str(item.get("hash"));
        if hash.is_empty() || seen.contains(&hash) {
            continue;
        }
        seen.insert(hash);
        deduped.push(item.clone());
    }

    let mut handles = Vec::new();
    for batch in deduped.chunks(100) {
        let batch = batch.to_vec();
        handles.push(tokio::spawn(async move {
            match fetch_kg_music_infos_batch(batch).await {
                Ok(v) => v,
                Err(e) => {
                    eprintln!("[playlist_fetcher] getKgMusicInfos batch failed: {}", e);
                    Vec::new()
                }
            }
        }));
    }

    let mut out: Vec<PlaylistSong> = Vec::new();
    for handle in handles {
        match handle.await {
            Ok(v) => out.extend(v),
            Err(e) => eprintln!("[playlist_fetcher] getKgMusicInfos batch join failed: {}", e),
        }
    }
    out
}

/// 批量详情单批请求
async fn fetch_kg_music_infos_batch(batch: Vec<Value>) -> Result<Vec<PlaylistSong>, String> {
    let key = crate::host_crypto::host_kugou_request_key();
    let data_obj = json!({
        "area_code": "1",
        "show_privilege": 1,
        "show_album_info": 1,
        "is_publish": "",
        "appid": 1005,
        "clientver": 11451,
        "mid": "1",
        "dfid": "-",
        "clienttime": now_millis(),
        "key": key,
        "fields": "album_info,author_name,audio_info,ori_audio_name,base,songname",
        "data": batch,
    });

    let resp = http_fetch_json(
        KG_AUDIO_GATEWAY_URL,
        "POST",
        &KG_AUDIO_HEADERS,
        Some(&data_obj.to_string()),
        None,
    )
    .await?;

    let body = resp.body;
    if !body.is_object() {
        return Ok(Vec::new());
    }
    let err_code = nullish_chain_value(&body, &["error_code", "errcode", "err_code"]);
    if !is_strict_zero(&err_code) {
        return Ok(Vec::new());
    }

    let data_v = body
        .get("data")
        .filter(|v| js_truthy(v))
        .cloned()
        .unwrap_or_else(|| Value::Array(Vec::new()));
    let Some(data_arr) = data_v.as_array() else {
        return Err("getKgMusicInfos: response data is not iterable".to_string());
    };
    let mut songs: Vec<PlaylistSong> = Vec::new();
    for item in data_arr {
        // 元素可能本身是数组，取 first
        let first = if item.is_array() { item.get(0) } else { Some(item) };
        if let Some(f) = first.filter(|v| js_truthy(v)) {
            if let Some(parsed) = parse_kg_song_detail_v2(f) {
                songs.push(parsed);
            }
        }
    }
    Ok(songs)
}

/// 批量详情条目 → PlaylistSong（对齐 parseKgSongDetailV2）
fn parse_kg_song_detail_v2(item: &Value) -> Option<PlaylistSong> {
    let audio_info = item
        .get("audio_info")
        .filter(|v| js_truthy(v))
        .cloned()
        .unwrap_or_else(|| json!({}));
    let album_info = item
        .get("album_info")
        .filter(|v| js_truthy(v))
        .cloned()
        .unwrap_or_else(|| json!({}));
    let hash = truthy_str(audio_info.get("hash"));
    let audio_id = ts_string(audio_info.get("audio_id").filter(|v| !v.is_null()));
    if hash.is_empty() && audio_id.is_empty() {
        return None;
    }

    let singer_name = decode_name(&truthy_str(item.get("author_name")));
    let songname = decode_name(&truthy_str(item.get("songname")));
    let album_name = decode_name(&truthy_str(album_info.get("album_name")));
    let album_cover = truthy_chain_str(&[
        album_info.get("sizable_cover"),
        album_info.get("cover"),
    ])
    .replacen("{size}", "400", 1);
    let duration_f = match audio_info.get("timelength") {
        Some(v) if js_truthy(v) => ts_number(v),
        _ => 0.0,
    };
    let duration_ms = duration_f as i64;

    let song_id_str = if !audio_id.is_empty() {
        audio_id.clone()
    } else {
        hash.clone()
    };
    let mut raw = json!({
        "songmid": song_id_str,
        "name": songname,
        "singer": singer_name,
        "source": "kg",
        "interval": format_play_time((duration_f / 1000.0).floor()),
    });
    if !hash.is_empty() {
        raw["hash"] = json!(hash);
    }

    Some(PlaylistSong::new(
        &song_id_str,
        &songname,
        &singer_name,
        &album_name,
        &album_cover,
        duration_ms,
        "酷狗",
        "kg",
        raw,
    ))
}

/// TS `String(a || b || '')`：取第一个 truthy 值转字符串
fn truthy_chain_str(vals: &[Option<&Value>]) -> String {
    match first_truthy(vals) {
        Some(v) => ts_string(Some(v)),
        None => String::new(),
    }
}

// ==================== 单测（仅纯函数，网络相关不测） ====================

#[cfg(test)]
mod tests {
    use super::*;

    const KG_V9_HTML: &str = include_str!("../fixtures/playlist/kg_v9.html");
    const KG_GATEWAY_JSON: &str = include_str!("../fixtures/playlist/kg_gateway.json");

    /// v9 fixture 中提取的 global.data 数组
    fn v9_list() -> Vec<Value> {
        let caps = kg_global_data_re()
            .captures(KG_V9_HTML)
            .expect("global.data 应可提取");
        let list_json = caps.get(1).unwrap().as_str();
        serde_json::from_str(list_json).expect("global.data 应为合法 JSON 数组")
    }

    /// gateway fixture 中的指定歌曲条目
    fn gateway_song(index: usize) -> Value {
        let body: Value = serde_json::from_str(KG_GATEWAY_JSON).unwrap();
        body.pointer("/data/songs")
            .and_then(|v| v.get(index))
            .cloned()
            .expect("songs 条目应存在")
    }

    fn raw_str(song: &PlaylistSong, key: &str) -> String {
        song.raw_data
            .get(key)
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string()
    }

    // ---------- v9 页面提取 ----------

    #[test]
    fn v9_data_and_info_regex_extraction() {
        let list = v9_list();
        assert_eq!(list.len(), 2);
        assert_eq!(list[0]["hash"], json!("HASHAAA000111"));

        let caps = kg_list_info_re()
            .captures(KG_V9_HTML)
            .expect("global info 应可提取");
        assert_eq!(caps.get(1).unwrap().as_str(), "测试歌单");
        assert_eq!(caps.get(2).unwrap().as_str(), "https://img.kugou.com/p.jpg");
    }

    // ---------- parse_kg_song ----------

    #[test]
    fn parse_kg_song_prefers_audio_id_and_maps_fields() {
        let song = parse_kg_song(&v9_list()[0]).expect("应解析成功");
        assert_eq!(song.id, "100001");
        assert_eq!(song.platform_id, "100001");
        assert_eq!(song.title, "歌曲一");
        assert_eq!(song.artist, "歌手甲");
        assert_eq!(song.album, "专辑一");
        assert_eq!(song.cover_url, "");
        assert_eq!(song.platform, "酷狗");
        assert_eq!(song.plugin_id, "kg");
        // duration 为毫秒
        assert_eq!(song.duration, 245000);
        // rawData 键集合
        let keys: Vec<String> = song
            .raw_data
            .as_object()
            .unwrap()
            .keys()
            .cloned()
            .collect();
        assert_eq!(
            keys,
            vec![
                "hash",
                "interval",
                "name",
                "singer",
                "songmid",
                "source"
            ]
        );
        assert_eq!(raw_str(&song, "songmid"), "100001");
        assert_eq!(raw_str(&song, "hash"), "HASHAAA000111");
        assert_eq!(raw_str(&song, "name"), "歌曲一");
        assert_eq!(raw_str(&song, "singer"), "歌手甲");
        assert_eq!(raw_str(&song, "source"), "kg");
        assert_eq!(raw_str(&song, "interval"), "04:05");
    }

    #[test]
    fn parse_kg_song_falls_back_to_hash_and_decodes_entities() {
        let song = parse_kg_song(&v9_list()[1]).expect("应解析成功");
        // audio_id 为空串 → songId 回落到 hash
        assert_eq!(song.id, "HASHBBB000222");
        assert_eq!(raw_str(&song, "songmid"), "HASHBBB000222");
        // singername HTML 实体解码
        assert_eq!(song.artist, "歌手乙 & 歌手丙");
        assert_eq!(song.album, "");
        assert_eq!(song.duration, 180000);
        assert_eq!(raw_str(&song, "interval"), "03:00");
    }

    #[test]
    fn parse_kg_song_without_hash_omits_hash_key() {
        let item = json!({"hash": "", "audio_id": 100002, "songname": "纯AudioId"});
        let song = parse_kg_song(&item).expect("应解析成功");
        assert_eq!(song.id, "100002");
        assert!(song.raw_data.get("hash").is_none());
        let keys: Vec<String> = song
            .raw_data
            .as_object()
            .unwrap()
            .keys()
            .cloned()
            .collect();
        assert_eq!(keys, vec!["interval", "name", "singer", "songmid", "source"]);
        assert_eq!(raw_str(&song, "songmid"), "100002");
    }

    #[test]
    fn parse_kg_song_rejects_empty_identifiers() {
        assert!(parse_kg_song(&json!({"hash": "", "audio_id": null})).is_none());
        assert!(parse_kg_song(&json!({})).is_none());
    }

    // ---------- parse_gateway_song ----------

    #[test]
    fn parse_gateway_song_splits_name_and_maps_fields() {
        let song = parse_gateway_song(&gateway_song(0)).expect("应解析成功");
        // singername 已存在 → 拆分只影响 title
        assert_eq!(song.title, "歌曲一");
        assert_eq!(song.artist, "歌手甲");
        assert_eq!(song.id, "200001");
        assert_eq!(song.platform_id, "200001");
        assert_eq!(song.album, "专辑甲");
        // cover 走 item.cover，{size} → 400
        assert_eq!(song.cover_url, "https://img.kugou.com/c1/400.jpg");
        assert_eq!(song.duration, 245000);
        let keys: Vec<String> = song
            .raw_data
            .as_object()
            .unwrap()
            .keys()
            .cloned()
            .collect();
        assert_eq!(
            keys,
            vec![
                "audioId",
                "hash",
                "interval",
                "name",
                "singer",
                "songmid",
                "source"
            ]
        );
        assert_eq!(raw_str(&song, "songmid"), "200001");
        assert_eq!(raw_str(&song, "audioId"), "200001");
        assert_eq!(raw_str(&song, "hash"), "GWHASH000111");
        assert_eq!(raw_str(&song, "interval"), "04:05");
    }

    #[test]
    fn parse_gateway_song_artist_from_name_and_union_cover() {
        let song = parse_gateway_song(&gateway_song(1)).expect("应解析成功");
        // singername 为空 → artist 取 name 第一段
        assert_eq!(song.artist, "无名组合");
        assert_eq!(song.title, "未拆分歌名");
        // albuminfo 缺失 → remark 兜底
        assert_eq!(song.album, "备注专辑");
        // cover 走 trans_param.union_cover，{size} → 400
        assert_eq!(song.cover_url, "https://img.kugou.com/c2/400.jpg");
        // audio_id 为空串 → songId 回落 hash，且不写 audioId
        assert_eq!(song.id, "GWHASH000222");
        assert!(song.raw_data.get("audioId").is_none());
        assert_eq!(raw_str(&song, "songmid"), "GWHASH000222");
        assert_eq!(raw_str(&song, "singer"), "无名组合");
        assert_eq!(song.duration, 200000);
        assert_eq!(raw_str(&song, "interval"), "03:20");
    }

    #[test]
    fn parse_gateway_song_unknown_singer_fallback_and_rejects_missing_hash() {
        let item = json!({"hash": "SoloHash", "name": "没有分隔符的歌名"});
        let song = parse_gateway_song(&item).expect("应解析成功");
        assert_eq!(song.artist, "未知歌手");
        assert_eq!(raw_str(&song, "singer"), "未知歌手");
        assert_eq!(song.title, "没有分隔符的歌名");

        assert!(parse_gateway_song(&json!({"name": "无hash"})).is_none());
    }

    // ---------- gateway 去重键 ----------

    #[test]
    fn gateway_dedup_key_uses_hash_audio_id_and_raw_name() {
        // audio_id 非空 → 取 audio_id
        assert_eq!(
            gateway_dedup_key(&gateway_song(0)),
            "GWHASH000111|200001|歌手甲 - 歌曲一"
        );
        // audio_id 为空串（非 nullish）→ 不回落 album_audio_id
        assert_eq!(
            gateway_dedup_key(&gateway_song(1)),
            "GWHASH000222||无名组合 - 未拆分歌名"
        );
        // 两者都缺 → 0
        assert_eq!(
            gateway_dedup_key(&json!({"hash": "H", "name": "n"})),
            "H|0|n"
        );
    }

    // ---------- parse_kg_song_detail_v2 ----------

    #[test]
    fn parse_kg_song_detail_v2_maps_fields() {
        let item = json!({
            "audio_info": {"hash": "DetailHash001", "audio_id": 300001, "timelength": 245000},
            "album_info": {"album_name": "专辑X", "sizable_cover": "https://img.kugou.com/x/{size}.jpg"},
            "author_name": "歌手X",
            "songname": "歌名X"
        });
        let song = parse_kg_song_detail_v2(&item).expect("应解析成功");
        assert_eq!(song.id, "300001");
        assert_eq!(song.platform_id, "300001");
        assert_eq!(song.title, "歌名X");
        assert_eq!(song.artist, "歌手X");
        assert_eq!(song.album, "专辑X");
        // sizable_cover 优先，{size} → 400
        assert_eq!(song.cover_url, "https://img.kugou.com/x/400.jpg");
        // timelength 为毫秒
        assert_eq!(song.duration, 245000);
        let keys: Vec<String> = song
            .raw_data
            .as_object()
            .unwrap()
            .keys()
            .cloned()
            .collect();
        assert_eq!(
            keys,
            vec![
                "hash",
                "interval",
                "name",
                "singer",
                "songmid",
                "source"
            ]
        );
        assert_eq!(raw_str(&song, "songmid"), "300001");
        assert_eq!(raw_str(&song, "hash"), "DetailHash001");
        assert_eq!(raw_str(&song, "interval"), "04:05");
    }

    #[test]
    fn parse_kg_song_detail_v2_cover_fallback_and_rejects_empty() {
        // sizable_cover 缺失 → album_info.cover 兜底；audio_id 缺失 → songId 回落 hash
        let item = json!({
            "audio_info": {"hash": "DetailHash002", "timelength": 60000},
            "album_info": {"cover": "https://img.kugou.com/y/{size}.jpg"}
        });
        let song = parse_kg_song_detail_v2(&item).expect("应解析成功");
        assert_eq!(song.id, "DetailHash002");
        assert_eq!(song.cover_url, "https://img.kugou.com/y/400.jpg");
        assert_eq!(song.duration, 60000);
        assert_eq!(raw_str(&song, "interval"), "01:00");

        // hash 与 audio_id 皆空 → None
        assert!(parse_kg_song_detail_v2(&json!({"audio_info": {"hash": "", "audio_id": null}})).is_none());
    }
}
