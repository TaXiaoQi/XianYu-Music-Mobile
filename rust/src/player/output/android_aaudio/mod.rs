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
#![allow(dead_code)]
pub(crate) use crate::player::buffered_source::{BlockProducer, BufferedSource};
pub(crate) use crate::player::output::ExclusivePlayRequest;
pub(crate) use crate::player::dsd_dop::{parse_dsd_info, DopStreamSource};
pub(crate) use crate::player::equalizer::{
    ClipGuardSource, Equalizer, EqualizerHandle, EqualizerSettings, UserVolumeSource,
};
pub(crate) use crate::player::loudness::VolumeNormalizer;
pub(crate) use crate::player::sound_effect::{SoundEffectBlockProcessor, SoundEffectSettings};
pub(crate) use crate::player::types::global_visualizer;
pub(crate) use crate::player::qmc2::{looks_like_qmc_encrypted, extract_ekey_from_footer, QmcCrypto, QmcDecryptReader};
pub(crate) use std::io::{Read, Seek, SeekFrom};
pub(crate) use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
pub(crate) use std::sync::mpsc::{self, Receiver, Sender, SyncSender};
pub(crate) use std::sync::{Arc, Mutex, OnceLock};
/// 记录工作线程退出原因到共享 slot（诊断用：Flutter 侧在 active=false 时读取展示）。
/// 模块级定义（macro_rules! 仅对定义点之后的代码可见）。
macro_rules! set_exit_reason {
    ($last_error:expr, $msg:expr) => {
        if let Ok(mut slot) = $last_error.lock() {
            *slot = Some($msg.to_string());
        }
    };
}
pub(crate) use std::thread;
pub(crate) use std::time::Duration;

mod decoder;
mod dsd;
mod ffi;
mod playback;
mod stream;

pub use playback::*;
pub(crate) use decoder::*;
pub(crate) use dsd::*;
pub(crate) use ffi::*;
pub(crate) use stream::*;

/// 管线内诊断事件环（seek/panic 等，容量 16）：音频线程 EOF 退出时并入
/// last_error 上报 Flutter——管线线程的 eprintln 在 Android 上不可见，
/// 死亡消息是唯一能带出运行时现场的信道路径。
pub(crate) static PIPELINE_DIAG: OnceLock<Mutex<Vec<String>>> = OnceLock::new();

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

#[cfg(test)]
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
