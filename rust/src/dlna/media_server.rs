//! 媒体 token 服务：把本地文件/防盗链直链包装成局域网可访问 URL（双端同步一份代码，勿在本端私自改动）。
//!
//! - `POST` 由 DlnaCore 直接调用（不走 HTTP），token → MediaPayload 注册表。
//! - `GET /media/{token}`：支持 Range（本地文件 seek 直读；远程 reqwest 流式透传 + 上游防盗链头）。
//! - `GET /media/cover/{token}`：带头取封面字节（模式对齐现有 CoverProxy）。

use super::types::MediaPayload;
use axum::body::Body;
use axum::extract::{Path, State};
use axum::http::{HeaderMap, StatusCode, Uri};
use axum::response::Response;
use std::collections::{BTreeMap, HashMap};
use std::sync::{Arc, Mutex};
use tokio::io::{AsyncReadExt, AsyncSeekExt};

#[derive(Debug, Clone)]
pub struct RegistryEntry {
    pub payload: MediaPayload,
    pub created_at_ms: u64,
}

pub struct MediaRegistry {
    inner: Mutex<HashMap<String, RegistryEntry>>,
    /// remote 透传 / 封面拉取共用客户端（带超时配置，由 DlnaCore 注入）。
    client: reqwest::Client,
}

impl MediaRegistry {
    pub fn new(client: reqwest::Client) -> Self {
        Self {
            inner: Mutex::new(HashMap::new()),
            client,
        }
    }

    /// 注册载荷，返回随机 token。
    pub fn create(&self, payload: MediaPayload) -> String {
        let token = new_token();
        let now = now_ms();
        self.inner
            .lock()
            .unwrap()
            .insert(token.clone(), RegistryEntry { payload, created_at_ms: now });
        token
    }

    /// 原位更新 token 的上游（TTL 续投热替换，不换 token）。
    pub fn update(&self, token: &str, payload: MediaPayload) -> bool {
        if let Some(entry) = self.inner.lock().unwrap().get_mut(token) {
            entry.payload = payload;
            entry.created_at_ms = now_ms();
            true
        } else {
            false
        }
    }

    pub fn get(&self, token: &str) -> Option<RegistryEntry> {
        self.inner.lock().unwrap().get(token).cloned()
    }

    /// 按创建时间淘汰（上限 256 条，防长期运行膨胀）。
    pub fn evict_old(&self, keep: usize) {
        let mut map = self.inner.lock().unwrap();
        if map.len() <= keep {
            return;
        }
        let mut items: Vec<(String, u64)> = map
            .iter()
            .map(|(k, v)| (k.clone(), v.created_at_ms))
            .collect();
        items.sort_by_key(|(_, t)| *t);
        let excess = map.len() - keep;
        for (k, _) in items.into_iter().take(excess) {
            map.remove(&k);
        }
    }

    /// remote 分支使用的 HTTP 客户端克隆。
    pub fn client_for_remote(&self) -> reqwest::Client {
        self.client.clone()
    }
}

