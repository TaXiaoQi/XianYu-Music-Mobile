//! 歌词抓取共享 HTTP 管道：SSRF 防护、charset 解码。

use encoding_rs::{BIG5, EUC_KR, GBK, SHIFT_JIS, UTF_16BE, UTF_16LE};

pub(crate) struct HttpResponse {
    pub(crate) status: u16,
    pub(crate) body: String,
    pub(crate) body_bytes: Vec<u8>,
    /// 全部响应头（键转小写），对齐桌面端；歌单导入等场景需要读 location 等头
    pub(crate) headers: Vec<(String, String)>,
}

/// 从 Content-Type 头中提取 charset 参数，如 `text/plain; charset=gbk` → `gbk`。
/// （对齐桌面端 lyric_fetcher：GBK/Big5/Shift_JIS 等本地编码歌词页不再乱码）
pub(crate) fn extract_charset(content_type: Option<&str>) -> Option<String> {
    let header = content_type?;
    let (_, params) = header.split_once(';')?;
    for param in params.split(';') {
        let param = param.trim();
        if let Some(value) = param
            .strip_prefix("charset=")
            .or_else(|| param.strip_prefix("charset ="))
        {
            let value = value.trim().trim_matches('"').trim_matches('\'');
            if !value.is_empty() {
                return Some(value.to_ascii_lowercase());
            }
        }
    }
    None
}

/// 按 HTTP charset 解码响应体；无 charset 或未知 charset 时回退到内容探测。
pub(crate) fn decode_http_body(body_bytes: &[u8], content_type: Option<&str>) -> String {
    if let Some(charset) = extract_charset(content_type) {
        let decoded = match charset.as_str() {
            "utf-8" | "utf8" => None,
            "utf-16" | "utf-16le" => {
                let (decoded, _, _) = UTF_16LE.decode(body_bytes);
                Some(decoded.into_owned())
            }
            "utf-16be" => {
                let (decoded, _, _) = UTF_16BE.decode(body_bytes);
                Some(decoded.into_owned())
            }
            "gbk" | "gb2312" | "gb18030" | "cp936" => {
                let (decoded, _, _) = GBK.decode(body_bytes);
                Some(decoded.into_owned())
            }
            "big5" | "big-5" | "cp950" => {
                let (decoded, _, _) = BIG5.decode(body_bytes);
                Some(decoded.into_owned())
            }
            "shift_jis" | "shift-jis" | "sjis" | "cp932" => {
                let (decoded, _, _) = SHIFT_JIS.decode(body_bytes);
                Some(decoded.into_owned())
            }
            "euc-kr" | "euckr" | "cp949" => {
                let (decoded, _, _) = EUC_KR.decode(body_bytes);
                Some(decoded.into_owned())
            }
            _ => None,
        };
        if let Some(text) = decoded {
            return text;
        }
    }
    crate::music::lyrics::decode_lyrics_file_bytes(body_bytes)
}

pub(crate) async fn http_fetch_text(
    url: &str,
    method: &str,
    headers: &[(&str, &str)],
    body: Option<&str>,
) -> Result<HttpResponse, String> {
    // SSRF 防护：歌词取数仅允许公网 http/https 目标，拒绝内网/回环/元数据等
    crate::security::ssrf::validate_outbound_url(url)
        .await
        .map_err(|e| e.to_string())?;

    let client = reqwest::Client::builder()
        // 每个跳转目标都需通过 SSRF 校验
        .redirect(crate::security::ssrf::ssrf_redirect_policy())
        // DNS pinning：连接复用校验时刻已钉住的公网 IP，杜绝 rebinding TOCTOU
        .dns_resolver(crate::security::ssrf::pinned_dns_resolver())
        .build()
        .map_err(|e| e.to_string())?;

    let mut req = match method {
        "POST" => client.post(url),
        _ => client.get(url),
    };

    for (key, value) in headers {
        req = req.header(*key, *value);
    }

    if let Some(body) = body {
        req = req.body(body.to_string());
    }

    let resp = req.send().await.map_err(|e| e.to_string())?;
    let status = resp.status().as_u16();
    let headers: Vec<(String, String)> = resp
        .headers()
        .iter()
        .map(|(k, v)| {
            (
                k.as_str().to_ascii_lowercase(),
                v.to_str().unwrap_or_default().to_string(),
            )
        })
        .collect();
    let content_type = resp
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .map(|s| s.to_string());
    let body_bytes = resp.bytes().await.map_err(|e| e.to_string())?.to_vec();
    let body = decode_http_body(&body_bytes, content_type.as_deref());

    Ok(HttpResponse {
        status,
        body,
        body_bytes,
        headers,
    })
}

pub(crate) async fn http_fetch_binary(
    url: &str,
    method: &str,
    headers: &[(&str, &str)],
    body: Option<&str>,
) -> Result<HttpResponse, String> {
    http_fetch_text(url, method, headers, body).await
}

