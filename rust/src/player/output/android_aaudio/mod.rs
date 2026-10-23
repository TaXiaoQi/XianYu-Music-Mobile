//! AAudio 独占模式实现（仅 Android）。
//!
//! 移植自 RawS `native_audio_engine.cpp` 的 AAudio DIRECT 路径：
//! - `AAUDIO_SHARING_MODE_EXCLUSIVE` 绕过 Android 混音器
//! - `setDeviceId` 路由到 USB DAC
//! - 浮点 32bit / Int16 双格式协商
//! - 失败时返回明确错误，供调用方降级到 `just_audio`
//!
//! 动态加载 `libaaudio.so`（API 26+），低版本自动降级。
//!
//! 拆分说明：FFI 绑定见 ffi，解码见 decoder，播放状态机见 playback，DSD 直通见 dsd，流创建见 stream。
//!
//! 本模块整体在 `any(android, ohos)`（即 `any(target_os = "android",
//! target_env = "ohos")`）下编译：decoder（Symphonia 解码）与
//! 管线诊断（PIPELINE_DIAG / reset / take）是平台无关的共享基础设施，
//! `ohos_audio` 输出层直接复用；AAudio 相关的 ffi/stream/dsd/playback
//! 仅在 android 编译。测试依赖 ffi 的格式转换，保持 android 门控。
#![allow(dead_code)]
// 以下 re-export 仅供 android 专属子模块（playback/stream/dsd/ffi）消费；
// ohos 侧只用 decoder 与诊断基础设施，不门控会在 ohos target 下报
// unused_imports（decoder 共享，qmc2/io/Arc/Duration 等两平台都用）。
pub(crate) use crate::player::buffered_source::BlockProducer;
#[cfg(target_os = "android")]
pub(crate) use crate::player::buffered_source::BufferedSource;
#[cfg(target_os = "android")]
pub(crate) use crate::player::output::ExclusivePlayRequest;
#[cfg(target_os = "android")]
pub(crate) use crate::player::dsd_dop::{parse_dsd_info, DopStreamSource};
#[cfg(target_os = "android")]
pub(crate) use crate::player::equalizer::{
    ClipGuardSource, Equalizer, EqualizerHandle, EqualizerSettings, UserVolumeSource,
};
#[cfg(target_os = "android")]
pub(crate) use crate::player::loudness::VolumeNormalizer;
#[cfg(target_os = "android")]
pub(crate) use crate::player::sound_effect::{SoundEffectBlockProcessor, SoundEffectSettings};
#[cfg(target_os = "android")]
pub(crate) use crate::player::types::global_visualizer;
pub(crate) use crate::player::qmc2::{looks_like_qmc_encrypted, extract_ekey_from_footer, QmcCrypto, QmcDecryptReader};
pub(crate) use std::io::{Read, Seek, SeekFrom};
pub(crate) use std::sync::atomic::{AtomicBool, Ordering};
#[cfg(target_os = "android")]
pub(crate) use std::sync::atomic::{AtomicU32, AtomicU64};
#[cfg(target_os = "android")]
pub(crate) use std::sync::mpsc::{self, Receiver, Sender, SyncSender};
pub(crate) use std::sync::{Arc, Mutex, OnceLock};
/// 记录工作线程退出原因到共享 slot（诊断用：Flutter 侧在 active=false 时读取展示）。
/// 模块级定义（macro_rules! 仅对定义点之后的代码可见）。
#[cfg(target_os = "android")]
macro_rules! set_exit_reason {
    ($last_error:expr, $msg:expr) => {
        if let Ok(mut slot) = $last_error.lock() {
            *slot = Some($msg.to_string());
        }
    };
}
#[cfg(target_os = "android")]
pub(crate) use std::thread;
pub(crate) use std::time::Duration;

mod decoder;
#[cfg(target_os = "android")]
mod dsd;
#[cfg(target_os = "android")]
mod ffi;
#[cfg(target_os = "android")]
mod playback;
#[cfg(target_os = "android")]
mod stream;

#[cfg(target_os = "android")]
pub use playback::*;
pub(crate) use decoder::*;
#[cfg(target_os = "android")]
pub(crate) use dsd::*;
#[cfg(target_os = "android")]
pub(crate) use ffi::*;
#[cfg(target_os = "android")]
pub(crate) use stream::*;

