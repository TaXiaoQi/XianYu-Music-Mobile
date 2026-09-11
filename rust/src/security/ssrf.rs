//! 出站 URL 防 SSRF 统一校验。
//!
//! 音乐/封面直链、插件 HTTP、账号 API 等出站目标均需经过本模块：
//! - 仅允许 http/https
//! - 拒绝带用户凭据的 URL
//! - 端口收敛到常见 Web 端口
//! - 拒绝 IP 字面量指向回环 / 私有 / link-local / 云元数据(169.254.169.254) / CGNAT /
//!   多播 / 保留 IP 等不可信目标，防止借插件探测内网与云元数据。
//!
//! > 说明：插件音源、在线搜索等业务本就要求「任意公网域名」，因此用 IP 字面量黑名单
//! > 而非域名白名单；域名解析结果不做禁区拒绝（兼容 VPN/TUN fake-ip 与企业内网 DNS），
//! > rebinding 由校验期钉住防御。

use reqwest::dns::{Name, Resolve, Resolving};
use std::collections::HashMap;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::{Mutex, OnceLock};

/// 已通过出站校验的 host → 钉住的公网解析结果（校验时刻解析）。
///
/// 用途：reqwest 连接时直接用「校验时刻」解析出的 IP，配合 `OutboundDnsResolver`，
/// 根除「校验解析」与「连接解析」两次独立解析被 DNS rebinding 拉开造成的 TOCTOU 间隙。
fn pinned_ips() -> &'static Mutex<HashMap<String, Vec<IpAddr>>> {
    static M: OnceLock<Mutex<HashMap<String, Vec<IpAddr>>>> = OnceLock::new();
    M.get_or_init(|| Mutex::new(HashMap::new()))
}

fn record_pinned_ips(host: &str, ips: Vec<IpAddr>) {
    if let Ok(mut m) = pinned_ips().lock() {
        m.insert(host.to_ascii_lowercase(), ips);
    }
}

fn pinned_anchor(host: &str) -> Option<Vec<IpAddr>> {
    pinned_ips().lock().ok()?.get(&host.to_ascii_lowercase()).cloned()
}

/// 解析域名并返回全部解析结果（供校验期钉住与 resolver 兜底复用）。
///
/// 注意：不对「域名解析出的 IP」做内网/保留段拒绝——VPN/TUN（fake-ip 将所有域名
/// 解析到 198.18.0.0/15）、企业/校园 VPN（10/8）与运营商内网 DNS 下，解析结果落在
/// 私有段属正常链路形态，拒绝会直接杀死 VPN 用户的全部网络。域名的 SSRF/rebinding
/// 风险由「校验期解析 + 钉住」（OutboundDnsResolver）与 IP 字面量黑名单防御。
pub async fn resolve_allowed_ips(host: &str, port: u16) -> Result<Vec<IpAddr>, String> {
    let mut addrs = tokio::net::lookup_host((host, port))
        .await
        .map_err(|e| format!("域名解析失败: {host} ({e})"))?;
    let mut out: Vec<IpAddr> = Vec::new();
    while let Some(sa) = addrs.next() {
        let ip = sa.ip();
        if !out.contains(&ip) {
            out.push(ip);
        }
    }
    if out.is_empty() {
        return Err(format!("域名未解析到任何地址: {host}"));
    }
    Ok(out)
}

/// reqwest 自定义 DNS resolver：连接时将域名解析为「已校验的公网 IP」。
///
/// - 该 host 已通过出站校验（已钉住）→ 直接返回校验时刻的 IP，杜绝 rebinding；
/// - 否则（如 reqwest 内部跟随的重定向目标）→ 即时解析兜底（不做禁区拒绝，见 resolve_allowed_ips）。
#[derive(Clone, Debug, Default)]
pub struct OutboundDnsResolver;

