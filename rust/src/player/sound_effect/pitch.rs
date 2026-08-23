//! 变调/变速机架 —— OLA 时间拉伸 + 线性插值重采样。
//!
//! 原位增强 YinDongMusic 后端的"纯线性重采样"方案，把原本仅由前端 WebAudio
//! 处理的 `preserves_pitch`（变速保调）下沉到 Rust DSP，对齐任务目标：
//!
//! - **线性重采样**：用于变调 pitch_shift（经典黑胶式，音调与速度同步变化）。
//! - **OLA 时间拉伸**：用于变速 playback_rate 且 `preserves_pitch=true` 的场景，
//!   用 Hann 窗 50% 重叠相加（perfect COLA）在保持音调的前提下拉伸/压缩时间轴。
//! - **两者叠加**：变速保调(OLA) 再叠变调(重采样)，输出采样率仍等于原始采样率
//!   （音调不受变速影响，仅受 pitch_shift 影响）。
//!
//! 流式接口保持与之前一致（`fill` 逐帧输出，跨帧状态常驻），对外不新增 API。

use super::SoundEffectSettings;
use std::collections::VecDeque;

/// Hann 窗 50% 重叠的 OLA 分段帧数（越大越平稳，时延略增）。
const OLA_SEG: usize = 1024;
/// 每次发射的跳出帧数（= seg/2，保证 perfect COLA）。
const OLA_HOP: usize = OLA_SEG / 2;

/// 线性插值重采样 + OLA 时间拉伸的复合变速变调处理器。
pub struct PitchRateProcessor {
    channels: usize,
    sample_rate: f32,

    // 是否启用各阶段
    do_ola: bool,       // OLA 时间拉伸（变速保调）
    ola_stretch: f64,   // 拉伸因子（>1 变慢，<1 变快）
    do_resample: bool,  // 线性重采样（变调）
    resample_ratio: f64,

    // 原始输入缓冲（OLA 的原始输入；无 OLA 时作为重采样直接输入）
    input_buf: VecDeque<f32>,
    // OLA 输出缓冲（OLA→重采样 或 直接输出）
    ola_q: VecDeque<f32>,

    // OLA 内部状态
    ola_out: Vec<f32>, // 环形输出累加器（seg*ch）
    ola_head: usize,   // 尚未发射的首样本位置（样本下标）
    ola_pos: f64,      // 下一分段的输入帧起点（含小数）
    ola_win: Vec<f32>, // 周期 Hann 窗
    raw_eof: bool,     // inner 是否已 EOF

    // 重采样拖尾补零帧数
    tail_zero_frames: usize,

    // 重采样读取位置（帧单位，含小数）。仅重采样模式下有意义。
    read_src_pos: f64,
}

impl PitchRateProcessor {
    pub fn new(channels: u16, sample_rate: u32) -> Self {
        let ch = (channels as usize).max(1);
        let mut win = vec![0.0f32; OLA_SEG];
        for (k, w) in win.iter_mut().enumerate() {
            let th = (std::f32::consts::TAU * k as f32) / OLA_SEG as f32;
            *w = 0.5 * (1.0 - th.cos());
        }
        Self {
            channels: ch,
            sample_rate: sample_rate as f32,
            do_ola: false,
            ola_stretch: 1.0,
            do_resample: false,
            resample_ratio: 1.0,
            input_buf: VecDeque::with_capacity(16384),
            ola_q: VecDeque::with_capacity(8192),
            ola_out: vec![0.0f32; OLA_SEG * ch],
            ola_head: 0,
            ola_pos: 0.0,
            ola_win: win,
            raw_eof: false,
            tail_zero_frames: 0,
            read_src_pos: 0.0,
        }
    }

    pub fn prepare(&mut self, sample_rate: f32, channels: usize) {
        self.sample_rate = sample_rate;
        self.channels = channels.max(1);
        self.input_buf.clear();
        self.ola_q.clear();
        self.ola_out.fill(0.0);
        self.ola_head = 0;
        self.ola_pos = 0.0;
        self.raw_eof = false;
        self.downstream_reset();
    }

