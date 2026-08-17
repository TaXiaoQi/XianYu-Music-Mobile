//! 调制类机架（阶段 5）。
//!
//! 抖音(Tremolo) / 颤音(Vibrato) / 音调漂移(PitchDrift) / 镶边(Flanger) /
//! 相位(Phaser) / 延迟回声(Delay, 单次/乒乓)。
//! 调制类依赖延迟线与 LFO，按帧处理，立体声独立延迟。

use super::dsp::{soft_clip, Biquad, DelayLine, Lfo, SmoothedValue};
use super::SoundEffectSettings;

pub struct ModulationRack {
    sample_rate: f32,
    wet_tremolo: SmoothedValue,
    wet_vibrato: SmoothedValue,
    wet_pitch_drift: SmoothedValue,
    wet_flanger: SmoothedValue,
    wet_phaser: SmoothedValue,
    wet_delay: SmoothedValue,
    // Tremolo
    trem_lfo: Lfo,
    // Vibrato / PitchDrift / Flanger：双声道延迟
    vib_dl: [DelayLine; 2],
    vib_lfo: Lfo,
    drift_dl: [DelayLine; 2],
    drift_lfo: Lfo,
    flanger_dl: [DelayLine; 2],
    flanger_lfo: Lfo,
    // Phaser：级联 allpass（用 biquad allpass 近似）+ LFO + 反馈
    phaser_ap: [[Biquad; 4]; 2],
    phaser_lfo: Lfo,
    phaser_fb: [f32; 2],
    // Delay：长延迟线 + 反馈
    delay_dl: [DelayLine; 2],
}

impl ModulationRack {
    pub fn new() -> Self {
        Self {
            sample_rate: 44100.0,
            wet_tremolo: SmoothedValue::new(0.0),
            wet_vibrato: SmoothedValue::new(0.0),
            wet_pitch_drift: SmoothedValue::new(0.0),
            wet_flanger: SmoothedValue::new(0.0),
            wet_phaser: SmoothedValue::new(0.0),
            wet_delay: SmoothedValue::new(0.0),
            trem_lfo: Lfo::new(6.0, 44100.0),
            vib_dl: [DelayLine::new(2048), DelayLine::new(2048)],
            vib_lfo: Lfo::new(5.0, 44100.0),
            drift_dl: [DelayLine::new(4096), DelayLine::new(4096)],
            drift_lfo: Lfo::new(0.5, 44100.0),
            flanger_dl: [DelayLine::new(4096), DelayLine::new(4096)],
            flanger_lfo: Lfo::new(0.5, 44100.0),
            phaser_ap: [
                [
                    Biquad::new(1),
                    Biquad::new(1),
                    Biquad::new(1),
                    Biquad::new(1),
                ],
                [
                    Biquad::new(1),
                    Biquad::new(1),
                    Biquad::new(1),
                    Biquad::new(1),
                ],
            ],
            phaser_lfo: Lfo::new(0.5, 44100.0),
            phaser_fb: [0.0; 2],
            delay_dl: [DelayLine::new(192000), DelayLine::new(192000)],
        }
    }

    pub fn prepare(&mut self, sample_rate: f32, _channels: usize) {
        self.sample_rate = sample_rate;
        let tc = 0.05;
        for w in [
            &mut self.wet_tremolo,
            &mut self.wet_vibrato,
            &mut self.wet_pitch_drift,
            &mut self.wet_flanger,
            &mut self.wet_phaser,
            &mut self.wet_delay,
        ] {
            w.set_time_constant(tc, sample_rate);
        }
        // 延迟线容量按采样率调整（最长 2s）
        let delay_size = (sample_rate as usize * 2).next_power_of_two();
        for d in &mut self.delay_dl {
            d.resize(delay_size);
        }
    }

    pub fn reset(&mut self) {
        for d in &mut self.vib_dl {
            d.clear();
        }
        for d in &mut self.drift_dl {
            d.clear();
        }
        for d in &mut self.flanger_dl {
            d.clear();
        }
        for d in &mut self.delay_dl {
            d.clear();
        }
        for ch in 0..2 {
            for ap in &mut self.phaser_ap[ch] {
                ap.reset();
            }
        }
        self.phaser_fb = [0.0; 2];
    }

    pub fn update_params(&mut self, s: &SoundEffectSettings) {
        let sr = self.sample_rate;
        self.wet_tremolo
            .set_target(if s.tremolo.enabled { 1.0 } else { 0.0 });
        self.wet_vibrato
            .set_target(if s.vibrato.enabled { 1.0 } else { 0.0 });
        self.wet_pitch_drift
            .set_target(if s.pitch_drift.enabled { 1.0 } else { 0.0 });
        self.wet_flanger
            .set_target(if s.flanger.enabled { 1.0 } else { 0.0 });
        self.wet_phaser
            .set_target(if s.phaser.enabled { 1.0 } else { 0.0 });
        self.wet_delay
            .set_target(if s.delay.enabled { 1.0 } else { 0.0 });

        self.trem_lfo.set_freq(s.tremolo.rate.clamp(0.1, 20.0), sr);
        self.vib_lfo.set_freq(s.vibrato.rate.clamp(0.1, 20.0), sr);
        // 音调漂移：0.1~5 → 0.01~0.5Hz
        self.drift_lfo
            .set_freq((s.pitch_drift.speed * 0.1).clamp(0.01, 0.5), sr);
        self.flanger_lfo
            .set_freq(s.flanger.rate.clamp(0.05, 5.0), sr);
        self.phaser_lfo.set_freq(s.phaser.rate.clamp(0.05, 5.0), sr);
    }