impl Default for MediaRegistry {
    fn default() -> Self {
        Self::new(reqwest::Client::new())
    }
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// 128bit 随机 hex token（uuid v4 去连字符 ×2 拼接，双端均有 uuid 依赖）。
fn new_token() -> String {
    let a = uuid::Uuid::new_v4();
    let b = uuid::Uuid::new_v4();
    format!("{a:x}{b:x}").replace('-', "")
}

/// 解析 Range 头 → (start, 可选 end)。
pub fn parse_range(range: Option<&str>, total: Option<u64>) -> Option<(u64, Option<u64>)> {
    let raw = range?;
    let spec = raw.strip_prefix("bytes=")?.trim();
    if spec.contains(',') {
        return None; // 仅支持单区间
    }
    let (start_s, end_s) = spec.split_once('-')?;
    if start_s.is_empty() {
        // bytes=-N 后缀区间
        let n: u64 = end_s.trim().parse().ok()?;
        let total = total?;
        let start = total.saturating_sub(n);
        return Some((start, Some(total.saturating_sub(1))));
    }
    let start: u64 = start_s.trim().parse().ok()?;
    if let Some(t) = total {
        if start >= t {
            return None; // 起点越界 → 416
        }
    }
    let end = end_s.trim().parse::<u64>().ok();
    if let (Some(e), Some(_)) = (end, total) {
        if start > e {
            return None; // 越界 → 416
        }
    }
    Some((start, end))
}

fn simple_response(status: StatusCode, headers: Vec<(&'static str, String)>, body: Body) -> Response {
    let mut builder = Response::builder().status(status);
    for (k, v) in headers {
        builder = builder.header(k, v);
    }
    builder.body(body).unwrap_or_else(|_| {
        Response::builder()
            .status(StatusCode::INTERNAL_SERVER_ERROR)
            .body(Body::empty())
            .unwrap()
    })
}

fn error_response(status: StatusCode, msg: &str) -> Response {
    simple_response(status, vec![("CONTENT-TYPE", "text/plain".into())], Body::from(msg.to_string()))
}

/// GET|HEAD /media/{token}
pub async fn serve_media(
    State(registry): State<Arc<MediaRegistry>>,
    Path(token): Path<String>,
    uri: Uri,
    headers: HeaderMap,
) -> Response {
    let Some(entry) = registry.get(&token) else {
        return error_response(StatusCode::NOT_FOUND, "token not found");
    };
    let head_only = uri.path().is_empty(); // 由 httpd 层区分，此处仅占位
    let _ = head_only;

    match entry.payload {
        MediaPayload::LocalFile { path } => serve_local_file(&path, &headers).await,
        MediaPayload::Remote { url, headers: uh, .. } => {
            serve_remote(&registry.client_for_remote(), &url, &uh, &headers).await
        }
        MediaPayload::Cover { .. } => error_response(StatusCode::NOT_FOUND, "not a media token"),
    }
}

/// GET /media/cover/{token}
pub async fn serve_cover(
    State(registry): State<Arc<MediaRegistry>>,
    Path(token): Path<String>,
) -> Response {
    let Some(entry) = registry.get(&token) else {
        return error_response(StatusCode::NOT_FOUND, "token not found");
    };
    let MediaPayload::Cover { url, headers } = entry.payload else {
        return error_response(StatusCode::NOT_FOUND, "not a cover token");
    };
    let client = registry.client_for_remote();
    let mut req = client.get(&url);
    for (k, v) in &headers {
        if let (Ok(name), Ok(val)) = (
            k.parse::<reqwest::header::HeaderName>(),
            v.parse::<reqwest::header::HeaderValue>(),
        ) {
            req = req.header(name, val);
        }
    }
    let resp = match req.timeout(std::time::Duration::from_secs(15)).send().await {
        Ok(r) => r,
        Err(e) => return error_response(StatusCode::BAD_GATEWAY, &format!("cover fetch failed: {e}")),
    };
    let content_type = resp
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("image/jpeg")
        .to_string();
    match resp.bytes().await {
        Ok(bytes) => simple_response(
            StatusCode::OK,
            vec![
                ("CONTENT-TYPE", content_type),
                ("ACCEPT-RANGES", "none".into()),
            ],
            Body::from(bytes),
        ),
        Err(e) => error_response(StatusCode::BAD_GATEWAY, &format!("cover read failed: {e}")),
    }
}

async fn serve_local_file(path: &str, headers: &HeaderMap) -> Response {
    let path = path.to_string();
    let meta = match tokio::fs::metadata(&path).await {
        Ok(m) if m.is_file() => m,
        _ => return error_response(StatusCode::NOT_FOUND, "file not found"),
    };
    let total = meta.len();
    let range_hdr = headers
        .get("range")
        .and_then(|v| v.to_str().ok())
        .map(|s| s.to_string());
    let range = parse_range(range_hdr.as_deref(), Some(total));

    let Some((start, end)) = range else {
        if range_hdr.is_some() {
            return simple_response(
                StatusCode::RANGE_NOT_SATISFIABLE,
                vec![("CONTENT-RANGE", format!("bytes */{total}"))],
                Body::empty(),
            );
        }
        // 200 全量。
        let file = match tokio::fs::File::open(&path).await {
            Ok(f) => f,
            Err(e) => return error_response(StatusCode::INTERNAL_SERVER_ERROR, &format!("open failed: {e}")),
        };
        let stream = tokio_util::io::ReaderStream::new(file);
        return simple_response(
            StatusCode::OK,
            vec![
                ("CONTENT-TYPE", "audio/mpeg".into()),
                ("ACCEPT-RANGES", "bytes".into()),
                ("CONTENT-LENGTH", total.to_string()),
            ],
            Body::from_stream(stream),
        );
    };

    let end = end.unwrap_or(total.saturating_sub(1)).min(total.saturating_sub(1));
    let length = end - start + 1;
    let mut file = match tokio::fs::File::open(&path).await {
        Ok(f) => f,
        Err(e) => return error_response(StatusCode::INTERNAL_SERVER_ERROR, &format!("open failed: {e}")),
    };
    if file.seek(std::io::SeekFrom::Start(start)).await.is_err() {
        return error_response(StatusCode::INTERNAL_SERVER_ERROR, "seek failed");
    }
    let limited = file.take(length);
    let stream = tokio_util::io::ReaderStream::new(limited);
    simple_response(
        StatusCode::PARTIAL_CONTENT,
        vec![
            ("CONTENT-TYPE", "audio/mpeg".into()),
            ("ACCEPT-RANGES", "bytes".into()),
            ("CONTENT-LENGTH", length.to_string()),
            ("CONTENT-RANGE", format!("bytes {start}-{end}/{total}")),
        ],
        Body::from_stream(stream),
    )
}

async fn serve_remote(
    client: &reqwest::Client,
    url: &str,
    upstream_headers: &BTreeMap<String, String>,
    client_headers: &HeaderMap,
) -> Response {
    let mut req = client.get(url);
    for (k, v) in upstream_headers {
        if let (Ok(name), Ok(val)) = (
            k.parse::<reqwest::header::HeaderName>(),
            v.parse::<reqwest::header::HeaderValue>(),
        ) {
            req = req.header(name, val);
        }
    }
    // Range 透传给上游。
    if let Some(range) = client_headers.get("range") {
        req = req.header("RANGE", range.as_bytes());
    }
    let resp = match req
        .timeout(std::time::Duration::from_secs(20))
        .send()
        .await
    {
        Ok(r) => r,
        Err(e) => return error_response(StatusCode::BAD_GATEWAY, &format!("upstream failed: {e}")),
    };

    let status = resp.status();
    let mut out_headers: Vec<(&'static str, String)> = vec![
        ("ACCEPT-RANGES", "bytes".into()),
        ("CONTENT-TYPE", "audio/mpeg".into()),
    ];
    if let Some(cr) = resp.headers().get(reqwest::header::CONTENT_RANGE) {
        if let Ok(v) = cr.to_str() {
            out_headers.push(("CONTENT-RANGE", v.to_string()));
        }
    }
    if let Some(cl) = resp.headers().get(reqwest::header::CONTENT_LENGTH) {
        if let Ok(v) = cl.to_str() {
            out_headers.push(("CONTENT-LENGTH", v.to_string()));
        }
    }
    let out_status = if status == reqwest::StatusCode::PARTIAL_CONTENT {
        StatusCode::PARTIAL_CONTENT
    } else if status.is_success() {
        StatusCode::OK
    } else {
        // 上游 403/404/410 等：把失败透出给编排层救活逻辑。
        return error_response(
            StatusCode::from_u16(status.as_u16()).unwrap_or(StatusCode::BAD_GATEWAY),
            "upstream rejected",
        );
    };
    let stream = resp.bytes_stream();
    simple_response(out_status, out_headers, Body::from_stream(stream))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn range_parse_cases() {
        assert_eq!(parse_range(Some("bytes=0-99"), Some(1000)), Some((0, Some(99))));
        assert_eq!(parse_range(Some("bytes=500-"), Some(1000)), Some((500, None)));
        assert_eq!(parse_range(Some("bytes=-200"), Some(1000)), Some((800, Some(999))));
        assert_eq!(parse_range(Some("bytes=0-99"), None), Some((0, Some(99))));
        assert_eq!(parse_range(Some("bytes=0-99,200-299"), Some(1000)), None);
        assert_eq!(parse_range(Some("bytes=5000-"), Some(1000)), None);
        assert_eq!(parse_range(None, Some(1000)), None);
    }

    #[test]
    fn registry_create_update_get() {
        let reg = MediaRegistry::new(reqwest::Client::new());
        let t = reg.create(MediaPayload::LocalFile { path: "/a.mp3".into() });
        assert_eq!(t.len(), 64);
        assert!(reg.get(&t).is_some());
        assert!(reg.update(&t, MediaPayload::LocalFile { path: "/b.flac".into() }));
        if let Some(e) = reg.get(&t) {
            match e.payload {
                MediaPayload::LocalFile { path } => assert_eq!(path, "/b.flac"),
                _ => panic!("wrong payload"),
            }
        }
        assert!(!reg.update("nope", MediaPayload::LocalFile { path: "/x".into() }));
    }
}
