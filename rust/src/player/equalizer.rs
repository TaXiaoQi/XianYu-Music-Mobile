//! 10 段均衡器（从桌面端 equalizer.rs 抽取，剥离 rodio 依赖）。
//!
//! 核心 DSP（TDF2 双二阶滤波器、参数平滑渐变、硬旁路）与桌面端一致，
//! 仅把「逐样本 Iterator 组合」重构为「缓冲级 process_block(&[f32])」，
//! 便于被 Flutter 播放引擎直接调用。交错 PCM 输入输出。

use serde::Deserialize;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex};

// 精确的 10 段中心频率表 (Hz)
pub const BANDS: [f32; 10] = [
    31.25, 62.5, 125.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0, 8000.0, 16000.0,
];

#[derive(Clone, Debug, PartialEq, Deserialize)]
pub struct EqualizerSettings {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default)]
    pub preamp: f32, // preamp 增益 (dB)
    #[serde(default)]
    pub gains: [f32; 10], // 10个频带的增益 (dB)
}

impl Default for EqualizerSettings {
    fn default() -> Self {
        Self {
            enabled: false,
            preamp: 0.0,
            gains: [0.0; 10],
        }
    }
}

pub struct EqualizerHandle {
    pub settings: Arc<Mutex<EqualizerSettings>>,
    pub dirty: Arc<AtomicBool>,
}

impl EqualizerHandle {
    pub fn new(settings: EqualizerSettings) -> Self {
        Self {
            settings: Arc::new(Mutex::new(settings)),
            dirty: Arc::new(AtomicBool::new(false)),
        }
    }

    pub fn set_settings(&self, new_settings: EqualizerSettings) {
        if let Ok(mut s) = self.settings.lock() {
            *s = new_settings;
        }
        self.dirty.store(true, Ordering::Relaxed);
    }
}

#[derive(Clone, Default)]
struct BiquadState {
    s1: f32,
    s2: f32,
}

struct BiquadFilter {
    frequency: f32,
    b0: f32,
    b1: f32,
    b2: f32,
    a1: f32,
    a2: f32,
    states: Vec<BiquadState>,
}

impl BiquadFilter {
    fn new(frequency: f32, sample_rate: f32, q: f32, gain_db: f32, channels: usize) -> Self {
        let mut filter = Self {
            frequency,
            b0: 1.0,
            b1: 0.0,
            b2: 0.0,
            a1: 0.0,
            a2: 0.0,
            states: vec![BiquadState::default(); channels],
        };
        filter.calculate_coefficients(sample_rate, q, gain_db);
        filter
    }

    fn calculate_coefficients(&mut self, sample_rate: f32, q: f32, gain_db: f32) {
        let gain_db = gain_db.clamp(-12.0, 12.0);

        // 奈奎斯特频率硬性保护
        let nyquist = sample_rate / 2.0;
        let mut target_freq = self.frequency;

        if target_freq >= nyquist - 100.0 {
            target_freq = sample_rate * 0.45;
            if target_freq >= nyquist || target_freq <= 10.0 {
                self.b0 = 1.0;
                self.b1 = 0.0;
                self.b2 = 0.0;
                self.a1 = 0.0;
                self.a2 = 0.0;
                return;
            }
        }

        // 增益接近 0 则完全直通
        if gain_db.abs() < 0.01 {
            self.b0 = 1.0;
            self.b1 = 0.0;
            self.b2 = 0.0;
            self.a1 = 0.0;
            self.a2 = 0.0;
            return;
        }

        let a = 10.0_f32.powf(gain_db / 40.0);
        let w0 = 2.0 * std::f32::consts::PI * target_freq / sample_rate;
        let alpha = w0.sin() / (2.0 * q);
        let cos_w0 = w0.cos();

        let b0_raw = 1.0 + alpha * a;
        let b1_raw = -2.0 * cos_w0;
        let b2_raw = 1.0 - alpha * a;
        let a0_raw = 1.0 + alpha / a;
        let a1_raw = -2.0 * cos_w0;
        let a2_raw = 1.0 - alpha / a;

        // TDF2 要求对 a0 实施归一化
        self.b0 = b0_raw / a0_raw;
        self.b1 = b1_raw / a0_raw;
        self.b2 = b2_raw / a0_raw;
        self.a1 = a1_raw / a0_raw;
        self.a2 = a2_raw / a0_raw;
    }

