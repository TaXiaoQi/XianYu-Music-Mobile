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
    /// Bit-perfect 输出：绕过响度归一化/EQ/音效/用户音量，按源位深整数直出。
    /// 开启时 DSP 全部旁通，仅保留安全限幅。
    pub bit_perfect: bool,
    /// DSD 原生 DoP 直通开关：仅对 .dsf/.dff 且为真时走 DoP 打包直出
    /// （绕过解码器与 DSP）；为假时 DSD 容器按 PCM 解码走常规管线。
    pub dsd_native_passthrough: bool,
    /// 共享模式 DSP 管线（日常播放）：AAudio 共享流走系统混音器输出到
    /// 当前默认设备，全效果链（EQ/混响/空间音效/变速变调）生效。
    /// 共享模式下 bit_perfect/DSD 直通/device_id 均被忽略。
    #[serde(default)]
    pub shared_mode: bool,
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
    #[cfg(not(target_os = "android"))]
    {
        let _ = (time_secs, is_playing);
    }
}

/// 暂停独占播放（不改变进度）。
pub fn pause_exclusive() {
    #[cfg(target_os = "android")]
    {
        android_aaudio::pause_exclusive();
    }
}

/// 从暂停恢复独占播放（不改变进度）。
pub fn resume_exclusive() {
    #[cfg(target_os = "android")]
    {
        android_aaudio::resume_exclusive();
    }
}

/// 设置用户音量（0.0–1.0）。
pub fn set_exclusive_volume(volume: f32) {
    #[cfg(target_os = "android")]
    {
        android_aaudio::set_exclusive_volume(volume);
    }
    #[cfg(not(target_os = "android"))]
    {
        let _ = volume;
    }
}

/// 运行时更新音量平衡（ReplayGain）目标增益，平滑渐变不中断播放。
pub fn set_exclusive_volume_balance_gain(gain: f32) {
    #[cfg(target_os = "android")]
    {
        android_aaudio::set_exclusive_volume_balance_gain(gain);
    }
    #[cfg(not(target_os = "android"))]
    {
        let _ = gain;
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

/// 运行时切换 Bit-perfect 直出：开启时立即绕过响度/EQ/音效/音量；
/// 关闭时恢复当前 DSP 链。格式协商（整数 vs 浮点）在启动时按初始值确定。
pub fn set_exclusive_bit_perfect(enabled: bool) {
    #[cfg(target_os = "android")]
    {
        android_aaudio::set_exclusive_bit_perfect(enabled);
    }
    #[cfg(not(target_os = "android"))]
    {
        let _ = enabled;
    }
}

/// 查询当前独占播放是否处于 Bit-perfect 直出状态。
pub fn is_exclusive_bit_perfect() -> bool {
    #[cfg(target_os = "android")]
    {
        android_aaudio::is_exclusive_bit_perfect()
    }
    #[cfg(not(target_os = "android"))]
    {
        false
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

/// 查询当前独占播放输出设备/格式信息（JSON），用于前端展示已选输出。
pub fn get_exclusive_device_info() -> String {
    #[cfg(target_os = "android")]
    {
        android_aaudio::get_exclusive_device_info()
    }
    #[cfg(not(target_os = "android"))]
    {
        serde_json::json!({
            "active": false,
            "deviceName": "",
            "sampleRate": 0,
            "channels": 0,
            "bitPerfect": false,
        })
        .to_string()
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
