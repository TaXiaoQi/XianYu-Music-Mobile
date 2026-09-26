//! SSDP（简单服务发现协议，UPnP 设备发现层；双端同步一份代码，勿在本端私自改动）。
//!
//! - 发送端（DMC）：M-SEARCH 搜索局域网 MediaRenderer。
//! - 接收端（DMR）：NOTIFY alive/byebye 广播 + 监听 1900 端口单播应答 M-SEARCH。
//!
//! 全程使用 socket2 设置 SO_REUSEADDR，与 Windows SSDP Discovery 服务、
//! 其它投屏 App 常驻的 1900 端口共存。

use socket2::{Domain, Protocol, Socket, Type};
use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4};
use std::sync::Arc;
use std::time::Duration;
use tokio::net::UdpSocket;
use tokio::sync::watch;

pub const SSDP_MULTICAST_V4: Ipv4Addr = Ipv4Addr::new(239, 255, 255, 250);
pub const SSDP_PORT: u16 = 1900;
pub const ALIVE_MAX_AGE: &str = "1800";

/// 取默认路由出网 IPv4（与 net_util::lan_ip 同判据；本文件三端同步，避免跨模块依赖）。
fn lan_ipv4() -> Option<Ipv4Addr> {
    let sock = std::net::UdpSocket::bind("0.0.0.0:0").ok()?;
    sock.connect("8.8.8.8:80").ok()?;
    match sock.local_addr().ok()?.ip() {
        std::net::IpAddr::V4(v4) => Some(v4),
        std::net::IpAddr::V6(_) => None,
    }
}

/// 组播 socket 绑定（三端复用；SO_REUSEADDR 允许多进程共用 1900）。
fn bind_multicast_socket() -> std::io::Result<Socket> {
    let sock = Socket::new(Domain::IPV4, Type::DGRAM, Some(Protocol::UDP))?;
    sock.set_reuse_address(true)?;
    #[cfg(unix)]
    let _ = sock.set_reuse_port(true);
    let bind_addr = SocketAddr::from((Ipv4Addr::UNSPECIFIED, SSDP_PORT));
    sock.bind(&bind_addr.into())?;
    // 加入 SSDP 组播组必须显式落在默认路由网卡：交给系统自选（UNSPECIFIED）时，
    // 多网卡机器（虚拟网卡/WiFi Direct/蓝牙并存）常 join 到收不到局域网
    // M-SEARCH 的接口，导致 DMR 无法被搜索发现。加入失败不致命：仍可发 alive
    // 广播、应答单播 M-SEARCH，仅主动搜索路径不可用。
    let iface = lan_ipv4();
    if let Some(ip) = iface {
        let _ = sock.set_multicast_if_v4(&ip);
    }
    let join = match iface {
        Some(ip) => sock.join_multicast_v4(&SSDP_MULTICAST_V4, &ip),
        None => sock.join_multicast_v4(&SSDP_MULTICAST_V4, &Ipv4Addr::UNSPECIFIED),
    };
    if let Err(e) = join {
        eprintln!("[dlna] join SSDP multicast group on {iface:?} failed: {e}");
    }
    Ok(sock)
}

fn tokio_udp_from_socket(sock: Socket) -> std::io::Result<UdpSocket> {
    sock.set_nonblocking(true)?;
    let std_sock: std::net::UdpSocket = sock.into();
    UdpSocket::from_std(std_sock)
}

/// 从 SSDP 报文提取头部值（大小写不敏感）。
fn header_value(msg: &str, name: &str) -> Option<String> {
    msg.lines()
        .skip(1)
        .find_map(|line| {
            let (k, v) = line.split_once(':')?;
            if k.trim().eq_ignore_ascii_case(name) {
                Some(v.trim().to_string())
            } else {
                None
            }
        })
}

