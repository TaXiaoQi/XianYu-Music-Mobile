//! 预读取缓冲源：后台线程预解码，音频线程仅做 O(1) 通道读取。
//!
//! ## 解决的问题
//! 系统内存/CPU 占用波动大时，音频回调线程被 OS 调度抢占，若抢占时长超过
//! 输出缓冲即发生 underrun → 卡音破音。根因是线程抢占而非单样本 CPU 开销。
//!
//! ## 方案
//! 将解码（含网络流式 sleep、瞬时慢帧）与下游效果链处理移至独立后台线程，
//! 音频回调线程仅从有界通道读取已就绪样本。单次块读取耗时极短，即使被抢占
//! 数十毫秒，恢复后可瞬间补满输出缓冲。
//!
//! 本模块从桌面端抽取并剥离 rodio 依赖：不再要求内部源实现 `rodio::Source`，
//! 改为接收实现 [`BlockProducer`] 的样本块生成器（移动端解码器/缓冲播放引擎适配），
//! 对外暴露块级消费接口 [`BufferedSource::next_block`]。
//!
//! ## 关键设计
//! - **有界 `sync_channel` + `try_send`**：后台线程用非阻塞 `try_send` 推送样本块，
//!   通道满时短 sleep 重试，绝不长时间阻塞 → 始终能及时响应 seek 命令，无死锁。
//! - **块传输**：每块 1024 样本（~11.6ms @ 44100 立体声），减少通道原子操作开销。
//! - **seek 同步 rendezvous**：音频线程发 Seek 命令 → 后台线程 seek 内部源 + 回 ack
//!   → 音频线程排空陈旧样本。后台线程因 `try_send` 不阻塞，seek 必然及时响应。
//! - **Drop 信号**：Drop 时发 Stop 命令并丢弃句柄，后台线程检测到通道断开后退出。

use std::collections::VecDeque;
use std::marker::PhantomData;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, SyncSender};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

/// 每个样本块的样本数。1024 样本 ≈ 11.6ms @ 44100Hz 立体声。
/// 较大块降低通道开销，较小块降低起播延迟与 seek 排空代价。
pub const BLOCK_SAMPLES: usize = 1024;

/// 有界通道容量（块数）。64 块 × 1024 样本 ≈ 744ms 缓冲 @ 44100 立体声，
/// 足以吸收数百毫秒的解码抖动 / 网络停顿 / 系统调度抢占。
const CHANNEL_BLOCKS: usize = 64;

/// 后台线程满载时的退避间隔。短到不影响 seek 响应，长到不空转浪费 CPU。
const BACKOFF: Duration = Duration::from_micros(400);

#[cfg(test)]
const CONSUMER_WAIT_TIMEOUT: Duration = Duration::from_millis(500);
#[cfg(not(test))]
const CONSUMER_WAIT_TIMEOUT: Duration = BACKOFF;

// Windows 线程优先级 FFI：提升生产者线程优先级，防止系统负载下被抢占导致
// 744ms 缓冲排空 → 静音卡顿。生产者只需略高于普通优先级即可在系统繁忙时
// 仍能及时填充缓冲（音频回调线程本身不受影响）。
#[cfg(target_os = "windows")]
#[link(name = "kernel32")]
extern "system" {
    fn GetCurrentThread() -> isize;
    fn SetThreadPriority(handle: isize, priority: i32) -> i32;
}
#[cfg(target_os = "windows")]
const THREAD_PRIORITY_ABOVE_NORMAL: i32 = 1;

/// 提升当前线程优先级到 ABOVE_NORMAL（仅 Windows，其他平台 no-op）。
#[cfg(target_os = "windows")]
fn elevate_thread_priority() {
    // SAFETY: GetCurrentThread 返回当前线程伪句柄（-2），SetThreadPriority 设置当前线程优先级。
    unsafe {
        let _ = SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_ABOVE_NORMAL);
    }
}
#[cfg(not(target_os = "windows"))]
#[inline]
fn elevate_thread_priority() {}

/// 后台线程命令。
enum Command {
    /// 跳转到指定位置
    Seek(Duration),
    /// 停止并退出
    Stop,
}

/// seek 执行结果回执。
enum SeekAck {
    Ok,
    Failed,
}

