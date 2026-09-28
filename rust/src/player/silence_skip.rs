//! 跳过静音：把过长的静音段压到「保留时长」，多出来的样本丢掉。
//!
//! 语义（对齐 ExoPlayer `skipSilence` 的思路，但不引入 look-ahead 延迟）：
//! - 按**帧峰值**低于阈值连续判定静音段；
//! - 静音段不超过 `keep_ms` 时原样透传（短停顿、乐句间隙不受影响）；
//! - 超出部分边解码边丢；保留段末尾做淡出、声音恢复处做淡入，避免切点爆音；
//! - 丢弃的**交错样本数**累加到共享计数器，位置上报把它加回去，所以对 UI 而言
//!   仍是原曲时间轴：进度条照常走、曲终判定不受影响。
//!
//! 因为不做 look-ahead，静音段的前 `keep_ms` 会照常输出、之后才开始丢，
//! 音频不会整体延后，MV 音画同步不受影响。

use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;

use super::buffered_source::BlockProducer;

/// 淡入/淡出时长（毫秒）。
const FADE_MS: u32 = 20;

/// dBFS → 线性幅度。
pub fn db_to_linear(db: f32) -> f32 {
    10f32.powf(db / 20.0)
}

/// 运行期可改的跳过静音参数（设置里切开关/阈值时经命令通道更新，不用重启管线）。
pub struct SkipSilenceState {
    enabled: AtomicBool,
    /// 静音阈值：线性幅度（按 f32 位模式存放）。
    threshold: AtomicU32,
    /// 静音段保留时长（毫秒），超出的部分剪掉。
    keep_ms: AtomicU32,
    /// 累计丢弃的交错样本数（与 `ExclusiveProgress` 共享同一计数器）。
    skipped_samples: Arc<AtomicU64>,
}

/// 阈值/保留时长的兜底：非法值走默认（-45dB / 500ms），并限制保留时长上限。
pub fn normalize_skip_params(threshold_db: f32, keep_ms: u32) -> (f32, u32) {
    let thr = if threshold_db < 0.0 && threshold_db > -120.0 {
        threshold_db
    } else {
        -45.0
    };
    let keep = if keep_ms > 0 { keep_ms.min(10_000) } else { 500 };
    (thr, keep)
}

impl SkipSilenceState {
    pub fn new(
        enabled: bool,
        threshold_db: f32,
        keep_ms: u32,
        skipped_samples: Arc<AtomicU64>,
    ) -> Self {
        let (thr, keep) = normalize_skip_params(threshold_db, keep_ms);
        Self {
            enabled: AtomicBool::new(enabled),
            threshold: AtomicU32::new(db_to_linear(thr).to_bits()),
            keep_ms: AtomicU32::new(keep),
            skipped_samples,
        }
    }

    /// 运行期更新参数。
    pub fn apply(&self, enabled: bool, threshold_db: f32, keep_ms: u32) {
        let (thr, keep) = normalize_skip_params(threshold_db, keep_ms);
        self.enabled.store(enabled, Ordering::Relaxed);
        self.threshold
            .store(db_to_linear(thr).to_bits(), Ordering::Relaxed);
        self.keep_ms.store(keep, Ordering::Relaxed);
    }

    #[inline]
    fn is_enabled(&self) -> bool {
        self.enabled.load(Ordering::Relaxed)
    }

    #[inline]
    fn threshold(&self) -> f32 {
        f32::from_bits(self.threshold.load(Ordering::Relaxed))
    }

    #[inline]
    fn keep_frames(&self, sample_rate: u32) -> usize {
        let ms = self.keep_ms.load(Ordering::Relaxed) as u64;
        ((ms * sample_rate as u64) / 1000).max(1) as usize
    }
}

/// 静音跳过包装层：套在解码器外面，输出已是压缩过的样本流。
pub struct SilenceSkipProducer<P> {
    inner: P,
    channels: usize,
    sample_rate: u32,
    state: Arc<SkipSilenceState>,
    /// 当前静音段已保留输出的帧数。
    kept_frames: usize,
    /// 是否正在丢弃静音。
    dropping: bool,
    /// 恢复后剩余的淡入帧数。
    fade_in_left: usize,
    /// 上一轮截断后剩下的样本（保证每次输出不超过调用方要求）。
    carry: VecDeque<f32>,
}

