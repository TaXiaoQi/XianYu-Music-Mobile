//! 混响机架 —— 纯 Freeverb 混响引擎。
//!
//! 架构（2026-08-04 最终版）：纯 Freeverb，无叠加算法。
//! 所有 22 个预设统一使用 Freeverb（8 梳状 + 4 全通），仅靠参数差异区分听感。
//!
//! 设计原则（消除"空灵感"和"回声"）：
//! - **无早期反射**（ER_GAIN=0）：早期反射会产生离散回声感
//! - **低湿信号增益**（WET_BOOST=1.0）：避免湿信号过强导致空灵
//! - **高阻尼**（SCALE_DAMP=0.55）：去除高频金属共振，尾音更暖
//! - **低反馈上限**（FEEDBACK_MAX=0.92）：防止过长尾音
//! - **保守预设参数**：room_size ≤ 0.65、damping ≥ 0.45、width ≤ 0.75
//! - **无叠加算法**：彻底移除 Tunnel/Valley/Metal/Spring 专用算法叠加
//!
//! 性能：所有 Vec 在 `prepare()` 一次性分配，`process()` 热路径零分配、零锁、零 I/O。

use super::dsp::{soft_clip, SmoothedValue};
use super::{ReverbKind, SoundEffectSettings};

// =========================================================================
// Freeverb 常量（标准 Dreampoint/STK 调谐）
// =========================================================================

const FIXED_GAIN: f32 = 0.04;
const WET_BOOST: f32 = 1.0;
const ER_GAIN: f32 = 0.0; // 禁用早期反射——消除回声感
const SCALE_ROOM: f32 = 0.28;
const OFFSET_ROOM: f32 = 0.7;
const ROOM_EXTEND_SLOPE: f32 = 0.015;
const FEEDBACK_MAX: f32 = 0.92; // 降低反馈上限，防止过长尾音
const SCALE_DAMP: f32 = 0.55; // 提高阻尼系数，更暖
const ALLPASS_FEEDBACK: f32 = 0.5;
const LIMITER_CEILING: f32 = 0.95;

const COMB_L: [usize; 8] = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617];
const COMB_R: [usize; 8] = [1139, 1211, 1300, 1379, 1445, 1514, 1580, 1640];
const ALLPASS_L: [usize; 4] = [556, 441, 341, 225];
const ALLPASS_R: [usize; 4] = [579, 464, 364, 248];

const ER_DELAYS_MS: [f32; 6] = [11.0, 19.0, 29.0, 37.0, 47.0, 61.0];
const ER_GAINS: [f32; 6] = [0.65, 0.52, 0.45, 0.38, 0.32, 0.25];

// =========================================================================
// 梳状滤波器（低通反馈，Freeverb 核心）
// =========================================================================

struct Comb {
    buffer: Vec<f32>,
    idx: usize,
    feedback: f32,
    filter_store: f32,
    damp1: f32,
    damp2: f32,
}

impl Comb {
    fn new(len: usize) -> Self {
        Self {
            buffer: vec![0.0; len.max(1)],
            idx: 0,
            feedback: 0.5,
            filter_store: 0.0,
            damp1: 0.5,
            damp2: 0.5,
        }
    }

    fn clear(&mut self) {
        self.buffer.fill(0.0);
        self.idx = 0;
        self.filter_store = 0.0;
    }

    #[inline]
    fn process(&mut self, input: f32) -> f32 {
        let output = self.buffer[self.idx];
        self.filter_store = output * self.damp2 + self.filter_store * self.damp1;
        self.buffer[self.idx] = input + self.filter_store * self.feedback;
        self.idx = if self.idx + 1 >= self.buffer.len() {
            0
        } else {
            self.idx + 1
        };
        output
    }
}

// =========================================================================
// 全通滤波器（Schroeder）
// =========================================================================

struct Allpass {
    buffer: Vec<f32>,
    idx: usize,
    feedback: f32,
}