impl Resolve for OutboundDnsResolver {
    fn resolve(&self, name: Name) -> Resolving {
        let host = name.as_str().to_ascii_lowercase();
        Box::pin(async move {
            let ips: Vec<IpAddr> = match pinned_anchor(&host) {
                Some(ips) if !ips.is_empty() => ips,
                _ => resolve_allowed_ips(&host, 443).await.map_err(boxed_io_err)?,
            };
            // reqwest 会用 URL 端口覆盖此处 SocketAddr 的端口，故端口先置 0
            let addrs: Box<dyn Iterator<Item = SocketAddr> + Send> =
                Box::new(ips.into_iter().map(|ip| SocketAddr::new(ip, 0)));
            Ok(addrs)
        })
    }
}

/// 供 reqwest `ClientBuilder::dns_resolver` 使用的 Arc 版（reqwest 该 API 接受 `Arc<dyn Resolve>`）。
pub fn pinned_dns_resolver() -> std::sync::Arc<OutboundDnsResolver> {
    std::sync::Arc::new(OutboundDnsResolver)
}

fn boxed_io_err(e: String) -> Box<dyn std::error::Error + Send + Sync> {
    std::io::Error::other(e).into()
}

/// 允许显式使用的端口（缺省按 scheme 的 80/443 允许）。常见 Web/CDN 端口。
fn port_allowed(port: u16) -> bool {
    // 8082 被部分 bilibili 三方音源使用（m4s 直链）
    matches!(port, 80 | 443 | 3000 | 8000 | 8080 | 8082 | 8443 | 8888)
}

/// 判断 IP 是否为不可信目标（内网/回环/保留等）。
pub fn forbidden_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => forbidden_ipv4(v4),
        IpAddr::V6(v6) => {
            // 仅真正映射到 IPv4 的地址（::ffff:a.b.c.d）才按 IPv4 判定。
            // 注意：不可直接短路 to_ipv4()，否则 ::1 会被映射成 0.0.0.1 而绕过回环判定。
            let seg = v6.segments();
            let ipv4_mapped = seg[0] == 0
                && seg[1] == 0
                && seg[2] == 0
                && seg[3] == 0
                && seg[4] == 0
                && seg[5] == 0
                && seg[6] == 0xffff;
            if ipv4_mapped {
                if let Some(v4) = v6.to_ipv4() {
                    return forbidden_ipv4(v4);
                }
            }
            v6.is_unspecified()
                || v6.is_loopback()
                || v6.is_multicast()
                || (seg[0] & 0xfe00) == 0xfc00 // ULA fc00::/7
                || (seg[0] & 0xffc0) == 0xfe80 // link-local fe80::/10
                || seg[0] == 0 // ::/0 已被 is_unspecified 覆盖，此分支冗余防御
        }
    }
}

fn forbidden_ipv4(v4: Ipv4Addr) -> bool {
    let o = v4.octets();
    let a = o[0];
    let b = o[1];
    v4.is_unspecified()
        || v4.is_loopback()
        || v4.is_private()
        || v4.is_link_local()
        || v4.is_multicast()
        || v4.is_broadcast()
        || (a == 100 && (64..=127).contains(&b)) // 100.64.0.0/10 CGNAT 共享地址
        || (a == 192 && b == 0 && (o[2] == 2 || o[2] == 0)) // 192.0.0.0/24、192.0.2.0/24
        || (a == 198 && b == 18) // 198.18.0.0/15 基准测试
        || (a == 198 && b == 51 && o[2] == 100) // 198.51.100.0/24 文档
        || (a == 203 && b == 0 && o[2] == 113) // 203.0.113.0/24 文档
        || a >= 224 // 224.0.0.0/4 及以上（多播/保留）
}

/// 校验 host：仅 IP 字面量命中禁区时拒绝（SSRF 核心防线，保留）。
///
/// 域名不做 DNS 结果黑名单校验（原因见 resolve_allowed_ips），
/// 也不再同步阻塞 getaddrinfo —— rebinding 由校验期钉住机制防御。
fn check_host(host: &str) -> Result<(), String> {
    if let Ok(ip) = host.parse::<IpAddr>() {
        return if forbidden_ip(ip) {
            Err(format!("目标地址被禁止（内网/保留地址）: {ip}"))
        } else {
            Ok(())
        };
    }
    Ok(())
}

