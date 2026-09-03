//! 局域网工具（双端同步一份代码，勿在本端私自改动）。

use std::net::IpAddr;

/// 探测本机对局域网的出口 IP（UDP connect 不发包，仅查路由表）。
pub fn lan_ip() -> Option<IpAddr> {
    let sock = std::net::UdpSocket::bind("0.0.0.0:0").ok()?;
    sock.connect("8.8.8.8:80").ok()?;
    sock.local_addr().ok().map(|a| a.ip())
}

/// 局域网媒体服务基础 URL。
pub fn lan_base_url(port: u16) -> String {
    let ip = lan_ip()
        .map(|i| i.to_string())
        .unwrap_or_else(|| "127.0.0.1".into());
    format!("http://{ip}:{port}")
}
