//! 共享 DSP 原语：Biquad / OnePole / AllPass / DelayLine / 平滑值 / 包络跟随器 / LFO / DC 阻断。
//!
//! 全部为无锁、单线程（音频线程）使用的设计。系数计算与状态分离，便于在参数变更时
//! 仅重算系数而保留状态（避免 click）。所有滤波器对 NaN/Inf 输出做硬保护，退化直通。

#![allow(dead_code)]

use std::f32::consts::PI;

// =========================================================================
// Biquad（TDF2，多声道独立状态）
// =========================================================================

#[derive(Clone, Default)]
pub struct BiquadState {
    s1: f32,
    s2: f32,
}

/// 通用二阶 IIR 滤波器（Transposed Direct Form II）。
/// 支持 lowpass/highpass/bandpass/peaking/lowshelf/highshelf/notch/allpass。
pub struct Biquad {
    pub b0: f32,
    pub b1: f32,
    pub b2: f32,
    pub a1: f32,
    pub a2: f32,
    pub states: Vec<BiquadState>,
    /// 系数是否为纯直通（增益≈0 的 peaking 等），直通时跳过运算
    pub passthrough: bool,
}

impl Biquad {
    pub fn new(channels: usize) -> Self {
        Self {
            b0: 1.0,
            b1: 0.0,
            b2: 0.0,
            a1: 0.0,
            a2: 0.0,
            states: vec![BiquadState::default(); channels],
            passthrough: true,
        }
    }

    fn clamp_freq(freq: f32, sample_rate: f32) -> f32 {
        let nyq = sample_rate * 0.5;
        freq.clamp(10.0, nyq * 0.95)
    }

    /// Peaking EQ（参考 RBJ Audio EQ Cookbook）
    pub fn set_peaking(&mut self, freq: f32, sample_rate: f32, gain_db: f32, q: f32) {
        if gain_db.abs() < 0.05 {
            self.set_passthrough();
            return;
        }
        let f = Self::clamp_freq(freq, sample_rate);
        let w0 = 2.0 * PI * f / sample_rate;
        let cosw = w0.cos();
        let sinw = w0.sin();
        let a = 10.0_f32.powf(gain_db / 40.0);
        let alpha = sinw / (2.0 * q);
        let b0 = 1.0 + alpha * a;
        let b1 = -2.0 * cosw;
        let b2 = 1.0 - alpha * a;
        let a0 = 1.0 + alpha / a;
        self.set_coeffs(
            b0 / a0,
            b1 / a0,
            b2 / a0,
            -2.0 * cosw / a0,
            (1.0 - alpha / a) / a0,
        );
    }

    /// Lowpass
    pub fn set_lowpass(&mut self, freq: f32, sample_rate: f32, q: f32) {
        let f = Self::clamp_freq(freq, sample_rate);
        let w0 = 2.0 * PI * f / sample_rate;
        let cosw = w0.cos();
        let sinw = w0.sin();
        let alpha = sinw / (2.0 * q);
        let b0 = (1.0 - cosw) / 2.0;
        let b1 = 1.0 - cosw;
        let b2 = (1.0 - cosw) / 2.0;
        let a0 = 1.0 + alpha;
        self.set_coeffs(
            b0 / a0,
            b1 / a0,
            b2 / a0,
            -2.0 * cosw / a0,
            (1.0 - alpha) / a0,
        );
    }

    /// Highpass
    pub fn set_highpass(&mut self, freq: f32, sample_rate: f32, q: f32) {
        let f = Self::clamp_freq(freq, sample_rate);
        let w0 = 2.0 * PI * f / sample_rate;
        let cosw = w0.cos();
        let sinw = w0.sin();
        let alpha = sinw / (2.0 * q);
        let b0 = (1.0 + cosw) / 2.0;
        let b1 = -(1.0 + cosw);
        let b2 = (1.0 + cosw) / 2.0;
        let a0 = 1.0 + alpha;
        self.set_coeffs(
            b0 / a0,
            b1 / a0,
            b2 / a0,
            -2.0 * cosw / a0,
            (1.0 - alpha) / a0,
        );
    }

