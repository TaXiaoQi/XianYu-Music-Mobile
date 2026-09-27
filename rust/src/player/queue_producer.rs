//! 无缝拼接：把「下一首」提前解码好，当前曲到 EOF 时直接接上，不打断输出。
//!
//! 与 AAudio 会话配合：整条 DSP 链与输出流保持存活，只有采样来源切换，
//! 所以听感连续（不插静音、不重启流）。采样率/声道与当前流不一致时无法拼接，
//! 由准备阶段用 [`can_splice`] 提前拒掉，退回普通切歌。
//!
//! 「下一首」经 [`NextSlot`] 交接：准备线程写入，预读线程里的本生产者取用，
//! 这样交接不需要动 `BufferedSource` 的命令通道。

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use super::buffered_source::BlockProducer;

/// 已准备好的下一首：生产者 + 它的格式信息。
pub struct PreparedSource {
    pub producer: Box<dyn BlockProducer + Send>,
    pub sample_rate: u32,
    pub channels: u16,
    pub duration: Option<Duration>,
}

/// 交接槽：准备线程写入 `Some`，取消时写 `None`，生产者到 EOF 时取走。
pub type NextSlot = Arc<Mutex<Option<PreparedSource>>>;

pub fn new_next_slot() -> NextSlot {
    Arc::new(Mutex::new(None))
}

/// 拼接是否与当前流兼容：采样率与声道必须一致，否则只能普通切歌。
pub fn can_splice(current_rate: u32, current_channels: u16, next: &PreparedSource) -> bool {
    next.sample_rate == current_rate && next.channels == current_channels
}

/// 过渡状态：无缝拼接发生时通知上层（Dart 轮询到 `seq` 变化即知已切到下一首）。
pub struct TransitionState {
    /// 拼接次数。
    pub seq: AtomicU64,
    /// 拼接后新曲时长（毫秒），供进度条更新。
    pub duration_ms: AtomicU64,
}

impl TransitionState {
    pub fn new() -> Self {
        Self {
            seq: AtomicU64::new(0),
            duration_ms: AtomicU64::new(0),
        }
    }
}

impl Default for TransitionState {
    fn default() -> Self {
        Self::new()
    }
}

/// 队列生产者：持有当前源 + 交接槽，EOF 时把槽里的下一首接上。
pub struct QueueProducer {
    cur: Box<dyn BlockProducer + Send>,
    slot: NextSlot,
    transition: Arc<TransitionState>,
    /// 当前源的格式（供准备阶段判断能否拼接）。
    sample_rate: u32,
    channels: u16,
    /// 当前源的时长（供上层查询；交叉淡入淡出靠它算尾段起点）。
    duration: Option<Duration>,
    /// 当前源已产出的帧数（判断是否进入尾段）。
    frames_emitted: u64,
    /// 交叉淡入淡出时长（毫秒，运行期可改）；0 = 只做无缝拼接（默认）。
    /// 用共享原子量是因为生产者活在预读线程里，音频线程只能通过句柄改它。
    crossfade_ms: Arc<AtomicU64>,
    /// 交叉进行中时持有的下一首（已从槽里取出，混完提升为当前源）。
    mixing: Option<PreparedSource>,
    /// 本次交叉的总帧数与已完成帧数。
    crossfade_total: u64,
    crossfade_done: u64,
    /// 混音时 A 一侧多出来的样本（两个源块长不等时留到下一轮，不能丢）。
    mix_carry: Vec<f32>,
}

impl QueueProducer {
    pub fn new(
        cur: Box<dyn BlockProducer + Send>,
        sample_rate: u32,
        channels: u16,
        duration: Option<Duration>,
        slot: NextSlot,
        transition: Arc<TransitionState>,
    ) -> Self {
        Self {
            cur,
            slot,
            transition,
            sample_rate,
            channels,
            duration,
            frames_emitted: 0,
            crossfade_ms: Arc::new(AtomicU64::new(0)),
            mixing: None,
            crossfade_total: 0,
            crossfade_done: 0,
            mix_carry: Vec::new(),
        }
    }

