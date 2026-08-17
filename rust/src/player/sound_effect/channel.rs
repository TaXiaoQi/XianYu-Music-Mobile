//! 声道处理机架 —— 复现 YinDongMusic `advancedEffects.ts` 效果架。
//!
//! 按 YinDongMusic WebAudio 节点拓扑 1:1 映射到 Rust DSP：
//!
//! ## 消人声（模块 1）
//! YinDongMusic: ChannelSplitter → inverter(gain=-1) → summer → merger
//! Rust: side = R - L（全幅），输出到两个声道
//!
//! ## Bass 重低音增强（模块 5）
//! YinDongMusic: lowshelf(120Hz, Q=0.7) → dynamicGain(1+avg*0.5)
//!   AnalyserNode(fftSize=256) 分析前 1/8 频段（低频）
//! Rust: lowshelf(120Hz, Q=0.707) + 低通检测(250Hz) + EnvelopeFollower + 动态乘法
//!
//! ## 动态均衡（模块 6）
//! YinDongMusic: lowshelf(80Hz, +3dB) → split(LP/HP @ 5kHz)
//!   → 低频直通 + 高频 DynamicsCompressor(-12dB, ratio=8, attack=1ms, release=50ms) → 合并
//! Rust: 相同拓扑，高频用 EnvelopeFollower + dB 域压缩
//!
//! ## 立体声拓宽（模块 13）
//! YinDongMusic: M/S 矩阵 L'=L*(1+w)/2+R*(1-w)/2, R'=L*(1-w)/2+R*(1+w)/2
//! Rust: mid = (L+R)/2, side = (L-R)/2, L' = mid + side*w, R' = mid - side*w（等价）
//!
//! 每个效果用 SmoothedValue(50ms) 做 wet 混合，启停无 click。

use super::dsp::{db_to_gain, gain_to_db, Biquad, EnvelopeFollower, SmoothedValue};
use super::SoundEffectSettings;

pub struct ChannelRack {
    sample_rate: f32,

    // ---- wet 混合平滑 ----
    wet_vocal: SmoothedValue,
    wet_mono: SmoothedValue,
    wet_swap: SmoothedValue,
    wet_widen: SmoothedValue,
    wet_sep: SmoothedValue,
    wet_crossfeed: SmoothedValue,
    wet_bass: SmoothedValue,
    wet_dyn_eq: SmoothedValue,

    // ---- Crossfeed（模块 12）----
    cross_lp: [Biquad; 2],

    // ---- Bass Boost（模块 5）----
    bass_shelf: [Biquad; 2],      // lowshelf @ 120Hz, Q=0.707
    bass_detect_lp: [Biquad; 2],  // 低通 @ 250Hz（等效 AnalyserNode 前 1/8 频段）
    bass_env: EnvelopeFollower,   // 低频包络跟随
    bass_dyn_gain: SmoothedValue, // 动态增益乘法（1.0~1.5）
    bass_last_gain: f32,          // 跟踪 gain，避免每帧重设系数

    // ---- 动态均衡（模块 6）----
    dyn_low_boost: [Biquad; 2],     // lowshelf @ 80Hz, +3dB
    dyn_split_lp: [Biquad; 2],      // lowpass @ 5kHz
    dyn_split_hp: [Biquad; 2],      // highpass @ 5kHz
    dyn_comp_env: EnvelopeFollower, // 高频包络（attack=1ms, release=50ms）
    dyn_comp_reduction: [f32; 2],   // 各声道压缩增益
}