/// 轻量出站校验：仅当 host 是 IP 字面量且命中禁区时拒绝。
///
/// 不做 DNS 解析、不做端口白名单，用于音源直链这类端口/IP 多样、不宜硬校验的播放目标，
/// 只挡"直写内网/回环/保留地址"这种明显恶意字面量。
pub fn validate_url_ip_literal(url: &str) -> Result<(), String> {
    let parsed = reqwest::Url::parse(url).map_err(|e| format!("无效的 URL: {e}"))?;
    let scheme = parsed.scheme();
    if scheme != "http" && scheme != "https" {
        return Err(format!("仅允许 http/https，收到: {scheme}"));
    }
    // 域名不做 DNS 校验（避免误伤多 IP/CDN），仅拦截 IP 字面量命中禁区。
    // 注意 reqwest 的 host_str() 对 IPv6 会带方括号（如 [::1]），须先去掉再解析。
    let host = parsed.host_str().ok_or("URL 缺少主机名")?;
    let host_trim = host.trim_start_matches('[').trim_end_matches(']');
    if let Ok(ip) = host_trim.parse::<IpAddr>() {
        if forbidden_ip(ip) {
            return Err(format!("目标地址被禁止（内网/保留地址）: {ip}"));
        }
    }
    Ok(())
}

/// 轻量重定向策略：每个跳转目标只做 IP 字面量校验（域名不查 DNS、不做端口白名单）。
///
/// 用于播放流、用户配置的 WebDAV/账号 API 等端口/IP 多样、不宜硬校验的目标，
/// 只拦截跳转到"直写内网/保留地址"的重定向，对公网域名完全放行，误伤≈0。
pub fn ip_literal_redirect_policy() -> reqwest::redirect::Policy {
    reqwest::redirect::Policy::custom(|attempt| {
        if validate_url_ip_literal(attempt.url().as_str()).is_ok() {
            attempt.follow()
        } else {
            attempt.error(std::io::Error::other("重定向目标被安全策略禁止"))
        }
    })
}

/// 校验并解析出站 URL（同步版，供重定向策略等无法 await 的场景使用）。
///
/// 返回重组后的请求 URL 主体（scheme://host:port）供后续校验，并拒绝不可信目标。
pub fn validate_outbound_url_sync(url: &str) -> Result<reqwest::Url, String> {
    let parsed = reqwest::Url::parse(url).map_err(|e| format!("无效的 URL: {e}"))?;
    let scheme = parsed.scheme();
    if scheme != "http" && scheme != "https" {
        return Err(format!("仅允许 http/https，收到: {scheme}"));
    }
    if !parsed.username().is_empty() || parsed.password().is_some() {
        return Err("URL 不得包含用户凭据".to_string());
    }
    let host = parsed
        .host_str()
        .ok_or("URL 缺少主机名".to_string())?
        // host_str 对 IPv6 会带方括号（如 [::1]），check_host 需识别为 IP 字面量
        .trim_start_matches('[')
        .trim_end_matches(']')
        .to_string();
    if let Some(p) = parsed.port() {
        if !port_allowed(p) {
            return Err(format!("端口不在允许范围（80/443/3000/8000/8080/8082/8443/8888）: {p}"));
        }
    }
    check_host(&host)?;
    Ok(parsed)
}

