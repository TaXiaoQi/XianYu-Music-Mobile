//! 变调/变速机架 —— 线性插值重采样（复现 YinDongMusic Rust 后端）。
//!
//! 设计：与 YinDongMusic `src-tauri/src/player/effects/pitch_shift.rs` 一致。
//! YinDongMusic 的 Rust 后端只做简单的线性插值重采样——同时改变音调和速度
//! （黑胶式变调），不做 OLA 时间拉伸。preservesPitch 由前端 WebAudio 处理。
//!
//! 原理：
//! - ratio = pitch_shift / 100（100% = 原调，200% = 升八度，50% = 降八度）
//! - ratio > 1 → 升调+加速（跳过样本，输出更少）
//! - ratio < 1 → 降调+减速（重复样本，输出更多）
//! - 播放速度由 sample_rate 调整（rodio 引擎特性）
//!
//! 流式处理：维护跨帧的浮点读取位置 `read_pos`，保证连续性。
//! 按帧（一个完整通道组）处理，保持立体声声道关系。

use super::SoundEffectSettings;
use std::collections::VecDeque;

/// 变调/变速处理器（线性插值重采样）
pub struct PitchRateProcessor {
    channels: usize,
    sample_rate: f32,

    /// 重采样比率（read_pos 每输出帧推进的输入帧数）
    /// ratio > 1 → 升调+加速，ratio < 1 → 降调+减速
    ratio: f64,
    /// 输入缓冲中的浮点读取位置（帧单位）
    read_pos: f64,
    /// 输入缓冲（交错样本 [L, R, L, R, ...]）
    input_buf: VecDeque<f32>,

    /// 是否激活重采样
    active: bool,
    /// 是否仅调整 sample_rate（纯变速变调，样本直通）
    sample_rate_mode: bool,
    /// sample_rate 倍率
    rate_multiplier: f32,

    /// inner 是否已 EOF
    eof: bool,
}

impl PitchRateProcessor {
    pub fn new(channels: u16, sample_rate: u32) -> Self {
        let ch = channels as usize;
        Self {
            channels: ch.max(1),
            sample_rate: sample_rate as f32,
            ratio: 1.0,
            read_pos: 0.0,
            input_buf: VecDeque::with_capacity(8192),
            active: false,
            sample_rate_mode: false,
            rate_multiplier: 1.0,
            eof: false,
        }
    }

    pub fn prepare(&mut self, sample_rate: f32, channels: usize) {
        self.sample_rate = sample_rate;
        self.channels = channels.max(1);
        self.input_buf.clear();
        self.read_pos = 0.0;
        self.eof = false;
    }

    pub fn reset(&mut self) {
        self.input_buf.clear();
        self.read_pos = 0.0;
        self.eof = false;
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

        // ================================================================
        // 复现 YinDongMusic Rust 后端行为：
        // - 变调 = 线性插值重采样（同时改变音调和速度）
        // - 变速 = sample_rate 调整（同时改变速度和音调）
        // - preservesPitch 由前端 WebAudio 处理，Rust 不处理
        //
        // 组合策略：
        // - 只有变调：重采样（ratio=pitch），速度也随之改变
        // - 只有变速：sample_rate 调整（rate_multiplier=rate），音调也随之改变
        // - 两者都有：重采样 + sample_rate 组合
        //   pitch_total = pitch * rate, speed_total = pitch * rate
        // - 都没有：直通
        // ================================================================

        if pitch_changed {
            // 变调：线性插值重采样
            self.ratio = pitch as f64;
            self.active = true;
            // 如果同时有变速，叠加 sample_rate 调整
            if rate_changed {
                self.sample_rate_mode = false;
                self.rate_multiplier = rate;
            } else {
                self.sample_rate_mode = false;
                self.rate_multiplier = 1.0;
            }
        } else if rate_changed {
            // 只有变速：sample_rate 调整（样本直通）
            self.active = false;
            self.sample_rate_mode = true;
            self.rate_multiplier = rate;
            self.ratio = 1.0;
        } else {
            // 直通
            self.active = false;
            self.sample_rate_mode = false;
            self.rate_multiplier = 1.0;
            self.ratio = 1.0;
        }
    }