impl ChannelRack {
    pub fn new() -> Self {
        Self {
            sample_rate: 44100.0,
            wet_vocal: SmoothedValue::new(0.0),
            wet_mono: SmoothedValue::new(0.0),
            wet_swap: SmoothedValue::new(0.0),
            wet_widen: SmoothedValue::new(0.0),
            wet_sep: SmoothedValue::new(0.0),
            wet_crossfeed: SmoothedValue::new(0.0),
            wet_bass: SmoothedValue::new(0.0),
            wet_dyn_eq: SmoothedValue::new(0.0),
            // Crossfeed
            cross_lp: [Biquad::new(2), Biquad::new(2)],
            // Bass boost
            bass_shelf: [Biquad::new(2), Biquad::new(2)],
            bass_detect_lp: [Biquad::new(2), Biquad::new(2)],
            bass_env: EnvelopeFollower::new(5.0, 80.0, 44100.0),
            bass_dyn_gain: SmoothedValue::new(1.0),
            bass_last_gain: f32::NAN,
            // 动态均衡
            dyn_low_boost: [Biquad::new(2), Biquad::new(2)],
            dyn_split_lp: [Biquad::new(2), Biquad::new(2)],
            dyn_split_hp: [Biquad::new(2), Biquad::new(2)],
            dyn_comp_env: EnvelopeFollower::new(1.0, 50.0, 44100.0),
            dyn_comp_reduction: [1.0, 1.0],
        }
    }

    pub fn prepare(&mut self, sample_rate: f32, channels: usize) {
        self.sample_rate = sample_rate;
        let ch = channels.max(1);
        for i in 0..2 {
            self.cross_lp[i].resize_channels(ch);
            self.bass_shelf[i].resize_channels(ch);
            self.bass_detect_lp[i].resize_channels(ch);
            self.dyn_low_boost[i].resize_channels(ch);
            self.dyn_split_lp[i].resize_channels(ch);
            self.dyn_split_hp[i].resize_channels(ch);
        }
        // 50ms wet 平滑
        let tc = 0.05;
        self.wet_vocal.set_time_constant(tc, sample_rate);
        self.wet_mono.set_time_constant(tc, sample_rate);
        self.wet_swap.set_time_constant(tc, sample_rate);
        self.wet_widen.set_time_constant(tc, sample_rate);
        self.wet_sep.set_time_constant(tc, sample_rate);
        self.wet_crossfeed.set_time_constant(tc, sample_rate);
        self.wet_bass.set_time_constant(tc, sample_rate);
        self.wet_dyn_eq.set_time_constant(tc, sample_rate);
        self.bass_dyn_gain.set_time_constant(tc, sample_rate);

        // Crossfeed 低通 ~1.8kHz
        for i in 0..2 {
            self.cross_lp[i].set_lowpass(1800.0, sample_rate, 0.707);
        }
        // Bass 检测低通：~250Hz（模拟 AnalyserNode 前 1/8 频段）
        for i in 0..2 {
            self.bass_detect_lp[i].set_lowpass(250.0, sample_rate, 0.707);
        }
        // 动态均衡高频包络：attack=1ms, release=50ms（对齐 YinDongMusic highCompressor）
        self.dyn_comp_env.set_times(1.0, 50.0, sample_rate);
    }

    pub fn reset(&mut self) {
        for i in 0..2 {
            self.cross_lp[i].reset();
            self.bass_shelf[i].reset();
            self.bass_detect_lp[i].reset();
            self.dyn_low_boost[i].reset();
            self.dyn_split_lp[i].reset();
            self.dyn_split_hp[i].reset();
        }
        self.bass_env.reset();
        self.bass_dyn_gain.set_immediate(1.0);
        self.dyn_comp_env.reset();
        self.dyn_comp_reduction = [1.0, 1.0];
    }

