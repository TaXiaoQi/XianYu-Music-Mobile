//! DLNA 双向投屏公共类型（双端同步一份代码，勿在本端私自改动）。

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// 局域网内发现的 DLNA 渲染器（MediaRenderer）设备。
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct DlnaDevice {
    pub udn: String,
    pub friendly_name: String,
    pub model_name: String,
    /// 设备描述 XML 的 URL（SSDP LOCATION）。
    pub location: String,
    /// 描述 XML 的 origin（scheme://host:port），用于相对路径解析。
    pub base_url: String,
    /// AVTransport 控制端点（绝对 URL）。
    pub avt_control_url: Option<String>,
    /// RenderingControl 控制端点（绝对 URL）。
    pub rcs_control_url: Option<String>,
}

/// 投屏媒体载荷：本地文件直接读，远程 URL 带防盗链头代理转发。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind")]
pub enum MediaPayload {
    #[serde(rename = "local")]
    LocalFile { path: String },
    #[serde(rename = "remote")]
    Remote {
        url: String,
        #[serde(default)]
        headers: BTreeMap<String, String>,
        /// 直链解析时间戳（毫秒），上层用于 TTL 续投判断。
        #[serde(default)]
        resolved_at_ms: u64,
    },
    /// 封面：服务端带头取回字节，供电视拉取 albumArtURI。
    #[serde(rename = "cover")]
    Cover {
        url: String,
        #[serde(default)]
        headers: BTreeMap<String, String>,
    },
}

/// UPnP AVTransport 传输状态。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
pub enum TransportState {
    Playing,
    PausedPlayback,
    #[default]
    Stopped,
    NoMedia,
    Transitioning,
}

impl TransportState {
    pub fn as_str(&self) -> &'static str {
        match self {
            TransportState::Playing => "PLAYING",
            TransportState::PausedPlayback => "PAUSED_PLAYBACK",
            TransportState::Stopped => "STOPPED",
            TransportState::NoMedia => "NO_MEDIA_PRESENT",
            TransportState::Transitioning => "TRANSITIONING",
        }
    }
    pub fn from_upnp(s: &str) -> Self {
        match s.trim().to_ascii_uppercase().as_str() {
            "PLAYING" => TransportState::Playing,
            "PAUSED_PLAYBACK" => TransportState::PausedPlayback,
            "STOPPED" => TransportState::Stopped,
            "TRANSITIONING" => TransportState::Transitioning,
            _ => TransportState::NoMedia,
        }
    }
}

/// DMR 渲染器收到的控制点指令（交宿主播放器执行）。
#[derive(Debug, Clone, Serialize)]
#[serde(tag = "type")]
pub enum DmrCommand {
    #[serde(rename = "loadUri")]
    LoadUri {
        uri: String,
        #[serde(default)]
        title: String,
        #[serde(default)]
        artist: String,
        #[serde(default)]
        album: String,
        #[serde(default)]
        duration_ms: u64,
        /// 原始 DIDL-Lite 元数据（宿主可忽略）。
        #[serde(default)]
        metadata_xml: String,
    },
    #[serde(rename = "play")]
    Play,
    #[serde(rename = "pause")]
    Pause,
    #[serde(rename = "stop")]
    Stop,
    #[serde(rename = "seek")]
    Seek { secs: f64 },
    #[serde(rename = "setVolume")]
    SetVolume { percent: u8 },
    #[serde(rename = "setMute")]
    SetMute { on: bool },
}

/// 宿主播放器状态快照（供 GetPositionInfo / GetTransportInfo 应答）。
#[derive(Debug, Clone, Copy, Default)]
pub struct DmrPlaybackReport {
    pub state: TransportState,
    pub position_secs: f64,
    pub duration_secs: f64,
}

/// DMR 宿主抽象：渲染器从宿主播放器读取当前状态。
pub trait DmrHost: Send + Sync {
    fn playback_snapshot(&self) -> DmrPlaybackReport;
    /// (volume 0-100, muted)
    fn volume_snapshot(&self) -> (u8, bool);
}

/// 渲染器启动配置。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RendererConfig {
    /// 对外展示的设备名（如「弦予音乐 · XX的电脑」）。
    pub friendly_name: String,
    /// 稳定 UDN（uuid），空则本次随机生成（建议上层持久化）。
    #[serde(default)]
    pub udn: String,
}

/// cast_set_uri 返回结果（token 供 TTL 续投热替换上游）。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CastMediaInfo {
    pub media_token: String,
    pub media_url: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cover_token: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cover_url: Option<String>,
}

/// 播放传输状态查询结果。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CastTransportState {
    pub position_secs: f64,
    pub duration_secs: f64,
    pub state: String,
}