impl<P> SilenceSkipProducer<P>
where
    P: BlockProducer,
{
    pub fn new(
        inner: P,
        channels: u16,
        sample_rate: u32,
        state: Arc<SkipSilenceState>,
    ) -> Self {
        Self {
            inner,
            channels: channels.max(1) as usize,
            sample_rate,
            state,
            kept_frames: 0,
            dropping: false,
            fade_in_left: 0,
            carry: VecDeque::new(),
        }
    }

    fn reset_segment_state(&mut self) {
        self.kept_frames = 0;
        self.dropping = false;
        self.fade_in_left = 0;
    }

    /// 处理一块输入：按帧判定静音，把该保留的推进 `out`，该丢的计入计数器。
    fn process(&mut self, input: &[f32], out: &mut Vec<f32>) {
        let ch = self.channels;
        if !self.state.is_enabled() {
            // 关掉时透传并清掉段状态，避免下次打开接着旧段继续算
            self.reset_segment_state();
            out.extend_from_slice(input);
            return;
        }
        let threshold = self.state.threshold();
        let keep = self.state.keep_frames(self.sample_rate);
        let fade = (((FADE_MS as u64 * self.sample_rate as u64) / 1000).max(1)) as usize;
        let mut skipped: u64 = 0;
        let frames = input.len() / ch;
        for f in 0..frames {
            let frame = &input[f * ch..(f + 1) * ch];
            let peak = frame.iter().fold(0.0f32, |m, s| m.max(s.abs()));
            if peak < threshold {
                if self.kept_frames < keep {
                    // 保留段：末尾 fade 帧做淡出，提前压掉切点的爆音
                    self.kept_frames += 1;
                    let gain = if self.kept_frames + fade > keep {
                        ((keep - self.kept_frames) as f32 / fade as f32).clamp(0.0, 1.0)
                    } else {
                        1.0
                    };
                    for s in frame {
                        out.push(s * gain);
                    }
                } else {
                    self.dropping = true;
                    skipped += ch as u64;
                }
            } else {
                self.kept_frames = 0;
                if self.dropping {
                    self.dropping = false;
                    self.fade_in_left = fade;
                }
                let gain = if self.fade_in_left > 0 {
                    let g = (fade - self.fade_in_left) as f32 / fade as f32;
                    self.fade_in_left -= 1;
                    g
                } else {
                    1.0
                };
                for s in frame {
                    out.push(s * gain);
                }
            }
        }
        if skipped > 0 {
            self.state
                .skipped_samples
                .fetch_add(skipped, Ordering::Relaxed);
        }
    }
}

