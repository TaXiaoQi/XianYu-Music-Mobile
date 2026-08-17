//! Android USB 独占音频输出模块。
//!
//! 移植自 RawS 的 `native_audio_engine.cpp` AAudio DIRECT 路径。
//! 通过 `AAUDIO_SHARING_MODE_EXCLUSIVE` 绕过 Android 混音器，
//! 直接路由到 USB DAC，实现 bit-perfect 独占播放。
//!
//! 仅在 `target_os = "android"` 编译；其他平台提供桩函数返回不支持。

use serde::{Deserialize, Serialize};

#[cfg(target_os = "android")]
pub(crate) mod android_aaudio;

/// 独占播放启动请求。
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ExclusivePlayRequest {
    /// 本地文件路径
    pub path: String,
    /// AAudio 设备 ID（USB DAC），-1 = 默认设备
    pub device_id: i32,
    /// 初始音量 0.0–1.0
    pub volume: f32,
    /// 起始播放位置（秒）
    pub start_time_secs: f64,
    /// true = 启动即播放；false = 暂停等待 resume
    pub is_playing: bool,
    /// 音量平衡增益（响度归一化，1.0 = 不变）
    pub volume_balance_gain: f32,
    /// EQ 设置 JSON（camelCase），空串 = 默认
    pub equalizer_settings_json: String,
    /// 音效设置 JSON（camelCase），空串 = 默认
    pub sound_effect_settings_json: String,
}

// =========================================================================
// 跨平台 API（非 Android 为桩实现）
// =========================================================================

/// 启动 USB 独占播放。返回设备名或错误信息。
pub fn start_exclusive_playback(request: ExclusivePlayRequest) -> Result<String, String> {
    #[cfg(target_os = "android")]
    {
        android_aaudio::start_exclusive_playback(request)
    }
    #[cfg(not(target_os = "android"))]
    {
        let _ = request;
        Err("USB 独占模式仅在 Android 端可用".to_string())
    }
}

/// 停止独占播放并释放设备。
pub fn stop_exclusive_playback() {
    #[cfg(target_os = "android")]
    {
        android_aaudio::stop_exclusive_playback();
    }
}

/// 跳转到指定位置（秒）。`is_playing` 控制跳转后是否恢复播放。
pub fn seek_exclusive(time_secs: f64, is_playing: bool) {
    #[cfg(target_os = "android")]
    {
        android_aaudio::seek_exclusive(time_secs, is_playing);
    }
}

/// 设置用户音量（0.0–1.0）。
pub fn set_exclusive_volume(volume: f32) {
    #[cfg(target_os = "android")]
    {
        android_aaudio::set_exclusive_volume(volume);
    }
}

/// 更新 EQ 设置。
pub fn set_exclusive_equalizer(settings_json: String) -> Result<(), String> {
    #[cfg(target_os = "android")]
    {
        android_aaudio::set_exclusive_equalizer(&settings_json)
    }
    #[cfg(not(target_os = "android"))]
    {
        let _ = settings_json;
        Ok(())
    }
}

/// 更新音效设置。
pub fn set_exclusive_sound_effect(settings_json: String) -> Result<(), String> {
    #[cfg(target_os = "android")]
    {
        android_aaudio::set_exclusive_sound_effect(&settings_json)
    }
    #[cfg(not(target_os = "android"))]
    {
        let _ = settings_json;
        Ok(())
    }
}

/// 独占播放是否活跃。
pub fn is_exclusive_active() -> bool {
    #[cfg(target_os = "android")]
    {
        android_aaudio::is_exclusive_active()
    }
    #[cfg(not(target_os = "android"))]
    {
        false
    }
}

/// 获取当前播放位置（秒）。
pub fn get_exclusive_position_secs() -> f64 {
    #[cfg(target_os = "android")]
    {
        android_aaudio::get_exclusive_position_secs()
    }
    #[cfg(not(target_os = "android"))]
    {
        0.0
    }
}

/// 获取当前播放采样率。
pub fn get_exclusive_sample_rate() -> u32 {
    #[cfg(target_os = "android")]
    {
        android_aaudio::get_exclusive_sample_rate()
    }
    #[cfg(not(target_os = "android"))]
    {
        0
    }
}

/// 获取当前声道数。
pub fn get_exclusive_channels() -> u16 {
    #[cfg(target_os = "android")]
    {
        android_aaudio::get_exclusive_channels()
    }
    #[cfg(not(target_os = "android"))]
    {
        0
    }
}