    #[inline]
    fn process(&mut self, sample: f32, channel_index: usize) -> f32 {
        if channel_index >= self.states.len() {
            self.states
                .resize(channel_index + 1, BiquadState::default());
        }
        let state = &mut self.states[channel_index];

        // Transposed Direct Form II (TDF2) 差分方程
        let out = self.b0 * sample + state.s1;
        state.s1 = self.b1 * sample - self.a1 * out + state.s2;
        state.s2 = self.b2 * sample - self.a2 * out;

        if !out.is_finite() {
            state.s1 = 0.0;
            state.s2 = 0.0;
            return sample;
        }
        out
    }

    fn reset_state(&mut self) {
        for state in &mut self.states {
            state.s1 = 0.0;
            state.s2 = 0.0;
        }
    }
}

/// 缓冲级 10 段均衡器（交错 PCM）。
pub struct Equalizer {
    shared_settings: Arc<Mutex<EqualizerSettings>>,

    last_target_settings: EqualizerSettings,
    current_preamp: f32,
    target_preamp: f32,
    current_gains: [f32; 10],
    target_gains: [f32; 10],

    ramp_frames: usize,
    current_frame: usize,
    is_ramping: bool,

    is_hard_bypassed: bool,
    is_fade_out_for_disable: bool,

    filters: Vec<BiquadFilter>,
    channels: u16,
    current_channel: u16,
    sample_rate: u32,

    frame_counter: usize,
}

impl Equalizer {
    pub fn new(sample_rate: u32, channels: u16, handle: Arc<EqualizerHandle>) -> Self {
        let initial_settings = if let Ok(s) = handle.settings.lock() {
            s.clone()
        } else {
            EqualizerSettings::default()
        };

        let ramp_frames = ((0.05 * sample_rate as f64).round() as usize).max(1);

        let mut eq = Self {
            shared_settings: handle.settings.clone(),
            last_target_settings: initial_settings.clone(),
            current_preamp: 1.0,
            target_preamp: 1.0,
            current_gains: [0.0; 10],
            target_gains: [0.0; 10],
            ramp_frames,
            current_frame: 0,
            is_ramping: false,
            is_hard_bypassed: true,
            is_fade_out_for_disable: false,
            filters: Vec::new(),
            channels,
            current_channel: 0,
            sample_rate,
            frame_counter: 0,
        };

        eq.initialize_parameters(&initial_settings);
        eq.rebuild_filters();
        eq
    }

    fn initialize_parameters(&mut self, settings: &EqualizerSettings) {
        if settings.enabled {
            self.target_preamp = 10.0_f32.powf(settings.preamp.clamp(-12.0, 12.0) / 20.0);
            self.target_gains = settings.gains;
            self.is_hard_bypassed = false;
            self.is_fade_out_for_disable = false;
        } else {
            self.target_preamp = 1.0;
            self.target_gains = [0.0; 10];
            self.is_hard_bypassed = true;
            self.is_fade_out_for_disable = false;
        }
        self.current_preamp = self.target_preamp;
        self.current_gains = self.target_gains;
        self.is_ramping = false;
    }