impl<P> BlockProducer for SilenceSkipProducer<P>
where
    P: BlockProducer,
{
    fn produce(&mut self, max_samples: usize) -> Option<Vec<f32>> {
        let ch = self.channels.max(1);
        // 按整帧对齐，避免把一帧切成两半
        let want = ((max_samples / ch).max(1)) * ch;
        let mut out: Vec<f32> = self.carry.drain(..).collect();
        loop {
            if out.len() >= want {
                break;
            }
            let block = match self.inner.produce(want) {
                Some(b) => b,
                None => break,
            };
            if block.is_empty() {
                continue;
            }
            self.process(&block, &mut out);
            // out 仍为空 = 整块都是被丢掉的静音，继续取下一块，
            // 不能返回空块（上层会把空块跳过并立刻再取，变成空转）
        }
        if out.len() > want {
            self.carry.extend(out.drain(want..));
        }
        if out.is_empty() {
            None
        } else {
            Some(out)
        }
    }

    fn try_seek(&mut self, pos: Duration) -> Result<(), String> {
        // 跳转后按新位置重新开始判定
        self.reset_segment_state();
        self.carry.clear();
        self.inner.try_seek(pos)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 可编排的假 producer：按段描述生成样本。
    struct FakeProducer {
        samples: Vec<f32>,
        idx: usize,
        block: usize,
    }

    impl FakeProducer {
        fn new(samples: Vec<f32>, block: usize) -> Self {
            Self {
                samples,
                idx: 0,
                block,
            }
        }
    }

    impl BlockProducer for FakeProducer {
        fn produce(&mut self, _max: usize) -> Option<Vec<f32>> {
            if self.idx >= self.samples.len() {
                return None;
            }
            let end = (self.idx + self.block).min(self.samples.len());
            let out = self.samples[self.idx..end].to_vec();
            self.idx = end;
            Some(out)
        }
        fn try_seek(&mut self, _pos: Duration) -> Result<(), String> {
            Ok(())
        }
    }

    const RATE: u32 = 1000; // 用 1kHz 采样率简化计算：1 帧 = 1ms
    const CH: usize = 2;

    /// 拼一段：静音 ms 毫秒 + 正弦 tone_ms 毫秒
    fn push_seg(buf: &mut Vec<f32>, silent: bool, ms: usize, amp: f32) {
        for i in 0..ms {
            let v = if silent {
                0.0
            } else {
                let t = i as f32 / RATE as f32;
                (t * 440.0 * std::f32::consts::TAU).sin() * amp
            };
            for _ in 0..CH {
                buf.push(v);
            }
        }
    }

    fn drain<P: BlockProducer>(p: &mut P) -> Vec<f32> {
        let mut out = Vec::new();
        while let Some(b) = p.produce(64) {
            out.extend_from_slice(&b);
        }
        out
    }

    fn frames(samples: &[f32]) -> usize {
        samples.len() / CH
    }

    #[test]
    fn keeps_short_silence_untouched() {
        // 100ms 静音 + 200ms 声音，保留时长 500ms → 全部保留
        let mut src = Vec::new();
        push_seg(&mut src, true, 100, 0.0);
        push_seg(&mut src, false, 200, 0.5);
        let total = frames(&src);
        let counter = Arc::new(AtomicU64::new(0));
        let state = Arc::new(SkipSilenceState::new(true, -45.0, 500, counter.clone()));
        let mut p = SilenceSkipProducer::new(FakeProducer::new(src, 128), CH as u16, RATE, state);
        let out = drain(&mut p);
        assert_eq!(frames(&out), total, "短静音不应被剪");
        assert_eq!(counter.load(Ordering::Relaxed), 0);
    }

    #[test]
    fn long_silence_is_trimmed_to_keep() {
        // 3000ms 静音 + 500ms 声音，保留 500ms → 只留 500ms 静音
        let mut src = Vec::new();
        push_seg(&mut src, true, 3000, 0.0);
        push_seg(&mut src, false, 500, 0.5);
        let counter = Arc::new(AtomicU64::new(0));
        let state = Arc::new(SkipSilenceState::new(true, -45.0, 500, counter.clone()));
        let mut p = SilenceSkipProducer::new(FakeProducer::new(src, 100), CH as u16, RATE, state);
        let out = drain(&mut p);
        let kept = frames(&out);
        // 正弦首帧落在零点会被当成静音丢掉，所以留 ±2 帧容差
        assert!(
            (998..=1002).contains(&kept),
            "应保留约 500ms 静音 + 500ms 声音，实得 {kept} 帧"
        );
        let skipped_ms = counter.load(Ordering::Relaxed) as usize / CH;
        assert!(
            (2498..=2502).contains(&skipped_ms),
            "应丢掉约 2500ms 静音，实得 {skipped_ms}ms"
        );
    }

    #[test]
    fn fades_at_boundaries_no_click() {
        // 静音 → 声音 的恢复点必须从 ~0 起，避免爆音
        let mut src = Vec::new();
        push_seg(&mut src, true, 2000, 0.0);
        push_seg(&mut src, false, 300, 0.8);
        let counter = Arc::new(AtomicU64::new(0));
        let state = Arc::new(SkipSilenceState::new(true, -45.0, 500, counter.clone()));
        let mut p = SilenceSkipProducer::new(FakeProducer::new(src, 64), CH as u16, RATE, state);
        let out = drain(&mut p);
        // 找到第一个非静音样本
        let first_loud = out
            .iter()
            .enumerate()
            .find(|(_, s)| s.abs() > 0.01)
            .map(|(i, _)| i)
            .expect("应有声音样本");
        assert!(
            out[first_loud].abs() < 0.05,
            "恢复处应从 ~0 淡入，实得 {}",
            out[first_loud]
        );
    }

    #[test]
    fn disabled_is_passthrough() {
        let mut src = Vec::new();
        push_seg(&mut src, true, 2000, 0.0);
        push_seg(&mut src, false, 200, 0.5);
        let total = frames(&src);
        let counter = Arc::new(AtomicU64::new(0));
        let state = Arc::new(SkipSilenceState::new(false, -45.0, 500, counter.clone()));
        let mut p = SilenceSkipProducer::new(FakeProducer::new(src, 100), CH as u16, RATE, state);
        let out = drain(&mut p);
        assert_eq!(frames(&out), total);
        assert_eq!(counter.load(Ordering::Relaxed), 0);
    }

    #[test]
    fn output_never_exceeds_requested() {
        let mut src = Vec::new();
        push_seg(&mut src, true, 300, 0.0);
        push_seg(&mut src, false, 2000, 0.5);
        let counter = Arc::new(AtomicU64::new(0));
        let state = Arc::new(SkipSilenceState::new(true, -45.0, 100, counter));
        let mut p = SilenceSkipProducer::new(FakeProducer::new(src, 1000), CH as u16, RATE, state);
        let mut n = 0;
        while let Some(b) = p.produce(64) {
            assert!(b.len() <= 64, "块长度必须不超过请求值，实得 {}", b.len());
            n += b.len();
        }
        assert!(n > 0);
    }
}