/// 管线内诊断事件环（seek/panic 等，容量 16）：音频线程 EOF 退出时并入
/// last_error 上报 Flutter——管线线程的 eprintln 在 Android 上不可见，
/// 死亡消息是唯一能带出运行时现场的信道路径。
pub(crate) static PIPELINE_DIAG: OnceLock<Mutex<Vec<String>>> = OnceLock::new();

/// 从 URL 提取小写扩展名（去掉 query/fragment），供流式源格式探测。
/// 无扩展名返回 None（此时 symphonia 依赖嗅探）。
/// （原在 dsd.rs，decoder 在 ohos 下也用它，上移到共享层。）
pub(crate) fn url_path_extension(url: &str) -> Option<String> {
    let path = url.split(['?', '#']).next()?;
    let file = path.rsplit('/').next()?;
    let ext = file.rsplit('.').next()?;
    if ext.is_empty() || ext.len() == file.len() {
        return None;
    }
    let lower = ext.to_ascii_lowercase();
    // 仅接受合理扩展名形态（字母数字），排除版本号类路径段。
    if !lower.chars().all(|c| c.is_ascii_alphanumeric()) {
        return None;
    }
    Some(lower)
}

pub(crate) fn record_pipeline_diag(msg: &str) {
    let slot = PIPELINE_DIAG.get_or_init(|| Mutex::new(Vec::new()));
    if let Ok(mut guard) = slot.lock() {
        guard.push(msg.to_string());
        if guard.len() > 16 {
            guard.remove(0);
        }
    }
}

pub fn take_pipeline_diag() -> String {
    let slot = PIPELINE_DIAG.get_or_init(|| Mutex::new(Vec::new()));
    match slot.lock() {
        Ok(mut g) => std::mem::take(&mut *g).join(" | "),
        Err(_) => String::new(),
    }
}

/// 管线启动时清空上一会话的诊断残留。DECODER_LAST_ERROR 跨播放不重置，
/// 曾把新会话的死因误注解成旧会话的「end of stream」，排障被严重误导。
pub fn reset_pipeline_diag() {
    if let Some(slot) = DECODER_LAST_ERROR.get() {
        if let Ok(mut guard) = slot.lock() {
            *guard = None;
        }
    }
    if let Some(slot) = PIPELINE_DIAG.get() {
        if let Ok(mut guard) = slot.lock() {
            guard.clear();
        }
    }
}

// =========================================================================
// 测试
// =========================================================================

#[cfg(all(test, target_os = "android"))]
mod tests {
    use super::*;

    #[test]
    fn push_sample_bytes_float32_roundtrip() {
        let mut buf = Vec::new();
        push_sample_bytes(&mut buf, 0.5, DeviceFormat::Float32);
        assert_eq!(buf.len(), 4);
        let val = f32::from_le_bytes([buf[0], buf[1], buf[2], buf[3]]);
        assert!((val - 0.5).abs() < 1e-6);
    }

    #[test]
    fn push_sample_bytes_int16_range() {
        let mut buf = Vec::new();
        push_sample_bytes(&mut buf, 1.0, DeviceFormat::Int16);
        let val = i16::from_le_bytes([buf[0], buf[1]]);
        assert_eq!(val, 32767);

        let mut buf = Vec::new();
        push_sample_bytes(&mut buf, -1.0, DeviceFormat::Int16);
        let val = i16::from_le_bytes([buf[0], buf[1]]);
        assert_eq!(val, -32767);
    }

    #[test]
    fn push_sample_bytes_clamps_overflow() {
        let mut buf = Vec::new();
        push_sample_bytes(&mut buf, 2.0, DeviceFormat::Float32);
        let val = f32::from_le_bytes([buf[0], buf[1], buf[2], buf[3]]);
        assert!((val - 1.0).abs() < 1e-6);
    }

    #[test]
    fn device_format_bytes_per_sample() {
        assert_eq!(DeviceFormat::Float32.bytes_per_sample(), 4);
        assert_eq!(DeviceFormat::Int16.bytes_per_sample(), 2);
    }
}