    pub fn reset(&mut self) {
        self.input_buf.clear();
        self.ola_q.clear();
        self.ola_out.fill(0.0);
        self.ola_head = 0;
        self.ola_pos = 0.0;
        self.raw_eof = false;
        self.downstream_reset();
    }

    /// 同步参数（每 64 帧由音频线程调用）。
    pub fn update_params(&mut self, s: &SoundEffectSettings) {
        // 防御：0/负/NaN 视为 100（原调原速）
        let raw_rate = if !s.playback_rate.is_finite() || s.playback_rate <= 0.0 {
            100.0
        } else {
            s.playback_rate
        };
        let raw_pitch = if !s.pitch_shift.is_finite() || s.pitch_shift <= 0.0 {
            100.0
        } else {
            s.pitch_shift
        };
        let rate = (raw_rate / 100.0).clamp(0.25, 4.0);
        let pitch = (raw_pitch / 100.0).clamp(0.25, 4.0);

        let pitch_changed = (pitch - 1.0).abs() >= 0.001;
        let rate_changed = (rate - 1.0).abs() >= 0.001;

        if s.preserves_pitch {
            // 变速保调模式：OLA 负责变速，重采样负责变调（二者可叠加）。
            // ola_stretch 是"时间拉伸因子"：>1 变慢（输出更长），<1 变快。
            // playback_rate 是速度（100=正常，>100 更快），故取倒数映射到拉伸因子。
            self.do_ola = rate_changed;
            self.ola_stretch = 1.0 / rate as f64;
            self.do_resample = pitch_changed;
            self.resample_ratio = pitch as f64;
            if !self.do_ola {
                // 仅变调：重采样直接读原始输入
                self.ola_q.clear();
            }
            if rate_changed || pitch_changed {
                self.update_downstream_stage();
            }
        } else {
            // 经典模式：与 YinDongMusic 一致，线性重采样（黑胶式），
            // 音调与速度同步变化；仅有变速时不重采样，而是调 sample_rate。
            if pitch_changed {
                self.do_ola = false;
                self.ola_q.clear();
                self.do_resample = true;
                // 变速叠加进重采样比率（保持原行为：pitch*rate 组合）
                self.resample_ratio = if rate_changed {
                    pitch as f64 * rate as f64
                } else {
                    pitch as f64
                };
                self.update_downstream_stage();
            } else if rate_changed {
                self.do_ola = false;
                self.ola_q.clear();
                self.do_resample = false;
                self.downstream_reset();
            } else {
                self.do_ola = false;
                self.do_resample = false;
                self.ola_q.clear();
                self.input_buf.clear();
                self.ola_out.fill(0.0);
                self.ola_head = 0;
                self.ola_pos = 0.0;
                self.raw_eof = false;
            }
        }
    }

    /// 重置下游重采样状态（当阶段切换时调用）。
    fn downstream_reset(&mut self) {
        // 重采样使用 input_buf/read_pos 内联实现；阶段切换时由实际模式显式处理。
    }

    fn update_downstream_stage(&mut self) {
        // 重采样内部状态直接在 fill 中维护（read_src 位置）。
    }

    /// 有效采样率。
    /// - 非保调纯变速（经典 sample_rate 模式已废弃为 OLA/重采样），此处统一返回 inner。
    /// - OLA 变速保调：输出采样率 = inner（音调不变）。
    /// - 重采样变调：仅在 OLA 不参与时按 ratio 修正；保调叠加时仍为 inner。
    pub fn effective_sample_rate(&self, inner_rate: u32) -> u32 {
        if self.do_ola {
            inner_rate
        } else if self.do_resample && (self.resample_ratio - 1.0).abs() >= 0.001 {
            // 经典非保调变调：重采样改变音调同时采样率不变（样本已在时域拉伸）。
            inner_rate
        } else {
            inner_rate
        }
    }

