//! 动态类机架（阶段 4）。
//!
//! 噪声门 / 扩展器 / 压缩器 / 多段压缩 / 去齿音 / 限制器 / 自动增益(AGC)。
//! 全部采用立体声联动检测（取 L/R 最大值驱动增益），增益用包络平滑。

use super::dsp::{db_to_gain, gain_to_db, soft_clip, Biquad, EnvelopeFollower, SmoothedValue};
use super::SoundEffectSettings;

/// 4 阶 Linkwitz-Riley 分频器（2 个级联 biquad），2 通道
struct LinkwitzRiley {
    s1: [Biquad; 2],
    s2: [Biquad; 2],
}

impl LinkwitzRiley {
    fn new() -> Self {
        Self {
            s1: [Biquad::new(2), Biquad::new(2)],
            s2: [Biquad::new(2), Biquad::new(2)],
        }
    }
    fn set_lp(&mut self, freq: f32, sr: f32) {
        let q = 0.5; // LR4 = 2x Butterworth Q=0.707 → cascade q=0.5
        for i in 0..2 {
            self.s1[i].set_lowpass(freq, sr, q);
            self.s2[i].set_lowpass(freq, sr, q);
        }
    }
    fn set_hp(&mut self, freq: f32, sr: f32) {
        let q = 0.5;
        for i in 0..2 {
            self.s1[i].set_highpass(freq, sr, q);
            self.s2[i].set_highpass(freq, sr, q);
        }
    }
    #[inline]
    fn process_lp(&mut self, x: f32, ch: usize) -> f32 {
        let a = self.s1[ch].process(x, ch);
        self.s2[ch].process(a, ch)
    }
    #[inline]
    fn process_hp(&mut self, x: f32, ch: usize) -> f32 {
        let a = self.s1[ch].process(x, ch);
        self.s2[ch].process(a, ch)
    }
    fn reset(&mut self) {
        for i in 0..2 {
            self.s1[i].reset();
            self.s2[i].reset();
        }
    }
}

pub struct DynamicsRack {
    sample_rate: f32,
    wet_gate: SmoothedValue,
    wet_expander: SmoothedValue,
    wet_comp: SmoothedValue,
    wet_multi: SmoothedValue,
    wet_deesser: SmoothedValue,
    wet_limiter: SmoothedValue,
    wet_agc: SmoothedValue,
    // 包络
    gate_env: EnvelopeFollower,
    exp_env: EnvelopeFollower,
    comp_env: EnvelopeFollower,
    agc_env: EnvelopeFollower,
    comp_rms: f32,
    // 当前增益（线性）
    gate_gain: f32,
    exp_gain: f32,
    comp_gain: f32,
    limiter_gain: f32,
    agc_gain: f32,
    // 压缩器补偿增益（温和补偿，避免固定大补偿导致泵吸）
    comp_makeup_gain: f32,
    // 去齿音：带通检测 + 高shelf 动态衰减
    deess_detect: [Biquad; 2],
    deess_shelf: [Biquad; 2],
    deess_env: EnvelopeFollower,
    deess_reduction: f32,
    // 多段：LR 分频 + 各段增益
    mb_low_lp: LinkwitzRiley,
    mb_mid_hp: LinkwitzRiley,
    mb_mid_lp: LinkwitzRiley,
    mb_high_hp: LinkwitzRiley,
    mb_env: [EnvelopeFollower; 3],
    mb_gain: [f32; 3],
}

impl DynamicsRack {
    pub fn new() -> Self {
        Self {
            sample_rate: 44100.0,
            wet_gate: SmoothedValue::new(0.0),
            wet_expander: SmoothedValue::new(0.0),
            wet_comp: SmoothedValue::new(0.0),
            wet_multi: SmoothedValue::new(0.0),
            wet_deesser: SmoothedValue::new(0.0),
            wet_limiter: SmoothedValue::new(0.0),
            wet_agc: SmoothedValue::new(0.0),
            gate_env: EnvelopeFollower::new(5.0, 50.0, 44100.0),
            exp_env: EnvelopeFollower::new(5.0, 100.0, 44100.0),
            comp_env: EnvelopeFollower::new(8.0, 400.0, 44100.0),
            agc_env: EnvelopeFollower::new(10.0, 500.0, 44100.0),
            comp_rms: 0.0,
            gate_gain: 1.0,
            exp_gain: 1.0,
            comp_gain: 1.0,
            limiter_gain: 1.0,
            agc_gain: 1.0,
            comp_makeup_gain: 1.0,
            deess_detect: [Biquad::new(2), Biquad::new(2)],
            deess_shelf: [Biquad::new(2), Biquad::new(2)],
            deess_env: EnvelopeFollower::new(2.0, 80.0, 44100.0),
            deess_reduction: 0.0,
            mb_low_lp: LinkwitzRiley::new(),
            mb_mid_hp: LinkwitzRiley::new(),
            mb_mid_lp: LinkwitzRiley::new(),
            mb_high_hp: LinkwitzRiley::new(),
            mb_env: [
                EnvelopeFollower::new(5.0, 200.0, 44100.0),
                EnvelopeFollower::new(5.0, 200.0, 44100.0),
                EnvelopeFollower::new(5.0, 200.0, 44100.0),
            ],
            mb_gain: [1.0; 3],
        }
    }