    fn rebuild_filters(&mut self) {
        if self.is_hard_bypassed {
            self.filters.clear();
            return;
        }

        if self.filters.len() != BANDS.len() {
            self.filters = BANDS
                .iter()
                .map(|&freq| {
                    BiquadFilter::new(
                        freq,
                        self.sample_rate as f32,
                        1.0,
                        0.0,
                        self.channels as usize,
                    )
                })
                .collect();
        }

        for (i, filter) in self.filters.iter_mut().enumerate() {
            if filter.states.len() != self.channels as usize {
                filter
                    .states
                    .resize(self.channels as usize, BiquadState::default());
            }
            filter.calculate_coefficients(self.sample_rate as f32, 1.0, self.current_gains[i]);
        }
    }

    fn reset_all_filters(&mut self) {
        for filter in &mut self.filters {
            filter.reset_state();
        }
    }

    /// 采样率/声道数瞬变时更新参数（等价桌面端换轨检测）。
    pub fn configure(&mut self, sample_rate: u32, channels: u16) {
        if sample_rate != self.sample_rate || channels != self.channels {
            self.sample_rate = sample_rate;
            self.channels = channels;
            self.rebuild_filters();
            self.reset_all_filters();
        }
    }

    /// 清空内部滤波器状态（seek 时调用防 click）。
    pub fn reset(&mut self) {
        self.current_channel = 0;
        self.reset_all_filters();
    }

    /// 更新均衡器设置（写入共享句柄，由音频线程在 256 帧内非阻塞读取并平滑渐变）。
    pub fn set_settings(&mut self, settings: EqualizerSettings) {
        if let Ok(mut s) = self.shared_settings.lock() {
            *s = settings;
        }
    }

    fn sync_settings_nonblocking(&mut self) {
        self.frame_counter += 1;
        if self.frame_counter < 256 {
            return;
        }
        self.frame_counter = 0;

        if let Ok(new_settings) = self.shared_settings.try_lock() {
            if *new_settings != self.last_target_settings {
                self.last_target_settings = new_settings.clone();
                self.ramp_frames = ((0.05 * self.sample_rate as f64).round() as usize).max(1);
                self.current_frame = 0;
                self.is_ramping = true;

                if new_settings.enabled {
                    self.target_preamp =
                        10.0_f32.powf(new_settings.preamp.clamp(-12.0, 12.0) / 20.0);
                    self.target_gains = new_settings.gains;
                    self.is_hard_bypassed = false;
                    self.is_fade_out_for_disable = false;
                } else {
                    self.target_preamp = 1.0;
                    self.target_gains = [0.0; 10];
                    self.is_fade_out_for_disable = true;
                }
            }
        }
    }

    fn step_parameter_smoothing(&mut self) {
        if !self.is_ramping {
            return;
        }

        self.current_frame += 1;
        let progress = self.current_frame as f32 / self.ramp_frames as f32;

        if progress >= 1.0 {
            self.current_preamp = self.target_preamp;
            self.current_gains = self.target_gains;
            self.is_ramping = false;

            if self.is_fade_out_for_disable {
                self.is_hard_bypassed = true;
                self.is_fade_out_for_disable = false;
                self.reset_all_filters();
            }
        } else {
            self.current_preamp =
                self.current_preamp + (self.target_preamp - self.current_preamp) * progress;
            for i in 0..10 {
                self.current_gains[i] = self.current_gains[i]
                    + (self.target_gains[i] - self.current_gains[i]) * progress;
            }
        }
    }

    /// 处理一块交错 PCM，返回处理后的交错 PCM。
    /// 输入样本数应为 channels 的整数倍；直通时长度不变。
    pub fn process_block(&mut self, input: &[f32]) -> Vec<f32> {
        let mut out = Vec::with_capacity(input.len());
        for &sample in input {
            // 每帧开头做非阻塞设置同步
            if self.current_channel == 0 {
                self.sync_settings_nonblocking();

                if self.is_ramping {
                    self.step_parameter_smoothing();
                    if !self.is_hard_bypassed {
                        self.rebuild_filters();
                    }
                }

                if !self.is_ramping
                    && (self.current_preamp - 1.0).abs() < 0.001
                    && self.current_gains.iter().all(|g| g.abs() < 0.01)
                {
                    self.is_hard_bypassed = true;
                }
            }

            // 硬旁路无损直通
            if self.is_hard_bypassed {
                self.advance_channel();
                out.push(sample);
                continue;
            }

            let preamped_sample = sample * self.current_preamp;
            let mut val = preamped_sample;
            let channel_idx = self.current_channel as usize;
            for filter in &mut self.filters {
                val = filter.process(val, channel_idx);
            }
            self.advance_channel();
            out.push(val);
        }
        out
    }