    /// Low shelf
    pub fn set_lowshelf(&mut self, freq: f32, sample_rate: f32, gain_db: f32, q: f32) {
        if gain_db.abs() < 0.05 {
            self.set_passthrough();
            return;
        }
        let f = Self::clamp_freq(freq, sample_rate);
        let w0 = 2.0 * PI * f / sample_rate;
        let cosw = w0.cos();
        let sinw = w0.sin();
        let a = 10.0_f32.powf(gain_db / 40.0);
        let alpha = sinw / (2.0 * q);
        let sq = 2.0 * (a.sqrt()) * alpha;
        let b0 = a * ((a + 1.0) - (a - 1.0) * cosw + sq);
        let b1 = 2.0 * a * ((a - 1.0) - (a + 1.0) * cosw);
        let b2 = a * ((a + 1.0) - (a - 1.0) * cosw - sq);
        let a0 = (a + 1.0) + (a - 1.0) * cosw + sq;
        let a1 = -2.0 * ((a - 1.0) + (a + 1.0) * cosw);
        let a2 = (a + 1.0) + (a - 1.0) * cosw - sq;
        self.set_coeffs(b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0);
    }

    /// High shelf
    pub fn set_highshelf(&mut self, freq: f32, sample_rate: f32, gain_db: f32, q: f32) {
        if gain_db.abs() < 0.05 {
            self.set_passthrough();
            return;
        }
        let f = Self::clamp_freq(freq, sample_rate);
        let w0 = 2.0 * PI * f / sample_rate;
        let cosw = w0.cos();
        let sinw = w0.sin();
        let a = 10.0_f32.powf(gain_db / 40.0);
        let alpha = sinw / (2.0 * q);
        let sq = 2.0 * (a.sqrt()) * alpha;
        let b0 = a * ((a + 1.0) + (a - 1.0) * cosw + sq);
        let b1 = -2.0 * a * ((a - 1.0) + (a + 1.0) * cosw);
        let b2 = a * ((a + 1.0) + (a - 1.0) * cosw - sq);
        let a0 = (a + 1.0) - (a - 1.0) * cosw + sq;
        let a1 = 2.0 * (a - 1.0) - (a + 1.0) * cosw;
        let a2 = (a + 1.0) - (a - 1.0) * cosw - sq;
        self.set_coeffs(b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0);
    }

    /// Notch
    pub fn set_notch(&mut self, freq: f32, sample_rate: f32, q: f32) {
        let f = Self::clamp_freq(freq, sample_rate);
        let w0 = 2.0 * PI * f / sample_rate;
        let cosw = w0.cos();
        let sinw = w0.sin();
        let alpha = sinw / (2.0 * q);
        let b0 = 1.0;
        let b1 = -2.0 * cosw;
        let b2 = 1.0;
        let a0 = 1.0 + alpha;
        self.set_coeffs(
            b0 / a0,
            b1 / a0,
            b2 / a0,
            -2.0 * cosw / a0,
            (1.0 - alpha) / a0,
        );
    }

    /// Allpass（用于相位器/镶边）
    pub fn set_allpass(&mut self, freq: f32, sample_rate: f32, q: f32) {
        let f = Self::clamp_freq(freq, sample_rate);
        let w0 = 2.0 * PI * f / sample_rate;
        let cosw = w0.cos();
        let sinw = w0.sin();
        let alpha = sinw / (2.0 * q);
        let b0 = 1.0 - alpha;
        let b1 = -2.0 * cosw;
        let b2 = 1.0 + alpha;
        let a0 = 1.0 + alpha;
        self.set_coeffs(
            b0 / a0,
            b1 / a0,
            b2 / a0,
            -2.0 * cosw / a0,
            (1.0 - alpha) / a0,
        );
    }

    fn set_coeffs(&mut self, b0: f32, b1: f32, b2: f32, a1: f32, a2: f32) {
        self.b0 = b0;
        self.b1 = b1;
        self.b2 = b2;
        self.a1 = a1;
        self.a2 = a2;
        self.passthrough = false;
    }

    fn set_passthrough(&mut self) {
        self.b0 = 1.0;
        self.b1 = 0.0;
        self.b2 = 0.0;
        self.a1 = 0.0;
        self.a2 = 0.0;
        self.passthrough = true;
    }

    pub fn resize_channels(&mut self, channels: usize) {
        self.states.resize(channels, BiquadState::default());
    }

    pub fn reset(&mut self) {
        for s in &mut self.states {
            s.s1 = 0.0;
            s.s2 = 0.0;
        }
    }