    /// 从 inner 读取并填充一帧（channels 个样本）到 out。
    /// 返回 false 表示输入已结束且缓冲已耗尽。
    pub fn fill<I: Iterator<Item = f32>>(&mut self, inner: &mut I, out: &mut [f32]) -> bool {
        let ch = self.channels;

        if !self.do_ola && !self.do_resample {
            // 纯直通
            for i in 0..ch.min(out.len()) {
                if let Some(s) = inner.next() {
                    out[i] = s;
                } else {
                    return false;
                }
            }
            return true;
        }

        if !self.do_resample {
            // 仅 OLA 时间拉伸（变速保调）：直接消费 ola_q
            loop {
                if self.ola_q.len() >= ch {
                    for i in 0..ch.min(out.len()) {
                        out[i] = self.ola_q.pop_front().unwrap_or(0.0);
                    }
                    return true;
                }
                if !self.ola_pump(inner) {
                    return false;
                }
            }
        }

        // 存在重采样：线性插值，从"上游"读取。
        // 上游 = OLA 输出（保调变速）或 原始输入（仅变调）。
        self.fill_resampled(inner, out)
    }

    /// 线性插值重采样输出一帧。上游样本经 `pull_source` 获取。
    fn fill_resampled<I: Iterator<Item = f32>>(
        &mut self,
        inner: &mut I,
        out: &mut [f32],
    ) -> bool {
        let ch = self.channels;
        let ratio = self.resample_ratio;

        if !self.raw_eof {
            self.ensure_resample_input(inner);
        }

        // 确保至少有 2 帧可插值
        let src = self.resample_src_len();
        if src < (self.read_src_pos.floor() as usize) + 2 {
            if self.raw_eof && self.input_eof() {
                // EOF：输出残余一帧
                let idx = self.read_src_pos.floor() as usize;
                if idx * ch < src * ch {
                    for c in 0..ch.min(out.len()) {
                        out[c] = self.source_sample(idx * ch + c);
                    }
                } else {
                    for i in 0..ch.min(out.len()) {
                        out[i] = 0.0;
                    }
                }
                return false;
            }
            if self.raw_eof {
                // 补零让重采样自然衰减
                for i in 0..ch.min(out.len()) {
                    out[i] = self.source_sample((self.read_src_pos.floor() as usize) * ch + i);
                }
                self.read_src_pos += ratio;
                return true;
            }
            for i in 0..ch.min(out.len()) {
                out[i] = 0.0;
            }
            return true;
        }

        let idx = self.read_src_pos.floor() as usize;
        let frac = (self.read_src_pos - idx as f64) as f32;
        for c in 0..ch.min(out.len()) {
            let s0 = self.source_sample(idx * ch + c);
            let s1 = self.source_sample((idx + 1) * ch + c);
            out[c] = s0 + (s1 - s0) * frac;
        }
        self.read_src_pos += ratio;

        let consumed = self.read_src_pos.floor() as usize;
        if consumed > 0 {
            self.discard_source(consumed * ch);
            self.read_src_pos -= consumed as f64;
        }
        true
    }

    // =====================================================================
    // 统一"上游样本源"抽象：让重采样既能读 OLA 输出，也能读原始输入。
    // =====================================================================

    /// 重采样读取的源缓冲区长度（帧数）。无 OLA 时 = input_buf / ch。
    fn resample_src_len(&self) -> usize {
        if self.do_ola {
            self.ola_q.len() / self.channels.max(1)
        } else {
            self.input_buf.len() / self.channels.max(1)
        }
    }

    fn source_sample(&self, sample_idx: usize) -> f32 {
        if self.do_ola {
            self.ola_q.get(sample_idx).copied().unwrap_or(0.0)
        } else {
            self.input_buf.get(sample_idx).copied().unwrap_or(0.0)
        }
    }