    #[inline]
    fn advance_channel(&mut self) {
        self.current_channel += 1;
        if self.current_channel >= self.channels {
            self.current_channel = 0;
        }
    }
}

// =========================================================================
// Custom UserVolumeSource (自定义主音量控制源) —— 缓冲级移植
// =========================================================================

/// 用户主音量控制（缓冲级）：语义对齐桌面端 `UserVolumeSource` ——
/// 目标音量变化时以 50ms 渐变逼近，消除音量跳变的 zipper noise / click。
/// 每帧开头采样共享音量快照（`Arc<AtomicU32>` 存 f32 bits，与桌面端一致）。
pub struct UserVolumeSource {
    current_volume: f32,
    target_volume: f32,
    ramp_frames: usize,
    current_frame: usize,
    is_ramping: bool,
    sample_rate: u32,
}

#[inline]
fn volume_ramp_frames(sample_rate: u32) -> usize {
    ((0.05 * sample_rate as f64).round() as usize).max(1)
}

impl UserVolumeSource {
    pub fn new(initial_volume: f32, sample_rate: u32) -> Self {
        let vol = initial_volume.clamp(0.0, 1.0);
        Self {
            current_volume: vol,
            target_volume: vol,
            ramp_frames: volume_ramp_frames(sample_rate),
            current_frame: 0,
            is_ramping: false,
            sample_rate,
        }
    }

    /// 处理一块交错 PCM（原地应用音量渐变）。
    /// 输入样本数应为 channels 的整数倍（与输出流的帧分组一致）。
    pub fn process_block(&mut self, input: &mut [f32], channels: u16, volume: &AtomicU32) {
        let channels = channels.max(1) as usize;
        for frame in input.chunks_mut(channels) {
            // 每帧开头（对齐桌面端 channel == 0 时机）采样目标音量并推进渐变
            let next_target = f32::from_bits(volume.load(Ordering::Relaxed)).clamp(0.0, 1.0);
            if (next_target - self.target_volume).abs() > 0.00001 {
                self.target_volume = next_target;
                self.ramp_frames = volume_ramp_frames(self.sample_rate);
                self.current_frame = 0;
                self.is_ramping = true;
            }

            if self.is_ramping {
                self.current_frame += 1;
                let progress = self.current_frame as f32 / self.ramp_frames as f32;
                if progress >= 1.0 {
                    self.current_volume = self.target_volume;
                    self.is_ramping = false;
                } else {
                    self.current_volume =
                        self.current_volume + (self.target_volume - self.current_volume) * progress;
                }
            }

            for sample in frame.iter_mut() {
                *sample *= self.current_volume;
            }
        }
    }
}

// =========================================================================
// Custom ClipGuardSource (自定义最终安全防削波限幅源) —— 缓冲级移植
// =========================================================================

/// 最终安全防削波限幅（缓冲级）：语义对齐桌面端 `ClipGuardSource` ——
/// ±1.0 以内完全透传（零失真），超出时硬限幅保护 DAC；统计削波计数供诊断。
#[derive(Default)]
pub struct ClipGuardSource {
    clip_count: u64,
    total_count: u64,
    max_seen: f32,
}

impl ClipGuardSource {
    pub fn new() -> Self {
        Self::default()
    }

    /// 处理一块交错 PCM（原地限幅）。
    pub fn process_block(&mut self, input: &mut [f32]) {
        for sample in input.iter_mut() {
            self.total_count += 1;
            let ax = sample.abs();
            if ax > self.max_seen {
                self.max_seen = ax;
            }
            if ax > 1.0 {
                self.clip_count += 1;
            }
            *sample = sample.clamp(-1.0, 1.0);
        }
    }

