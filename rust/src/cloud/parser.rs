// 分享链接归属识别：输入任意分享 URL，识别属于哪张盘并提取分享码/提取码。
// 移植自移动端 share_link_parser.dart（正则逐条对齐，行为以 Dart 版为准）。

use serde_json::json;

pub struct ShareLinkInfo {
    pub provider_id: &'static str,
    pub share_id: String,
    pub passcode: Option<String>,
    pub url: String,
}

/// 按域名/路径正则逐盘匹配；未识别返回 None。
pub fn parse_url_to_provider(raw: &str) -> Option<ShareLinkInfo> {
    let url = raw.trim();
    if url.is_empty() {
        return None;
    }

    // 百度：pan.baidu.com/s/1xxxx（surl= 与短链 #/s/1xxx）
    if let Some(m) = regex::Regex::new(
        r"pan\.baidu\.com/(?:s/1|#/s/1|\?surl=|share/init\?surl=)([A-Za-z0-9_-]+)",
    )
    .ok()
    .and_then(|re| re.captures(url))
    {
        return Some(ShareLinkInfo {
            provider_id: "baidu",
            share_id: m[1].to_string(),
            passcode: query_param(url, "pwd"),
            url: url.to_string(),
        });
    }

    // 阿里：www.alipan.com/s/xxx / www.aliyundrive.com/s/xxx
    if let Some(m) = regex::Regex::new(r"(?:alipan|aliyundrive)\.com/(?:s|#/s)/([A-Za-z0-9]+)")
        .ok()
        .and_then(|re| re.captures(url))
    {
        return Some(ShareLinkInfo {
            provider_id: "aliyun",
            share_id: m[1].to_string(),
            passcode: query_param(url, "pwd"),
            url: url.to_string(),
        });
    }

    // 夸克：pan.quark.cn/s/xxx（#提取码）
    if let Some(m) = regex::Regex::new(r"pan\.quark\.cn/s/([A-Za-z0-9]+)")
        .ok()
        .and_then(|re| re.captures(url))
    {
        return Some(ShareLinkInfo {
            provider_id: "quark",
            share_id: m[1].to_string(),
            passcode: trailing_pwd(url).or_else(|| query_param(url, "pwd")),
            url: url.to_string(),
        });
    }

    // UC：drive.uc.cn/s/xxx
    if let Some(m) = regex::Regex::new(r"drive\.uc\.cn/s/([A-Za-z0-9]+)")
        .ok()
        .and_then(|re| re.captures(url))
    {
        return Some(ShareLinkInfo {
            provider_id: "uc",
            share_id: m[1].to_string(),
            passcode: trailing_pwd(url).or_else(|| query_param(url, "pwd")),
            url: url.to_string(),
        });
    }

    // 天翼：cloud.189.cn/t/xxx（web 分享）；web/share?code=xxx（web 分享页变体）
    if let Some(m) = regex::Regex::new(r"cloud\.189\.cn/(?:t|web/share)/([A-Za-z0-9]+)|cloud\.189\.cn/web/share\?code=([A-Za-z0-9]+)")
        .ok()
        .and_then(|re| re.captures(url))
    {
        return Some(ShareLinkInfo {
            provider_id: "ecloud189",
            // 两个分支各占一个捕获组，取先命中者。
            share_id: m
                .get(1)
                .or_else(|| m.get(2))
                .map(|c| c.as_str().to_string())
                .unwrap_or_default(),
            passcode: query_param(url, "accessCode"),
            url: url.to_string(),
        });
    }

    // 139：yun.139.com/shareweb/#/w/i/xxx
    if let Some(m) = regex::Regex::new(r"yun\.139\.com/shareweb/#/w/i/([A-Za-z0-9]+)")
        .ok()
        .and_then(|re| re.captures(url))
    {
        return Some(ShareLinkInfo {
            provider_id: "mobile139",
            share_id: m[1].to_string(),
            passcode: query_param(url, "pwd"),
            url: url.to_string(),
        });
    }

    // 迅雷：pan.xunlei.com/s/xxx#提取码
    if let Some(m) = regex::Regex::new(r"pan\.xunlei\.com/s/([A-Za-z0-9]+)")
        .ok()
        .and_then(|re| re.captures(url))
    {
        return Some(ShareLinkInfo {
            provider_id: "thunder",
            share_id: m[1].to_string(),
            passcode: trailing_pwd(url),
            url: url.to_string(),
        });
    }

    // 123 盘：新域名 {uid}.share.123pan.cn/123pan/{key}，经典域名
    // 123pan.com / 123684 / 123865 / 123912 等 /s/{key}；key 现为 a-b
    // 连字符形态，整段即 ShareKey（实测拆开报 ShareKey格式异常）；提取码取 ?pwd=
    if let Some(m) = regex::Regex::new(
        r"[A-Za-z0-9]+\.share\.123pan\.cn/123pan/([A-Za-z0-9]+(?:-[A-Za-z0-9]+)*)|(?:123pan|123684|123865|123912|123685)\.(?:com|cn)/s/([A-Za-z0-9]+(?:-[A-Za-z0-9]+)*)",
    )
    .ok()
    .and_then(|re| re.captures(url))
    {
        let id = m
            .get(1)
            .map(|c| c.as_str().to_string())
            .unwrap_or_else(|| m[2].to_string());
        return Some(ShareLinkInfo {
            provider_id: "pan123",
            share_id: id,
            passcode: query_param(url, "pwd"),
            url: url.to_string(),
        });
    }

    // PikPak：mypikpak.com/s/xxx
    if let Some(m) = regex::Regex::new(r"mypikpak\.com/s/([A-Za-z0-9]+)")
        .ok()
        .and_then(|re| re.captures(url))
    {
        return Some(ShareLinkInfo {
            provider_id: "pikpak",
            share_id: m[1].to_string(),
            passcode: trailing_pwd(url),
            url: url.to_string(),
        });
    }

    // 蓝奏：lanzou[xiouu]/lanzn/lanvf/lanpv 等域名 /s/ 或 /#/s/
    if let Some(m) = regex::Regex::new(
        r"lanzou[a-z]?\.com/(?:s/|#(?:/s/))([A-Za-z0-9]+)|lanz(?:n|vf|pv|ou?i|ou?u|ou?x|ou?e)\.(?:com|net|org)/(?:s/|#(?:/s/))([A-Za-z0-9]+)",
    )
    .ok()
    .and_then(|re| re.captures(url))
    {
        let id = m
            .get(1)
            .map(|c| c.as_str().to_string())
            .unwrap_or_else(|| m[2].to_string());
        return Some(ShareLinkInfo {
            provider_id: "lanzou",
            share_id: id,
            passcode: query_param(url, "pwd"),
            url: url.to_string(),
        });
    }

    // 微云：share.weiyun.com/xxx
    if let Some(m) = regex::Regex::new(r"share\.weiyun\.com/([A-Za-z0-9]+)")
        .ok()
        .and_then(|re| re.captures(url))
    {
        return Some(ShareLinkInfo {
            provider_id: "weiyun",
            share_id: m[1].to_string(),
            passcode: query_param(url, "pwd"),
            url: url.to_string(),
        });
    }

    None
}