    fn discard_source(&mut self, count: usize) {
        let buf = if self.do_ola {
            &mut self.ola_q
        } else {
            &mut self.input_buf
        };
        let to_remove = count.min(buf.len());
        for _ in 0..to_remove {
            buf.pop_front();
        }
    }

    /// 从上游补充样本（OLA 或原始输入）到各自的源缓冲。
    fn ensure_resample_input<I: Iterator<Item = f32>>(&mut self, inner: &mut I) {
        if self.do_ola {
            // 上游是 OLA：先让 OLA 产出，再供给 ola_q
            for _ in 0..2 {
                if self.resample_src_len() >= 8 {
                    break;
                }
                if !self.ola_pump(inner) {
                    self.raw_eof = true;
                    break;
                }
            }
            return;
        }
        // 上游是原始输入
        let consumption = self.resample_ratio.max(1.0);
        let max_per_call = (consumption.ceil() as usize).max(1).min(32);
        let need_frames = self.read_src_pos.floor() as usize + 4;
        for _ in 0..max_per_call {
            if self.input_buf.len() / self.channels >= need_frames {
                break;
            }
            let mut frame_eof = false;
            for _ in 0..self.channels {
                match inner.next() {
                    Some(s) => self.input_buf.push_back(s),
                    None => {
                        frame_eof = true;
                        self.input_buf.push_back(0.0);
                    }
                }
            }
            if frame_eof {
                self.raw_eof = true;
                break;
            }
        }
    }

    /// 是否上游原始输入已彻底耗尽。
    fn input_eof(&self) -> bool {
        self.raw_eof && !self.do_ola
    }

    // =====================================================================
    // OLA 时间拉伸
    // =====================================================================

    /// 尽力生产 OLA 输出到 ola_q；返回是否可能还有后续输出。
    /// 输入不足时尝试继续拉取 inner，拉不到则进入 EOF。
    fn ola_pump<I: Iterator<Item = f32>>(&mut self, inner: &mut I) -> bool {
        // 1. 尝试拉取更多原始输入（最多若干帧/次）
        if !self.raw_eof {
            for _ in 0..(OLA_SEG / 2) {
                match inner.next() {
                    Some(s) => self.input_buf.push_back(s),
                    None => {
                        self.raw_eof = true;
                        // EOF 补零够放最后一个分段
                        for _ in 0..self.channels * OLA_SEG {
                            self.input_buf.push_back(0.0);
                        }
                        break;
                    }
                }
            }
        }

        // 2. 反复放置分段并发射
        loop {
            let seg_start = self.ola_pos.floor() as usize;
            let need_frames = seg_start + OLA_SEG;
            if (self.input_buf.len() / self.channels) < need_frames {
                // 输入不足：交给上层判断（EOF 或继续拉）
                break;
            }
            self.ola_place(seg_start);
            self.ola_emit();
            // 重置 tail 计数
            self.tail_zero_frames = 0;
        }

        self.ola_q.len() >= self.channels || !(self.raw_eof && self.ola_q.is_empty())
    }

    /// 放置一个 Hann 窗分段到环形累加器（输入位置用小数 + 线性插值保证连续性）。
    fn ola_place(&mut self, seg_start: usize) {
        let ch = self.channels;
        let seg = OLA_SEG;
        let frac = (self.ola_pos - seg_start as f64) as f32;
        let ring_len = seg * ch;
        // 段首写位置 = 当前发射头
        let base = self.ola_head;

        for k in 0..seg {
            let fa = seg_start + k;
            let w = self.ola_win[k];
            for c in 0..ch {
                let idx = base + (k * ch + c);
                let ring_idx = idx % ring_len;
                let s0 = self.input_buf.get(fa * ch + c).copied().unwrap_or(0.0);
                let s1 = self
                    .input_buf
                    .get((fa + 1) * ch + c)
                    .copied()
                    .unwrap_or(0.0);
                let sample = if frac > 1e-6 {
                    s0 + (s1 - s0) * frac
                } else {
                    s0
                };
                self.ola_out[ring_idx] += sample * w;
            }
        }
        self.ola_pos += OLA_HOP as f64 / self.ola_stretch;
    }