    pub fn prepare(&mut self, sample_rate: f32, channels: usize) {
        self.sample_rate = sample_rate;
        let ch = channels.max(1);
        for i in 0..2 {
            self.deess_detect[i].resize_channels(ch);
            self.deess_shelf[i].resize_channels(ch);
        }
        let tc = 0.05;
        for w in [
            &mut self.wet_gate,
            &mut self.wet_expander,
            &mut self.wet_comp,
            &mut self.wet_multi,
            &mut self.wet_deesser,
            &mut self.wet_limiter,
            &mut self.wet_agc,
        ] {
            w.set_time_constant(tc, sample_rate);
        }
        self.gate_env.set_times(5.0, 50.0, sample_rate);
        self.exp_env.set_times(5.0, 100.0, sample_rate);
        // 压缩器包络默认 8ms/400ms，update_params 会按用户参数覆盖。
        // 纯峰值 + 过快释放容易造成“忽高忽低”的泵吸感，这里默认更偏音乐响度稳定。
        self.comp_env.set_times(8.0, 400.0, sample_rate);
        self.agc_env.set_times(10.0, 500.0, sample_rate);
        self.deess_env.set_times(2.0, 80.0, sample_rate);
        for e in &mut self.mb_env {
            e.set_times(5.0, 200.0, sample_rate);
        }
    }

    pub fn reset(&mut self) {
        for i in 0..2 {
            self.deess_detect[i].reset();
            self.deess_shelf[i].reset();
        }
        self.mb_low_lp.reset();
        self.mb_mid_hp.reset();
        self.mb_mid_lp.reset();
        self.mb_high_hp.reset();
        self.gate_env.reset();
        self.exp_env.reset();
        self.comp_env.reset();
        self.comp_rms = 0.0;
        self.agc_env.reset();
        self.deess_env.reset();
        for e in &mut self.mb_env {
            e.reset();
        }
        self.gate_gain = 1.0;
        self.exp_gain = 1.0;
        self.comp_gain = 1.0;
        self.limiter_gain = 1.0;
        self.agc_gain = 1.0;
        self.deess_reduction = 0.0;
        self.mb_gain = [1.0; 3];
    }

