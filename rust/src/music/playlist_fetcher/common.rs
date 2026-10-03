// 歌单导入 common：类型契约 + HTTP/格式化工具。
// 由前端 playlistImportBase.ts / musicFormat.ts 下沉而来，返回形状与
// 热修 JS 模块（playlist_import）逐字段一致，serde 字段名被前端依赖，冻结。

use serde::{Deserialize, Serialize};

// ==================== 数据契约 ====================

/// 对齐前端 PlaylistInfo（playlistImportBase.ts）
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlaylistInfo {
    pub name: String,
    pub img: String,
    pub desc: String,
    pub author: String,
    pub play_count: String,
}

/// 对齐前端 PluginSearchResult（types/index.ts），rawData 为任意 JSON
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlaylistSong {
    pub id: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub cover_url: String,
    /// 毫秒（与 TS createSearchResult 一致）
    pub duration: i64,
    pub platform: String,
    pub platform_id: String,
    pub plugin_id: String,
    pub raw_data: serde_json::Value,
}

impl PlaylistSong {
    /// 对齐前端 createSearchResult：platformId = id
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn new(
        id: &str,
        title: &str,
        artist: &str,
        album: &str,
        cover_url: &str,
        duration_ms: i64,
        platform: &str,
        plugin_id: &str,
        raw_data: serde_json::Value,
    ) -> Self {
        Self {
            id: id.to_string(),
            title: title.to_string(),
            artist: artist.to_string(),
            album: album.to_string(),
            cover_url: cover_url.to_string(),
            duration: duration_ms,
            platform: platform.to_string(),
            platform_id: id.to_string(),
            plugin_id: plugin_id.to_string(),
            raw_data,
        }
    }
}

/// 对齐前端 PlaylistImportResult
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlaylistImportResult {
    pub source: String,
    pub songs: Vec<PlaylistSong>,
    pub total: i64,
    pub info: PlaylistInfo,
}

impl PlaylistImportResult {
    /// TS 各平台通用的空结果：{ source, songs: [], total: 0, info: 空对象 }
    pub(crate) fn empty(source: &str) -> Self {
        Self {
            source: source.to_string(),
            songs: Vec::new(),
            total: 0,
            info: PlaylistInfo::default(),
        }
    }
}

// ==================== 格式化工具（对齐 musicFormat.ts / playlistImportBase.ts） ====================

/// 对齐 TS decodeName：HTML 实体解码（复用歌词域实现）
pub(crate) fn decode_name(s: &str) -> String {
    crate::music::lyric_fetcher::decode_html_entities(s)
}

/// 对齐 TS formatSingerName：数组取 name 键解码后以「、」拼接；非数组按字符串解码
pub(crate) fn format_singer_name(singers: &serde_json::Value) -> String {
    if let Some(arr) = singers.as_array() {
        let mut names: Vec<String> = Vec::new();
        for item in arr {
            if let Some(name) = item.get("name").and_then(|v| v.as_str()) {
                if !name.trim().is_empty() {
                    names.push(decode_name(name));
                }
            }
        }
        return names.join("、");
    }
    decode_name(singers.as_str().unwrap_or(""))
}

/// 对齐 TS formatPlayTime：秒 → m:ss（分钟不足两位补零），0/NaN → '--/--'
pub(crate) fn format_play_time(seconds: f64) -> String {
    if !seconds.is_finite() || seconds == 0.0 {
        return "--/--".to_string();
    }
    let m = (seconds / 60.0).floor();
    let s = (seconds % 60.0).floor();
    if m < 10.0 {
        format!("0{}:{:02}", m, s)
    } else {
        format!("{}:{:02}", m, s)
    }
}

/// 对齐 JS encodeURIComponent：保留 A-Za-z0-9-_.!~*'()，其余按 UTF-8 百分号编码（大写 hex）
pub(crate) fn percent_encode_component(input: &str) -> String {
    const HEX: &[u8; 16] = b"0123456789ABCDEF";
    let mut out = String::with_capacity(input.len());
    for &b in input.as_bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'!' | b'~'
            | b'*' | b'\'' | b'(' | b')' => out.push(b as char),
            _ => {
                out.push('%');
                out.push(HEX[(b >> 4) as usize] as char);
                out.push(HEX[(b & 0x0F) as usize] as char);
            }
        }
    }
    out
}

// ==================== HTTP（对齐 playlistImportBase.ts httpFetch） ====================

const DEFAULT_UA: &str = "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/69.0.3497.100 Safari/537.36";

pub(crate) struct HttpJsonResponse {
    /// JSON 解析结果；解析失败时为字符串值（对齐 TS parsedBody 兜底）
    pub body: serde_json::Value,
    /// 原始响应文本（kg v9 HTML / 汽水 _ROUTER_DATA / 短链正则等场景使用）
    pub text: String,
    /// 全部响应头（键转小写）
    pub headers: Vec<(String, String)>,
}

impl HttpJsonResponse {
    pub(crate) fn header(&self, name: &str) -> Option<&str> {
        let lower = name.to_ascii_lowercase();
        self.headers
            .iter()
            .find(|(k, _)| k == &lower)
            .map(|(_, v)| v.as_str())
    }
}

/// 对齐 TS httpFetch：默认 UA/Accept（调用方可覆盖）、form 百分号编码、
/// status>=400 仅记日志、body 尽量 JSON 解析（失败保留字符串）
pub(crate) async fn http_fetch_json(
    url: &str,
    method: &str,
    headers: &[(&str, &str)],
    body: Option<&str>,
    form: Option<&[(&str, &str)]>,
) -> Result<HttpJsonResponse, String> {
    // 默认头在前，调用方同名头覆盖（对齐 TS 对象展开语义）
    let mut merged: Vec<(String, String)> = vec![
        ("User-Agent".to_string(), DEFAULT_UA.to_string()),
        ("Accept".to_string(), "application/json".to_string()),
    ];
    for (k, v) in headers {
        merged.retain(|(ek, _)| !ek.eq_ignore_ascii_case(k));
        merged.push(((*k).to_string(), (*v).to_string()));
    }

    let mut request_body = body.map(|b| b.to_string());
    if method.eq_ignore_ascii_case("POST") {
        if let Some(pairs) = form {
            merged.retain(|(k, _)| !k.eq_ignore_ascii_case("content-type"));
            merged.push((
                "Content-Type".to_string(),
                "application/x-www-form-urlencoded".to_string(),
            ));
            request_body = Some(
                pairs
                    .iter()
                    .map(|(k, v)| {
                        format!(
                            "{}={}",
                            percent_encode_component(k),
                            percent_encode_component(v)
                        )
                    })
                    .collect::<Vec<_>>()
                    .join("&"),
            );
        } else if request_body.is_some()
            && !merged
                .iter()
                .any(|(k, _)| k.eq_ignore_ascii_case("content-type"))
        {
            merged.push(("Content-Type".to_string(), "application/json".to_string()));
        }
    }

    let header_refs: Vec<(&str, &str)> =
        merged.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
    let resp = crate::music::lyric_fetcher::http_fetch_text(
        url,
        method,
        &header_refs,
        request_body.as_deref(),
    )
    .await?;

    if resp.status >= 400 {
        let preview: String = resp.body.chars().take(500).collect();
        eprintln!("[playlist_fetcher] HTTP {} body: {}", resp.status, preview);
    }

    let text = resp.body;
    let parsed = serde_json::from_str::<serde_json::Value>(&text)
        .unwrap_or(serde_json::Value::String(text.clone()));

    Ok(HttpJsonResponse {
        body: parsed,
        text,
        headers: resp.headers,
    })
}