    pub fn update_params(&mut self, s: &SoundEffectSettings) {
        // wet 目标
        self.wet_vocal
            .set_target(if s.vocal_removal { 1.0 } else { 0.0 });
        self.wet_mono
            .set_target(if s.mono_merge { 1.0 } else { 0.0 });
        self.wet_swap
            .set_target(if s.channel_swap { 1.0 } else { 0.0 });
        self.wet_widen
            .set_target(if s.stereo_widen.enabled { 1.0 } else { 0.0 });
        self.wet_sep.set_target(if s.stereo_separation.enabled {
            1.0
        } else {
            0.0
        });
        self.wet_crossfeed
            .set_target(if s.crossfeed.enabled { 1.0 } else { 0.0 });
        self.wet_bass
            .set_target(if s.bass_boost.enabled { 1.0 } else { 0.0 });
        self.wet_dyn_eq
            .set_target(if s.dynamic_eq.enabled { 1.0 } else { 0.0 });

        // Bass boost: lowshelf @ 120Hz, Q=0.707（仅 gain 变化时重设）
        let bg = s.bass_boost.gain.clamp(0.0, 15.0);
        if !self.bass_last_gain.is_finite() || (bg - self.bass_last_gain).abs() > 0.01 {
            self.bass_last_gain = bg;
            for i in 0..2 {
                self.bass_shelf[i].set_lowshelf(120.0, self.sample_rate, bg, 0.707);
            }
        }

        // 动态均衡: lowshelf(80Hz, +3dB) + 分频(5kHz)
        for i in 0..2 {
            self.dyn_low_boost[i].set_lowshelf(80.0, self.sample_rate, 3.0, 0.707);
            self.dyn_split_lp[i].set_lowpass(5000.0, self.sample_rate, 0.707);
            self.dyn_split_hp[i].set_highpass(5000.0, self.sample_rate, 0.707);
        }
    }

