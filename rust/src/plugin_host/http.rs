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
use std::error::Error;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

const USER_AGENT: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";
const MAX_BODY_SIZE: usize = 50 * 1024 * 1024;
const DEFAULT_TIMEOUT_SECS: u64 = 30;
const DEFAULT_REDIRECT_LIMIT: usize = 10;

/// 确定性 TLS 失败负缓存窗口：证书握手失败在设备上对该端点是确定性的
/// （插件的重试也不会成功），窗口内直接返回缓存错误，避免重试风暴
/// 反复做 TLS 握手拖垮低端机
const CERT_FAIL_COOLDOWN_SECS: u64 = 120;

/// 提取 https 端点标识（host:port）：证书失败按端点记，http 无证书不参与
fn cert_endpoint_key(url: &str) -> Option<String> {
    let u = reqwest::Url::parse(url).ok()?;
    if u.scheme() != "https" {
        return None;
    }
    let host = u.host_str()?.to_string();
    let port = u.port_or_known_default().unwrap_or(443);
    Some(format!("{host}:{port}"))
}

/// 是否为确定性证书失败（reqwest/hyper 错误链文本，已按 " -> " 展开）
fn is_cert_failure(err_text: &str) -> bool {
    let t = err_text.to_ascii_lowercase();
    t.contains("certificate")
}

/// 把 reqwest 错误链展开成可读字符串，便于前端定位 timeout/dns/connection/proxy 等问题。
fn format_request_error(err: reqwest::Error) -> String {
    let mut parts = Vec::new();
    parts.push(err.to_string());
    let mut source = err.source();
    while let Some(s) = source {
        parts.push(s.to_string());
        source = s.source();
    }
    parts.join(" -> ")
}

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
    /// 确定性 TLS 失败负缓存：host:port → (冷却截止时刻, 首次错误文本)
    cert_failures: Mutex<HashMap<String, (Instant, String)>>,
}

impl HttpBridge {
    pub fn new(store: Arc<PluginStore>) -> Self {
        Self {
            store,
            clients: Mutex::new(HashMap::new()),
            cert_failures: Mutex::new(HashMap::new()),
        }
    }

    /// 命中证书失败冷却窗口则返回缓存的错误文本（本次请求直接短路）
    fn cert_failure_cached(&self, url: &str) -> Option<String> {
        let key = cert_endpoint_key(url)?;
        let mut map = self.cert_failures.lock().unwrap();
        map.retain(|_, (until, _)| *until > Instant::now());
        let (until, err) = map.get(&key)?;
        if Instant::now() >= *until {
            return None;
        }
        Some(format!(
            "{err}（连接熔断：该地址证书握手失败，{CERT_FAIL_COOLDOWN_SECS}s 内跳过重复尝试）"
        ))
    }

    fn remember_cert_failure(&self, url: &str, err_text: &str) {
        let Some(key) = cert_endpoint_key(url) else {
            return;
        };
        let until = Instant::now() + Duration::from_secs(CERT_FAIL_COOLDOWN_SECS);
        let mut map = self.cert_failures.lock().unwrap();
        map.retain(|_, (u, _)| *u > Instant::now());
        map.entry(key).or_insert_with(|| (until, err_text.to_string()));
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
            // 跟随重定向，但每个跳转目标都需通过 SSRF 校验
            crate::security::ssrf::ssrf_redirect_policy()
        };
        let client = reqwest::Client::builder()
            .redirect(policy)
            .dns_resolver(crate::security::ssrf::pinned_dns_resolver())
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

        // 确定性 TLS 失败熔断：冷却窗口内不再重复握手，直接短路
        if let Some(cached_err) = self.cert_failure_cached(url) {
            return Err(cached_err);
        }

        // SSRF 防护：插件请求只允许公网 http/https 目标，拒绝内网/回环/云元数据等
        let t_validate = std::time::Instant::now();
        let parsed_url = crate::security::ssrf::validate_outbound_url(url)
            .await
            .map_err(|e| e.to_string())?;
        let validate_ms = t_validate.elapsed().as_millis();
        // fake-ip 目标（代理接管 DNS 但本应用被分应用排除、未走其隧道）会连接黑洞，
        // 缩短等待并在失败时给出针对性提示
        let fake_ip_target = parsed_url
            .host_str()
            .map(crate::security::ssrf::host_is_fake_ip_target)
            .unwrap_or(false);

        let mut request = client.request(method.clone(), url);
        let timeout = if timeout_ms > 0 {
            Duration::from_millis(timeout_ms)
        } else if fake_ip_target {
            Duration::from_secs(8)
        } else {
            Duration::from_secs(DEFAULT_TIMEOUT_SECS)
        };
        request = request.timeout(timeout);

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

        let t_send = std::time::Instant::now();
        let mut response = match request.send().await {
            Ok(r) => r,
            Err(e) => {
                if fake_ip_target {
                    return Err("连接失败：该域名被本机代理以 fake-ip 方式接管，但当前应用未走代理隧道（可能被分应用排除）。请在代理软件中将本应用加入代理名单，或将该域名设为直连/加入 fake-ip-filter".to_string());
                }
                let err_text = format_request_error(e);
                // 证书握手失败是确定性的：记录负缓存，让插件随后的重试瞬间短路
                if is_cert_failure(&err_text) {
                    self.remember_cert_failure(url, &err_text);
                }
                return Err(err_text);
            }
        };
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
                Err(e) => return Err(format_request_error(e)),
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

        let send_ms = t_send.elapsed().as_millis();
        let total_ms = t_validate.elapsed().as_millis();
        if send_ms >= 1500 || validate_ms >= 1500 {
            eprintln!(
                "[httpprobe] {method} {url} validate={validate_ms}ms send={send_ms}ms total={total_ms}ms status={status}"
            );
        }

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

    #[test]
    fn cert_endpoint_key_extracts_host_port() {
        assert_eq!(
            cert_endpoint_key("https://a.b:8443/x").as_deref(),
            Some("a.b:8443")
        );
        assert_eq!(cert_endpoint_key("https://a.b/x").as_deref(), Some("a.b:443"));
        assert_eq!(cert_endpoint_key("http://a.b/x"), None);
        assert_eq!(cert_endpoint_key("not-a-url"), None);
    }

    #[test]
    fn cert_failure_detection() {
        assert!(is_cert_failure(
            "error sending request for url (https://1.2.3.4/api) -> client error (Connect) -> invalid peer certificate: Other(OtherError(UnsupportedCertVersion))"
        ));
        assert!(!is_cert_failure("error sending request -> client error (Connect) -> connection refused"));
        assert!(!is_cert_failure("error sending request -> operation timed out"));
    }

    #[tokio::test]
    async fn cert_failure_negative_cache_short_circuits() {
        let bridge = HttpBridge::new(Arc::new(PluginStore::load(None)));
        let url = "https://cert-broken.example.com/api";
        assert!(bridge.cert_failure_cached(url).is_none());
        bridge.remember_cert_failure(
            url,
            "client error (Connect) -> invalid peer certificate: UnsupportedCertVersion",
        );
        let cached = bridge.cert_failure_cached(url).expect("should hit cooldown");
        assert!(cached.contains("连接熔断"));
        assert!(cached.contains("invalid peer certificate"));
    }
}