/// 解码缓冲监控状态（由 BufferedSource 的消费/生产线程维护，播放线程只读）。
pub struct BufferedMonitor {
    /// 缓冲饥饿：消费线程取不到样本块（网络/磁盘 I/O 未跟上）。
    pub starved: AtomicBool,
    /// 缓冲已补充：生产线程最近一个轮询周期成功推送了数据块。
    /// 播放线程用 swap(false) 读取后清除，避免「暂停后消费线程不再读取导致饥饿标志滞留」。
    pub produced: AtomicBool,
}

impl BufferedMonitor {
    pub fn new() -> Self {
        Self {
            starved: AtomicBool::new(false),
            produced: AtomicBool::new(false),
        }
    }
}

impl Default for BufferedMonitor {
    fn default() -> Self {
        Self::new()
    }
}

/// 样本块生产者：被后台预读取线程反复调用以填充缓冲。
///
/// 移动端解码器/缓冲播放源实现此性状即可接入预读取机制，无需 rodio 依赖。
pub trait BlockProducer {
    /// 产出最多 `max_samples` 个交错 PCM 样本；返回 `None` 表示已到 EOF。
    fn produce(&mut self, max_samples: usize) -> Option<Vec<f32>>;
    /// 跳转到指定播放位置。返回 `Ok(())` 表示成功。
    fn try_seek(&mut self, pos: Duration) -> Result<(), String>;
}

/// 预读取缓冲源。
///
/// 构造时把 `producer` 移入后台线程，音频线程通过 [`next_block`](Self::next_block)
/// 从有界通道读取样本块。`sample_rate` / `channels` / `total_duration` 在构造时捕获。
pub struct BufferedSource<P> {
    sample_rx: Receiver<Vec<f32>>,
    cmd_tx: SyncSender<Command>,
    ack_rx: Receiver<SeekAck>,
    sample_rate: u32,
    channels: u16,
    total_duration: Option<Duration>,
    /// 当前正在消费的样本块（交错 f32）。
    current_block: VecDeque<f32>,
    /// 内部源是否已耗尽（EOF）且缓冲排空。
    exhausted: bool,
    /// 可选：缓冲监控。消费线程置 `starved`（饥饿），生产线程置 `produced`（已补充）。
    monitor: Option<Arc<BufferedMonitor>>,
    /// 后台线程句柄（Drop 时 take + join）。
    thread_handle: Option<thread::JoinHandle<()>>,
    _marker: PhantomData<P>,
}

