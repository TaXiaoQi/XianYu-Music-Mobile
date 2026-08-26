//! 统一播放命令层（Unified playback command layer）。
//!
//! 把移动端独占（AAudio）播放的所有控制命令收敛到单一枚举 + 单一分发入口，
//! 对齐桌面端 `AudioCommand` + session 运行时循环。前端任意播放控制
//! （播放/暂停/恢复/跳转/停止/音量/响度/EQ/音效/Bit-perfect 直出）都经
//! [`dispatch_playback_command`] 派发，避免散落的逐函数调用导致状态不一致。
//!
//! 说明：移动端常规播放由 Flutter 侧 just_audio 负责，Rust 仅接管 USB 独占
//! 直出（AAudio）。因此本命令层面向独占引擎；对常规播放无副作用。

use crate::player::output;

/// 统一播放命令。
#[derive(Clone, Debug)]
pub enum PlaybackCommand {
    /// 启动独占播放（含 Bit-perfect/DSD 直出参数）。
    Play {
        path: String,
        device_id: i32,
        volume: f32,
        start_time_secs: f64,
        is_playing: bool,
        volume_balance_gain: f32,
        equalizer_settings_json: String,
        sound_effect_settings_json: String,
        bit_perfect: bool,
        dsd_native_passthrough: bool,
    },
    /// 暂停（保持进度）。
    Pause,
    /// 恢复播放。
    Resume,
    /// 跳转（`is_playing` 控制跳转后是否播放）。
    Seek { time_secs: f64, is_playing: bool },
    /// 停止并释放设备。
    Stop,
    /// 设置用户音量（0.0–1.0）。Bit-perfect 直出时被旁通。
    SetVolume(f32),
    /// 更新响度归一化（ReplayGain）目标增益。
    SetVolumeBalanceGain(f32),
    /// 更新 EQ 设置（camelCase JSON）。
    SetEqualizer(String),
    /// 更新音效设置（camelCase JSON）。
    SetSoundEffect(String),
    /// 运行时切换 Bit-perfect 直出（绕过响度/EQ/音效/音量）。
    SetBitPerfect(bool),
}

/// 统一分发入口。
///
/// `Play` 返回设备名；其余返回空串。错误返回 `Err`（含「未处于独占播放」）。
pub fn dispatch_playback_command(cmd: PlaybackCommand) -> Result<String, String> {
    match cmd {
        PlaybackCommand::Play {
            path,
            device_id,
            volume,
            start_time_secs,
            is_playing,
            volume_balance_gain,
            equalizer_settings_json,
            sound_effect_settings_json,
            bit_perfect,
            dsd_native_passthrough,
        } => {
            let request = output::ExclusivePlayRequest {
                path,
                device_id,
                volume,
                start_time_secs,
                is_playing,
                volume_balance_gain,
                equalizer_settings_json,
                sound_effect_settings_json,
                bit_perfect,
                dsd_native_passthrough,
            };
            output::start_exclusive_playback(request)
        }
        PlaybackCommand::Pause => {
            output::pause_exclusive();
            Ok(String::new())
        }
        PlaybackCommand::Resume => {
            output::resume_exclusive();
            Ok(String::new())
        }
        PlaybackCommand::Seek { time_secs, is_playing } => {
            output::seek_exclusive(time_secs, is_playing);
            Ok(String::new())
        }
        PlaybackCommand::Stop => {
            output::stop_exclusive_playback();
            Ok(String::new())
        }
        PlaybackCommand::SetVolume(volume) => {
            output::set_exclusive_volume(volume);
            Ok(String::new())
        }
        PlaybackCommand::SetVolumeBalanceGain(gain) => {
            output::set_exclusive_volume_balance_gain(gain);
            Ok(String::new())
        }
        PlaybackCommand::SetEqualizer(json) => {
            output::set_exclusive_equalizer(json)?;
            Ok(String::new())
        }
        PlaybackCommand::SetSoundEffect(json) => {
            output::set_exclusive_sound_effect(json)?;
            Ok(String::new())
        }
        PlaybackCommand::SetBitPerfect(enabled) => {
            output::set_exclusive_bit_perfect(enabled);
            Ok(String::new())
        }
    }
}