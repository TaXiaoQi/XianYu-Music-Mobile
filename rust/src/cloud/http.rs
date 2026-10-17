// 网盘出站 HTTP 封装。
//
// 行为对齐移动端 cloud_http.dart：手动重定向（不自动跟随，逐跳捕获
// Set-Cookie）、15s 超时、json/form/raw 三种 body 形态。出站方为用户设备上
// 的客户端自身，SSRF 校验不在本模块重复（与 cloud_http.dart 同一安全模型）。
// 全局共享一个 Client（连接池）。

use std::sync::OnceLock;
use std::time::Duration;

use reqwest::redirect::Policy;
use serde_json::Value;

static CLIENT: OnceLock<reqwest::Client> = OnceLock::new();

pub fn client() -> &'static reqwest::Client {
    CLIENT.get_or_init(|| {
        reqwest::Client::builder()
            .timeout(Duration::from_secs(15))
            .connect_timeout(Duration::from_secs(10))
            .redirect(Policy::none())
            .build()
            .unwrap_or_default()
    })
}

/// 出站响应：status + headers + body + 原始 Set-Cookie 列表。
pub struct Outbound {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: String,
    pub set_cookies: Vec<String>,
    /// 本次请求实际命中的 URL（手动跟随重定向时由调用方续发，此值始终
    /// 等于请求 URL，留作扩展）。
    pub url: String,
}

impl Outbound {
    pub fn is_ok(&self) -> bool {
        (200..300).contains(&self.status)
    }

    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.as_str())
    }

    pub fn location(&self) -> Option<String> {
        self.header("location").map(|s| s.to_string())
    }

    /// Set-Cookie 解析成 name → value（取分号前的首段；同名后写覆盖前写，
    /// 贴合浏览器语义；保持插入序以稳定单测）。
    pub fn set_cookie_pairs(&self) -> Vec<(String, String)> {
        let mut keys: Vec<String> = Vec::new();
        let mut map: std::collections::HashMap<String, String> = std::collections::HashMap::new();
        for raw in &self.set_cookies {
            let head = raw.split(';').next().unwrap_or("");
            let eq = match head.find('=') {
                Some(i) if i > 0 => i,
                _ => continue,
            };
            let k = head[..eq].trim().to_string();
            let v = head[eq + 1..].trim().to_string();
            if !keys.contains(&k) {
                keys.push(k.clone());
            }
            map.insert(k, v);
        }
        keys.into_iter()
            .filter_map(|k| map.get(&k).map(|v| (k.clone(), v.clone())))
            .collect()
    }

    /// 懒解析 JSON；解析失败返回 Err。
    pub fn json(&self) -> Result<Value, String> {
        serde_json::from_str::<Value>(&self.body)
            .ok()
            .filter(|v| v.is_object() || v.is_array())
            .ok_or_else(|| "接口返回格式异常".to_string())
    }
}

/// 请求体形态（cloud_http.dart 的 json > form > raw 优先级由调用方保证）。
pub enum Body {
    Json(Value),
    Form(Vec<(String, String)>),
    Raw(String),
}

/// 统一请求入口：method 大小写不敏感；headers 逐条注入（UA/Referer/Cookie
/// 由各盘自行构造）。网络失败/超时统一返回 Err 文案。
pub async fn request(
    method: &str,
    url: &str,
    headers: &[(String, String)],
    body: Option<&Body>,
) -> Result<Outbound, String> {
    let m = reqwest::Method::from_bytes(method.to_uppercase().as_bytes())
        .map_err(|_| format!("非法请求方法: {method}"))?;
    let mut req = client().request(m, url);
    for (k, v) in headers {
        req = req.header(k.as_str(), v.as_str());
    }
    if let Some(b) = body {
        // 调用方已显式带 Content-Type 时不再注入——reqwest 对同名头
        // 逗号合并（application/json,application/json），阿里等严格
        // 校验 mime 的接口直接 400 InvalidContentType。
        let has_ct = headers
            .iter()
            .any(|(k, _)| k.eq_ignore_ascii_case("content-type"));
        req = match b {
            Body::Json(v) => {
                if !has_ct {
                    req = req.header("content-type", "application/json");
                }
                req.body(v.to_string())
            }
            Body::Form(pairs) => {
                let encoded: Vec<String> = pairs
                    .iter()
                    .map(|(k, v)| {
                        format!(
                            "{}={}",
                            url_encode(k),
                            url_encode(v)
                        )
                    })
                    .collect();
                if !has_ct {
                    req = req
                        .header("content-type", "application/x-www-form-urlencoded");
                }
                req.body(encoded.join("&"))
            }
            Body::Raw(s) => req.body(s.clone()),
        };
    }
    let resp = req
        .send()
        .await
        .map_err(|e| format!("网络请求失败: {e}"))?;
    let status = resp.status().as_u16();
    let mut headers_out: Vec<(String, String)> = Vec::new();
    let mut set_cookies: Vec<String> = Vec::new();
    for (name, value) in resp.headers() {
        let k = name.as_str().to_string();
        if k.eq_ignore_ascii_case("set-cookie") {
            if let Ok(v) = value.to_str() {
                set_cookies.push(v.to_string());
            }
        } else if let Ok(v) = value.to_str() {
            headers_out.push((k, v.to_string()));
        }
    }
    let body = resp.text().await.map_err(|e| format!("读取响应失败: {e}"))?;
    Ok(Outbound {
        status,
        headers: headers_out,
        body,
        set_cookies,
        url: url.to_string(),
    })
}