    /// 设置交叉淡入淡出时长（0 = 关闭，只做无缝拼接）。
    pub fn set_crossfade(&mut self, crossfade: Duration) {
        self.crossfade_ms
            .store(crossfade.as_millis() as u64, Ordering::Relaxed);
    }

    /// 交叉时长的共享句柄：音频线程收到运行期命令时直接写入，不用重启管线。
    pub fn crossfade_handle(&self) -> Arc<AtomicU64> {
        self.crossfade_ms.clone()
    }

    /// 交叉窗帧数（需要采样率与总时长已知）。
    fn tail_frames(&self) -> Option<u64> {
        let ms = self.crossfade_ms.load(Ordering::Relaxed);
        if ms == 0 {
            return None;
        }
        let total = self.duration?;
        let total_frames = (total.as_millis() as u64 * self.sample_rate as u64) / 1000;
        let tail = ((ms * self.sample_rate as u64) / 1000).max(1);
        if total_frames <= tail {
            // 太短的曲子不交叉（整体淡入淡出会很怪）
            return None;
        }
        if self.frames_emitted + tail < total_frames {
            return None;
        }
        Some(tail)
    }

    /// 进入尾段且槽里有下一首时，取出下一首开始交叉。
    fn start_crossfade_if_due(&mut self) {
        if self.mixing.is_some() {
            return;
        }
        let Some(tail) = self.tail_frames() else { return };
        let prepared = match self.slot.lock() {
            Ok(mut g) => g.take(),
            Err(_) => None,
        };
        let Some(p) = prepared else { return };
        self.mixing = Some(p);
        self.crossfade_total = tail;
        self.crossfade_done = 0;
    }

    /// 交叉一步：A 尾段 × B 首段按等功率曲线混音；交叉完成时把 B 提升为当前源。
    ///
    /// 返回 None 表示本次不产出（A 先到 EOF：把 B 放回槽里交给拼接路径处理）。
    fn mix_step(&mut self, max_samples: usize) -> Option<Vec<f32>> {
        let ch = self.channels.max(1) as usize;
        let want = ((max_samples / ch).max(1)) * ch;
        // A：优先用掉上一轮多出来的样本（两源块长不等时不能丢）
        let a = if self.mix_carry.is_empty() {
            match self.cur.produce(want) {
                Some(a) if !a.is_empty() => a,
                _ => {
                    // A 比交叉窗更早结束：把下一首放回槽里，让拼接路径正常接上
                    if let (Some(p), Ok(mut g)) = (self.mixing.take(), self.slot.lock()) {
                        *g = Some(p);
                    }
                    return None;
                }
            }
        } else {
            std::mem::take(&mut self.mix_carry)
        };
        // B 按 A 的样本数取（生产者契约不会超发），取少了就以短的为准
        let b = match self
            .mixing
            .as_mut()
            .and_then(|m| m.producer.produce(a.len()))
        {
            Some(b) if !b.is_empty() => b,
            // 下一首意外提前结束：放弃交叉，直接交出 A
            _ => {
                self.mixing = None;
                self.frames_emitted += (a.len() / ch) as u64;
                return Some(a);
            }
        };
        let n = (a.len() / ch).min(b.len() / ch);
        // A 多出来的尾巴留到下一轮，丢掉就是丢样本
        if a.len() > n * ch {
            self.mix_carry = a[n * ch..].to_vec();
        }
        let tail = self.crossfade_total.max(1) as f32;
        let mut out = Vec::with_capacity(n * ch);
        for f in 0..n {
            let t = ((self.crossfade_done + f as u64) as f32 / tail).clamp(0.0, 1.0);
            // 等功率律：cos²+sin²=1，两段音乐不成比例地互相淹没
            let ga = (t * std::f32::consts::FRAC_PI_2).cos();
            let gb = (t * std::f32::consts::FRAC_PI_2).sin();
            for c in 0..ch {
                out.push(a[f * ch + c] * ga + b[f * ch + c] * gb);
            }
        }
        self.frames_emitted += n as u64;
        self.crossfade_done += n as u64;
        if self.crossfade_done >= self.crossfade_total {
            // 交叉结束：B 提升为当前源并报一次过渡（Dart 靠它推进队列）
            if let Some(mixing) = self.mixing.take() {
                self.sample_rate = mixing.sample_rate;
                self.channels = mixing.channels;
                self.duration = mixing.duration;
                self.cur = mixing.producer;
                self.frames_emitted = 0;
                if let Some(d) = self.duration {
                    self.transition
                        .duration_ms
                        .store(d.as_millis() as u64, Ordering::Relaxed);
                }
                self.transition.seq.fetch_add(1, Ordering::Relaxed);
            }
            self.crossfade_total = 0;
            self.crossfade_done = 0;
            self.mix_carry.clear();
        }
        Some(out)
    }