    pub fn update_params(&mut self, s: &SoundEffectSettings) {
        self.wet_gate
            .set_target(if s.noise_gate.enabled { 1.0 } else { 0.0 });
        self.wet_expander
            .set_target(if s.expander.enabled { 1.0 } else { 0.0 });
        self.wet_comp
            .set_target(if s.compressor.enabled { 1.0 } else { 0.0 });
        self.wet_multi
            .set_target(if s.multiband.enabled { 1.0 } else { 0.0 });
        self.wet_deesser
            .set_target(if s.de_esser.enabled { 1.0 } else { 0.0 });
        self.wet_limiter
            .set_target(if s.limiter.enabled { 1.0 } else { 0.0 });
        self.wet_agc
            .set_target(if s.agc.enabled { 1.0 } else { 0.0 });

        let sr = self.sample_rate;
        // 压缩器：按用户参数更新 attack/release。
        // 为降低音乐播放中的泵吸感，释放时间下限保持在 120ms；更快的瞬态保护交给 limiter。
        self.comp_env.set_times(
            sane_ms(s.compressor.attack, 8.0, 1.0, 100.0),
            sane_ms(s.compressor.release, 400.0, 120.0, 1000.0),
            sr,
        );
        self.gate_env.set_times(
            sane_ms(s.noise_gate.attack, 5.0, 0.5, 200.0),
            sane_ms(s.noise_gate.release, 80.0, 5.0, 1000.0),
            sr,
        );
        self.exp_env.set_times(8.0, 160.0, sr);
        self.agc_env.set_times(20.0, 600.0, sr);
        for e in &mut self.mb_env {
            e.set_times(8.0, 180.0, sr);
        }
        // 温和补偿增益：旧版固定 1.2 会无差别抬高安静段，在高压缩比下容易听成忽高忽低。
        // 这里按阈值/压缩比估算，并限制到最多 +2.4dB，只补回一部分响度。
        self.comp_makeup_gain = if s.compressor.enabled {
            compressor_makeup_gain(s.compressor.threshold, s.compressor.ratio)
        } else {
            1.0
        };
        for i in 0..2 {
            // 去齿音：带通检测 ~ 频率，高 shelf 衰减
            self.deess_detect[i].set_highpass(
                s.de_esser.frequency.clamp(3000.0, 10000.0),
                sr,
                0.707,
            );
            self.deess_shelf[i].set_highshelf(
                s.de_esser.frequency.clamp(3000.0, 10000.0),
                sr,
                0.0,
                0.707,
            );
        }
        // 多段分频
        self.mb_low_lp
            .set_lp(s.multiband.low_freq.clamp(50.0, 1000.0), sr);
        self.mb_mid_hp
            .set_hp(s.multiband.low_freq.clamp(50.0, 1000.0), sr);
        self.mb_mid_lp
            .set_lp(s.multiband.mid_freq.clamp(1000.0, 8000.0), sr);
        self.mb_high_hp
            .set_hp(s.multiband.mid_freq.clamp(1000.0, 8000.0), sr);
    }