impl Allpass {
    fn new(len: usize) -> Self {
        Self {
            buffer: vec![0.0; len.max(1)],
            idx: 0,
            feedback: ALLPASS_FEEDBACK,
        }
    }

    fn clear(&mut self) {
        self.buffer.fill(0.0);
        self.idx = 0;
    }

    #[inline]
    fn process(&mut self, input: f32) -> f32 {
        let bufout = self.buffer[self.idx];
        let output = -input + bufout;
        self.buffer[self.idx] = input + bufout * self.feedback;
        self.idx = if self.idx + 1 >= self.buffer.len() {
            0
        } else {
            self.idx + 1
        };
        output
    }
}

// =========================================================================
// 早期反射（6 抽头多抽头延迟）
// =========================================================================

struct EarlyReflections {
    delays: [Vec<f32>; 6],
    indices: [usize; 6],
    gains: [f32; 6],
}

impl EarlyReflections {
    fn new(sample_rate: f32) -> Self {
        let sr = sample_rate;
        let delays = std::array::from_fn(|i| {
            let len = ((ER_DELAYS_MS[i] * sr / 1000.0).round() as usize).max(1);
            vec![0.0; len]
        });
        Self {
            delays,
            indices: [0; 6],
            gains: ER_GAINS,
        }
    }

    fn clear(&mut self) {
        for d in &mut self.delays {
            d.fill(0.0);
        }
        self.indices = [0; 6];
    }

    #[inline]
    fn process(&mut self, input: f32) -> f32 {
        let mut sum = 0.0_f32;
        for i in 0..6 {
            let out = self.delays[i][self.indices[i]];
            self.delays[i][self.indices[i]] = input;
            self.indices[i] = if self.indices[i] + 1 >= self.delays[i].len() {
                0
            } else {
                self.indices[i] + 1
            };
            sum += out * self.gains[i];
        }
        sum
    }
}

// =========================================================================
// Freeverb 主体（8 梳状并联 + 4 全通串联 + 早期反射）
// =========================================================================

pub struct ReverbRack {
    sample_rate: f32,
    channels: usize,
    enabled: SmoothedValue,

    // --- Freeverb 路径 ---
    combs_l: [Comb; 8],
    combs_r: [Comb; 8],
    allpass_l: [Allpass; 4],
    allpass_r: [Allpass; 4],
    early_l: EarlyReflections,
    early_r: EarlyReflections,

    // --- 公共参数 ---
    cur_preset: String,
    cur_kind: ReverbKind,
    room_size: f32,
    damping: f32,
    width: f32,
    input_gain: f32,
    limiter_gain: f32,
}

impl ReverbRack {
    pub fn new() -> Self {
        Self {
            sample_rate: 44100.0,
            channels: 2,
            enabled: SmoothedValue::new(0.0),
            combs_l: std::array::from_fn(|i| Comb::new(COMB_L[i])),
            combs_r: std::array::from_fn(|i| Comb::new(COMB_R[i])),
            allpass_l: std::array::from_fn(|i| Allpass::new(ALLPASS_L[i])),
            allpass_r: std::array::from_fn(|i| Allpass::new(ALLPASS_R[i])),
            early_l: EarlyReflections::new(44100.0),
            early_r: EarlyReflections::new(44100.0),
            cur_preset: String::new(),
            cur_kind: ReverbKind::None,
            room_size: 0.5,
            damping: 0.5,
            width: 1.0,
            input_gain: 1.0,
            limiter_gain: 1.0,
        }
    }

