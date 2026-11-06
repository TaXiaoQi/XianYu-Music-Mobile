//! iOS CoreAudio 共享模式输出（仅 `target_os = "ios"`）。
//!
//! 对齐 `android_aaudio` / `ohos_audio` 共享路径语义：Symphonia 解码 →
//! DSP 全链（响度归一 / EQ / 音效 / 变速变调 / 用户音量 / 安全限幅）→
//! PCM 交系统音频硬件。输出层用 cpal（CoreAudio host，AURemoteIO）：
//! 管线线程产出交错 f32 写入环形缓冲，cpal 渲染回调在系统音频线程搬运
//! 到设备，欠载补零维持时间轴。
//!
//! 平台边界：
//! - iOS 无 USB 独占途径（第三方 App 不能 claim UAC），`shared_mode=false`
//!   直接报错，Dart 侧 `_tryStartExclusive` 失败自然回落 DSP 管线；
//! - AVAudioSession（category/激活/中断/路由）Rust 侧做不了，由 Swift 侧
//!   `IosAudioSessionPlugin` 配合：Dart 起播前 `configurePipeline` 激活
//!   `.playback` 会话，中断/路由变化经 MethodChannel 回传 Dart 处理
//!   （audio_session 插件的 interruption 流在 iOS 同样生效，双路信号幂等）；
//! - 采样率：cpal 流按设备默认输出格式（硬件当前 rate）创建，管线输出与
//!   设备 rate 不一致时用 rubato FftFixedIn 流式重采样（起播前 Dart 已把
//!   源采样率作为 AVAudioSession 偏好提交，一致时零重采样直通）；
//! - 后台播放：`UIBackgroundModes=audio` 已配置 + `.playback` 会话激活
//!   即可后台续播，无需额外保活；
//! - 静音键：`.playback` category 本身不受静音键影响。

use super::ExclusivePlayRequest;
use crate::player::buffered_source::BufferedSource;
use crate::player::equalizer::{
    ClipGuardSource, Equalizer, EqualizerHandle, EqualizerSettings, UserVolumeSource,
};
use crate::player::loudness::VolumeNormalizer;
use crate::player::output::android_aaudio::{
    record_pipeline_diag, reset_pipeline_diag, take_decoder_error, CacheDiag, SymphoniaDecoder,
};
use crate::player::sound_effect::{SoundEffectBlockProcessor, SoundEffectSettings};
use crate::player::types::global_visualizer;
use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver, Sender, SyncSender};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;
use std::time::Duration;

// rubato Resampler trait 提供 input_frames_next / process_into_buffer 等方法
use rubato::Resampler;

// cpal Device/Host/Stream 能力方法分属三个 trait（0.15 起收拢在 cpal::traits）
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};

// =========================================================================
// 进度与管线共享态
// =========================================================================

/// 进度共享态。双时间轴记账：
/// - 设备域：cpal 回调消费的交错样本数（dev_rate/dev_channels）；
/// - 源域：跳过静音丢弃的交错样本数（src_rate/playback_channels，由
///   SilenceSkipProducer 累加）。
/// 位置 = 设备域真实时间 × (源率/有效率) + 跳过静音补偿 − 重采样群延迟。
/// 有效率（eff_rate）是变速变调后的 DSP 输出率，除回源率即得原曲时间轴
/// （对齐 ohos_audio 的 eff_rate 语义）。
struct IosProgress {
    samples_dev: AtomicU64,
    dev_rate: AtomicU32,
    dev_channels: AtomicU32,
    eff_rate: AtomicU32,
    playback_channels: AtomicU32,
    src_rate: AtomicU32,
    /// 流式重采样器群延迟（设备域帧数），0 = 无重采样直通。
    resample_delay_frames: AtomicU32,
    /// 源总时长（毫秒），供 Flutter 在 DSP 管线播放时更新进度条。
    duration_ms: AtomicU64,
    /// 跳过静音累计丢弃的源域交错样本数（与 SilenceSkipProducer 共享）。
    skipped_samples: Arc<AtomicU64>,
    /// 无缝拼接次数：Dart 轮询到变化即知「已经切到下一首了」。
    transition_seq: AtomicU64,
}

impl IosProgress {
    fn new() -> Self {
        Self {
            samples_dev: AtomicU64::new(0),
            dev_rate: AtomicU32::new(0),
            dev_channels: AtomicU32::new(0),
            eff_rate: AtomicU32::new(0),
            playback_channels: AtomicU32::new(0),
            src_rate: AtomicU32::new(0),
            resample_delay_frames: AtomicU32::new(0),
            duration_ms: AtomicU64::new(0),
            skipped_samples: Arc::new(AtomicU64::new(0)),
            transition_seq: AtomicU64::new(0),
        }
    }
}

/// 管线线程 → cpal 渲染回调的共享态：环形样本缓冲。
/// Mutex<VecDeque<f32>> 本身 Send+Sync，无需 unsafe 实现。
struct PipeShared {
    ring: Mutex<RingInner>,
    progress: Arc<IosProgress>,
}

struct RingInner {
    buf: VecDeque<f32>,
}

// =========================================================================
// 运行时命令（对齐 ohos OhosCommand 共享子集）
// =========================================================================