pub async fn get(url: &str, headers: &[(String, String)]) -> Result<Outbound, String> {
    request("GET", url, headers, None).await
}

/// 用调用方提供的 Client 发 GET（连接池独立于全局共享池）。
/// ecloud189 会话绑出口 IP 的换连接重试专用。
pub async fn request_with_client(
    client: &reqwest::Client,
    url: &str,
    headers: &[(String, String)],
) -> Result<Outbound, String> {
    let mut req = client.get(url);
    for (k, v) in headers {
        req = req.header(k.as_str(), v.as_str());
    }
    let resp = req
        .send()
        .await
        .map_err(|e| format!("网络请求失败: {e}"))?;
    let status = resp.status().as_u16();
    let mut headers_out: Vec<(String, String)> = Vec::new();
    let mut set_cookies: Vec<String> = Vec::new();
    for (name, value) in resp.headers() {
        let k = name.as_str().to_string();
        if k.eq_ignore_ascii_case("set-cookie") {
            if let Ok(v) = value.to_str() {
                set_cookies.push(v.to_string());
            }
        } else if let Ok(v) = value.to_str() {
            headers_out.push((k, v.to_string()));
        }
    }
    let body = resp.text().await.map_err(|e| format!("读取响应失败: {e}"))?;
    Ok(Outbound {
        status,
        headers: headers_out,
        body,
        set_cookies,
        url: url.to_string(),
    })
}

pub async fn post_json(
    url: &str,
    headers: &[(String, String)],
    body: &Value,
) -> Result<Outbound, String> {
    request("POST", url, headers, Some(&Body::Json(body.clone()))).await
}

pub async fn post_form(
    url: &str,
    headers: &[(String, String)],
    form: Vec<(String, String)>,
) -> Result<Outbound, String> {
    request("POST", url, headers, Some(&Body::Form(form))).await
}

/// 凭据键值拼 Cookie 请求头（cred 存 'cookie' 单键整串的盘不走这里）。
pub fn cookie_header(pairs: &[(String, String)]) -> String {
    pairs
        .iter()
        .map(|(k, v)| format!("{k}={v}"))
        .collect::<Vec<_>>()
        .join("; ")
}

/// 组合 query（跳过空值）；返回空串或 `?a=b&c=d`。对齐 cloud_http.dart joinQuery。
pub fn join_query(params: &[(&str, Option<&str>)]) -> String {
    let q: Vec<String> = params
        .iter()
        .filter_map(|(k, v)| {
            v.filter(|s| !s.is_empty())
                .map(|v| format!("{}={}", url_encode(k), url_encode(v)))
        })
        .collect();
    if q.is_empty() {
        String::new()
    } else {
        format!("?{}", q.join("&"))
    }
}

/// percent-encode（application/x-www-form-urlencoded 语义：空格转 +）。
/// 覆盖 URI 保留字符与非 ASCII；不转字母数字与 `-_.~`。
pub fn url_encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.as_bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(*b as char)
            }
            b' ' => out.push('+'),
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

/// percent-decode（对齐 Dart Uri.decodeComponent：'+' 不转空格）。
pub fn url_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            let hi = (b[i + 1] as char).to_digit(16);
            let lo = (b[i + 2] as char).to_digit(16);
            if let (Some(h), Some(l)) = (hi, lo) {
                out.push((h * 16 + l) as u8);
                i += 3;
                continue;
            }
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn join_query_skips_empty() {
        assert_eq!(join_query(&[("a", Some("1")), ("b", Some(""))]), "?a=1");
        assert_eq!(join_query(&[("a", None)]), "");
        assert_eq!(
            join_query(&[("k", Some("a b&c"))]),
            "?k=a+b%26c"
        );
    }

    #[test]
    fn cookie_header_pairs() {
        assert_eq!(
            cookie_header(&[("__pus".into(), "x".into()), ("puus".into(), "y".into())]),
            "__pus=x; puus=y"
        );
    }

    #[test]
    fn set_cookie_pairs_overrides_same_name() {
        let ob = Outbound {
            status: 200,
            headers: vec![],
            body: String::new(),
            set_cookies: vec![
                "a=1; Path=/".into(),
                "b=2; Expires=x".into(),
                "a=3; Path=/".into(),
            ],
            url: String::new(),
        };
        assert_eq!(
            ob.set_cookie_pairs(),
            vec![("a".to_string(), "3".to_string()), ("b".to_string(), "2".to_string())]
        );
    }

    #[test]
    fn url_decode_keeps_plus() {
        assert_eq!(url_decode("a%20b+c"), "a b+c");
        assert_eq!(url_decode("%E4%B8%AD%E6%96%87"), "中文");
    }
}