    /// 按采样率/声道初始化延迟线（一次性分配，热路径零分配）。
    pub fn prepare(&mut self, sample_rate: f32, channels: usize) {
        self.sample_rate = sample_rate;
        self.channels = channels;
        self.enabled.set_time_constant(0.05, sample_rate);
        let scale = |base: usize| -> usize {
            ((base as f32 * sample_rate / 44100.0).round() as usize).max(1)
        };
        // Freeverb 延迟线按采样率缩放
        for (i, c) in self.combs_l.iter_mut().enumerate() {
            *c = Comb::new(scale(COMB_L[i]));
        }
        for (i, c) in self.combs_r.iter_mut().enumerate() {
            *c = Comb::new(scale(COMB_R[i]));
        }
        for (i, a) in self.allpass_l.iter_mut().enumerate() {
            *a = Allpass::new(scale(ALLPASS_L[i]));
        }
        for (i, a) in self.allpass_r.iter_mut().enumerate() {
            *a = Allpass::new(scale(ALLPASS_R[i]));
        }
        self.early_l = EarlyReflections::new(sample_rate);
        self.early_r = EarlyReflections::new(sample_rate);
        // 重置变更检测
        self.cur_kind = ReverbKind::None;
        self.cur_preset.clear();
        self.limiter_gain = 1.0;
    }

    pub fn reset(&mut self) {
        for c in &mut self.combs_l {
            c.clear();
        }
        for c in &mut self.combs_r {
            c.clear();
        }
        for a in &mut self.allpass_l {
            a.clear();
        }
        for a in &mut self.allpass_r {
            a.clear();
        }
        self.early_l.clear();
        self.early_r.clear();
        self.limiter_gain = 1.0;
    }

    /// 同步参数（每 64 帧由音频线程调用）。
    pub fn update_params(&mut self, s: &SoundEffectSettings) {
        let active = s.reverb_kind != ReverbKind::None && !s.reverb_preset.is_empty();
        self.enabled.set_target(if active { 1.0 } else { 0.0 });

        let (room, damp, width, gain) = preset_params(&s.reverb_preset);

        if s.reverb_kind != self.cur_kind
            || s.reverb_preset != self.cur_preset
            || room != self.room_size
            || damp != self.damping
            || width != self.width
            || gain != self.input_gain
        {
            self.cur_kind = s.reverb_kind.clone();
            self.cur_preset = s.reverb_preset.clone();
            self.room_size = room;
            self.damping = damp;
            self.width = width;
            self.input_gain = gain;

            let fb = feedback_from_room(room);
            let damp1 = damp * SCALE_DAMP;
            let damp2 = 1.0 - damp1;
            for c in &mut self.combs_l {
                c.feedback = fb;
                c.damp1 = damp1;
                c.damp2 = damp2;
            }
            for c in &mut self.combs_r {
                c.feedback = fb;
                c.damp1 = damp1;
                c.damp2 = damp2;
            }
        }
    }

    /// 处理一帧（frame[0]=L, frame[1]=R），原地修改。
    pub fn process(&mut self, frame: &mut [f32], channels: u16, s: &SoundEffectSettings) {
        if channels != 2 || frame.len() < 2 {
            return;
        }
        let w = self.enabled.tick();
        if w < 0.001 {
            return;
        }

        let in_l = frame[0];
        let in_r = frame[1];

        let (wet_l, wet_r) = self.process_freeverb(in_l, in_r);

        // 干/湿混合（与旧版语义一致 + Freeverb 立体声宽度交叉混合）
        let dry_gain = 1.0 + (s.reverb_dry - 1.0) * w;
        let wet = s.reverb_wet * w;
        let wet1 = wet * (self.width * 0.5 + 0.5);
        let wet2 = wet * (self.width * 0.5 - 0.5);
        let wet_out_l = wet_l * wet1 + wet_r * wet2;
        let wet_out_r = wet_r * wet1 + wet_l * wet2;
        let mixed_l = in_l * dry_gain + wet_out_l;
        let mixed_r = in_r * dry_gain + wet_out_r;

        // 砖墙限制器
        let peak = mixed_l.abs().max(mixed_r.abs()).max(1e-9);
        let target_gain = if peak > LIMITER_CEILING {
            LIMITER_CEILING / peak
        } else {
            1.0
        };
        let coeff = if target_gain < self.limiter_gain {
            0.5
        } else {
            0.0005
        };
        self.limiter_gain += (target_gain - self.limiter_gain) * coeff;
        let comp = 1.0 + (self.limiter_gain - 1.0) * w;
        frame[0] = soft_clip(mixed_l * comp);
        frame[1] = soft_clip(mixed_r * comp);
    }