enum CoreAudioCommand {
    Seek {
        time_secs: f64,
        is_playing: bool,
    },
    Stop,
    Pause,
    Resume,
    SetVolume(f32),
    SetVolumeBalanceGain(f32),
    SetEqualizer(EqualizerSettings),
    SetSoundEffect(SoundEffectSettings),
    /// 直出切换在共享模式下仅作 DSP 旁路开关（对齐 android/ohos 共享路径）。
    SetBitPerfect(bool),
    SetSkipSilence {
        enabled: bool,
        threshold_db: f32,
        keep_ms: u32,
    },
    SetNext {
        path: String,
        stream_cache_url: Option<String>,
        /// 头部参数保留以对齐管线签名；iOS 侧在线源不走无缝拼接。
        #[allow(dead_code)]
        stream_cache_headers_json: Option<String>,
    },
    CancelNext,
    SetCrossfade(u32),
}

fn set_exit_reason(last_error: &Mutex<Option<String>>, msg: String) {
    if let Ok(mut slot) = last_error.lock() {
        *slot = Some(msg);
    }
}

// =========================================================================
// 播放控制器
// =========================================================================

struct CoreAudioPlayback {
    tx: Sender<CoreAudioCommand>,
    join_handle: Option<thread::JoinHandle<()>>,
    progress: Arc<IosProgress>,
    device_name: String,
    /// DSP 旁路当前状态（供外部查询，工作线程持有同一 Arc）。
    bit_perfect: Arc<AtomicBool>,
    /// 工作线程是否仍在运行（false=播放结束/异常退出，供 Flutter 检测回退）。
    running: Arc<AtomicBool>,
    /// 工作线程退出原因（空=正常 Stop）。
    last_error: Arc<Mutex<Option<String>>>,
}

impl Drop for CoreAudioPlayback {
    fn drop(&mut self) {
        let _ = self.tx.send(CoreAudioCommand::Stop);
        if let Some(handle) = self.join_handle.take() {
            let _ = handle.join();
        }
    }
}

static INSTANCE: OnceLock<Mutex<Option<CoreAudioPlayback>>> = OnceLock::new();

fn instance() -> &'static Mutex<Option<CoreAudioPlayback>> {
    INSTANCE.get_or_init(|| Mutex::new(None))
}

// =========================================================================
// 公共 API（由 output/mod.rs 按 cfg 路由）
// =========================================================================

pub fn start_exclusive_playback(request: ExclusivePlayRequest) -> Result<String, String> {
    // iOS 仅共享模式（系统混音器）：USB 独占在 iOS 上没有合法途径。
    if !request.shared_mode {
        return Err("USB 独占模式在 iOS 不可用".to_string());
    }
    // 共享混音器不走 bit-perfect（无整数直出语义），对齐 android/ohos 共享路径。
    let mut request = request;
    request.bit_perfect = false;
    // SSRF 纵深：HTTP 直链为 IP 字面量且命中禁区时拒绝（对齐 android/ohos 路径）。
    // 放行本机回环——在线播放的 DSP 管线输入是 Dart 本地回环代理 URL。
    if request.path.starts_with("http://") || request.path.starts_with("https://") {
        crate::security::ssrf::validate_url_ip_literal_allow_loopback(&request.path)
            .map_err(|e| format!("播放链接校验失败: {e}"))?;
    }
    stop_exclusive_playback();
    take_decoder_error();

    let progress = Arc::new(IosProgress::new());
    let (tx, rx) = mpsc::channel::<CoreAudioCommand>();
    let (init_tx, init_rx) = mpsc::sync_channel::<Result<(String, u32, u16), String>>(1);
    let progress_clone = progress.clone();
    let bit_perfect = Arc::new(AtomicBool::new(false));
    let bit_perfect_clone = bit_perfect.clone();
    let running = Arc::new(AtomicBool::new(true));
    let running_clone = running.clone();
    let last_error: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));
    let last_error_clone = last_error.clone();

    let stream_cache = request.stream_cache_url.is_some();

    let handle = thread::Builder::new()
        .name("xy-ios-audio".to_string())
        .spawn(move || {
            run_coreaudio_playback(
                request,
                rx,
                init_tx,
                progress_clone,
                bit_perfect_clone,
                running_clone,
                last_error_clone,
            );
        })
        .map_err(|e| e.to_string())?;

    // 初始化等待窗口：流缓存直读含最小缓冲等待，最宽；其余模式一致。
    let init_wait = if stream_cache {
        Duration::from_secs(15)
    } else {
        Duration::from_secs(6)
    };
    let device_name = match init_rx.recv_timeout(init_wait) {
        Ok(Ok((name, dev_rate, dev_ch))) => {
            progress.dev_rate.store(dev_rate, Ordering::Relaxed);
            progress
                .dev_channels
                .store(dev_ch as u32, Ordering::Relaxed);
            name
        }
        Ok(Err(e)) => {
            let _ = handle.join();
            return Err(e);
        }
        Err(_) => {
            let _ = handle.join();
            return Err("音频管线初始化超时".to_string());
        }
    };

    let playback = CoreAudioPlayback {
        tx,
        join_handle: Some(handle),
        progress,
        device_name: device_name.clone(),
        bit_perfect,
        running,
        last_error,
    };

    let mut guard = instance().lock().map_err(|e| e.to_string())?;
    *guard = Some(playback);

    Ok(device_name)
}

pub fn stop_exclusive_playback() {
    if let Ok(mut guard) = instance().lock() {
        if let Some(mut playback) = guard.take() {
            let _ = playback.tx.send(CoreAudioCommand::Stop);
            if let Some(handle) = playback.join_handle.take() {
                let _ = handle.join();
            }
        }
    }
}