/// M-SEARCH 搜索局域网 DLNA 渲染器，返回去重后的 LOCATION 列表。
pub async fn search_renderers(timeout_ms: u64) -> Vec<String> {
    let std_sock = match lan_ipv4() {
        // 多网卡时显式指定组播出接口，避免 M-SEARCH 从虚拟网卡发出导致设备收不到
        Some(iface) => Socket::new(Domain::IPV4, Type::DGRAM, Some(Protocol::UDP))
            .and_then(|s| {
                s.set_multicast_if_v4(&iface)?;
                s.bind(&SocketAddr::from((Ipv4Addr::UNSPECIFIED, 0)).into())?;
                s.set_nonblocking(true)?;
                Ok(s)
            })
            .map(std::net::UdpSocket::from),
        None => std::net::UdpSocket::bind("0.0.0.0:0"),
    };
    let Ok(std_sock) = std_sock else {
        return Vec::new();
    };
    let sock = match UdpSocket::from_std(std_sock) {
        Ok(s) => s,
        Err(_) => return Vec::new(),
    };
    let target: SocketAddr = SocketAddrV4::new(SSDP_MULTICAST_V4, SSDP_PORT).into();
    let mut packet = String::from("M-SEARCH * HTTP/1.1\r\n");
    packet.push_str("HOST: 239.255.255.250:1900\r\n");
    packet.push_str("MAN: \"ssdp:discover\"\r\n");
    packet.push_str("MX: 3\r\n");
    packet.push_str("ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n");
    let ssdp_all = packet.replace(
        "ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n",
        "ST: ssdp:all\r\n",
    );

    // 发两轮提高命中率；防火墙丢组播时至少一轮单播回包可达。
    for p in [&packet, &ssdp_all] {
        let _ = sock.send_to(p.as_bytes(), target).await;
    }

    let mut found: Vec<String> = Vec::new();
    let deadline = tokio::time::Instant::now() + Duration::from_millis(timeout_ms.max(300));
    let mut buf = vec![0u8; 4096];
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            break;
        }
        match tokio::time::timeout(remaining, sock.recv_from(&mut buf)).await {
            Ok(Ok((n, _from))) => {
                let msg = String::from_utf8_lossy(&buf[..n]).to_string();
                if !msg.starts_with("HTTP/1.1 200") {
                    continue;
                }
                if let Some(loc) = header_value(&msg, "LOCATION") {
                    if !found.contains(&loc) {
                        found.push(loc);
                    }
                }
            }
            _ => break, // 超时或错误
        }
    }
    found
}

/// DMR 广播会话句柄：stop() 即下线（byebye 由任务内部发出）。
pub struct SsdpAdvertiser {
    shutdown_tx: watch::Sender<bool>,
}

pub struct AdvertiseConfig {
    pub udn: String,
    /// desc.xml 完整 URL。
    pub location: String,
}

impl SsdpAdvertiser {
    /// 启动 alive 广播 + M-SEARCH 单播应答。
    ///
    /// socket 与常驻任务均在专用 runtime 上创建/运行（IO 资源与创建它的
    /// runtime 绑定，不能跨 runtime 迁移），结果经 oneshot 回传调用方。
    pub async fn start(cfg: AdvertiseConfig) -> Result<Self, String> {
        let (ready_tx, ready_rx) = tokio::sync::oneshot::channel::<Result<(), String>>();
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        super::spawn::spawn_persistent(async move {
            let _ = run_advertiser(cfg, shutdown_rx, ready_tx).await;
        });
        ready_rx
            .await
            .map_err(|_| "SSDP 任务启动失败".to_string())??;
        Ok(Self { shutdown_tx })
    }

    /// 发送 byebye 并结束广播（幂等）。
    pub fn stop(&self) {
        let _ = self.shutdown_tx.send(true);
    }
}