    pub fn process(&mut self, frame: &mut [f32], channels: u16, s: &SoundEffectSettings) {
        if channels != 2 || frame.len() < 2 {
            return;
        }

        // ====== 消人声（模块 1）======
        // YinDongMusic: splitter(0)→inverter(-1)→summer←splitter(1) = R-L → merger(L,R)
        let w = self.wet_vocal.tick();
        if w > 0.001 {
            let l = frame[0];
            let r = frame[1];
            let side = r - l; // 全幅 side（不乘 0.5）
            frame[0] = l * (1.0 - w) + side * w;
            frame[1] = r * (1.0 - w) + side * w;
        }

        // ====== 单声道合并（模块 14）======
        let w = self.wet_mono.tick();
        if w > 0.001 {
            let l = frame[0];
            let r = frame[1];
            let mid = (l + r) * 0.5;
            frame[0] = l * (1.0 - w) + mid * w;
            frame[1] = r * (1.0 - w) + mid * w;
        }

        // ====== 声道交换（模块 15）======
        let w = self.wet_swap.tick();
        if w > 0.001 {
            let l = frame[0];
            let r = frame[1];
            frame[0] = l * (1.0 - w) + r * w;
            frame[1] = r * (1.0 - w) + l * w;
        }

        // ====== 立体声拓宽（模块 13）======
        // YinDongMusic M/S 矩阵: L'=L*(1+w)/2+R*(1-w)/2 = mid+side*w
        let w = self.wet_widen.tick();
        if w > 0.001 {
            let amount = s.stereo_widen.amount.clamp(0.0, 3.0);
            let l = frame[0];
            let r = frame[1];
            let mid = (l + r) * 0.5;
            let side = (l - r) * 0.5 * amount;
            frame[0] = l * (1.0 - w) + (mid + side) * w;
            frame[1] = r * (1.0 - w) + (mid - side) * w;
        }

        // ====== 立体声分离度 M/S ======
        let w = self.wet_sep.tick();
        if w > 0.001 {
            let width = (s.stereo_separation.width / 100.0).clamp(0.0, 2.0);
            let center = (s.stereo_separation.center_level / 100.0).clamp(0.0, 2.0);
            let l = frame[0];
            let r = frame[1];
            let mid = (l + r) * 0.5 * center;
            let side = (l - r) * 0.5 * width;
            frame[0] = l * (1.0 - w) + (mid + side) * w;
            frame[1] = r * (1.0 - w) + (mid - side) * w;
        }

        // ====== Crossfeed（模块 12）======
        // YinDongMusic: splitter→delay(0.4ms)→lowpass(700Hz)→gain(0.3)→交叉到对侧
        let w = self.wet_crossfeed.tick();
        if w > 0.001 {
            let strength = (s.crossfeed.strength / 100.0).clamp(0.0, 1.0) * 0.4 * w;
            let l = frame[0];
            let r = frame[1];
            let cf_l = self.cross_lp[0].process(r, 0);
            let cf_r = self.cross_lp[1].process(l, 1);
            frame[0] = l + cf_l * strength;
            frame[1] = r + cf_r * strength;
        }

        // ====== Bass 重低音增强（模块 5）======
        // YinDongMusic: lowshelf(120Hz,Q=0.7) → dynamicGain(1+avg*0.5)
        // AnalyserNode 分析前 1/8 频段（≈低频），此处用低通 250Hz + EnvelopeFollower
        let w = self.wet_bass.tick();
        if w > 0.001 {
            // 动态检测：低通滤波后取包络
            if s.bass_boost.dynamic {
                let lp_l = self.bass_detect_lp[0].process(frame[0], 0);
                let lp_r = self.bass_detect_lp[1].process(frame[1], 1);
                let energy = self.bass_env.process(lp_l.abs().max(lp_r.abs()));
                // boost = 1 + avg * 0.5（对齐 YinDongMusic），上限 1.5
                let boost = 1.0 + (energy * 0.5).min(0.5);
                self.bass_dyn_gain.set_target(boost);
            } else {
                self.bass_dyn_gain.set_target(1.0);
            }
            let dyn_g = self.bass_dyn_gain.tick();
            // lowshelf → ×dyn_g（对齐 YinDongMusic 链路）
            let l = frame[0];
            let r = frame[1];
            let nl = self.bass_shelf[0].process(l, 0) * dyn_g;
            let nr = self.bass_shelf[1].process(r, 1) * dyn_g;
            frame[0] = l * (1.0 - w) + nl * w;
            frame[1] = r * (1.0 - w) + nr * w;
        }

        // ====== 动态均衡（模块 6）======
        // YinDongMusic: lowshelf(80Hz,+3dB) → split(LP/HP@5kHz)
        //   低频直通 + 高频 DynamicsCompressor(-12dB,ratio=8,attack=1ms,release=50ms) → 合并
        let w = self.wet_dyn_eq.tick();
        if w > 0.001 {
            for i in 0..2 {
                let in_s = frame[i];
                let boosted = self.dyn_low_boost[i].process(in_s, i);
                let low = self.dyn_split_lp[i].process(boosted, i);
                let high = self.dyn_split_hp[i].process(boosted, i);
                // 高频压缩
                let env = self.dyn_comp_env.process(high.abs());
                let threshold = 0.25; // -12dB 线性
                let ratio = 8.0;
                let target = if env > threshold {
                    let env_db = gain_to_db(env);
                    let thr_db = gain_to_db(threshold);
                    db_to_gain(-((env_db - thr_db) * (1.0 - 1.0 / ratio)))
                } else {
                    1.0
                };
                self.dyn_comp_reduction[i] = smooth_gain(
                    self.dyn_comp_reduction[i],
                    target,
                    1.0,
                    50.0,
                    self.sample_rate,
                );
                let merged = low + high * self.dyn_comp_reduction[i];
                frame[i] = in_s * (1.0 - w) + merged * w;
            }
        }
    }
}

#[inline]
fn smoothing_amount(ms: f32, sr: f32) -> f32 {
    let ms = ms.max(0.1);
    let sr = sr.max(1.0);
    1.0 - (-1.0 / (ms * 0.001 * sr)).exp()
}

#[inline]
fn smooth_gain(current: f32, target: f32, attack_ms: f32, release_ms: f32, sr: f32) -> f32 {
    let t = if target.is_finite() {
        target.clamp(0.0, 32.0)
    } else {
        1.0
    };
    let c = if t < current {
        smoothing_amount(attack_ms, sr)
    } else {
        smoothing_amount(release_ms, sr)
    };
    current + (t - current) * c
}