    pub fn sample_rate(&self) -> u32 {
        self.sample_rate
    }

    pub fn channels(&self) -> u16 {
        self.channels
    }

    /// 槽里是否已有下一首（准备阶段用它避免重复准备）。
    pub fn has_pending(&self) -> bool {
        self.slot.lock().map(|g| g.is_some()).unwrap_or(false)
    }

    /// 交接槽的共享句柄（准备线程写入用）。
    pub fn slot(&self) -> NextSlot {
        self.slot.clone()
    }

    /// 接上下一首，返回是否成功拼接。
    fn splice(&mut self) -> bool {
        let prepared = match self.slot.lock() {
            Ok(mut g) => g.take(),
            Err(_) => None,
        };
        match prepared {
            Some(p) => {
                self.sample_rate = p.sample_rate;
                self.channels = p.channels;
                self.duration = p.duration;
                self.cur = p.producer;
                // 帧计数必须跟着归零到新曲起点：否则「尾段判定」以为还在曲尾，
                // 一旦槽里又排了下一首，会立刻把它交叉混进来（新曲刚开头就被换掉）。
                self.frames_emitted = 0;
                self.mix_carry.clear();
                if let Some(d) = p.duration {
                    self.transition
                        .duration_ms
                        .store(d.as_millis() as u64, Ordering::Relaxed);
                }
                // 先写时长再 +1，读侧看到 seq 变化时时长已就位
                self.transition.seq.fetch_add(1, Ordering::Relaxed);
                true
            }
            None => false,
        }
    }
}

impl BlockProducer for QueueProducer {
    fn produce(&mut self, max_samples: usize) -> Option<Vec<f32>> {
        let ch = self.channels.max(1) as usize;
        loop {
            // 交叉淡入淡出进行中：先出混音块
            if self.mixing.is_some() {
                if let Some(block) = self.mix_step(max_samples) {
                    return Some(block);
                }
            }
            match self.cur.produce(max_samples) {
                // 内层可能返回空块（包装层丢静音时），继续取
                Some(b) if b.is_empty() => continue,
                Some(b) => {
                    self.frames_emitted += (b.len() / ch) as u64;
                    // 进入尾段就把下一首取出来，下一次调用开始混音
                    self.start_crossfade_if_due();
                    return Some(b);
                }
                None => {
                    // 当前曲到头：槽里有下一首就直接接上，同一调用内继续产出，
                    // 调用方看不到接缝（既不插静音也不停流）。
                    if !self.splice() {
                        return None;
                    }
                }
            }
        }
    }