    // --- Freeverb 处理 ---

    #[inline]
    fn process_freeverb(&mut self, in_l: f32, in_r: f32) -> (f32, f32) {
        // 早期反射
        let er_l = self.early_l.process(in_l) * ER_GAIN;
        let er_r = self.early_r.process(in_r) * ER_GAIN;

        let ig = FIXED_GAIN * self.input_gain;
        let input_l = in_l * ig;
        let input_r = in_r * ig;

        // 左声道：8 梳状并联 → 4 全通串联
        let mut out_l = 0.0_f32;
        for c in &mut self.combs_l {
            out_l += c.process(input_l);
        }
        for a in &mut self.allpass_l {
            out_l = a.process(out_l);
        }

        // 右声道
        let mut out_r = 0.0_f32;
        for c in &mut self.combs_r {
            out_r += c.process(input_r);
        }
        for a in &mut self.allpass_r {
            out_r = a.process(out_r);
        }

        (out_l * WET_BOOST + er_l, out_r * WET_BOOST + er_r)
    }
}

// =========================================================================
// room_size → 反馈增益
// =========================================================================

#[inline]
fn feedback_from_room(room: f32) -> f32 {
    if room <= 1.0 {
        (room * SCALE_ROOM + OFFSET_ROOM).min(FEEDBACK_MAX)
    } else {
        (OFFSET_ROOM + SCALE_ROOM + (room - 1.0) * ROOM_EXTEND_SLOPE).min(FEEDBACK_MAX)
    }
}

// =========================================================================
// 预设 → Freeverb 参数映射
// =========================================================================

/// 22 个预设映射到 (room_size, damping, width, input_gain)。
/// 全部预设统一使用 Freeverb，仅靠参数差异区分听感：
/// room_size ≤ 0.65（短尾音）、damping ≥ 0.45（暖色）、width ≤ 0.75（不空灵）
fn preset_params(preset: &str) -> (f32, f32, f32, f32) {
    match preset {
        // --- 13 个卷积混响预设 ---
        "phone" => (0.10, 0.80, 0.0, 1.0),
        "church" => (0.55, 0.55, 0.70, 1.0),
        "hall" => (0.60, 0.50, 0.70, 1.0),
        "cinema" => (0.50, 0.55, 0.60, 1.0),
        "restaurant" => (0.30, 0.65, 0.50, 1.0),
        "bathroom" => (0.20, 0.70, 0.40, 1.0),
        "room" => (0.30, 0.60, 0.50, 1.0),
        "stereo" => (0.45, 0.50, 0.65, 1.0),
        "matrixReverb1" => (0.40, 0.55, 0.60, 1.0),
        "matrixReverb2" => (0.45, 0.60, 0.60, 1.0),
        "cardioidSpread" => (0.40, 0.55, 0.65, 1.0),
        "magneticStereo" => (0.50, 0.55, 0.65, 1.0),
        "feedbackSuppressor" => (0.35, 0.70, 0.50, 1.0),
        // --- 9 个算法混响预设 ---
        "algoStudio" => (0.30, 0.55, 0.55, 1.0),
        "algoHall" => (0.60, 0.50, 0.70, 1.0),
        "algoBathroom" => (0.20, 0.70, 0.40, 1.0),
        "algoTunnel" => (0.45, 0.55, 0.65, 1.0),
        "algoValley" => (0.40, 0.60, 0.65, 1.0),
        "algoMetal" => (0.35, 0.60, 0.50, 1.0),
        "algoPlate" => (0.40, 0.50, 0.60, 1.0),
        "algoSpring" => (0.30, 0.60, 0.50, 1.0),
        "algoPreDelay" => (0.55, 0.50, 0.60, 1.0),
        _ => (0.40, 0.55, 0.60, 1.0),
    }
}

// =========================================================================
// 单元测试
// =========================================================================

#[cfg(test)]
mod tests {
    use super::*;