    #[inline]
    pub fn process(&mut self, sample: f32, ch: usize) -> f32 {
        if self.passthrough {
            return sample;
        }
        if ch >= self.states.len() {
            self.states.resize(ch + 1, BiquadState::default());
        }
        let st = &mut self.states[ch];
        let out = self.b0 * sample + st.s1;
        st.s1 = self.b1 * sample - self.a1 * out + st.s2;
        st.s2 = self.b2 * sample - self.a2 * out;
        if !out.is_finite() {
            st.s1 = 0.0;
            st.s2 = 0.0;
            return sample;
        }
        out
    }
}

// =========================================================================
// OnePole（一阶低通/高通，用于包络跟随、空气吸收低通）
// =========================================================================

pub struct OnePole {
    pub z1: f32,
    pub a0: f32,
    pub b1: f32,
    pub is_lowpass: bool,
}

impl OnePole {
    /// 低通，cutoff Hz
    pub fn lowpass(cutoff: f32, sample_rate: f32) -> Self {
        let cutoff = cutoff.clamp(10.0, sample_rate * 0.45);
        let b1 = (-2.0 * PI * cutoff / sample_rate).exp();
        Self {
            z1: 0.0,
            a0: 1.0 - b1,
            b1,
            is_lowpass: true,
        }
    }

    /// 高通，cutoff Hz
    pub fn highpass(cutoff: f32, sample_rate: f32) -> Self {
        let cutoff = cutoff.clamp(10.0, sample_rate * 0.45);
        let b1 = (-2.0 * PI * cutoff / sample_rate).exp();
        Self {
            z1: 0.0,
            a0: (1.0 + b1) / 2.0,
            b1,
            is_lowpass: false,
        }
    }

    pub fn set_lowpass(&mut self, cutoff: f32, sample_rate: f32) {
        let cutoff = cutoff.clamp(10.0, sample_rate * 0.45);
        self.b1 = (-2.0 * PI * cutoff / sample_rate).exp();
        self.a0 = 1.0 - self.b1;
        self.is_lowpass = true;
    }

    #[inline]
    pub fn process(&mut self, sample: f32) -> f32 {
        self.z1 = self.a0 * sample + self.b1 * self.z1;
        if self.is_lowpass {
            self.z1
        } else {
            sample - self.z1
        }
    }

    pub fn reset(&mut self) {
        self.z1 = 0.0;
    }
}

// =========================================================================
// DC Blocker（一阶高通 @ ~20Hz，去除直流偏移）
// =========================================================================

pub struct DcBlocker {
    pub r: f32,
    pub prev_in: f32,
    pub prev_out: f32,
}

impl DcBlocker {
    pub fn new(sample_rate: f32) -> Self {
        let r = 1.0 - (2.0 * PI * 20.0 / sample_rate).min(PI);
        Self {
            r,
            prev_in: 0.0,
            prev_out: 0.0,
        }
    }

    #[inline]
    pub fn process(&mut self, sample: f32) -> f32 {
        let out = sample - self.prev_in + self.r * self.prev_out;
        self.prev_in = sample;
        self.prev_out = out;
        out
    }

    pub fn reset(&mut self) {
        self.prev_in = 0.0;
        self.prev_out = 0.0;
    }
}

// =========================================================================
// DelayLine（线性插值读，用于镶边/相位/延迟/混响）
// =========================================================================

pub struct DelayLine {
    pub buffer: Vec<f32>,
    pub mask: usize, // buffer.len() - 1（要求 2 的幂）
    pub write_pos: usize,
}

impl DelayLine {
    pub fn new(size: usize) -> Self {
        let size = size.next_power_of_two().max(2);
        Self {
            buffer: vec![0.0; size],
            mask: size - 1,
            write_pos: 0,
        }
    }

    pub fn clear(&mut self) {
        self.buffer.fill(0.0);
        self.write_pos = 0;
    }

    pub fn resize(&mut self, size: usize) {
        let size = size.next_power_of_two().max(2);
        if size != self.buffer.len() {
            self.buffer = vec![0.0; size];
            self.mask = size - 1;
            self.write_pos = 0;
        }
    }

    #[inline]
    pub fn write(&mut self, sample: f32) {
        self.buffer[self.write_pos] = sample;
        self.write_pos = (self.write_pos + 1) & self.mask;
    }