/// 识别结果的 JSON 形态（cloud_proxy parse_share op 前置使用）。
pub fn parse_to_json(raw: &str) -> Option<serde_json::Value> {
    parse_url_to_provider(raw).map(|i| {
        json!({
            "providerId": i.provider_id,
            "shareId": i.share_id,
            "passcode": i.passcode,
            "url": i.url,
        })
    })
}

/// URL query 取参（对齐 Dart _queryParam：值含 '=' 的段跳过）。
pub fn query_param(url: &str, key: &str) -> Option<String> {
    let idx = url.find('?')?;
    let q = &url[idx + 1..];
    for seg in q.split(['#', '&']) {
        let parts: Vec<&str> = seg.split('=').collect();
        if parts.len() == 2 && parts[0] == key && !parts[1].is_empty() {
            return Some(super::http::url_decode(parts[1]));
        }
    }
    None
}

/// `.../s/xxx#提取码` 形式的尾缀提取码（对齐 Dart _trailingPwd）。
pub fn trailing_pwd(url: &str) -> Option<String> {
    let hash_idx = url.find('#')?;
    let tail = url[hash_idx + 1..].trim();
    if tail.is_empty() || tail.contains('/') {
        return None;
    }
    if tail.starts_with("访问码:") || tail.starts_with("pwd=") {
        return Some(
            tail.rsplit(':')
                .next()
                .unwrap_or(tail)
                .rsplit('=')
                .next()
                .unwrap_or(tail)
                .to_string(),
        );
    }
    Some(tail.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(url: &str) -> ShareLinkInfo {
        parse_url_to_provider(url).expect("should parse")
    }

    #[test]
    fn baidu() {
        let i = parse("https://pan.baidu.com/s/1AbC_d-9?pwd=xy12");
        assert_eq!(i.provider_id, "baidu");
        assert_eq!(i.share_id, "AbC_d-9");
        assert_eq!(i.passcode.as_deref(), Some("xy12"));
    }

    #[test]
    fn baidu_short_link() {
        let i = parse("https://pan.baidu.com/share/init?surl=AbC123");
        assert_eq!(i.provider_id, "baidu");
        assert_eq!(i.share_id, "AbC123");
    }

    #[test]
    fn aliyun() {
        let i = parse("https://www.alipan.com/s/abcXYZ123");
        assert_eq!(i.provider_id, "aliyun");
        assert_eq!(i.share_id, "abcXYZ123");
    }

    #[test]
    fn quark_trailing_pwd() {
        let i = parse("https://pan.quark.cn/s/abc123#访问码:xy99");
        assert_eq!(i.provider_id, "quark");
        assert_eq!(i.share_id, "abc123");
        assert_eq!(i.passcode.as_deref(), Some("xy99"));
    }

    #[test]
    fn quark_plain_hash_pwd() {
        let i = parse("https://pan.quark.cn/s/abc123#9zzz");
        assert_eq!(i.passcode.as_deref(), Some("9zzz"));
    }

    #[test]
    fn uc() {
        let i = parse("https://drive.uc.cn/s/ucshare1");
        assert_eq!(i.provider_id, "uc");
        assert_eq!(i.share_id, "ucshare1");
    }

    #[test]
    fn ecloud189() {
        let i = parse("https://cloud.189.cn/t/AbCdEf?accessCode=8899");
        assert_eq!(i.provider_id, "ecloud189");
        assert_eq!(i.share_id, "AbCdEf");
        assert_eq!(i.passcode.as_deref(), Some("8899"));
    }

    #[test]
    fn ecloud189_web_share_code() {
        // web 分享页变体；中文访问码尾巴不参与提取（用户单独填）。
        let i = parse("https://cloud.189.cn/web/share?code=NJRbUfrQfIZb（访问码：cm8n）");
        assert_eq!(i.provider_id, "ecloud189");
        assert_eq!(i.share_id, "NJRbUfrQfIZb");
        assert_eq!(i.passcode, None);
        let i2 = parse("https://cloud.189.cn/web/share?code=NJRbUfrQfIZb&accessCode=cm8n");
        assert_eq!(i2.share_id, "NJRbUfrQfIZb");
        assert_eq!(i2.passcode.as_deref(), Some("cm8n"));
    }

    #[test]
    fn mobile139() {
        let i = parse("https://yun.139.com/shareweb/#/w/i/abcDEF123");
        assert_eq!(i.provider_id, "mobile139");
        assert_eq!(i.share_id, "abcDEF123");
    }

    #[test]
    fn thunder() {
        let i = parse("https://pan.xunlei.com/s/XYabc123#pwd12");
        assert_eq!(i.provider_id, "thunder");
        assert_eq!(i.share_id, "XYabc123");
        assert_eq!(i.passcode.as_deref(), Some("pwd12"));
    }

    #[test]
    fn pan123_new_share_domain() {
        let i = parse("https://1823556104.share.123pan.cn/123pan/4xPFjv-68d5A?pwd=vRuu");
        assert_eq!(i.provider_id, "pan123");
        assert_eq!(i.share_id, "4xPFjv-68d5A");
        assert_eq!(i.passcode.as_deref(), Some("vRuu"));
    }

    #[test]
    fn pan123_classic_domain_hyphen_key() {
        let i = parse("https://www.123684.com/s/4xPFjv-68d5A?pwd=vRuu");
        assert_eq!(i.provider_id, "pan123");
        assert_eq!(i.share_id, "4xPFjv-68d5A");
        assert_eq!(i.passcode.as_deref(), Some("vRuu"));
    }

    #[test]
    fn pan123_classic_domain_plain_key() {
        let i = parse("https://www.123pan.com/s/abc123");
        assert_eq!(i.provider_id, "pan123");
        assert_eq!(i.share_id, "abc123");
        assert_eq!(i.passcode.as_deref(), None);
    }

    #[test]
    fn lanzou_com() {
        let i = parse("https://lanzoui.com/s/abc123");
        assert_eq!(i.provider_id, "lanzou");
        assert_eq!(i.share_id, "abc123");
    }

    #[test]
    fn lanzou_hash_route() {
        let i = parse("https://lanzn.com/#/s/xyz789");
        assert_eq!(i.provider_id, "lanzou");
        assert_eq!(i.share_id, "xyz789");
    }

    #[test]
    fn lanzou_alt_domain() {
        let i = parse("https://lanzouv.com/s/ab12cd");
        assert_eq!(i.provider_id, "lanzou");
        assert_eq!(i.share_id, "ab12cd");
    }

    #[test]
    fn weiyun() {
        let i = parse("https://share.weiyun.com/abc123XYZ");
        assert_eq!(i.provider_id, "weiyun");
        assert_eq!(i.share_id, "abc123XYZ");
    }

    #[test]
    fn unknown_returns_none() {
        assert!(parse_url_to_provider("https://example.com/s/xxx").is_none());
        assert!(parse_url_to_provider("").is_none());
    }

    #[test]
    fn query_param_skips_value_with_equals() {
        // Dart 版 kv.length==2 才命中：值里含 '=' 视为不匹配
        assert_eq!(query_param("https://x.com/s/1?pwd=a=b", "pwd"), None);
        assert_eq!(
            query_param("https://x.com/s/1?pwd=ab%20cd", "pwd"),
            Some("ab cd".to_string())
        );
    }
}
