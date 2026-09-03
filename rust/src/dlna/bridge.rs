//! 移动端 DMR 宿主桥（移动端专属文件，非双端同步；桌面端实现在 dlna/commands.rs）。
//!
//! ExoPlayer 的播放状态在 Dart/原生侧，Rust 无法直接读取：
//! Dart 侧在播放状态/进度变化时调用 `dlna_dmr_report_playback`（api 层）
//! 把快照写进全局状态，SOAP GetPositionInfo / GetTransportInfo 应答从这里读取。

use super::types::{DmrHost, DmrPlaybackReport, TransportState};
use std::sync::{Arc, Mutex, OnceLock};

#[derive(Debug, Clone)]
struct Snapshot {
    state: TransportState,
    position_secs: f64,
    duration_secs: f64,
    volume_percent: u8,
    muted: bool,
}

impl Default for Snapshot {
    fn default() -> Self {
        Self {
            state: TransportState::NoMedia,
            position_secs: 0.0,
            duration_secs: 0.0,
            volume_percent: 100,
            muted: false,
        }
    }
}

fn snapshot() -> &'static Mutex<Snapshot> {
    static SNAP: OnceLock<Mutex<Snapshot>> = OnceLock::new();
    SNAP.get_or_init(|| Mutex::new(Snapshot::default()))
}

/// Dart 侧上报播放快照（api 层 `dlna_dmr_report_playback` 调用）。
pub fn report_playback(
    state: TransportState,
    position_secs: f64,
    duration_secs: f64,
    volume_percent: u8,
    muted: bool,
) {
    let mut snap = snapshot().lock().unwrap();
    snap.state = state;
    snap.position_secs = position_secs.max(0.0);
    snap.duration_secs = duration_secs.max(0.0);
    snap.volume_percent = volume_percent.clamp(0, 100);
    snap.muted = muted;
}

/// 清空快照（渲染器关闭时调用，避免残留旧状态）。
pub fn reset_playback() {
    *snapshot().lock().unwrap() = Snapshot::default();
}

/// 移动端 DMR 宿主：从 Dart 上报的快照读取状态。
struct MobileDmrHost;

impl DmrHost for MobileDmrHost {
    fn playback_snapshot(&self) -> DmrPlaybackReport {
        let snap = snapshot().lock().unwrap();
        DmrPlaybackReport {
            state: snap.state,
            position_secs: snap.position_secs,
            duration_secs: snap.duration_secs,
        }
    }

    fn volume_snapshot(&self) -> (u8, bool) {
        let snap = snapshot().lock().unwrap();
        (snap.volume_percent, snap.muted)
    }
}

/// 渲染器启用时取宿主实例。
pub fn host() -> Arc<dyn DmrHost> {
    Arc::new(MobileDmrHost)
}