    fn try_seek(&mut self, pos: Duration) -> Result<(), String> {
        // 交叉途中 seek：用户跳走了，进行中的交叉没有意义——中止它，并把已经
        // 取出的下一首退回槽里（等新位置播完照常拼接）。
        if let Some(p) = self.mixing.take() {
            if let Ok(mut g) = self.slot.lock() {
                if g.is_none() {
                    *g = Some(p);
                }
            }
            self.crossfade_total = 0;
            self.crossfade_done = 0;
            self.mix_carry.clear();
        }
        // 帧计数跟着跳到新位置：否则向后 seek 后尾段判定仍以为「快播完了」，
        // 会立刻又进入交叉。
        self.frames_emitted = (pos.as_millis() as u64 * self.sample_rate as u64) / 1000;
        self.cur.try_seek(pos)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 固定长度假源：产生 `frames` 帧的常量值，便于按值定位拼接点。
    struct ConstProducer {
        frames_left: usize,
        channels: usize,
        value: f32,
    }

    impl ConstProducer {
        fn new(frames: usize, channels: usize, value: f32) -> Self {
            Self {
                frames_left: frames,
                channels,
                value,
            }
        }
    }

    impl BlockProducer for ConstProducer {
        fn produce(&mut self, max_samples: usize) -> Option<Vec<f32>> {
            if self.frames_left == 0 {
                return None;
            }
            let want_frames = (max_samples / self.channels).max(1);
            let take = want_frames.min(self.frames_left);
            self.frames_left -= take;
            Some(vec![self.value; take * self.channels])
        }
        fn try_seek(&mut self, _pos: Duration) -> Result<(), String> {
            Ok(())
        }
    }

    fn prepared(value: f32, frames: usize, ch: usize, rate: u32, ms: u64) -> PreparedSource {
        PreparedSource {
            producer: Box::new(ConstProducer::new(frames, ch, value)),
            sample_rate: rate,
            channels: ch as u16,
            duration: Some(Duration::from_millis(ms)),
        }
    }

    fn drain_all(p: &mut QueueProducer) -> Vec<f32> {
        let mut out = Vec::new();
        while let Some(b) = p.produce(16) {
            out.extend_from_slice(&b);
        }
        out
    }

    #[test]
    fn splices_next_without_gap() {
        let slot = new_next_slot();
        *slot.lock().unwrap() = Some(prepared(2.0, 40, 2, 44100, 1234));
        let transition = Arc::new(TransitionState::new());
        let mut p = QueueProducer::new(
            Box::new(ConstProducer::new(60, 2, 1.0)),
            44100,
            2,
            Some(Duration::from_millis(100)),
            slot,
            transition.clone(),
        );
        let out = drain_all(&mut p);
        // 60 帧 + 40 帧，中间无静音插入
        assert_eq!(out.len(), 200, "拼接后样本数应为两段之和");
        assert!(out[..120].iter().all(|s| *s == 1.0), "前半段应来自当前曲");
        assert!(out[120..].iter().all(|s| *s == 2.0), "后半段应来自下一首");
        assert_eq!(transition.seq.load(Ordering::Relaxed), 1);
        assert_eq!(transition.duration_ms.load(Ordering::Relaxed), 1234);
    }

    #[test]
    fn ends_cleanly_without_next() {
        let slot = new_next_slot();
        let transition = Arc::new(TransitionState::new());
        let mut p = QueueProducer::new(
            Box::new(ConstProducer::new(30, 2, 1.0)),
            44100,
            2,
            None,
            slot,
            transition.clone(),
        );
        let out = drain_all(&mut p);
        assert_eq!(out.len(), 60);
        assert_eq!(transition.seq.load(Ordering::Relaxed), 0, "没有下一首不应报过渡");
    }

    #[test]
    fn cancelled_next_is_ignored() {
        let slot = new_next_slot();
        let transition = Arc::new(TransitionState::new());
        let mut p = QueueProducer::new(
            Box::new(ConstProducer::new(20, 2, 1.0)),
            44100,
            2,
            None,
            slot.clone(),
            transition.clone(),
        );
        *slot.lock().unwrap() = Some(prepared(9.0, 20, 2, 44100, 100));
        *slot.lock().unwrap() = None; // 取消
        let out = drain_all(&mut p);
        assert_eq!(out.len(), 40, "取消后不应拼接");
        assert_eq!(transition.seq.load(Ordering::Relaxed), 0);
    }

    #[test]
    fn format_mismatch_is_rejected_upfront() {
        let next = prepared(1.0, 10, 2, 48000, 100);
        assert!(can_splice(44100, 2, &next) == false, "采样率不同不能拼接");
        let next2 = prepared(1.0, 10, 1, 44100, 100);
        assert!(can_splice(44100, 2, &next2) == false, "声道不同不能拼接");
        let next3 = prepared(1.0, 10, 2, 44100, 100);
        assert!(can_splice(44100, 2, &next3), "同格式应可拼接");
    }

    #[test]
    fn seek_after_splice_targets_new_source() {
        struct SeekRecorder {
            last: Arc<Mutex<Option<u64>>>,
        }
        impl BlockProducer for SeekRecorder {
            fn produce(&mut self, _max: usize) -> Option<Vec<f32>> {
                None
            }
            fn try_seek(&mut self, pos: Duration) -> Result<(), String> {
                *self.last.lock().unwrap() = Some(pos.as_millis() as u64);
                Ok(())
            }
        }

        let last = Arc::new(Mutex::new(None));
        let slot = new_next_slot();
        *slot.lock().unwrap() = Some(PreparedSource {
            producer: Box::new(SeekRecorder { last: last.clone() }),
            sample_rate: 44100,
            channels: 2,
            duration: None,
        });
        let transition = Arc::new(TransitionState::new());
        let mut p = QueueProducer::new(
            Box::new(ConstProducer::new(0, 2, 1.0)),
            44100,
            2,
            None,
            slot,
            transition,
        );
        assert!(p.produce(16).is_none(), "当前曲立即 EOF，应拼上下一首");
        // 拼接后 seek 应落到新源
        p.try_seek(Duration::from_millis(500)).unwrap();
        assert_eq!(*last.lock().unwrap(), Some(500));
    }

    #[test]
    fn crossfade_follows_equal_power_curve() {
        // A=1.0（1 秒）与 B=0.0（1 秒）交叉 200ms：尾段应按 cos 曲线从 1 降到 0，
        // 中点 ≈ cos45° = 0.707；B 的首段被混音吃掉，所以总长比两段之和少 200。
        let slot = new_next_slot();
        *slot.lock().unwrap() = Some(PreparedSource {
            producer: Box::new(ConstProducer::new(1000, 2, 0.0)),
            sample_rate: 1000,
            channels: 2,
            duration: Some(Duration::from_millis(1000)),
        });
        let transition = Arc::new(TransitionState::new());
        let mut p = QueueProducer::new(
            Box::new(ConstProducer::new(1000, 2, 1.0)),
            1000,
            2,
            Some(Duration::from_millis(1000)),
            slot,
            transition.clone(),
        );
        p.set_crossfade(Duration::from_millis(200));
        let out = drain_all(&mut p);
        let frames = out.len() / 2;
        assert_eq!(frames, 1800, "交叉段重合 200 帧，总长应为 1800");
        assert_eq!(transition.seq.load(Ordering::Relaxed), 1);
        let at = |f: usize| out[f * 2];
        assert!(at(799).abs() > 0.9, "交叉开始前应还是 A：{}", at(799));
        let mid = at(900).abs();
        assert!((0.6..=0.8).contains(&mid), "中点应约 0.707，实得 {mid}");
        assert!(
            at(frames - 1).abs() < 0.05,
            "交叉末尾应≈0（B 的权重吃满）：{}",
            at(frames - 1)
        );
    }

    #[test]
    fn crossfade_without_next_falls_back_to_plain_end() {
        // 没预排下一首：不进入交叉，A 播完干净结束，不报过渡
        let slot = new_next_slot();
        let transition = Arc::new(TransitionState::new());
        let mut p = QueueProducer::new(
            Box::new(ConstProducer::new(500, 2, 1.0)),
            1000,
            2,
            Some(Duration::from_millis(500)),
            slot,
            transition.clone(),
        );
        p.set_crossfade(Duration::from_millis(200));
        let out = drain_all(&mut p);
        assert_eq!(out.len() / 2, 500);
        assert_eq!(transition.seq.load(Ordering::Relaxed), 0);
    }

    #[test]
    fn crossfade_handles_current_ending_inside_window() {
        // A 在交叉窗内提前结束（尾段判定有块粒度误差时会落到这条路径）：
        // 要求不丢样本、不重复计过渡，接缝处直接续上 B。
        let slot = new_next_slot();
        *slot.lock().unwrap() = Some(PreparedSource {
            producer: Box::new(ConstProducer::new(1000, 2, 2.0)),
            sample_rate: 1000,
            channels: 2,
            duration: Some(Duration::from_millis(1000)),
        });
        let transition = Arc::new(TransitionState::new());
        // A 实际只有 850 帧，但时长元数据仍是 1000ms → 交叉从第 800 帧开始，
        // A 在窗内（只剩 50 帧）就结束了
        let mut p = QueueProducer::new(
            Box::new(ConstProducer::new(850, 2, 1.0)),
            1000,
            2,
            Some(Duration::from_millis(1000)),
            slot,
            transition.clone(),
        );
        p.set_crossfade(Duration::from_millis(200));
        let out = drain_all(&mut p);
        let frames = out.len() / 2;
        // 800（窗内混音前）+ 50（交叉段）+ 950（B 余下）= 1800，样本一个不丢
        assert_eq!(frames, 1800, "实得 {frames} 帧");
        assert_eq!(
            transition.seq.load(Ordering::Relaxed),
            1,
            "应恰好一次过渡，不能因为窗内结束而重复计"
        );
        assert_eq!(out[(frames - 1) * 2], 2.0, "末尾应已切换到下一首");
    }

    #[test]
    fn splice_resets_frame_counter_so_next_crossfade_waits() {
        // 纯拼接（不是交叉提升）也要把帧计数重置到新曲起点。
        // 否则接上 B 之后，「尾段判定」仍以为在曲尾，一旦槽里又有 C，
        // 会立刻把 C 交叉混进来（B 才刚开头就被换掉）。
        let slot = new_next_slot();
        let b_frames = 1000usize;
        *slot.lock().unwrap() = Some(PreparedSource {
            producer: Box::new(ConstProducer::new(b_frames, 2, 2.0)),
            sample_rate: 1000,
            channels: 2,
            duration: Some(Duration::from_millis(1000)),
        });
        let transition = Arc::new(TransitionState::new());
        // A 只有 850 帧 → 交叉从 800 帧开始、A 在窗内结束 → 走纯拼接路径
        let mut p = QueueProducer::new(
            Box::new(ConstProducer::new(850, 2, 1.0)),
            1000,
            2,
            Some(Duration::from_millis(1000)),
            slot.clone(),
            transition.clone(),
        );
        p.set_crossfade(Duration::from_millis(200));
        // drain 到拼接完（A 850 帧 + 交叉段消耗的 B 帧之后，进入纯 B）
        let mut produced = 0usize;
        while produced < 900 {
            let b = p.produce(16).expect("应有样本");
            produced += b.len() / 2;
        }
        assert_eq!(
            transition.seq.load(Ordering::Relaxed),
            1,
            "应已拼接到 B"
        );
        // 现在槽里放 C，并继续产出：B 才播到开头，不该立刻把 C 混进来
        *slot.lock().unwrap() = Some(PreparedSource {
            producer: Box::new(ConstProducer::new(1000, 2, 3.0)),
            sample_rate: 1000,
            channels: 2,
            duration: Some(Duration::from_millis(1000)),
        });
        let mut window = Vec::new();
        while window.len() / 2 < 50 {
            let b = p.produce(64).expect("应有样本");
            window.extend_from_slice(&b);
        }
        assert!(
            window.iter().all(|s| *s == 2.0),
            "接上 B 后 50 帧内应全是 B，不该已经混进 C（实得 {:?}）",
            window.iter().find(|s| **s != 2.0)
        );
    }

    #[test]
    fn seek_aborts_pending_crossfade_and_returns_next() {
        // 交叉混音途中 seek：交叉必须中止（否则 seek 后的 A 会和 B 继续混），
        // 已取出的下一首要退回槽里；并且向后 seek 后不能因为"帧计数还停在旧位置"
        // 而立刻又进入交叉。
        let slot = new_next_slot();
        *slot.lock().unwrap() = Some(PreparedSource {
            producer: Box::new(ConstProducer::new(500, 2, 2.0)),
            sample_rate: 1000,
            channels: 2,
            duration: Some(Duration::from_millis(500)),
        });
        let transition = Arc::new(TransitionState::new());
        let mut p = QueueProducer::new(
            Box::new(ConstProducer::new(1000, 2, 1.0)),
            1000,
            2,
            Some(Duration::from_millis(1000)),
            slot.clone(),
            transition.clone(),
        );
        p.set_crossfade(Duration::from_millis(200));
        // 推进到交叉进行中（尾段起点是第 800 帧）
        let mut produced = 0usize;
        while produced < 850 {
            let b = p.produce(16).expect("应有样本");
            produced += b.len() / 2;
        }
        assert!(
            slot.lock().unwrap().is_none(),
            "交叉开始后下一首应已从槽里取出"
        );
        // 向后 seek 到 100ms
        p.try_seek(Duration::from_millis(100)).unwrap();
        assert!(
            slot.lock().unwrap().is_some(),
            "seek 中止交叉后，下一首应退回槽里等新位置播完"
        );
        // 之后 100 帧内必须是纯本曲：既没有残留混音，也没有因为帧计数过期
        // 而立刻重新进入交叉
        let mut window = Vec::new();
        while window.len() / 2 < 100 {
            let b = p.produce(64).expect("应有样本");
            window.extend_from_slice(&b);
        }
        assert!(
            window.iter().all(|s| *s == 1.0),
            "seek 后 100 帧内应全是本曲，实得含 {:?}",
            window.iter().find(|s| **s != 1.0)
        );
        assert_eq!(
            transition.seq.load(Ordering::Relaxed),
            0,
            "被中止的交叉不应报过渡"
        );
    }

    #[test]
    fn splice_works_with_skip_silence_inside() {
        // 组合风险：内层跳过静音丢样本时，外层拼接会不会把「被丢空的一段」
        // 误判成 EOF 而提前拼接 / 漏判？用真实的两层包装验一遍。
        use super::super::silence_skip::{SilenceSkipProducer, SkipSilenceState};
        use std::sync::atomic::AtomicU64 as A64;

        /// 按固定块吐出预置样本（0.0 = 静音，1.0/2.0 = 声音）
        struct VecProducer {
            data: Vec<f32>,
            idx: usize,
        }
        impl BlockProducer for VecProducer {
            fn produce(&mut self, max: usize) -> Option<Vec<f32>> {
                if self.idx >= self.data.len() {
                    return None;
                }
                let end = (self.idx + max).min(self.data.len());
                let out = self.data[self.idx..end].to_vec();
                self.idx = end;
                Some(out)
            }
            fn try_seek(&mut self, _p: Duration) -> Result<(), String> {
                Ok(())
            }
        }

        let seg = |v: f32, frames: usize| vec![v; frames * 2];
        let mut a = seg(0.0, 400); // 400 帧静音
        a.extend(seg(1.0, 400)); // 400 帧声音
        let b = seg(2.0, 400); // 下一首：400 帧声音

        let skipped = Arc::new(A64::new(0));
        let state = Arc::new(SkipSilenceState::new(true, -45.0, 100, skipped.clone()));
        let inner = SilenceSkipProducer::new(VecProducer { data: a, idx: 0 }, 2, 1000, state);

        let slot = new_next_slot();
        *slot.lock().unwrap() = Some(PreparedSource {
            producer: Box::new(VecProducer { data: b, idx: 0 }),
            sample_rate: 1000,
            channels: 2,
            duration: Some(Duration::from_millis(400)),
        });
        let transition = Arc::new(TransitionState::new());
        let mut p = QueueProducer::new(
            Box::new(inner),
            1000,
            2,
            Some(Duration::from_millis(800)),
            slot,
            transition.clone(),
        );
        let out = drain_all(&mut p);
        let frames = out.len() / 2;
        // 100 帧静音（保留时长）+ 400 帧声音 + 400 帧下一首
        assert_eq!(frames, 900, "实得 {frames} 帧");
        assert_eq!(transition.seq.load(Ordering::Relaxed), 1, "应恰好拼一次");
        // 丢弃量只来自静音段的前 300 帧（600 个交错样本），别把拼接点算进去
        assert_eq!(skipped.load(Ordering::Relaxed), 600);
        // 接缝连续：A 的最后一帧是 499，第 500 帧起紧接下一首，中间不插静音
        assert_eq!(out[499 * 2], 1.0, "拼接前应是第一首的尾音");
        assert_eq!(out[500 * 2], 2.0, "拼接点紧接下一首，不插静音");
    }
}