    /// 从环形累加器发射 OLA_HOP 帧到 ola_q，并推进发射头（覆盖已发射区域）。
    fn ola_emit(&mut self) {
        let ch = self.channels;
        let seg = OLA_SEG;
        let ring_len = seg * ch;
        for k in 0..OLA_HOP {
            for c in 0..ch {
                let idx = (self.ola_head + k * ch + c) % ring_len;
                let v = self.ola_out[idx];
                self.ola_q.push_back(v);
                // 发射后清零，为下一分段重叠相加腾出累加空间
                self.ola_out[idx] = 0.0;
            }
        }
        self.ola_head = (self.ola_head + OLA_HOP * ch) % ring_len;
        self.tail_zero_frames += OLA_HOP;
    }
}

#[cfg(test)]
mod tests {
    use super::PitchRateProcessor;
    use crate::player::sound_effect::SoundEffectSettings;

    const SR: usize = 44100;

    fn sine(n: usize) -> Vec<f32> {
        (0..n)
            .map(|i| {
                (std::f32::consts::TAU * 440.0 * i as f32 / SR as f32).sin()
            })
            .collect()
    }

    fn run(settings: &SoundEffectSettings, input_frames: usize) -> Vec<f32> {
        let mut p = PitchRateProcessor::new(1, SR as u32);
        p.prepare(SR as f32, 1);
        p.update_params(settings);
        let mut iter = sine(input_frames).into_iter();
        let mut out = Vec::with_capacity(input_frames * 2);
        let mut frame = vec![0.0f32; 1];
        let mut guard = 0;
        let max_guard = (input_frames as u64) * 8 + 1_000_000;
        while guard < max_guard {
            guard += 1;
            if !p.fill(&mut iter, &mut frame) {
                break;
            }
            out.push(frame[0]);
        }
        out
    }

    #[test]
    fn neutral_is_passthrough() {
        // 原调原速：输出与输入完全一致（不含首帧瞬态不适用，直接逐样本一致）
        let s = SoundEffectSettings {
            playback_rate: 100.0,
            pitch_shift: 100.0,
            preserves_pitch: false,
            ..Default::default()
        };
        let input = sine(4096);
        let out = run(&s, 4096);
        // OLA 不参与，应为逐帧直通
        assert_eq!(out.len(), input.len());
        for (a, b) in out.iter().zip(input.iter()) {
            assert!((a - b).abs() < 1e-4, "passthrough mismatch {a} vs {b}");
        }
    }

    #[test]
    fn ola_speed_up_half_duration() {
        // playback_rate=200（2 倍速，保调）→ 输出时长约为输入一半
        let s = SoundEffectSettings {
            playback_rate: 200.0,
            pitch_shift: 100.0,
            preserves_pitch: true,
            ..Default::default()
        };
        let input_frames = SR; // 1 秒
        let out = run(&s, input_frames);
        let ratio = out.len() as f64 / input_frames as f64;
        assert!((0.40..0.70).contains(&ratio), "speed-up ratio={ratio}");
    }

    #[test]
    fn ola_slow_down_double_duration() {
        // playback_rate=50（0.5 倍速，保调）→ 输出时长约为输入 2 倍
        let s = SoundEffectSettings {
            playback_rate: 50.0,
            pitch_shift: 100.0,
            preserves_pitch: true,
            ..Default::default()
        };
        let input_frames = SR; // 1 秒
        let out = run(&s, input_frames);
        let ratio = out.len() as f64 / input_frames as f64;
        assert!((1.55..2.30).contains(&ratio), "slow-down ratio={ratio}");
    }
}