    /// 有效采样率。
    /// - sample_rate_mode：inner_rate * rate_multiplier
    /// - active + rate_multiplier≠1：inner_rate * rate_multiplier
    /// - 其余：inner_rate
    pub fn effective_sample_rate(&self, inner_rate: u32) -> u32 {
        if self.sample_rate_mode || (self.active && (self.rate_multiplier - 1.0).abs() >= 0.001) {
            ((inner_rate as f32) * self.rate_multiplier)
                .round()
                .max(1.0) as u32
        } else {
            inner_rate
        }
    }

    /// 从 inner 读取并填充一帧（channels 个样本）到 out。
    /// 返回 false 表示 inner 已结束且缓冲已耗尽。
    pub fn fill<I: Iterator<Item = f32>>(&mut self, inner: &mut I, out: &mut [f32]) -> bool {
        let ch = self.channels;

        if !self.active && !self.sample_rate_mode {
            // 直通
            for i in 0..ch.min(out.len()) {
                if let Some(s) = inner.next() {
                    out[i] = s;
                } else {
                    return false;
                }
            }
            return true;
        }

        if self.sample_rate_mode {
            // 纯变速变调：样本直通，sample_rate 已调整
            for i in 0..ch.min(out.len()) {
                if let Some(s) = inner.next() {
                    out[i] = s;
                } else {
                    return false;
                }
            }
            return true;
        }

        // 重采样模式：线性插值
        if !self.eof {
            self.ensure_input(inner);
        }

        // 确保有足够输入进行插值（至少 2 帧）
        let need_frames = (self.read_pos as usize) + 2;
        if self.input_buf.len() < need_frames * ch {
            if self.eof {
                // EOF 且缓冲不足：输出残余并返回 false
                let idx = self.read_pos as usize;
                if idx * ch < self.input_buf.len() {
                    for c in 0..ch.min(out.len()) {
                        out[c] = self.input_buf.get(idx * ch + c).copied().unwrap_or(0.0);
                    }
                } else {
                    for i in 0..ch.min(out.len()) {
                        out[i] = 0.0;
                    }
                }
                return false;
            }
            // 缓冲不足但未 EOF：输出零（避免卡顿）
            for i in 0..ch.min(out.len()) {
                out[i] = 0.0;
            }
            return true;
        }

        // 线性插值生成一个输出帧
        let idx = self.read_pos.floor() as usize;
        let frac = (self.read_pos - idx as f64) as f32;
        for c in 0..ch.min(out.len()) {
            let s0 = self.input_buf[idx * ch + c];
            let s1 = self.input_buf[(idx + 1) * ch + c];
            out[c] = s0 + (s1 - s0) * frac;
        }

        // 推进读取位置
        self.read_pos += self.ratio;

        // 消费已过输入帧
        let consumed = self.read_pos.floor() as usize;
        if consumed > 0 {
            let to_remove = (consumed * ch).min(self.input_buf.len());
            for _ in 0..to_remove {
                self.input_buf.pop_front();
            }
            self.read_pos -= consumed as f64;
        }

        true
    }

    /// 从 inner 非阻塞增量读取样本补充输入缓冲。
    /// 按消耗率动态决定读取帧数，避免缓冲耗尽。
    fn ensure_input<I: Iterator<Item = f32>>(&mut self, inner: &mut I) {
        if self.eof {
            return;
        }

        // 消耗率：每输出 1 帧消耗的输入帧数
        let consumption = self.ratio.max(1.0);
        let max_per_call = (consumption.ceil() as usize).max(1).min(32);

        // 目标缓冲：至少 read_pos + 2 帧（插值需要 2 帧）
        let target = (self.read_pos as usize) + 4; // 留余量防抖

        for _ in 0..max_per_call {
            let need_more = self.input_buf.len() < target * self.channels;
            if !need_more {
                break;
            }
            // 读取一帧交错样本
            let mut frame_eof = false;
            for ci in 0..self.channels {
                match inner.next() {
                    Some(s) => {
                        self.input_buf.push_back(s);
                    }
                    None => {
                        frame_eof = true;
                        self.input_buf.push_back(0.0);
                    }
                }
                // ci unused warning suppression
                let _ = ci;
            }
            if frame_eof {
                self.eof = true;
                // 尾部补零让重采样自然衰减
                for _ in 0..self.channels * 2 {
                    self.input_buf.push_back(0.0);
                }
                break;
            }
        }
    }
}