async fn run_advertiser(
    cfg: AdvertiseConfig,
    mut shutdown_rx: watch::Receiver<bool>,
    ready_tx: tokio::sync::oneshot::Sender<Result<(), String>>,
) -> Result<(), String> {
    let sock = match bind_multicast_socket() {
        Ok(s) => match tokio_udp_from_socket(s) {
            Ok(s) => s,
            Err(e) => {
                let _ = ready_tx.send(Err(format!("convert SSDP socket failed: {e}")));
                return Err(format!("convert SSDP socket failed: {e}"));
            }
        },
        Err(e) => {
            let _ = ready_tx.send(Err(format!("bind SSDP 1900 failed: {e}")));
            return Err(format!("bind SSDP 1900 failed: {e}"));
        }
    };
    // socket 就绪立即回执：run_advertiser 是常驻循环，只有 shutdown 才返回，
    // ready 不能等循环退出再发（否则 start() 永远挂起，enable_renderer 卡死）。
    let _ = ready_tx.send(Ok(()));
    let sock = Arc::new(sock);

    let udn = cfg.udn.clone();
    let location = cfg.location.clone();
    let target: SocketAddr = SocketAddrV4::new(SSDP_MULTICAST_V4, SSDP_PORT).into();
    let alive = alive_messages(&udn, &location);
    let byebye = byebye_messages(&udn);

    // 启动连发 2 次 alive，加快被控制点发现。
    for _ in 0..2 {
        for msg in &alive {
            let _ = sock.send_to(msg.as_bytes(), target).await;
        }
    }

    let mut interval = tokio::time::interval(Duration::from_secs(30));
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    let mut buf = vec![0u8; 2048];

    loop {
        tokio::select! {
            _ = shutdown_rx.changed() => break,
            _ = interval.tick() => {
                for msg in &alive {
                    let _ = sock.send_to(msg.as_bytes(), target).await;
                }
            }
            res = sock.recv_from(&mut buf) => {
                let Ok((n, from)) = res else { break };
                let msg = String::from_utf8_lossy(&buf[..n]).to_string();
                if !msg.starts_with("M-SEARCH") {
                    continue;
                }
                let Some(st) = header_value(&msg, "ST") else { continue };
                // 只应答我们提供的服务类型。
                let matched = st == "ssdp:all"
                    || st == "upnp:rootdevice"
                    || st == "urn:schemas-upnp-org:device:MediaRenderer:1"
                    || st == "urn:schemas-upnp-org:service:AVTransport:1"
                    || st == "urn:schemas-upnp-org:service:RenderingControl:1"
                    || st.starts_with("uuid:");
                if !matched {
                    continue;
                }
                let usn = if st.starts_with("uuid:") {
                    st.clone()
                } else {
                    format!("uuid:{udn}::{st}")
                };
                // MX 抖动：随机延迟 0~500ms 应答，避免风暴。
                rand_delay().await;
                let reply = format!(
                    "HTTP/1.1 200 OK\r\n\
                     CACHE-CONTROL: max-age={ALIVE_MAX_AGE}\r\n\
                     EXT:\r\n\
                     LOCATION: {location}\r\n\
                     SERVER: XianYu-Music/1.0 UPnP/1.0 XianYuDLNA/1.0\r\n\
                     ST: {st}\r\n\
                     USN: {usn}\r\n\r\n"
                );
                let _ = sock.send_to(reply.as_bytes(), from).await;
            }
        }
    }

    // 下线广播。
    for msg in &byebye {
        let _ = sock.send_to(msg.as_bytes(), target).await;
    }
    Ok(())
}

fn alive_messages(udn: &str, location: &str) -> Vec<String> {
    let nt_usn = [
        (format!("uuid:{udn}"), format!("uuid:{udn}")),
        (
            "upnp:rootdevice".to_string(),
            format!("uuid:{udn}::upnp:rootdevice"),
        ),
        (
            "urn:schemas-upnp-org:device:MediaRenderer:1".to_string(),
            format!("uuid:{udn}::urn:schemas-upnp-org:device:MediaRenderer:1"),
        ),
        (
            "urn:schemas-upnp-org:service:AVTransport:1".to_string(),
            format!("uuid:{udn}::urn:schemas-upnp-org:service:AVTransport:1"),
        ),
        (
            "urn:schemas-upnp-org:service:RenderingControl:1".to_string(),
            format!("uuid:{udn}::urn:schemas-upnp-org:service:RenderingControl:1"),
        ),
    ];
    nt_usn
        .into_iter()
        .map(|(nt, usn)| {
            format!(
                "NOTIFY * HTTP/1.1\r\n\
                 HOST: 239.255.255.250:1900\r\n\
                 CACHE-CONTROL: max-age={ALIVE_MAX_AGE}\r\n\
                 LOCATION: {location}\r\n\
                 NT: {nt}\r\n\
                 NTS: ssdp:alive\r\n\
                 SERVER: XianYu-Music/1.0 UPnP/1.0 XianYuDLNA/1.0\r\n\
                 USN: {usn}\r\n\r\n"
            )
        })
        .collect()
}