pub fn seek_exclusive(time_secs: f64, is_playing: bool) {
    if let Ok(guard) = instance().lock() {
        if let Some(playback) = guard.as_ref() {
            let _ = playback.tx.send(CoreAudioCommand::Seek {
                time_secs,
                is_playing,
            });
        }
    }
}

pub fn set_exclusive_volume(volume: f32) {
    if let Ok(guard) = instance().lock() {
        if let Some(playback) = guard.as_ref() {
            let _ = playback.tx.send(CoreAudioCommand::SetVolume(volume));
        }
    }
}

pub fn set_exclusive_volume_balance_gain(gain: f32) {
    if let Ok(guard) = instance().lock() {
        if let Some(playback) = guard.as_ref() {
            let _ = playback
                .tx
                .send(CoreAudioCommand::SetVolumeBalanceGain(gain));
        }
    }
}

pub fn set_exclusive_equalizer(settings_json: &str) -> Result<(), String> {
    let settings: EqualizerSettings = if settings_json.is_empty() {
        EqualizerSettings::default()
    } else {
        serde_json::from_str(settings_json).map_err(|e| e.to_string())?
    };
    if let Ok(guard) = instance().lock() {
        if let Some(playback) = guard.as_ref() {
            let _ = playback.tx.send(CoreAudioCommand::SetEqualizer(settings));
        }
    }
    Ok(())
}

pub fn set_exclusive_sound_effect(settings_json: &str) -> Result<(), String> {
    let settings: SoundEffectSettings = if settings_json.is_empty() {
        SoundEffectSettings::default()
    } else {
        serde_json::from_str(settings_json).map_err(|e| e.to_string())?
    };
    if let Ok(guard) = instance().lock() {
        if let Some(playback) = guard.as_ref() {
            let _ = playback.tx.send(CoreAudioCommand::SetSoundEffect(settings));
        }
    }
    Ok(())
}

pub fn pause_exclusive() {
    if let Ok(guard) = instance().lock() {
        if let Some(playback) = guard.as_ref() {
            let _ = playback.tx.send(CoreAudioCommand::Pause);
        }
    }
}

pub fn resume_exclusive() {
    if let Ok(guard) = instance().lock() {
        if let Some(playback) = guard.as_ref() {
            let _ = playback.tx.send(CoreAudioCommand::Resume);
        }
    }
}

pub fn set_exclusive_bit_perfect(enabled: bool) {
    if let Ok(guard) = instance().lock() {
        if let Some(playback) = guard.as_ref() {
            let _ = playback.tx.send(CoreAudioCommand::SetBitPerfect(enabled));
        }
    }
}

pub fn is_exclusive_bit_perfect() -> bool {
    if let Ok(guard) = instance().lock() {
        if let Some(playback) = guard.as_ref() {
            return playback.bit_perfect.load(Ordering::Relaxed);
        }
    }
    false
}

pub fn set_exclusive_skip_silence(enabled: bool, threshold_db: f32, keep_ms: u32) {
    if let Ok(guard) = instance().lock() {
        if let Some(playback) = guard.as_ref() {
            let _ = playback.tx.send(CoreAudioCommand::SetSkipSilence {
                enabled,
                threshold_db,
                keep_ms,
            });
        }
    }
}

pub fn set_exclusive_next(
    path: String,
    stream_cache_url: Option<String>,
    stream_cache_headers_json: Option<String>,
) {
    if let Ok(guard) = instance().lock() {
        if let Some(playback) = guard.as_ref() {
            let _ = playback.tx.send(CoreAudioCommand::SetNext {
                path,
                stream_cache_url,
                stream_cache_headers_json,
            });
        }
    }
}

pub fn cancel_exclusive_next() {
    if let Ok(guard) = instance().lock() {
        if let Some(playback) = guard.as_ref() {
            let _ = playback.tx.send(CoreAudioCommand::CancelNext);
        }
    }
}

pub fn set_exclusive_crossfade(ms: u32) {
    if let Ok(guard) = instance().lock() {
        if let Some(playback) = guard.as_ref() {
            let _ = playback.tx.send(CoreAudioCommand::SetCrossfade(ms));
        }
    }
}

pub fn is_exclusive_active() -> bool {
    if let Ok(guard) = instance().lock() {
        if let Some(playback) = guard.as_ref() {
            return playback.running.load(Ordering::Relaxed);
        }
    }
    false
}

pub fn get_exclusive_position_secs() -> f64 {
    if let Ok(guard) = instance().lock() {
        if let Some(playback) = guard.as_ref() {
            let p = &playback.progress;
            let played = p.samples_dev.load(Ordering::Relaxed);
            let dev_rate = p.dev_rate.load(Ordering::Relaxed).max(1) as f64;
            let dev_ch = p.dev_channels.load(Ordering::Relaxed).max(1) as f64;
            let eff_rate = p.eff_rate.load(Ordering::Relaxed).max(1) as f64;
            let src_rate = p.src_rate.load(Ordering::Relaxed).max(1) as f64;
            let play_ch = p.playback_channels.load(Ordering::Relaxed).max(1) as f64;
            let delay_frames = p.resample_delay_frames.load(Ordering::Relaxed) as f64;
            let skipped = p.skipped_samples.load(Ordering::Relaxed) as f64;
            if p.dev_rate.load(Ordering::Relaxed) == 0 {
                return 0.0;
            }
            // 设备域真实时间 − 重采样群延迟，再映射回原曲时间轴
            let real_secs = (played as f64 / (dev_rate * dev_ch)) - delay_frames / dev_rate;
            let src_secs = real_secs * (src_rate / eff_rate);
            let skipped_secs = skipped / (src_rate * play_ch);
            return (src_secs + skipped_secs).max(0.0);
        }
    }
    0.0
}