    /// 线性插值读取，delay 为采样数（可小数）
    #[inline]
    pub fn read(&self, delay: f32) -> f32 {
        let delay_pos = self.write_pos as f32 - delay - 1.0;
        let mut idx = delay_pos.floor() as isize;
        let frac = delay_pos - idx as f32;
        let i0 = (idx & self.mask as isize) as usize;
        idx += 1;
        let i1 = (idx & self.mask as isize) as usize;
        let s0 = self.buffer[i0];
        let s1 = self.buffer[i1];
        s0 + (s1 - s0) * frac
    }
}

// =========================================================================
// AllPass（带增益的 Schroeder 全通，用于混响/相位）
// =========================================================================

pub struct AllPass {
    pub delay: DelayLine,
    pub gain: f32,
}

impl AllPass {
    pub fn new(size: usize, gain: f32) -> Self {
        Self {
            delay: DelayLine::new(size),
            gain,
        }
    }

    pub fn clear(&mut self) {
        self.delay.clear();
    }

    pub fn resize(&mut self, size: usize) {
        self.delay.resize(size);
    }

    /// 整数延迟全通（Schroeder）：y = -g*x + delay_in + g*delay_out
    /// 此处用整数长度延迟（size-1）
    #[inline]
    pub fn process_int(&mut self, sample: f32, len: usize) -> f32 {
        let delayed = self.delay.read(len as f32);
        let out = -self.gain * sample + delayed;
        self.delay.write(sample + self.gain * out);
        out
    }
}

// =========================================================================
// SmoothedValue（指数平滑，参数变更无 click）
// =========================================================================

pub struct SmoothedValue {
    pub current: f32,
    pub target: f32,
    pub coeff: f32, // 越接近 1 越慢
}

impl SmoothedValue {
    pub fn new(initial: f32) -> Self {
        Self {
            current: initial,
            target: initial,
            coeff: 0.99,
        }
    }

    /// 设置时间常数（秒）
    pub fn set_time_constant(&mut self, seconds: f32, sample_rate: f32) {
        let seconds = seconds.max(0.0005);
        self.coeff = (-1.0 / (seconds * sample_rate)).exp();
    }

    pub fn set_target(&mut self, target: f32) {
        self.target = target;
    }

    pub fn set_immediate(&mut self, value: f32) {
        self.current = value;
        self.target = value;
    }

    #[inline]
    pub fn tick(&mut self) -> f32 {
        if (self.target - self.current).abs() < 0.0001 {
            self.current = self.target;
        } else {
            self.current = self.current + (self.target - self.current) * (1.0 - self.coeff);
        }
        self.current
    }
}

// =========================================================================
// EnvelopeFollower（峰值检测，attack/release 秒）
// =========================================================================

pub struct EnvelopeFollower {
    pub envelope: f32,
    pub attack_coeff: f32,
    pub release_coeff: f32,
}

impl EnvelopeFollower {
    pub fn new(attack_ms: f32, release_ms: f32, sample_rate: f32) -> Self {
        let mut ef = Self {
            envelope: 0.0,
            attack_coeff: 0.0,
            release_coeff: 0.0,
        };
        ef.set_times(attack_ms, release_ms, sample_rate);
        ef
    }

    pub fn set_times(&mut self, attack_ms: f32, release_ms: f32, sample_rate: f32) {
        self.attack_coeff = (-1.0 / (attack_ms.max(0.1) * 0.001 * sample_rate)).exp();
        self.release_coeff = (-1.0 / (release_ms.max(0.1) * 0.001 * sample_rate)).exp();
    }

    #[inline]
    pub fn process(&mut self, input: f32) -> f32 {
        let inp = input.abs();
        let c = if inp > self.envelope {
            self.attack_coeff
        } else {
            self.release_coeff
        };
        self.envelope = self.envelope + (inp - self.envelope) * (1.0 - c);
        self.envelope
    }

    pub fn reset(&mut self) {
        self.envelope = 0.0;
    }
}

// =========================================================================
// LFO（低频振荡器，正弦/三角）
// =========================================================================

pub struct Lfo {
    pub phase: f32,
    pub phase_inc: f32,
}

impl Lfo {
    pub fn new(freq: f32, sample_rate: f32) -> Self {
        Self {
            phase: 0.0,
            phase_inc: (2.0 * PI * freq / sample_rate).min(PI),
        }
    }

    pub fn set_freq(&mut self, freq: f32, sample_rate: f32) {
        self.phase_inc = (2.0 * PI * freq / sample_rate).min(PI);
    }

    #[inline]
    pub fn tick_sine(&mut self) -> f32 {
        let v = self.phase.sin();
        self.phase += self.phase_inc;
        if self.phase >= 2.0 * PI {
            self.phase -= 2.0 * PI;
        }
        v
    }

