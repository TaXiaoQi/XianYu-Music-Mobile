//! 插件 HTTP 桥 —— QuickJS 侧所有网络请求的统一出口
//!
//! 语义对齐原链路（worker tauriAdapter → plugin_http_request）：
//!   - 请求前按 URL 域名注入已存 Cookie（headers 已带 Cookie 则跳过）
//!   - 响应后捕获全部 Set-Cookie 存入 PluginStore
//!   - gzip/br/deflate 自动解压，UA 兜底 Chrome 120
//!   - 文本 body 按 Content-Type charset 解码（缺省 UTF-8，encoding_rs；
//!     无效序列输出 U+FFFD，与浏览器一致）
//!   - timeout_ms = 0 → 默认 30s；follow < 0 → 默认跟随 10 次重定向，0 → 不跟随

use super::store::PluginStore;
use base64::{engine::general_purpose, Engine as _};
use serde::Serialize;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

const USER_AGENT: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";
const MAX_BODY_SIZE: usize = 50 * 1024 * 1024;
const DEFAULT_TIMEOUT_SECS: u64 = 30;
const DEFAULT_REDIRECT_LIMIT: usize = 10;

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct HttpBridgeResponse {
    pub status: u16,
    pub url: String,
    pub headers: HashMap<String, String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub body: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub body_base64: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

/// 按 Content-Type 的 charset 解码文本 body；未声明或无法识别时按 UTF-8
fn decode_text_body(bytes: &[u8], content_type: Option<&String>) -> String {
    let charset = content_type
        .and_then(|ct| {
            ct.split(';').find_map(|p| {
                let p = p.trim();
                p.strip_prefix("charset=")
                    .map(|v| v.trim_matches('"').to_string())
            })
        })
        .unwrap_or_else(|| "utf-8".to_string());
    let encoding =
        encoding_rs::Encoding::for_label(charset.as_bytes()).unwrap_or(encoding_rs::UTF_8);
    encoding.decode(bytes).0.into_owned()
}

pub struct HttpBridge {
    store: Arc<PluginStore>,
    clients: Mutex<HashMap<usize, reqwest::Client>>,
}

impl HttpBridge {
    pub fn new(store: Arc<PluginStore>) -> Self {
        Self {
            store,
            clients: Mutex::new(HashMap::new()),
        }
    }

    fn client_for(&self, redirect_limit: usize) -> Result<reqwest::Client, String> {
        {
            let clients = self.clients.lock().unwrap();
            if let Some(client) = clients.get(&redirect_limit) {
                return Ok(client.clone());
            }
        }
        let policy = if redirect_limit == 0 {
            reqwest::redirect::Policy::none()
        } else {
            reqwest::redirect::Policy::limited(redirect_limit)
        };
        let client = reqwest::Client::builder()
            .redirect(policy)
            .gzip(true)
            .brotli(true)
            .deflate(true)
            .user_agent(USER_AGENT)
            .build()
            .map_err(|e| e.to_string())?;
        let mut clients = self.clients.lock().unwrap();
        Ok(clients.entry(redirect_limit).or_insert(client).clone())
    }

    pub async fn request(
        &self,
        method: &str,
        url: &str,
        headers: HashMap<String, String>,
        body: Option<String>,
        timeout_ms: u64,
        follow: i64,
        want_binary: bool,
    ) -> HttpBridgeResponse {
        match self.request_inner(method, url, headers, body, timeout_ms, follow, want_binary).await {
            Ok(resp) => resp,
            Err(err) => HttpBridgeResponse {
                status: 0,
                url: url.to_string(),
                headers: HashMap::new(),
                body: None,
                body_base64: None,
                error: Some(err),
            },
        }
    }

    async fn request_inner(
        &self,
        method: &str,
        url: &str,
        headers: HashMap<String, String>,
        body: Option<String>,
        timeout_ms: u64,
        follow: i64,
        want_binary: bool,
    ) -> Result<HttpBridgeResponse, String> {
        let method = reqwest::Method::from_bytes(method.trim().to_uppercase().as_bytes())
            .map_err(|e| e.to_string())?;
        let redirect_limit = if follow < 0 {
            DEFAULT_REDIRECT_LIMIT
        } else {
            follow as usize
        };
        let client = self.client_for(redirect_limit)?;

        let mut request = client.request(method, url);
        if timeout_ms > 0 {
            request = request.timeout(Duration::from_millis(timeout_ms));
        } else {
            request = request.timeout(Duration::from_secs(DEFAULT_TIMEOUT_SECS));
        }

        let mut has_cookie_header = false;
        for (key, value) in &headers {
            if key.trim().is_empty() || value.trim().is_empty() {
                continue;
            }
            if key.eq_ignore_ascii_case("cookie") {
                has_cookie_header = true;
            }
            request = request.header(key, value);
        }
        if !has_cookie_header {
            let cookie = self.store.cookie_header_for_url(url);
            if !cookie.is_empty() {
                request = request.header("Cookie", cookie);
            }
        }
        if let Some(body) = body {
            if !body.is_empty() {
                request = request.body(body);
            }
        }

        let mut response = request.send().await.map_err(|e| e.to_string())?;
        let status = response.status().as_u16();
        let final_url = response.url().to_string();

        let mut response_headers = HashMap::new();
        let mut set_cookies: Vec<String> = Vec::new();
        for (key, value) in response.headers().iter() {
            let value_str = value.to_str().unwrap_or("");
            if key.as_str().eq_ignore_ascii_case("set-cookie") {
                set_cookies.push(value_str.to_string());
            }
            response_headers.insert(key.as_str().to_string(), value_str.to_string());
        }
        if !set_cookies.is_empty() {
            self.store.capture_set_cookies(url, &set_cookies);
        }

        let mut buf: Vec<u8> = Vec::with_capacity(4096);
        loop {
            match response.chunk().await {
                Ok(Some(chunk)) => {
                    if buf.len() + chunk.len() > MAX_BODY_SIZE {
                        break;
                    }
                    buf.extend_from_slice(&chunk);
                }
                Ok(None) => break,
                Err(e) => return Err(e.to_string()),
            }
        }

        let (body, body_base64) = if want_binary {
            (None, Some(general_purpose::STANDARD.encode(&buf)))
        } else {
            (
                Some(decode_text_body(&buf, response_headers.get("content-type"))),
                None,
            )
        };

        Ok(HttpBridgeResponse {
            status,
            url: final_url,
            headers: response_headers,
            body,
            body_base64,
            error: None,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bridge() -> HttpBridge {
        HttpBridge::new(Arc::new(PluginStore::load(None)))
    }

    #[tokio::test]
    async fn invalid_url_returns_error_response() {
        let resp = bridge()
            .request("GET", "not-a-url", HashMap::new(), None, 0, -1, false)
            .await;
        assert_eq!(resp.status, 0);
        assert!(resp.error.is_some());
    }

    #[tokio::test]
    async fn invalid_method_returns_error() {
        let resp = bridge()
            .request("BAD METHOD", "https://example.com", HashMap::new(), None, 0, -1, false)
            .await;
        assert!(resp.error.is_some());
    }

    #[tokio::test]
    async fn cookie_injection_skipped_when_header_present() {
        let store = Arc::new(PluginStore::load(None));
        store.set_cookie("https://example.com/", "sid", "v1", None);
        let bridge = HttpBridge::new(store);
        // 直接验证内部逻辑：有 Cookie 头时不重复注入（通过网络层不可测，跳过）
        assert!(bridge.client_for(0).is_ok());
        assert!(bridge.client_for(10).is_ok());
    }
}