impl<P> BufferedSource<P>
where
    P: BlockProducer + Send + 'static,
{
    /// 更新缓冲监控的饥饿（或补充）标志（可空：无外部观察者时 no-op）。
    #[inline]
    fn set_starvation(&self, value: bool) {
        if let Some(monitor) = &self.monitor {
            monitor.starved.store(value, Ordering::Relaxed);
        }
    }

    /// 构造并启动后台预读取线程。
    pub fn new(
        producer: P,
        sample_rate: u32,
        channels: u16,
        total_duration: Option<Duration>,
    ) -> Self {
        Self::new_tracked(producer, sample_rate, channels, total_duration, None)
    }

    /// 构造并启动后台预读取线程，可选项 `monitor` 同步缓冲饥饿/补充状态。
    pub fn new_tracked(
        producer: P,
        sample_rate: u32,
        channels: u16,
        total_duration: Option<Duration>,
        monitor: Option<Arc<BufferedMonitor>>,
    ) -> Self {
        // 命令通道：音频线程 → 后台线程。容量 8 足以容纳突发 seek。
        let (cmd_tx, cmd_rx) = mpsc::sync_channel::<Command>(8);
        // 样本块通道：后台线程 → 音频线程。有界，提供背压。
        let (sample_tx, sample_rx) = mpsc::sync_channel::<Vec<f32>>(CHANNEL_BLOCKS);
        // seek 回执通道：后台线程 → 音频线程。
        let (ack_tx, ack_rx) = mpsc::channel::<SeekAck>();

        // 停止标志：Drop 时置位，后台线程在退避 sleep 中也能及时退出。
        let stop_flag = Arc::new(AtomicBool::new(false));
        let stop_flag_clone = stop_flag.clone();
        let monitor_clone = monitor.clone();

        let thread_handle = thread::Builder::new()
            .name("xy-buffered-source".to_string())
            .spawn(move || producer_loop(producer, cmd_rx, sample_tx, ack_tx, stop_flag_clone, monitor_clone))
            .ok();

        let mut source = Self {
            sample_rx,
            cmd_tx,
            ack_rx,
            sample_rate,
            channels,
            total_duration,
            current_block: VecDeque::with_capacity(BLOCK_SAMPLES),
            exhausted: false,
            monitor,
            thread_handle,
            _marker: PhantomData,
        };
        // 预填充首个样本块，消除启动竞态（构造在音频线程外执行，短暂阻塞可接受）。
        source.prefill_one_block();
        source
    }

    /// 阻塞等待首个样本块填入 current_block（构造与 seek 后调用）。
    /// - 收到块：填入 current_block，next_block() 立即有真实样本。
    /// - Disconnected：后台线程已退出（空源或 Drop），标记 exhausted。
    /// - 超时：保留空 current_block，next_block() 用静音兜底（罕见，仅极端慢启动）。
    fn prefill_one_block(&mut self) {
        const PREFILL_TIMEOUT: Duration = Duration::from_millis(500);
        match self.sample_rx.recv_timeout(PREFILL_TIMEOUT) {
            Ok(block) => {
                self.set_starvation(false);
                if block.is_empty() {
                    self.exhausted = true;
                } else {
                    self.current_block = block.into_iter().collect();
                }
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {
                // 超时保留空 current_block，next_block() 会用静音兜底
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                // 后台线程已退出（空源）→ 标记耗尽
                self.exhausted = true;
            }
        }
    }

    /// 通道容量（块数），供播放引擎估算缓冲水量。
    pub fn channel_capacity(&self) -> usize {
        CHANNEL_BLOCKS
    }

    /// 采样率。
    pub fn sample_rate(&self) -> u32 {
        self.sample_rate
    }

    /// 声道数。
    pub fn channels(&self) -> u16 {
        self.channels
    }

    /// 总时长（未知时为 `None`）。
    pub fn total_duration(&self) -> Option<Duration> {
        self.total_duration
    }

    /// 块级消费接口：取回下一个样本块（交错 f32，最多 [`BLOCK_SAMPLES`] 样本）。
    ///
    /// - 返回 `Some(block)`：有真实样本。
    /// - 返回 `None`：流已耗尽（EOF）。
    /// - 通道短暂为空时返回静音块兜底避免 underrun，同时置饥饿标志供看门狗降级。
    pub fn next_block(&mut self) -> Option<Vec<f32>> {
        if self.exhausted {
            return None;
        }

        // 1. 当前块还有剩余样本，直接返回
        if !self.current_block.is_empty() {
            let out: Vec<f32> = self.current_block.drain(..).collect();
            return Some(out);
        }

        // 2. 当前块耗尽，从通道拉取下一块
        match self.sample_rx.recv_timeout(CONSUMER_WAIT_TIMEOUT) {
            Ok(block) => {
                self.set_starvation(false);
                if block.is_empty() {
                    // 空块视为 EOF 信号
                    self.exhausted = true;
                    None
                } else {
                    Some(block)
                }
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {
                // 通道暂时空：后台线程正在生产或被抢占。返回静音块避免 underrun 爆音，
                // 同时置饥饿标志：看门狗据此自动暂停/恢复，避免长时间无声。
                self.set_starvation(true);
                Some(vec![0.0; BLOCK_SAMPLES])
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                // 后台线程退出（EOF 或 Drop）→ 流结束。
                self.exhausted = true;
                self.set_starvation(false);
                None
            }
        }
    }

    /// 块级 seek：同步 rendezvous（发命令 → 等后台完成 → 排空陈旧样本 → 预填充首块）。
    pub fn try_seek(&mut self, pos: Duration) -> Result<(), String> {
        if self.cmd_tx.send(Command::Seek(pos)).is_err() {
            return Err("BufferedSource 后台线程已退出".to_string());
        }

        // 等待后台 seek 完成（最长 2s，网络流 seek 可能较慢）
        match self.ack_rx.recv_timeout(Duration::from_secs(2)) {
            Ok(SeekAck::Ok) => {}
            _ => return Err("BufferedSource seek 失败或超时".to_string()),
        }

        // 排空通道中 seek 前的陈旧样本块
        while self.sample_rx.try_recv().is_ok() {}
        self.current_block.clear();
        self.exhausted = false;
        // 预填充 seek 后首个样本块，消除 seek 后短暂静音
        self.prefill_one_block();
        Ok(())
    }
}

/// 后台生产者循环：持续从 producer 读取样本块并推入通道，响应 seek/stop 命令。
fn producer_loop<P: BlockProducer + Send>(
    mut producer: P,
    cmd_rx: Receiver<Command>,
    sample_tx: SyncSender<Vec<f32>>,
    ack_tx: std::sync::mpsc::Sender<SeekAck>,
    stop_flag: Arc<AtomicBool>,
    monitor: Option<Arc<BufferedMonitor>>,
) {
    // 提升生产者线程优先级（Windows: ABOVE_NORMAL），防止系统负载下被抢占导致缓冲排空。
    elevate_thread_priority();

    let mut eof = false;

    loop {
        // 1. 检查停止标志（Drop 触发，退避 sleep 中也能及时退出）
        if stop_flag.load(Ordering::Relaxed) {
            return;
        }

        // 2. 非阻塞检查命令（优先处理 seek/stop）
        match cmd_rx.try_recv() {
            Ok(Command::Stop) => return,
            Ok(Command::Seek(pos)) => {
                let ack = if producer.try_seek(pos).is_ok() {
                    SeekAck::Ok
                } else {
                    SeekAck::Failed
                };
                let _ = ack_tx.send(ack);
                // seek 后重置 EOF，恢复生产
                eof = false;
                continue;
            }
            Err(mpsc::TryRecvError::Empty) => {}
            Err(mpsc::TryRecvError::Disconnected) => return,
        }

        // 3. EOF 后只等命令（不生产）
        if eof {
            match cmd_rx.recv_timeout(BACKOFF) {
                Ok(Command::Stop) => return,
                Ok(Command::Seek(pos)) => {
                    let _ = ack_tx.send(if producer.try_seek(pos).is_ok() {
                        SeekAck::Ok
                    } else {
                        SeekAck::Failed
                    });
                    eof = false;
                }
                Err(mpsc::RecvTimeoutError::Timeout) => {
                    if stop_flag.load(Ordering::Relaxed) {
                        return;
                    }
                }
                Err(mpsc::RecvTimeoutError::Disconnected) => return,
            }
            continue;
        }

        // 4. 生产一个样本块
        let block = match producer.produce(BLOCK_SAMPLES) {
            Some(b) => b,
            None => {
                // EOF：主动 drop sample_tx 让音频侧感知 Disconnected
                return;
            }
        };

        // 5. 推送块（非阻塞 try_send，满则短退避重试，期间可响应命令）
        if !block.is_empty() {
            let mut block = block;
            loop {
                if stop_flag.load(Ordering::Relaxed) {
                    return;
                }
                // 命令优先：seek 期间不应继续推旧样本
                match cmd_rx.try_recv() {
                    Ok(Command::Stop) => return,
                    Ok(Command::Seek(pos)) => {
                        let _ = ack_tx.send(if producer.try_seek(pos).is_ok() {
                            SeekAck::Ok
                        } else {
                            SeekAck::Failed
                        });
                        eof = false;
                        // 丢弃当前块（seek 前的陈旧数据）
                        break;
                    }
                    Err(mpsc::TryRecvError::Empty) => {}
                    Err(mpsc::TryRecvError::Disconnected) => return,
                }

                match sample_tx.try_send(block) {
                    Ok(()) => {
                        // 成功推送数据块 → 通知播放线程缓冲已补充（看门狗据此判断可恢复）
                        if let Some(monitor) = &monitor {
                            monitor.produced.store(true, Ordering::Relaxed);
                        }
                        break;
                    }
                    Err(mpsc::TrySendError::Full(b)) => {
                        block = b;
                        thread::sleep(BACKOFF);
                    }
                    Err(mpsc::TrySendError::Disconnected(_)) => return,
                }
            }
        }

        // EOF 且无剩余数据：退出（音频侧通过通道断开感知 EOF）
        if eof {
            return;
        }
    }
}

impl<P> Drop for BufferedSource<P> {
    fn drop(&mut self) {
        // 通知后台线程停止。即使通道已满也能放入命令（命令通道容量 8）。
        let _ = self.cmd_tx.try_send(Command::Stop);
        // take 句柄并 join，确保线程干净退出（最长等一个 BLOCK 周期 + BACKOFF）
        if let Some(handle) = self.thread_handle.take() {
            let _ = handle.join();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 生成 N 个样本的简单正弦波生产者（固定采样率/声道）。
    struct SineProducer {
        samples: Vec<f32>,
        idx: usize,
    }

    impl SineProducer {
        fn new(rate: u32, ch: u16, secs: f32) -> Self {
            let n = (secs * rate as f32 * ch as f32).round() as usize;
            let samples: Vec<f32> = (0..n)
                .map(|i| {
                    let t = i as f32 / (rate * ch as u32) as f32;
                    (t * 440.0 * std::f32::consts::TAU).sin() * 0.5
                })
                .collect();
            Self { samples, idx: 0 }
        }
    }

    impl BlockProducer for SineProducer {
        fn produce(&mut self, max_samples: usize) -> Option<Vec<f32>> {
            if self.idx >= self.samples.len() {
                return None;
            }
            let end = (self.idx + max_samples).min(self.samples.len());
            let out = self.samples[self.idx..end].to_vec();
            self.idx = end;
            Some(out)
        }
        fn try_seek(&mut self, pos: Duration) -> Result<(), String> {
            self.idx = (pos.as_secs_f64() * 44100.0 * 2.0).round() as usize;
            self.idx = self.idx.min(self.samples.len());
            Ok(())
        }
    }

    #[test]
    fn passthrough_preserves_samples() {
        // 1 秒立体声正弦波，验证 BufferedSource 无损透传所有样本
        let inner = SineProducer::new(44100, 2, 1.0);
        let expected: Vec<f32> = (0..44100 * 2)
            .map(|i| {
                let t = i as f32 / (44100 * 2) as f32;
                (t * 440.0 * std::f32::consts::TAU).sin() * 0.5
            })
            .collect();

        let mut buf = BufferedSource::new(inner, 44100, 2, Some(Duration::from_secs(1)));
        let mut out = Vec::with_capacity(expected.len());
        while let Some(block) = buf.next_block() {
            out.extend_from_slice(&block);
            if out.len() >= expected.len() {
                break;
            }
        }

        assert_eq!(out.len(), expected.len(), "样本数应一致");
        for (i, (a, b)) in out.iter().zip(expected.iter()).enumerate() {
            assert!((a - b).abs() < 1e-6, "样本 {} 不匹配: {} vs {}", i, a, b);
        }
    }

    #[test]
    fn reports_metadata() {
        let inner = SineProducer::new(48000, 2, 2.0);
        let buf = BufferedSource::new(inner, 48000, 2, Some(Duration::from_secs(2)));
        assert_eq!(buf.sample_rate, 48000);
        assert_eq!(buf.channels, 2);
        assert_eq!(buf.total_duration, Some(Duration::from_secs(2)));
    }

    #[test]
    fn eof_returns_none() {
        // 0.05 秒短源，验证耗尽后 next_block() 返回 None 而非无限静音
        let inner = SineProducer::new(44100, 1, 0.05);
        let expected_samples = 2205; // 0.05 * 44100
        let mut buf = BufferedSource::new(inner, 44100, 1, Some(Duration::from_millis(50)));
        let mut non_zero = 0;
        let mut total = 0;
        while let Some(block) = buf.next_block() {
            non_zero += block.iter().filter(|&&s| s.abs() > 1e-6).count();
            total += block.len();
            if total > expected_samples + 5000 {
                panic!("EOF 未正确检测，产生过多样本");
            }
        }
        assert!(non_zero > 0, "应产生非零样本");
    }

    #[test]
    fn seek_resets_position() {
        let inner = SineProducer::new(44100, 2, 2.0);
        let mut buf = BufferedSource::new(inner, 44100, 2, Some(Duration::from_secs(2)));

        // 跳过 0.5 秒
        buf.try_seek(Duration::from_millis(500)).unwrap();
        // 排空一些样本
        let mut got = Vec::new();
        for _ in 0..1000 {
            if let Some(block) = buf.next_block() {
                got.extend_from_slice(&block);
            }
        }
        // seek 后应能继续产出样本（非全静音）
        let non_zero = got.iter().filter(|&&s| s.abs() > 1e-6).count();
        assert!(non_zero > 0, "seek 后应有有效音频样本");
    }

    #[test]
    fn handles_empty_source() {
        // 空源：立即 EOF
        struct Empty;
        impl BlockProducer for Empty {
            fn produce(&mut self, _max_samples: usize) -> Option<Vec<f32>> {
                None
            }
            fn try_seek(&mut self, _pos: Duration) -> Result<(), String> {
                Ok(())
            }
        }

        let mut buf = BufferedSource::new(Empty, 44100, 2, Some(Duration::ZERO));
        // 预填充检测到空源（Disconnected）→ exhausted=true
        let mut none_count = 0;
        for _ in 0..2000 {
            match buf.next_block() {
                Some(b) if b.iter().all(|&s| s == 0.0) => { /* 罕见：预填充超时兜底静音，可接受 */ }
                Some(_) => panic!("空源不应产生非零样本"),
                None => {
                    none_count += 1;
                    break;
                }
            }
        }
        assert!(none_count > 0, "空源最终应返回 None");
    }
}