    pub fn process(&mut self, frame: &mut [f32], channels: u16, s: &SoundEffectSettings) {
        if channels != 2 || frame.len() < 2 {
            return;
        }
        let sr = self.sample_rate;
        let l = frame[0];
        let r = frame[1];
        let det = l.abs().max(r.abs());

        // 噪声门
        let w = self.wet_gate.tick();
        if w > 0.001 {
            let env = self.gate_env.process(det);
            let thr = db_to_gain(s.noise_gate.threshold);
            let target = if env < thr { 0.0 } else { 1.0 };
            // 噪声门开/关都用时间常数平滑，避免硬切造成断续感。
            self.gate_gain = smooth_gate_gain(
                self.gate_gain,
                target,
                sane_ms(s.noise_gate.attack, 5.0, 0.5, 200.0),
                sane_ms(s.noise_gate.release, 80.0, 5.0, 1000.0),
                sr,
            );
            let g = lerp(1.0, self.gate_gain, w);
            frame[0] = l * g;
            frame[1] = r * g;
        }

        let det = frame[0].abs().max(frame[1].abs());

        // 扩展器
        let w = self.wet_expander.tick();
        if w > 0.001 {
            let env = self.exp_env.process(det);
            let thr = db_to_gain(s.expander.threshold);
            let ratio = s.expander.ratio.clamp(1.0, 10.0);
            let target = if env < thr {
                // 低于阈值：按 ratio 衰减（expander 斜率）
                let env_db = gain_to_db(env.max(1e-6));
                let thr_db = gain_to_db(thr);
                // 扩展器的 target 是“增益变化量”，不是目标输出电平。
                // output_db = thr_db + (env_db - thr_db) * ratio
                // gain_db = output_db - env_db = (ratio - 1) * (env_db - thr_db)
                db_to_gain(((ratio - 1.0) * (env_db - thr_db)).max(-48.0))
            } else {
                1.0
            };
            self.exp_gain = smooth_gain(self.exp_gain, target, 8.0, 160.0, sr);
            let g = lerp(1.0, self.exp_gain, w);
            frame[0] *= g;
            frame[1] *= g;
        }

        let det = frame[0].abs().max(frame[1].abs());

        // 压缩器
        // 使用 RMS/峰值混合检测：RMS 负责稳定响度，峰值只参与瞬态保护。
        // 旧版纯峰值检测 + 固定 1.2 补偿在鼓点密集或动态大的歌曲中容易产生泵吸。
        let w = self.wet_comp.tick();
        if w > 0.001 {
            let attack_ms = sane_ms(s.compressor.attack, 8.0, 1.0, 100.0);
            let release_ms = sane_ms(s.compressor.release, 400.0, 120.0, 1000.0);
            let rms_ms = (release_ms * 0.5).clamp(80.0, 500.0);
            let rms_coeff = (-1.0 / (rms_ms * 0.001 * sr.max(1.0))).exp();
            self.comp_rms = self.comp_rms * rms_coeff + det * det * (1.0 - rms_coeff);
            let rms = self.comp_rms.sqrt();
            let peak = self.comp_env.process(det);
            let env = (rms * 0.75 + peak * 0.25).max(peak * 0.65);
            let thr_db = s.compressor.threshold.clamp(-60.0, 0.0);
            let ratio = s.compressor.ratio.clamp(1.0, 20.0);
            let knee = 30.0; // dB，对齐 YinDongMusic DynamicsCompressorNode knee.value = 30
            let env_db = gain_to_db(env.max(1e-6));
            let slope = 1.0 - 1.0 / ratio;
            let x = env_db - thr_db;
            let half_knee = knee * 0.5;

            // 软 knee 压缩曲线（对齐 WebAudio spec）：
            // x < -knee/2: 无压缩
            // x > knee/2: 全压缩 gain_db = -(x - knee/2) * slope
            // 中间: 二次平滑过渡 gain_db = -(x + knee/2)^2 / (2*knee) * slope
            let target = if x < -half_knee {
                1.0
            } else if x > half_knee {
                db_to_gain(-(x - half_knee) * slope)
            } else {
                let gain_db = -(x + half_knee).powi(2) / (2.0 * knee) * slope;
                db_to_gain(gain_db)
            };
            // gain 平滑按 attack/release 跟随，避免固定步进在不同采样率/参数下产生泵吸。
            self.comp_gain = smooth_gain(self.comp_gain, target, attack_ms, release_ms, sr);
            let g = lerp(1.0, self.comp_gain, w);
            // 温和补偿增益，随湿度淡入，避免开启瞬间音量跳变。
            let makeup = 1.0 + (self.comp_makeup_gain - 1.0) * w;
            frame[0] *= g * makeup;
            frame[1] *= g * makeup;
        }

        // 多段压缩
        let w = self.wet_multi.tick();
        if w > 0.001 {
            let thr_db = s.multiband.threshold.clamp(-60.0, 0.0);
            let ratio = s.multiband.ratio.clamp(1.0, 20.0);
            let in_l = frame[0];
            let in_r = frame[1];
            // 三段分解
            let low_l = self.mb_low_lp.process_lp(in_l, 0);
            let low_r = self.mb_low_lp.process_lp(in_r, 1);
            let mid_l = self
                .mb_mid_lp
                .process_lp(self.mb_mid_hp.process_hp(in_l, 0), 0);
            let mid_r = self
                .mb_mid_lp
                .process_lp(self.mb_mid_hp.process_hp(in_r, 1), 1);
            let high_l = self.mb_high_hp.process_hp(in_l, 0);
            let high_r = self.mb_high_hp.process_hp(in_r, 1);
            // 各段压缩
            let bands = [(low_l, low_r, 0), (mid_l, mid_r, 1), (high_l, high_r, 2)];
            let mut out_l = 0.0;
            let mut out_r = 0.0;
            for (bl, br, idx) in bands {
                let env = self.mb_env[idx].process(bl.abs().max(br.abs()));
                let env_db = gain_to_db(env.max(1e-6));
                let target = if env_db > thr_db {
                    // 多段压缩同样需要输出“衰减增益”，而不是目标输出电平。
                    db_to_gain(-((env_db - thr_db) * (1.0 - 1.0 / ratio)))
                } else {
                    1.0
                };
                self.mb_gain[idx] = smooth_gain(self.mb_gain[idx], target, 8.0, 180.0, sr);
                out_l += bl * self.mb_gain[idx];
                out_r += br * self.mb_gain[idx];
            }
            frame[0] = in_l * (1.0 - w) + out_l * w;
            frame[1] = in_r * (1.0 - w) + out_r * w;
        }

        // 去齿音
        let w = self.wet_deesser.tick();
        if w > 0.001 {
            let hi_l = self.deess_detect[0].process(frame[0], 0);
            let hi_r = self.deess_detect[1].process(frame[1], 1);
            let env = self.deess_env.process(hi_l.abs().max(hi_r.abs()));
            let thr = db_to_gain(s.de_esser.threshold.clamp(-60.0, 0.0));
            let target_red = if env > thr {
                -((env - thr) * 40.0).min(12.0)
            } else {
                0.0
            };
            self.deess_reduction =
                smooth_db_reduction(self.deess_reduction, target_red, 2.0, 80.0, sr);
            for i in 0..2 {
                self.deess_shelf[i].set_highshelf(
                    s.de_esser.frequency,
                    sr,
                    self.deess_reduction,
                    0.707,
                );
            }
            let nl = self.deess_shelf[0].process(frame[0], 0);
            let nr = self.deess_shelf[1].process(frame[1], 1);
            frame[0] = frame[0] * (1.0 - w) + nl * w;
            frame[1] = frame[1] * (1.0 - w) + nr * w;
        }

        // 限制器（brickwall，快攻击）
        let w = self.wet_limiter.tick();
        if w > 0.001 {
            let thr = db_to_gain(s.limiter.threshold.clamp(-10.0, 0.0));
            let peak = frame[0].abs().max(frame[1].abs());
            let target = if peak > thr && peak > 1e-6 {
                (thr / peak).clamp(0.05, 1.0)
            } else {
                1.0
            };
            self.limiter_gain = smooth_gain(self.limiter_gain, target, 0.5, 60.0, sr);
            let g = lerp(1.0, self.limiter_gain, w);
            frame[0] = soft_clip(frame[0] * g);
            frame[1] = soft_clip(frame[1] * g);
        }

        // AGC 自动增益
        let w = self.wet_agc.tick();
        if w > 0.001 {
            let env = self.agc_env.process(frame[0].abs().max(frame[1].abs()));
            let target_level =
                db_to_gain((s.agc.target_level / 100.0).clamp(0.0, 1.0) * -6.0 + 6.0); // 映射到 -6..6dB
            let target_gain = if env > 1e-5 { target_level / env } else { 1.0 };
            let clamped = target_gain.clamp(0.1, 10.0);
            self.agc_gain = smooth_gain(self.agc_gain, clamped, 60.0, 600.0, sr);
            let g = lerp(1.0, self.agc_gain, w);
            frame[0] = soft_clip(frame[0] * g);
            frame[1] = soft_clip(frame[1] * g);
        }
    }
}