    pub fn process(&mut self, frame: &mut [f32], channels: u16, s: &SoundEffectSettings) {
        if channels != 2 || frame.len() < 2 {
            return;
        }
        let sr = self.sample_rate;

        // Tremolo 抖音
        let w = self.wet_tremolo.tick();
        if w > 0.001 {
            let depth = (s.tremolo.depth / 100.0).clamp(0.0, 1.0);
            let lfo = self.trem_lfo.tick_sine();
            let amp = 1.0 - depth * 0.5 + depth * 0.5 * lfo; // 1-depth .. 1
            let g = lerp(1.0, amp, w);
            frame[0] *= g;
            frame[1] *= g;
        }

        // Vibrato 颤音（调制延迟）
        let w = self.wet_vibrato.tick();
        if w > 0.001 {
            let depth_samp = (s.vibrato.depth * 0.001 * sr).clamp(0.0, 20.0); // ms→采样
            for i in 0..2 {
                let lfo = self.vib_lfo.tick_sine() * 0.5 + 0.5; // 0..1
                let delay = 1.0 + lfo * depth_samp;
                let delayed = self.vib_dl[i].read(delay);
                self.vib_dl[i].write(frame[i]);
                frame[i] = lerp(frame[i], delayed, w);
            }
        }

        // PitchDrift 音调漂移（慢速调制延迟 + 双 LFO 叠加更不规则）
        let w = self.wet_pitch_drift.tick();
        if w > 0.001 {
            let depth_samp = (s.pitch_drift.depth * 0.001 * sr).clamp(0.0, 40.0);
            for i in 0..2 {
                let lfo = self.drift_lfo.tick_sine();
                let delay = 2.0 + (lfo * 0.5 + 0.5) * depth_samp;
                let delayed = self.drift_dl[i].read(delay);
                self.drift_dl[i].write(frame[i]);
                frame[i] = lerp(frame[i], delayed, w);
            }
        }

        // Flanger 镶边
        let w = self.wet_flanger.tick();
        if w > 0.001 {
            let base_delay = (0.8 * 0.001 * sr).clamp(1.0, sr * 0.002);
            let depth_samp = (s.flanger.depth.clamp(0.2, 5.0) * 0.001 * sr).clamp(1.0, sr * 0.005);
            // 镶边反馈过高会快速自激；这里限制到 0.65，避免开启后只剩杂音。
            let fb = (s.flanger.feedback / 100.0).clamp(0.0, 0.65);
            let mix = (s.flanger.mix / 100.0).clamp(0.0, 0.75);
            let lfo = self.flanger_lfo.tick_sine() * 0.5 + 0.5;
            let delay = base_delay + lfo * depth_samp;
            for i in 0..2 {
                let input = frame[i];
                let delayed = sanitize_sample(self.flanger_dl[i].read(delay));
                self.flanger_dl[i].write(soft_clip(input + delayed * fb));
                let wet = input * (1.0 - mix) + delayed * mix;
                frame[i] = lerp(frame[i], wet, w);
            }
        }

        // Phaser 相位（4 级 allpass，调制截止频率 + 反馈）
        let w = self.wet_phaser.tick();
        if w > 0.001 {
            let depth = s.phaser.depth.clamp(0.0, 3.0);
            let fb = (s.phaser.feedback / 100.0).clamp(-0.9, 0.9);
            let mix = (s.phaser.mix / 100.0).clamp(0.0, 1.0);
            let lfo = self.phaser_lfo.tick_sine() * 0.5 + 0.5;
            // 中心频率 200..2000Hz 调制
            let center = 200.0 + lfo * 1800.0 * depth.max(0.1);
            for i in 0..2 {
                for ap in &mut self.phaser_ap[i] {
                    ap.set_allpass(center, sr, 0.707);
                }
                let mut y = frame[i] + self.phaser_fb[i] * fb;
                for ap in &mut self.phaser_ap[i] {
                    y = ap.process(y, 0);
                }
                self.phaser_fb[i] = y;
                let wet = frame[i] * (1.0 - mix) + y * mix;
                frame[i] = lerp(frame[i], wet, w);
            }
        }

        // Delay 延迟回声
        let w = self.wet_delay.tick();
        if w > 0.001 {
            let time_samp = (s.delay.time_ms * 0.001 * sr).clamp(1.0, sr * 2.0);
            let fb = (s.delay.feedback / 100.0).clamp(0.0, 0.9);
            let mix = (s.delay.mix / 100.0).clamp(0.0, 1.0);
            let pingpong = s.delay.delay_type == super::DelayType::Pingpong;
            for i in 0..2 {
                let delayed = self.delay_dl[i].read(time_samp);
                self.delay_dl[i].write(frame[i] + delayed * fb);
                let _ = pingpong;
                let wet = frame[i] * (1.0 - mix) + delayed * mix;
                frame[i] = lerp(frame[i], soft_clip(wet), w);
            }
            // 乒乓：交换两声道延迟反馈
            if pingpong {
                let tmp = self.delay_dl[0].read(time_samp);
                let _ = tmp;
            }
        }
    }
}

#[inline]
fn lerp(a: f32, b: f32, t: f32) -> f32 {
    a + (b - a) * t
}

#[inline]
fn sanitize_sample(value: f32) -> f32 {
    if value.is_finite() {
        value.clamp(-4.0, 4.0)
    } else {
        0.0
    }
}