    #[inline]
    pub fn tick_tri(&mut self) -> f32 {
        // 0..2PI → -1..1 三角
        let p = self.phase / (2.0 * PI);
        let v = if p < 0.5 {
            4.0 * p - 1.0
        } else {
            3.0 - 4.0 * p
        };
        self.phase += self.phase_inc;
        if self.phase >= 2.0 * PI {
            self.phase -= 2.0 * PI;
        }
        v
    }

    pub fn reset(&mut self) {
        self.phase = 0.0;
    }
}

/// dB → 线性增益
#[inline]
pub fn db_to_gain(db: f32) -> f32 {
    10.0_f32.powf(db / 20.0)
}

/// 线性 → dB
#[inline]
pub fn gain_to_db(gain: f32) -> f32 {
    20.0 * gain.max(1e-10).log10()
}

/// 软限幅：|x| < 0.95 透传（无失真），≥ 0.95 渐进饱和到 1.0
/// 旧版 tanh(x) 对 0.7~0.9 的正常信号也产生可闻谐波失真 → 刺声
/// 新版用指数饱和：C1 连续（值和导数在阈值处连续，无 click）
#[inline]
pub fn soft_clip(x: f32) -> f32 {
    const THRESHOLD: f32 = 0.95;
    let ax = x.abs();
    if ax <= THRESHOLD {
        x // 正常信号透传，零失真
    } else {
        let excess = ax - THRESHOLD;
        let headroom = 1.0 - THRESHOLD; // 0.05
                                        // 指数饱和：excess=0 → 0，excess→∞ → headroom
        let saturation = headroom * (1.0 - (-excess / headroom).exp());
        x.signum() * (THRESHOLD + saturation).min(1.0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_biquad_passthrough() {
        let mut bq = Biquad::new(1);
        bq.set_peaking(1000.0, 44100.0, 0.0, 1.0);
        assert!(bq.passthrough);
        assert_eq!(bq.process(0.5, 0), 0.5);
    }

    #[test]
    fn test_biquad_lowpass_finite() {
        let mut bq = Biquad::new(1);
        bq.set_lowpass(1000.0, 44100.0, 0.707);
        let mut out = 0.0;
        for _ in 0..1000 {
            out = bq.process(0.5, 0);
        }
        assert!(out.is_finite());
    }

    #[test]
    fn test_delay_line_interp() {
        let mut dl = DelayLine::new(16);
        dl.write(1.0);
        assert!((dl.read(0.0) - 1.0).abs() < 1e-5);
    }

    #[test]
    fn test_dc_blocker() {
        let mut dc = DcBlocker::new(44100.0);
        // 恒定直流应被滤除
        let mut last = 1.0;
        for _ in 0..5000 {
            last = dc.process(0.8);
        }
        assert!(last.abs() < 0.05, "dc not blocked: {last}");
    }

    #[test]
    fn test_soft_clip_transparent_below_threshold() {
        // |x| < 0.95 应透传（无失真）
        for x in [0.0f32, 0.1, 0.3, 0.5, 0.7, 0.8, 0.9, 0.94, -0.5, -0.9] {
            let out = soft_clip(x);
            assert!(
                (out - x).abs() < 1e-6,
                "soft_clip should be transparent for |x| < 0.95, got soft_clip({}) = {}",
                x,
                out
            );
        }
    }

    #[test]
    fn test_soft_clip_limits_above_threshold() {
        // |x| > 0.95 应限制到 ≤ 1.0
        for x in [0.96f32, 1.0, 1.5, 2.0, 5.0, -1.0, -2.0] {
            let out = soft_clip(x);
            assert!(
                out.abs() <= 1.0,
                "soft_clip should limit to [-1, 1], got soft_clip({}) = {}",
                x,
                out
            );
        }
    }

    #[test]
    fn test_soft_clip_continuous_at_threshold() {
        // 在阈值 0.95 处应连续（无 click）
        let below = soft_clip(0.949);
        let at = soft_clip(0.95);
        let above = soft_clip(0.951);
        assert!(
            (below - at).abs() < 0.01,
            "soft_clip should be continuous at threshold: {} vs {}",
            below,
            at
        );
        assert!(
            (at - above).abs() < 0.01,
            "soft_clip should be continuous at threshold: {} vs {}",
            at,
            above
        );
    }
}