pub fn get_exclusive_sample_rate() -> u32 {
    if let Ok(guard) = instance().lock() {
        if let Some(playback) = guard.as_ref() {
            return playback.progress.dev_rate.load(Ordering::Relaxed);
        }
    }
    0
}

pub fn get_exclusive_channels() -> u16 {
    if let Ok(guard) = instance().lock() {
        if let Some(playback) = guard.as_ref() {
            return playback.progress.dev_channels.load(Ordering::Relaxed) as u16;
        }
    }
    0
}

pub fn get_exclusive_device_info() -> String {
    let (
        active,
        device_name,
        sample_rate,
        channels,
        bit_perfect,
        duration_ms,
        last_error,
        transition_seq,
    ) = if let Ok(guard) = instance().lock() {
        if let Some(playback) = guard.as_ref() {
            (
                playback.running.load(Ordering::Relaxed),
                playback.device_name.clone(),
                playback.progress.dev_rate.load(Ordering::Relaxed),
                playback.progress.dev_channels.load(Ordering::Relaxed) as u16,
                playback.bit_perfect.load(Ordering::Relaxed),
                playback.progress.duration_ms.load(Ordering::Relaxed),
                playback
                    .last_error
                    .lock()
                    .ok()
                    .and_then(|e| e.clone())
                    .unwrap_or_default(),
                playback.progress.transition_seq.load(Ordering::Relaxed),
            )
        } else {
            (false, String::new(), 0, 0, false, 0, String::new(), 0)
        }
    } else {
        (false, String::new(), 0, 0, false, 0, String::new(), 0)
    };
    serde_json::json!({
        "active": active,
        "deviceName": device_name,
        "sampleRate": sample_rate,
        "channels": channels,
        "bitPerfect": bit_perfect,
        "durationSecs": duration_ms as f64 / 1000.0,
        "lastError": last_error,
        "transitionSeq": transition_seq,
    })
    .to_string()
}

// =========================================================================
// 流式重采样（rubato FftFixedIn；设备率 ≠ 管线率时启用）
// =========================================================================

struct StreamingResampler {
    inner: rubato::FftFixedIn<f32>,
    /// 分声道输入累积缓冲
    carry: Vec<Vec<f32>>,
    out_buf: Vec<Vec<f32>>,
    channels: usize,
    rate_in: usize,
    rate_out: usize,
}

impl StreamingResampler {
    fn new(rate_in: u32, rate_out: u32, channels: u16) -> Result<Self, String> {
        // chunk 1024 帧：FftFixedIn 群延迟约为一个 chunk，实时场景控制在 ~25ms
        let inner = rubato::FftFixedIn::<f32>::new(
            rate_in as usize,
            rate_out as usize,
            1024,
            2,
            channels as usize,
        )
        .map_err(|e| format!("重采样器初始化失败: {e}"))?;
        Ok(Self {
            out_buf: inner.output_buffer_allocate(true),
            inner,
            carry: vec![Vec::new(); channels as usize],
            channels: channels as usize,
            rate_in: rate_in as usize,
            rate_out: rate_out as usize,
        })
    }

    fn delay_frames(&self) -> usize {
        self.inner.output_delay()
    }

    /// 喂入交错样本，产出的交错样本追加到 `out`。
    fn push(&mut self, interleaved: &[f32], out: &mut Vec<f32>) {
        let ch = self.channels;
        for (i, s) in interleaved.iter().enumerate() {
            self.carry[i % ch].push(*s);
        }
        loop {
            let need = self.inner.input_frames_next();
            if self.carry[0].len() < need {
                break;
            }
            let input: Vec<Vec<f32>> = self.carry.iter().map(|c| c[..need].to_vec()).collect();
            let (_, out_gen) = match self
                .inner
                .process_into_buffer(&input, &mut self.out_buf, None)
            {
                Ok(r) => r,
                Err(_) => break,
            };
            for c in &mut self.carry {
                c.drain(..need);
            }
            for f in 0..out_gen {
                for c in 0..ch {
                    out.push(self.out_buf[c][f]);
                }
            }
        }
    }

    fn reset(&mut self) {
        for c in &mut self.carry {
            c.clear();
        }
        if let Ok(rs) =
            rubato::FftFixedIn::<f32>::new(self.rate_in, self.rate_out, 1024, 2, self.channels)
        {
            self.out_buf = rs.output_buffer_allocate(true);
            self.inner = rs;
        }
    }
}

// =========================================================================
// cpal 渲染回调
// =========================================================================

/// cpal 输出回调（系统音频线程）：从环形缓冲搬运到设备缓冲，
/// 不足部分补零（欠载表现为瞬时静音，不撕裂时间轴）。
fn render_into(data: &mut [f32], shared: &PipeShared) {
    let mut copied = 0usize;
    if let Ok(mut ring) = shared.ring.lock() {
        let take = data.len().min(ring.buf.len());
        if take > 0 {
            let (a, b) = ring.buf.as_slices();
            let n_a = take.min(a.len());
            data[..n_a].copy_from_slice(&a[..n_a]);
            let n_b = (take - n_a).min(b.len());
            if n_b > 0 {
                data[n_a..n_a + n_b].copy_from_slice(&b[..n_b]);
            }
            ring.buf.drain(..take);
        }
        copied = take;
    }
    if copied < data.len() {
        data[copied..].fill(0.0);
    }
    if copied > 0 {
        shared
            .progress
            .samples_dev
            .fetch_add(copied as u64, Ordering::Relaxed);
    }
}