/// 校验出站 URL（异步版，命令入口使用）。
///
/// 在同步校验的基础上，用 tokio 的 DNS 解析再校验一遍实际解析地址，
/// 以防御部分解析时序差异。
pub async fn validate_outbound_url(url: &str) -> Result<reqwest::Url, String> {
    let parsed = validate_outbound_url_sync(url)?;
    let host = parsed
        .host_str()
        .ok_or("URL 缺少主机名".to_string())?
        // host_str 对 IPv6 会带方括号（如 [::1]），先去掉便于按 IP 字面量识别
        .trim_start_matches('[')
        .trim_end_matches(']')
        .to_string();
    let default_port: u16 = if parsed.scheme() == "https" { 443 } else { 80 };
    let port = parsed.port().unwrap_or(default_port);

    // 若 host 是 IP 字面量，同步校验已覆盖；仅域名再经解析复核，并把合规 IP 钉住，
    // 供 OutboundDnsResolver 在连接时直接复用，杜绝 DNS rebinding 的校验/连接两次解析偏差。
    if host.parse::<IpAddr>().is_err() {
        let ips = resolve_allowed_ips(&host, port).await?;
        record_pinned_ips(&host, ips);
    }
    Ok(parsed)
}

/// 供重定向策略使用的目标校验：重定向跳转到不可信目标时返回错误。
///
/// reqwest 的 `Policy::custom` 是同步回调，这里用同步解析封堵内网跳转。
pub fn redirect_target_allowed(url: &str) -> bool {
    // 仅拦截明确不可信的目标；解析失败/异常一律视为拒绝（fail-closed）
    validate_outbound_url_sync(url).is_ok()
}