    fn settings_for(preset: &str) -> SoundEffectSettings {
        let mut s = SoundEffectSettings::default();
        s.reverb_kind = if preset.starts_with("algo") {
            ReverbKind::Algorithmic
        } else {
            ReverbKind::Convolution
        };
        s.reverb_preset = preset.to_string();
        s.reverb_dry = 0.8;
        s.reverb_wet = 0.5;
        s
    }

    #[test]
    fn test_freeverb_process_no_nan() {
        let mut rack = ReverbRack::new();
        rack.prepare(44100.0, 2);
        let s = settings_for("church");
        rack.update_params(&s);
        let mut nonzero = false;
        for _ in 0..44100 {
            let mut frame = [0.5_f32, 0.5];
            rack.process(&mut frame, 2, &s);
            assert!(frame[0].is_finite(), "L NaN/Inf");
            assert!(frame[1].is_finite(), "R NaN/Inf");
            if frame[0].abs() > 1e-6 || frame[1].abs() > 1e-6 {
                nonzero = true;
            }
        }
        assert!(nonzero, "输出全零，混响未生效");
    }

    #[test]
    fn test_preset_mapping_all_22() {
        let presets = [
            "phone",
            "church",
            "hall",
            "cinema",
            "restaurant",
            "bathroom",
            "room",
            "stereo",
            "matrixReverb1",
            "matrixReverb2",
            "cardioidSpread",
            "magneticStereo",
            "feedbackSuppressor",
            "algoStudio",
            "algoHall",
            "algoBathroom",
            "algoTunnel",
            "algoValley",
            "algoMetal",
            "algoPlate",
            "algoSpring",
            "algoPreDelay",
        ];
        for p in &presets {
            let (room, damp, width, gain) = preset_params(p);
            assert!(room >= 0.0, "preset {} room {} 为负", p, room);
            assert!(
                damp >= 0.0 && damp <= 1.0,
                "preset {} damp {} 越界",
                p,
                damp
            );
            assert!(
                width >= 0.0 && width <= 1.0,
                "preset {} width {} 越界",
                p,
                width
            );
            assert!(gain > 0.0, "preset {} gain {} 非正", p, gain);
        }
    }

    #[test]
    fn test_preset_switch_no_rebuild() {
        let mut rack = ReverbRack::new();
        rack.prepare(44100.0, 2);
        let len_after_prepare = rack.combs_l[0].buffer.len();
        for p in ["church", "phone", "hall", "algoTunnel", "room"] {
            let s = settings_for(p);
            rack.update_params(&s);
            assert_eq!(
                rack.combs_l[0].buffer.len(),
                len_after_prepare,
                "切换到 {} 后 Freeverb 缓冲被重建",
                p
            );
        }
        let s_church = settings_for("church");
        rack.update_params(&s_church);
        let fb_church = rack.combs_l[0].feedback;
        let s_phone = settings_for("phone");
        rack.update_params(&s_phone);
        let fb_phone = rack.combs_l[0].feedback;
        assert_ne!(fb_church, fb_phone, "切换预设后 feedback 未变");
    }

    #[test]
    fn test_sample_rate_scaling() {
        let mut rack44 = ReverbRack::new();
        rack44.prepare(44100.0, 2);
        let len44 = rack44.combs_l[0].buffer.len();

        let mut rack48 = ReverbRack::new();
        rack48.prepare(48000.0, 2);
        let len48 = rack48.combs_l[0].buffer.len();

        assert!(
            len48 > len44,
            "48000Hz 梳状长度({})应 > 44100Hz({})",
            len48,
            len44
        );
        assert_eq!(len44, 1116);
        assert_eq!(len48, 1215);
    }