// =========================================================================
// 工作线程
// =========================================================================

/// 预排「下一首」采样来源（无缝拼接用），对齐 android/ohos 语义：
/// 仅本地文件与直链；在线源需 Dart 先预热流缓存，未预热时退回普通切歌。
fn prepare_next_source(
    path: &str,
    stream_cache_url: Option<&str>,
    skip_state: &Arc<crate::player::silence_skip::SkipSilenceState>,
) -> Result<crate::player::queue_producer::PreparedSource, String> {
    if stream_cache_url.is_some() {
        return Err("在线源暂不走无缝拼接（需先预热流缓存）".to_string());
    }
    let decoder = SymphoniaDecoder::open(path, None, None)?;
    let rate = decoder.sample_rate;
    let channels = decoder.channels;
    let duration = decoder.total_duration;
    Ok(crate::player::queue_producer::PreparedSource {
        producer: Box::new(crate::player::silence_skip::SilenceSkipProducer::new(
            decoder,
            channels,
            rate,
            skip_state.clone(),
        )),
        sample_rate: rate,
        channels,
        duration,
    })
}

fn run_coreaudio_playback(
    request: ExclusivePlayRequest,
    cmd_rx: Receiver<CoreAudioCommand>,
    init_tx: SyncSender<Result<(String, u32, u16), String>>,
    progress: Arc<IosProgress>,
    bit_perfect: Arc<AtomicBool>,
    running: Arc<AtomicBool>,
    last_error: Arc<Mutex<Option<String>>>,
) {
    // 诊断残留清零：上一会话的死因注解不得泄入本会话
    reset_pipeline_diag();

    // 1. 预构建流缓存直读 Reader（在线歌曲，对齐 android/ohos 共享路径）
    let mut cache_state: Option<crate::player::stream_cache::StreamingTempFileState> = None;
    let mut cache_diag: Option<CacheDiag> = None;
    let stream_reader: Option<Box<dyn crate::player::stream_cache::ReadSeek + Send + Sync>> =
        match request.stream_cache_url.as_deref() {
            None => None,
            Some(url) => {
                let state = match crate::player::stream_cache::start_streaming_download(
                    url,
                    request.stream_cache_headers.as_ref(),
                    None,
                    None,
                    None,
                ) {
                    Ok(s) => s,
                    Err(e) => {
                        let _ = init_tx.send(Err(format!("流缓存启动失败: {e}")));
                        return;
                    }
                };
                cache_diag = Some(CacheDiag {
                    downloaded_bytes: state.downloaded_bytes.clone(),
                    download_complete: state.download_complete.clone(),
                    download_failed: state.download_failed.clone(),
                    download_error: state.download_error.clone(),
                });
                cache_state = Some(state.clone());
                let deadline = std::time::Instant::now() + Duration::from_secs(8);
                while !crate::player::stream_cache::is_buffer_ready(&state) {
                    if let Some(err) = state.download_error() {
                        let _ = init_tx.send(Err(format!("流缓存下载失败: {err}")));
                        return;
                    }
                    if !running.load(Ordering::Relaxed) || std::time::Instant::now() >= deadline {
                        let _ = init_tx.send(Err("流缓存缓冲超时".to_string()));
                        return;
                    }
                    std::thread::sleep(Duration::from_millis(20));
                }
                match state.new_reader_with_decryption() {
                    Ok(r) => Some(r),
                    Err(e) => {
                        let _ = init_tx.send(Err(format!("流缓存读取失败: {e}")));
                        return;
                    }
                }
            }
        };

    // 2. 打开 symphonia 解码器
    let decoder = match SymphoniaDecoder::open(
        request.stream_cache_url.as_deref().unwrap_or(&request.path),
        stream_reader,
        cache_state,
    ) {
        Ok(d) => d,
        Err(e) => {
            let _ = init_tx.send(Err(format!("打开音频文件失败: {e}")));
            return;
        }
    };

    let source_sample_rate = decoder.sample_rate;
    let source_channels = decoder.channels;
    let total_duration = decoder.total_duration;

    // 共享混音器不做声道映射：>2 声道流样本层下混为立体声（ITU BS.775）
    let playback_channels: u16 = if source_channels > 2 {
        2
    } else {
        source_channels
    };
    let downmix_active = playback_channels != source_channels;

    // 跳过静音：状态与进度共享同一个「已跳过样本数」计数器。
    let skip_state = Arc::new(crate::player::silence_skip::SkipSilenceState::new(
        request.skip_silence_enabled,
        request.skip_silence_threshold_db,
        request.skip_silence_keep_ms,
        progress.skipped_samples.clone(),
    ));

    // 3. BufferedSource + 无缝拼接/交叉淡入淡出生产者
    let skip_producer = crate::player::silence_skip::SilenceSkipProducer::new(
        decoder,
        source_channels,
        source_sample_rate,
        skip_state.clone(),
    );
    let next_slot = crate::player::queue_producer::new_next_slot();
    let transition = Arc::new(crate::player::queue_producer::TransitionState::new());
    let producer = crate::player::queue_producer::QueueProducer::new(
        Box::new(skip_producer),
        source_sample_rate,
        source_channels,
        total_duration,
        next_slot.clone(),
        transition.clone(),
    );
    let crossfade_ms = producer.crossfade_handle();
    let mut buffered = BufferedSource::new(
        producer,
        source_sample_rate,
        source_channels,
        total_duration,
    );

    // 4. 跳到起始位置
    if request.start_time_secs > 0.0 {
        if let Err(e) = buffered.try_seek(Duration::from_secs_f64(request.start_time_secs)) {
            let _ = init_tx.send(Err(format!("跳转失败: {e}")));
            return;
        }
    }

    // 5. DSP 链（共享模式恒不走 bit-perfect 直出）
    let (mut normalizer, normalizer_handle) = VolumeNormalizer::new(
        request.volume_balance_gain,
        source_sample_rate,
        playback_channels,
        100,
    );
    let eq_settings: EqualizerSettings = if request.equalizer_settings_json.is_empty() {
        EqualizerSettings::default()
    } else {
        serde_json::from_str(&request.equalizer_settings_json).unwrap_or_default()
    };
    let eq_handle = Arc::new(EqualizerHandle::new(eq_settings));
    let mut equalizer = Equalizer::new(source_sample_rate, playback_channels, eq_handle.clone());
    let mut sound_effect = SoundEffectBlockProcessor::new(source_sample_rate, playback_channels);
    if !request.sound_effect_settings_json.is_empty() {
        if let Ok(se_settings) =
            serde_json::from_str::<SoundEffectSettings>(&request.sound_effect_settings_json)
        {
            sound_effect.set_settings(se_settings);
        }
    }
    let mut user_volume_source = UserVolumeSource::new(request.volume, source_sample_rate);
    let mut clip_guard = ClipGuardSource::new();

    let user_volume = Arc::new(AtomicU32::new(request.volume.to_bits()));
    let is_paused = Arc::new(AtomicBool::new(!request.is_playing));

    // 6. 创建 cpal 输出流（设备默认输出格式，F32 交错）。
    //    流生命周期归本线程：Stop 后函数返回即 drop（cpal Stream drop 停流），
    //    控制器线程不持有 Stream，规避其跨线程可用性问题。
    let device = match cpal::default_host()
        .default_output_device()
        .ok_or_else(|| "找不到 iOS 音频输出设备".to_string())
    {
        Ok(d) => d,
        Err(e) => {
            let _ = init_tx.send(Err(e));
            return;
        }
    };
    let supported = match device.default_output_config() {
        Ok(c) => c,
        Err(e) => {
            let _ = init_tx.send(Err(format!("读取 iOS 输出格式失败: {e:?}")));
            return;
        }
    };
    let dev_rate = supported.sample_rate().0;
    let dev_channels = supported.channels();
    let stream_config = cpal::StreamConfig {
        channels: dev_channels,
        sample_rate: cpal::SampleRate(dev_rate),
        buffer_size: cpal::BufferSize::Default,
    };

    let shared = Arc::new(PipeShared {
        ring: Mutex::new(RingInner {
            buf: VecDeque::new(),
        }),
        progress: progress.clone(),
    });
    let callback_shared = shared.clone();
    let stream = match device.build_output_stream(
        &stream_config,
        move |data: &mut [f32], _info| {
            render_into(data, &callback_shared);
        },
        move |err| {
            record_pipeline_diag(&format!("cpal stream error: {err}"));
        },
        None,
    ) {
        Ok(s) => s,
        Err(e) => {
            let _ = init_tx.send(Err(format!("创建 iOS 输出流失败: {e}")));
            return;
        }
    };
    if let Err(e) = stream.play() {
        let _ = init_tx.send(Err(format!("启动 iOS 输出流失败: {e}")));
        return;
    }

    let effective_rate = sound_effect.effective_sample_rate();
    progress.eff_rate.store(effective_rate, Ordering::Relaxed);
    progress
        .src_rate
        .store(source_sample_rate, Ordering::Relaxed);
    progress
        .playback_channels
        .store(playback_channels as u32, Ordering::Relaxed);
    progress.dev_rate.store(dev_rate, Ordering::Relaxed);
    progress
        .dev_channels
        .store(dev_channels as u32, Ordering::Relaxed);
    progress.duration_ms.store(
        total_duration.map(|d| d.as_millis() as u64).unwrap_or(0),
        Ordering::Relaxed,
    );
    // 进度从起始位置起算（设备域交错样本）
    progress.samples_dev.store(
        (request.start_time_secs * dev_rate as f64 * dev_channels as f64) as u64,
        Ordering::Relaxed,
    );

    // 7. 重采样器（设备率 ≠ 有效率时启用）
    let mut resampler: Option<StreamingResampler> = None;
    if effective_rate != dev_rate {
        match StreamingResampler::new(effective_rate, dev_rate, playback_channels) {
            Ok(r) => {
                progress
                    .resample_delay_frames
                    .store(r.delay_frames() as u32, Ordering::Relaxed);
                resampler = Some(r);
            }
            Err(e) => {
                let _ = init_tx.send(Err(e));
                return;
            }
        }
    } else {
        progress.resample_delay_frames.store(0, Ordering::Relaxed);
    }

    let visualizer = global_visualizer();
    visualizer.reset();

    let device_name = format!(
        "系统混音器 (CoreAudio, {}Hz, {}ch){}",
        dev_rate,
        dev_channels,
        if downmix_active {
            format!(" {}ch→2ch 下混", source_channels)
        } else {
            String::new()
        }
    );
    let _ = init_tx.send(Ok((device_name, dev_rate, dev_channels)));

    // 8. 产出循环：解码 → DSP → （重采样 → 上混）→ 环形缓冲（回调侧消费）。
    //    环形缓冲上限 ~300ms，防管线跑太远拉高内存与 seek 延迟。
    let cap_samples = (dev_rate as usize * dev_channels as usize * 3 / 10).max(1);
    let mut last_transition: u64 = 0;

    loop {
        match cmd_rx.try_recv() {
            Ok(CoreAudioCommand::Stop) => break,
            Ok(CoreAudioCommand::Seek {
                time_secs,
                is_playing,
            }) => {
                let seek_res = buffered.try_seek(Duration::from_secs_f64(time_secs));
                match &seek_res {
                    Ok(()) => {
                        record_pipeline_diag(&format!("seek t={time_secs:.3}s ok=true"));
                        normalizer.reset();
                        equalizer.reset();
                        sound_effect.reset();
                        if let Some(rs) = resampler.as_mut() {
                            rs.reset();
                        }
                        progress.samples_dev.store(
                            (time_secs * dev_rate as f64 * dev_channels as f64) as u64,
                            Ordering::Relaxed,
                        );
                        progress.skipped_samples.store(0, Ordering::Relaxed);
                        visualizer.reset();
                    }
                    Err(e) => {
                        buffered.drain_stale();
                        record_pipeline_diag(&format!("seek t={time_secs:.3}s ok=false err={e}"));
                    }
                }
                // 丢弃陈旧样本：不清会先回放 seek 前位置的样本
                if let Ok(mut ring) = shared.ring.lock() {
                    ring.buf.clear();
                }
                is_paused.store(!is_playing, Ordering::Relaxed);
                if is_playing {
                    let _ = stream.play();
                } else {
                    let _ = stream.pause();
                }
            }
            Ok(CoreAudioCommand::Pause) => {
                let _ = stream.pause();
                is_paused.store(true, Ordering::Relaxed);
            }
            Ok(CoreAudioCommand::Resume) => {
                is_paused.store(false, Ordering::Relaxed);
                let _ = stream.play();
            }
            Ok(CoreAudioCommand::SetVolume(vol)) => {
                user_volume.store(vol.to_bits(), Ordering::Relaxed);
            }
            Ok(CoreAudioCommand::SetVolumeBalanceGain(gain)) => {
                normalizer_handle.set_target_gain(gain);
            }
            Ok(CoreAudioCommand::SetEqualizer(settings)) => {
                eq_handle.set_settings(settings);
            }
            Ok(CoreAudioCommand::SetSoundEffect(settings)) => {
                sound_effect.set_settings(settings);
            }
            Ok(CoreAudioCommand::SetBitPerfect(enabled)) => {
                bit_perfect.store(enabled, Ordering::Relaxed);
                if enabled {
                    normalizer.reset();
                    equalizer.reset();
                    sound_effect.reset();
                    if is_paused.load(Ordering::Relaxed) {
                        is_paused.store(false, Ordering::Relaxed);
                    }
                    let _ = stream.play();
                }
            }
            Ok(CoreAudioCommand::SetSkipSilence {
                enabled,
                threshold_db,
                keep_ms,
            }) => {
                skip_state.apply(enabled, threshold_db, keep_ms);
                record_pipeline_diag(&format!(
                    "skip_silence enabled={enabled} thr={threshold_db:.1}dB keep={keep_ms}ms"
                ));
            }
            Ok(CoreAudioCommand::SetNext {
                path,
                stream_cache_url,
                stream_cache_headers_json: _,
            }) => {
                let slot = next_slot.clone();
                let skip_state = skip_state.clone();
                let expect_rate = source_sample_rate;
                let expect_channels = source_channels;
                std::thread::spawn(move || {
                    match prepare_next_source(&path, stream_cache_url.as_deref(), &skip_state) {
                        Ok(prepared) => {
                            if crate::player::queue_producer::can_splice(
                                expect_rate,
                                expect_channels,
                                &prepared,
                            ) {
                                if let Ok(mut g) = slot.lock() {
                                    *g = Some(prepared);
                                }
                                record_pipeline_diag(&format!("next ready: {path}"));
                            } else {
                                record_pipeline_diag(&format!(
                                    "next declined (format mismatch {}/{} vs {}/{}): {path}",
                                    prepared.sample_rate,
                                    prepared.channels,
                                    expect_rate,
                                    expect_channels
                                ));
                            }
                        }
                        Err(e) => record_pipeline_diag(&format!("next prepare failed: {e}")),
                    }
                });
            }
            Ok(CoreAudioCommand::CancelNext) => {
                if let Ok(mut g) = next_slot.lock() {
                    *g = None;
                }
            }
            Ok(CoreAudioCommand::SetCrossfade(ms)) => {
                crossfade_ms.store(ms as u64, Ordering::Relaxed);
                record_pipeline_diag(&format!("crossfade {ms}ms"));
            }
            Err(mpsc::TryRecvError::Empty) => {}
            Err(mpsc::TryRecvError::Disconnected) => break,
        }

        // 无缝拼接已发生：进度重定位到新曲起点，并把次数通报给 Dart
        let tseq = transition.seq.load(Ordering::Relaxed);
        if tseq != last_transition {
            last_transition = tseq;
            progress.samples_dev.store(0, Ordering::Relaxed);
            progress.skipped_samples.store(0, Ordering::Relaxed);
            let d = transition.duration_ms.load(Ordering::Relaxed);
            if d > 0 {
                progress.duration_ms.store(d, Ordering::Relaxed);
            }
            progress.transition_seq.store(tseq, Ordering::Relaxed);
            record_pipeline_diag(&format!("gapless splice #{tseq}"));
        }

        if is_paused.load(Ordering::Relaxed) {
            thread::sleep(Duration::from_millis(10));
            continue;
        }

        // 背压：环形缓冲满则等待回调消费
        let pending = shared.ring.lock().map(|r| r.buf.len()).unwrap_or(0);
        if pending >= cap_samples {
            thread::sleep(Duration::from_millis(5));
            continue;
        }

        // 读取一块样本；>2 声道先样本层下混为立体声（对齐桌面端共享模式）
        let block = match buffered.next_block() {
            Some(block) => block,
            None => {
                let played = progress.samples_dev.load(Ordering::Relaxed);
                let dec_err = take_decoder_error()
                    .map(|e| format!(" ← 解码线程死因: {e}"))
                    .unwrap_or_default();
                let diag = {
                    let d = crate::player::output::android_aaudio::take_pipeline_diag();
                    if d.is_empty() {
                        String::new()
                    } else {
                        format!(" ← 管线事件: {d}")
                    }
                };
                let panic_note = if crate::player::buffered_source::take_producer_panicked() {
                    " ← 生产者线程panic"
                } else {
                    ""
                };
                let cache_note = cache_diag
                    .as_ref()
                    .map(|c| format!(" ← {}", c.snapshot()))
                    .unwrap_or_default();
                set_exit_reason(
                    &last_error,
                    format!(
                        "解码缓冲EOF(已播{played}设备样本, dev={dev_rate}Hz, rate={source_sample_rate}){dec_err}{diag}{panic_note}{cache_note}{}",
                        if played == 0 {
                            " ← 从未产出数据，拉流/解码失败"
                        } else {
                            ""
                        }
                    ),
                );
                break;
            }
        };
        let block = if downmix_active {
            crate::player::channel_downmix::downmix_block(&block, source_channels)
        } else {
            block
        };

        // DSP 链处理：bit-perfect 直出全旁路仅保留限幅；EQ/音效/响度归一
        // 全关时同样旁路（软解是固定开销，无效果时逐样本 DSP 是纯浪费）。
        // 音量与限幅始终保留，对齐 android/ohos 共享路径。
        let bit_perfect = bit_perfect.load(Ordering::Relaxed);
        let dsp_idle = !bit_perfect
            && normalizer.is_idle()
            && equalizer.is_hard_bypassed()
            && sound_effect.is_hard_bypassed();
        let mut effected = if bit_perfect || dsp_idle {
            block
        } else {
            let normalized = normalizer.process_block(&block);
            let eq_applied = equalizer.process_block(&normalized);
            sound_effect.process_block(eq_applied)
        };
        if !bit_perfect {
            user_volume_source.process_block(&mut effected, playback_channels, &user_volume);
        }
        clip_guard.process_block(&mut effected);

        // 重采样（有效率 → 设备率）→ 上混到设备声道 → 环形缓冲
        let resampled = match resampler.as_mut() {
            None => effected,
            Some(rs) => {
                let mut out = Vec::with_capacity(effected.len());
                rs.push(&effected, &mut out);
                out
            }
        };
        let mut ring_bytes: Vec<f32> = if playback_channels == dev_channels {
            resampled
        } else {
            upmix_channels(&resampled, playback_channels, dev_channels)
        };
        ring_bytes.shrink_to_fit();

        // 可视化按帧均值采样（重采样后计数，仅作频谱显示用途）
        let vis_ch = dev_channels as usize;
        let mut chan_sum = 0.0f32;
        let mut chan_count = 0u32;
        for &sample in &ring_bytes {
            chan_sum += sample;
            chan_count += 1;
            if chan_count >= vis_ch as u32 {
                visualizer.push_sample(chan_sum / chan_count as f32);
                chan_sum = 0.0;
                chan_count = 0;
            }
        }

        if let Ok(mut ring) = shared.ring.lock() {
            ring.buf.extend(ring_bytes);
        }
    }

    // 9. 清理。running=false 供 Flutter 检测自然结束/异常退出；
    //    停流后 stream drop（cpal drop 即释放 AURemoteIO）。
    running.store(false, Ordering::Relaxed);
    let _ = stream.pause();
}

/// 单声道 → 多声道（帧复制）；多声道 → 少声道（截断保留前 N 声道）。
/// 正常路径只有 1ch→2ch 上混，其余形态仅兜底。
fn upmix_channels(interleaved: &[f32], from: u16, to: u16) -> Vec<f32> {
    let (from, to) = (from.max(1) as usize, to.max(1) as usize);
    if from == to {
        return interleaved.to_vec();
    }
    let frames = interleaved.len() / from;
    let mut out = Vec::with_capacity(frames * to);
    for f in 0..frames {
        let src = &interleaved[f * from..(f + 1) * from];
        for c in 0..to {
            out.push(src.get(c).copied().unwrap_or(src[0]));
        }
    }
    out
}