    /// 累计被限幅的样本数（诊断用）。
    pub fn clip_count(&self) -> u64 {
        self.clip_count
    }

    /// 累计处理样本数（诊断用）。
    pub fn total_count(&self) -> u64 {
        self.total_count
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clip_guard_limits_out_of_range_samples() {
        let mut samples = vec![2.5, -3.0, 1.2, -0.99, 0.98, 0.0, 0.5, 1.0, -1.0];
        let mut clip_guard = ClipGuardSource::new();
        clip_guard.process_block(&mut samples);

        // ±1.0 以内完全透传，超出时 clamp 到 ±1.0（对齐桌面端 test_clip_guard_limit）
        assert_eq!(samples[0], 1.0); // 2.5 → clamp 到 1.0
        assert_eq!(samples[1], -1.0); // -3.0 → clamp 到 -1.0
        assert_eq!(samples[2], 1.0); // 1.2 → clamp 到 1.0
        assert_eq!(samples[3], -0.99); // -0.99 透传
        assert_eq!(samples[4], 0.98); // 0.98 透传
        assert_eq!(samples[5], 0.0); // 0.0 透传
        assert_eq!(samples[6], 0.5); // 0.5 透传
        assert_eq!(samples[7], 1.0); // 1.0 透传（边界值）
        assert_eq!(samples[8], -1.0); // -1.0 透传（边界值）
        assert_eq!(clip_guard.clip_count(), 3);
        assert_eq!(clip_guard.total_count(), 9);
    }

    #[test]
    fn user_volume_ramps_to_target_without_jump() {
        let volume = Arc::new(AtomicU32::new(1.0f32.to_bits()));
        let mut src = UserVolumeSource::new(1.0, 44100);
        let mut samples = vec![1.0; 4410]; // 100ms @ 44.1kHz，单声道
        src.process_block(&mut samples, 1, &volume);

        // 音量未变化 → 全程原样透传
        assert!(samples.iter().all(|&s| (s - 1.0).abs() < 1e-6));

        // 目标音量降到 0.5 → 50ms 内渐变收敛，无瞬时跳变
        volume.store(0.5f32.to_bits(), Ordering::Relaxed);
        let mut first = f32::MAX;
        let mut converged = 0usize;
        for chunk in samples.chunks_mut(441) {
            src.process_block(chunk, 1, &volume);
            let last = *chunk.last().unwrap();
            if first == f32::MAX {
                // 渐变的第一帧不应直接跳到目标值（对齐桌面端无 zipper noise 语义）
                assert!(last > 0.5 + 0.01, "首帧即跳变到目标音量: {last}");
                first = last;
            }
            if (last - 0.5).abs() < 0.001 {
                converged += 1;
            }
        }
        assert!(converged >= 1, "音量渐变未收敛到目标值");
        // 收敛后所有样本应精确等于目标音量
        assert!((samples[samples.len() - 1] - 0.5).abs() < 0.001);
    }

    #[test]
    fn user_volume_change_does_not_distort_first_frame_audibly() {
        // 音量从 1.0 → 0.0 的静音渐变应平滑（逐帧递减，不突变）
        let volume = Arc::new(AtomicU32::new(1.0f32.to_bits()));
        let mut src = UserVolumeSource::new(1.0, 44100);
        let mut samples = vec![1.0; 4410];
        volume.store(0.0f32.to_bits(), Ordering::Relaxed);
        src.process_block(&mut samples, 1, &volume);
        // 单调不增（渐变下行），且最终收敛到 0
        for w in samples.windows(2) {
            assert!(w[1] <= w[0] + 1e-6, "音量渐变出现上行跳变");
        }
        assert_eq!(*samples.last().unwrap(), 0.0);
    }
}