fn byebye_messages(udn: &str) -> Vec<String> {
    [
        format!("uuid:{udn}"),
        format!("uuid:{udn}::upnp:rootdevice"),
        format!("uuid:{udn}::urn:schemas-upnp-org:device:MediaRenderer:1"),
    ]
    .into_iter()
    .map(|nt| {
        format!(
            "NOTIFY * HTTP/1.1\r\n\
             HOST: 239.255.255.250:1900\r\n\
             NT: {nt}\r\n\
             NTS: ssdp:byebye\r\n\
             USN: {nt}\r\n\r\n"
        )
    })
    .collect()
}

async fn rand_delay() {
    // 无 rand crate 依赖，用时间熵做 0~500ms 抖动。
    let ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.subsec_millis() % 500)
        .unwrap_or(0);
    tokio::time::sleep(Duration::from_millis(ms as u64)).await;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn header_lookup_is_case_insensitive() {
        let msg = "HTTP/1.1 200 OK\r\nLOCATION: http://1.2.3.4/desc.xml\r\nusn: uuid:x\r\n\r\n";
        assert_eq!(
            header_value(msg, "location").as_deref(),
            Some("http://1.2.3.4/desc.xml")
        );
        assert_eq!(header_value(msg, "USN").as_deref(), Some("uuid:x"));
        assert_eq!(header_value(msg, "NT"), None);
    }

    #[test]
    fn alive_messages_cover_required_types() {
        let msgs = alive_messages("udn-1", "http://1.2.3.4:9958/dlna/desc.xml");
        assert_eq!(msgs.len(), 5);
        assert!(msgs[0].contains("NTS: ssdp:alive"));
        assert!(msgs.iter().all(|m| m.contains("udn-1")));
    }

    /// 回归：DMR 必须加入 SSDP 组播组，否则收不到控制点的 M-SEARCH，无法被主动发现。
    /// 环境不支持（1900 被独占 / 无组播）时跳过，避免 CI 误报。
    #[tokio::test]
    async fn advertiser_answers_msearch_after_join() {
        let probe = match std::net::UdpSocket::bind("0.0.0.0:0") {
            Ok(s) => s,
            Err(_) => return,
        };
        probe
            .set_read_timeout(Some(Duration::from_millis(500)))
            .unwrap();
        let adv = match SsdpAdvertiser::start(AdvertiseConfig {
            udn: "test-udn-1234".into(),
            location: "http://127.0.0.1:9958/dlna/desc.xml".into(),
        })
        .await
        {
            Ok(a) => a,
            Err(_) => return,
        };

        let target: SocketAddr = SocketAddrV4::new(SSDP_MULTICAST_V4, SSDP_PORT).into();
        let msg = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: ssdp:all\r\n\r\n";
        probe.send_to(msg.as_bytes(), target).unwrap();

        let mut buf = vec![0u8; 2048];
        let mut got = false;
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        while std::time::Instant::now() < deadline {
            match probe.recv_from(&mut buf) {
                Ok((n, _)) => {
                    let text = String::from_utf8_lossy(&buf[..n]).to_string();
                    if text.starts_with("HTTP/1.1 200") && text.contains("test-udn-1234") {
                        got = true;
                        break;
                    }
                }
                Err(_) => continue, // 超时继续等（应答带 0~500ms 抖动）
            }
        }
        adv.stop();
        assert!(got, "DMR 未应答 M-SEARCH（组播加入可能失败）");
    }
}