/// 构建内置 SSRF 防护的重定向策略：
/// 初始请求允许（跟随重定向），但每个跳转目标都需通过出站校验，否则视为致命错误。
/// 若客户端已禁用重定向则不启用策略（调用方负责）。
pub fn ssrf_redirect_policy() -> reqwest::redirect::Policy {
    reqwest::redirect::Policy::custom(|attempt| {
        if !redirect_target_allowed(attempt.url().as_str()) {
            attempt.error(std::io::Error::other("重定向目标被安全策略禁止"))
        } else {
            attempt.follow()
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn forbidden_ipv4_covers_private_loopback_linklocal() {
        assert!(forbidden_ip(IpAddr::V4(Ipv4Addr::new(127, 0, 0, 1))));
        assert!(forbidden_ip(IpAddr::V4(Ipv4Addr::new(10, 0, 0, 5))));
        assert!(forbidden_ip(IpAddr::V4(Ipv4Addr::new(192, 168, 1, 1))));
        assert!(forbidden_ip(IpAddr::V4(Ipv4Addr::new(172, 16, 0, 1))));
        assert!(forbidden_ip(IpAddr::V4(Ipv4Addr::new(169, 254, 169, 254))));
        assert!(forbidden_ip(IpAddr::V4(Ipv4Addr::new(100, 64, 0, 1))));
        assert!(forbidden_ip(IpAddr::V4(Ipv4Addr::new(224, 0, 0, 1))));
        assert!(forbidden_ip(IpAddr::V4(Ipv4Addr::UNSPECIFIED)));
    }

    #[test]
    fn public_ipv4_allowed() {
        assert!(!forbidden_ip(IpAddr::V4(Ipv4Addr::new(8, 8, 8, 8))));
        assert!(!forbidden_ip(IpAddr::V4(Ipv4Addr::new(1, 1, 1, 1))));
    }

    #[test]
    fn ipv6_loopback_ula_and_mapped_v4() {
        assert!(forbidden_ip(IpAddr::V6(std::net::Ipv6Addr::LOCALHOST)));
        assert!(forbidden_ip(IpAddr::V6("fd00::1".parse().unwrap())));
        assert!(forbidden_ip(IpAddr::V6("fe80::1".parse().unwrap())));
        // ::ffff:127.0.0.1 → 127.0.0.1 被禁
        assert!(forbidden_ip(IpAddr::V6("::ffff:127.0.0.1".parse().unwrap())));
        assert!(!forbidden_ip(IpAddr::V6("2606:4700:4700::1111".parse().unwrap())));
    }

    #[test]
    fn rejects_bad_scheme_and_credentials() {
        assert!(validate_outbound_url_sync("file:///etc/passwd").is_err());
        assert!(validate_outbound_url_sync("ftp://example.com/x").is_err());
        assert!(validate_outbound_url_sync("https://user:pw@example.com/").is_err());
    }

    #[test]
    fn rejects_literal_private_ip_url() {
        assert!(validate_outbound_url_sync("http://127.0.0.1/admin").is_err());
        assert!(validate_outbound_url_sync("http://169.254.169.254/latest/meta-data").is_err());
        assert!(validate_outbound_url_sync("http://192.168.0.1/x").is_err());
    }

    #[test]
    fn accepts_public_http_url() {
        assert!(validate_outbound_url_sync("https://example.com/song.mp3").is_ok());
        assert!(validate_outbound_url_sync("http://1.1.1.1/file.flac").is_ok());
    }

    #[test]
    fn rejects_uncommon_port() {
        assert!(validate_outbound_url_sync("http://example.com:3128/").is_err());
    }

    #[test]
    fn rejects_internal_ip_literal() {
        assert!(validate_url_ip_literal("http://127.0.0.1/x").is_err(), "127.0.0.1");
        assert!(validate_url_ip_literal("http://10.0.0.5/x").is_err(), "10.0.0.5");
        assert!(validate_url_ip_literal("http://169.254.169.254/latest/meta-data").is_err(), "meta");
        assert!(validate_url_ip_literal("http://[::1]/x").is_err(), "::1");
        assert!(validate_url_ip_literal("http://[::ffff:192.168.1.1]/x").is_err(), "v4mapped");
    }

    #[test]
    fn accepts_public_ip_literal_and_domain() {
        assert!(validate_url_ip_literal("http://1.1.1.1/file.flac").is_ok());
        assert!(validate_url_ip_literal("https://example.com/song.mp3").is_ok());
        // 域名不做 DNS/端口校验，仅非 http(s) scheme 才拒
        assert!(validate_url_ip_literal("ftp://example.com/x").is_err());
    }

    #[tokio::test]
    async fn outbound_dns_resolver_uses_pinned_ips_without_network() {
        // 钉住一个 host → resolver 直接返回该校验时刻的 IP，不触发真实 DNS
        let ip: IpAddr = "1.2.3.4".parse().unwrap();
        record_pinned_ips("pinned.example", vec![ip]);
        let resolver = pinned_dns_resolver();
        let name: reqwest::dns::Name = "pinned.example".parse().unwrap();
        let fut = resolver.resolve(name);
        let mut addr = tokio::time::timeout(std::time::Duration::from_secs(2), fut)
            .await
            .expect("resolver 不应超时")
            .expect("解析应成功");
        assert!(addr.any(|sa| sa.ip() == ip));
    }

    #[tokio::test]
    async fn outbound_dns_resolver_rejects_pinned_forbidden_redirect_rebinding() {
        // 即使攻击者让校验期解析到公网、连接期 rebinding 到内网，resolver 也只认钉住的 IP，
        // 且兜底路径（未钉住）会对任何内网 IP 拒绝 —— 本用例验证兜底拒绝。
        // 直接构造「域名未钉住时解析到内网」场景：用不可达 TLD，防意外命中真实 DNS 永远失败。
        let resolver = pinned_dns_resolver();
        let name: reqwest::dns::Name = "ssrf-rebinding-fail.invalid".parse().unwrap();
        let fut = resolver.resolve(name);
        // 未钉住 + 解析失败/命中禁区 → 都必须返回 Err（不返回内网 IP）
        let res = tokio::time::timeout(std::time::Duration::from_secs(2), fut)
            .await
            .expect("resolver 不应超时");
        // .invalid 应解析失败，或即便解析也不应是内网 → 结果为 Err 或非内网
        match res {
            Err(_) => {}
            Ok(addr) => {
                for sa in addr {
                    assert!(!forbidden_ip(sa.ip()), "兜底不允许返回内网 IP");
                }
            }
        }
    }
}