#[inline]
fn lerp(a: f32, b: f32, t: f32) -> f32 {
    a + (b - a) * t
}

/// 将用户参数 0/缺省值替换为安全默认值，并限制范围。
#[inline]
fn sane_ms(value: f32, fallback: f32, min: f32, max: f32) -> f32 {
    if value.is_finite() && value > 0.0 {
        value.clamp(min, max)
    } else {
        fallback.clamp(min, max)
    }
}

#[inline]
fn compressor_makeup_gain(threshold_db: f32, ratio: f32) -> f32 {
    let threshold = threshold_db.clamp(-60.0, 0.0);
    let ratio = ratio.clamp(1.0, 20.0);
    if ratio <= 1.01 {
        return 1.0;
    }
    let slope = 1.0 - 1.0 / ratio;
    let makeup_db = ((-threshold) * slope * 0.12).clamp(0.0, 2.4);
    db_to_gain(makeup_db)
}

#[inline]
fn smoothing_amount(ms: f32, sr: f32) -> f32 {
    let ms = ms.max(0.1);
    let sr = sr.max(1.0);
    1.0 - (-1.0 / (ms * 0.001 * sr)).exp()
}

/// 压缩/扩展/限制/AGC 的增益平滑：
/// target 变小表示进入衰减，用 attack；target 变大表示恢复，用 release。
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

/// 噪声门：target 变大为开门 attack，target 变小为关门 release。
#[inline]
fn smooth_gate_gain(current: f32, target: f32, attack_ms: f32, release_ms: f32, sr: f32) -> f32 {
    let t = if target.is_finite() {
        target.clamp(0.0, 1.0)
    } else {
        1.0
    };
    let c = if t > current {
        smoothing_amount(attack_ms, sr)
    } else {
        smoothing_amount(release_ms, sr)
    };
    current + (t - current) * c
}

/// dB 衰减平滑：更负表示增加衰减，用 attack；回到 0 用 release。
#[inline]
fn smooth_db_reduction(current: f32, target: f32, attack_ms: f32, release_ms: f32, sr: f32) -> f32 {
    let t = if target.is_finite() {
        target.clamp(-48.0, 0.0)
    } else {
        0.0
    };
    let c = if t < current {
        smoothing_amount(attack_ms, sr)
    } else {
        smoothing_amount(release_ms, sr)
    };
    current + (t - current) * c
}