    #[test]
    fn test_bypass_passthrough() {
        let mut rack = ReverbRack::new();
        rack.prepare(44100.0, 2);
        let mut s = SoundEffectSettings::default();
        s.reverb_kind = ReverbKind::None;
        s.reverb_preset = String::new();
        s.reverb_dry = 0.8;
        s.reverb_wet = 0.5;
        rack.update_params(&s);
        for _ in 0..20000 {
            let mut frame = [0.5_f32, 0.5];
            rack.process(&mut frame, 2, &s);
        }
        let mut frame = [0.42_f32, -0.17];
        rack.process(&mut frame, 2, &s);
        assert!(
            (frame[0] - 0.42).abs() < 1e-6,
            "bypass 后 L 不等于输入: {}",
            frame[0]
        );
        assert!(
            (frame[1] + 0.17).abs() < 1e-6,
            "bypass 后 R 不等于输入: {}",
            frame[1]
        );
    }

    #[test]
    fn test_feedback_extension_long_tail() {
        // 线性范围内：room 越大 feedback 越高
        let fb_small = feedback_from_room(0.2);
        let fb_mid = feedback_from_room(0.5);
        let fb_large = feedback_from_room(0.8);
        assert!(
            fb_mid > fb_small,
            "room=0.5 feedback({})应 > room=0.2({})",
            fb_mid,
            fb_small
        );
        assert!(
            fb_large > fb_mid,
            "room=0.8 feedback({})应 > room=0.5({})",
            fb_large,
            fb_mid
        );
        // 极端值被钳位到 FEEDBACK_MAX
        let fb_clamped = feedback_from_room(2.0);
        assert!(
            fb_clamped <= FEEDBACK_MAX,
            "feedback 超过上限 {}",
            fb_clamped
        );
    }

    #[test]
    fn test_early_reflections_nonzero() {
        let mut er = EarlyReflections::new(44100.0);
        for _ in 0..5000 {
            er.process(0.5);
        }
        let out = er.process(0.0);
        assert!(out.abs() > 1e-6, "早期反射输出为零，未生效");
    }

    #[test]
    fn test_wet_boost_louder_than_before() {
        let mut rack = ReverbRack::new();
        rack.prepare(44100.0, 2);
        let mut s = SoundEffectSettings::default();
        s.reverb_kind = ReverbKind::Convolution;
        s.reverb_preset = "hall".to_string();
        s.reverb_dry = 0.8;
        s.reverb_wet = 2.4;
        rack.update_params(&s);
        let mut sum_sq = 0.0_f32;
        let n = 44100_usize;
        for _ in 0..n {
            let mut frame = [0.5_f32, 0.4];
            rack.process(&mut frame, 2, &s);
            sum_sq += frame[0] * frame[0] + frame[1] * frame[1];
        }
        let rms = (sum_sq / (2.0 * n as f32)).sqrt();
        assert!(rms > 0.1, "hall 预设 RMS={} 过低", rms);
    }

    #[test]
    fn test_plate_process_no_nan() {
        let mut rack = ReverbRack::new();
        rack.prepare(44100.0, 2);
        let s = settings_for("algoPlate");
        rack.update_params(&s);
        let mut nonzero = false;
        for _ in 0..44100 {
            let mut frame = [0.5_f32, 0.4];
            rack.process(&mut frame, 2, &s);
            assert!(frame[0].is_finite(), "Plate L NaN/Inf");
            assert!(frame[1].is_finite(), "Plate R NaN/Inf");
            if frame[0].abs() > 1e-6 {
                nonzero = true;
            }
        }
        assert!(nonzero, "Plate 输出全零，算法未生效");
    }

    #[test]
    fn test_algorithm_switch_no_panic() {
        // 在所有算法间切换不应 panic
        let mut rack = ReverbRack::new();
        rack.prepare(44100.0, 2);
        for p in [
            "church",
            "algoTunnel",
            "algoValley",
            "algoMetal",
            "algoSpring",
            "algoPlate",
            "hall",
            "algoHall",
        ] {
            let s = settings_for(p);
            rack.update_params(&s);
            // 切换后处理若干帧不应崩溃
            for _ in 0..100 {
                let mut frame = [0.5_f32, 0.4];
                rack.process(&mut frame, 2, &s);
            }
        }
    }
}