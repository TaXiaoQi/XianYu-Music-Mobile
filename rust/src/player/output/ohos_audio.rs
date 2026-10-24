//! OHAudio 共享模式输出（仅 `target_env = "ohos"`，HarmonyOS HAP；
//! ohos triple 是 `aarch64-unknown-linux-ohos`，其 target_os 为 "linux"）。
//!
//! 对齐 `android_aaudio` 共享路径语义：Symphonia 解码 → DSP 全链
//! （响度归一 / EQ / 音效 / 变速变调 / 用户音量 / 安全限幅）→ PCM 交
//! 系统混音器。输出层用 OHAudio callback 渲染流（`OH_AudioStreamBuilder_*`，
//! 静态链接 `libohaudio.so`）：管线线程产出字节写入环形缓冲，
//! `OnWriteData` 回调在系统线程搬运到设备，欠载时补零维持时间轴。
//!
//! 平台边界：`shared_mode=true` 走 OHAudio 系统混音器（音频焦点由系统对
//! 渲染流自动托管，audio_session 插件无 ohos 实现，Dart 侧直接放行；
//! 强制打断时系统自动暂停渲染流，恢复播放由用户手动触发——diag 可见
//! interrupt 事件）。`shared_mode=false` 为 USB 拉取独占（椒盐式路线）：
//! 管线照常解码 → DSP → 环形缓冲，但不出声（无渲染流），由 ArkTS 侧经
//! usbManager claim UAC 接口后按等时传输拉取 ring 数据直写 DAC——
//! 见 ohos/entry `plugins/UsbExclusivePlayer.ets` 与 Dart 侧
//! `usb_exclusive_service.dart`（FFI 导出见本文件底部）。DSD DoP 直通
//! 不在鸿蒙实现（DSD 容器按 PCM 解码走常规管线）。

use super::ExclusivePlayRequest;
use crate::player::buffered_source::BufferedSource;
use crate::player::equalizer::{
    ClipGuardSource, Equalizer, EqualizerHandle, EqualizerSettings, UserVolumeSource,
};
use crate::player::loudness::VolumeNormalizer;
use crate::player::output::android_aaudio::{
    CacheDiag, SymphoniaDecoder, record_pipeline_diag, reset_pipeline_diag, take_decoder_error,
};
use crate::player::sound_effect::{SoundEffectBlockProcessor, SoundEffectSettings};
use crate::player::types::global_visualizer;
use std::collections::VecDeque;
use std::os::raw::{c_int, c_void};
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver, Sender, SyncSender};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;
use std::time::Duration;

// =========================================================================
// OHAudio FFI（静态声明，链接 sysroot 的 libohaudio.so）
// =========================================================================

const AUDIOSTREAM_SUCCESS: c_int = 0;
const AUDIOSTREAM_TYPE_RENDERER: c_int = 1;
const AUDIOSTREAM_SAMPLE_S16LE: c_int = 1;
const AUDIOSTREAM_SAMPLE_F32LE: c_int = 4;
const AUDIOSTREAM_LATENCY_MODE_NORMAL: c_int = 0;
const AUDIOSTREAM_USAGE_MUSIC: c_int = 1;
/// 写回调返回值：缓冲内容有效（欠载部分自行补零，不使用 INVALID 路径）。
const AUDIO_DATA_CALLBACK_RESULT_VALID: c_int = 0;

#[allow(non_camel_case_types)]
type OH_AudioStreamBuilder = std::os::raw::c_void;
#[allow(non_camel_case_types)]
type OH_AudioRenderer = std::os::raw::c_void;
type OhosWriteDataCallback = unsafe extern "C" fn(
    renderer: *mut OH_AudioRenderer,
    user_data: *mut c_void,
    audio_data: *mut c_void,
    audio_data_size: c_int,
) -> c_int;

#[link(name = "ohaudio")]
extern "C" {
    fn OH_AudioStreamBuilder_Create(
        builder: *mut *mut OH_AudioStreamBuilder,
        stream_type: c_int,
    ) -> c_int;
    fn OH_AudioStreamBuilder_Destroy(builder: *mut OH_AudioStreamBuilder) -> c_int;
    fn OH_AudioStreamBuilder_SetSamplingRate(builder: *mut OH_AudioStreamBuilder, rate: c_int)
        -> c_int;
    fn OH_AudioStreamBuilder_SetChannelCount(
        builder: *mut OH_AudioStreamBuilder,
        channel_count: c_int,
    ) -> c_int;
    fn OH_AudioStreamBuilder_SetSampleFormat(
        builder: *mut OH_AudioStreamBuilder,
        format: c_int,
    ) -> c_int;
    fn OH_AudioStreamBuilder_SetLatencyMode(
        builder: *mut OH_AudioStreamBuilder,
        latency_mode: c_int,
    ) -> c_int;
    fn OH_AudioStreamBuilder_SetRendererInfo(builder: *mut OH_AudioStreamBuilder, usage: c_int)
        -> c_int;
    fn OH_AudioStreamBuilder_SetRendererWriteDataCallback(
        builder: *mut OH_AudioStreamBuilder,
        callback: Option<OhosWriteDataCallback>,
        user_data: *mut c_void,
    ) -> c_int;
    fn OH_AudioStreamBuilder_GenerateRenderer(
        builder: *mut OH_AudioStreamBuilder,
        renderer: *mut *mut OH_AudioRenderer,
    ) -> c_int;
    fn OH_AudioRenderer_Start(renderer: *mut OH_AudioRenderer) -> c_int;
    fn OH_AudioRenderer_Pause(renderer: *mut OH_AudioRenderer) -> c_int;
    fn OH_AudioRenderer_Stop(renderer: *mut OH_AudioRenderer) -> c_int;
    fn OH_AudioRenderer_Release(renderer: *mut OH_AudioRenderer) -> c_int;
    fn OH_AudioRenderer_GetSamplingRate(renderer: *mut OH_AudioRenderer, rate: *mut c_int) -> c_int;
    fn OH_AudioRenderer_GetChannelCount(
        renderer: *mut OH_AudioRenderer,
        channel_count: *mut c_int,
    ) -> c_int;
    fn OH_AudioRenderer_GetSampleFormat(
        renderer: *mut OH_AudioRenderer,
        sample_format: *mut c_int,
    ) -> c_int;
}

// =========================================================================
// 输出格式
// =========================================================================

/// 共享混音器输出格式：F32（API 17+，本工程 compatibleSdkVersion 18）优先，
/// 协商失败回退 S16（全版本支持）。系统可能改写请求格式，创建后按实际回读。
#[derive(Clone, Copy, PartialEq)]
enum OutFormat {
    F32,
    S16,
}

impl OutFormat {
    fn ohos_format(self) -> c_int {
        match self {
            Self::F32 => AUDIOSTREAM_SAMPLE_F32LE,
            Self::S16 => AUDIOSTREAM_SAMPLE_S16LE,
        }
    }

    fn bytes_per_sample(self) -> usize {
        match self {
            Self::F32 => 4,
            Self::S16 => 2,
        }
    }

    fn of_ohos(fmt: c_int) -> Option<Self> {
        match fmt {
            AUDIOSTREAM_SAMPLE_F32LE => Some(Self::F32),
            AUDIOSTREAM_SAMPLE_S16LE => Some(Self::S16),
            _ => None,
        }
    }
}

/// f32 → 设备格式字节（小端 LE），带限幅。
fn push_sample_bytes(buf: &mut Vec<u8>, sample: f32, fmt: OutFormat) {
    let clamped = sample.clamp(-1.0, 1.0);
    match fmt {
        OutFormat::F32 => buf.extend_from_slice(&clamped.to_le_bytes()),
        OutFormat::S16 => {
            let val = (clamped * 32767.0) as i16;
            buf.extend_from_slice(&val.to_le_bytes());
        }
    }
}

// =========================================================================
// 进度与管线共享态
// =========================================================================

struct OhosProgress {
    /// 已被写回调消费的交错样本数（对齐 android 在写入点计数）。
    samples_played: AtomicU64,
    sample_rate: AtomicU32,
    channels: AtomicU32,
    /// 源总时长（毫秒），供 Flutter 侧在 DSP 管线播放时更新进度条。
    duration_ms: AtomicU64,
    /// 跳过静音累计丢弃的交错样本数（与 SilenceSkipProducer 共享同一计数器）。
    /// 位置上报要把它加回去，UI 才停留在原曲时间轴上。
    skipped_samples: Arc<AtomicU64>,
    /// 无缝拼接次数：Dart 轮询到变化即知「已经切到下一首了」。
    transition_seq: AtomicU64,
}

impl OhosProgress {
    fn new() -> Self {
        Self {
            samples_played: AtomicU64::new(0),
            sample_rate: AtomicU32::new(0),
            channels: AtomicU32::new(0),
            duration_ms: AtomicU64::new(0),
            skipped_samples: Arc::new(AtomicU64::new(0)),
            transition_seq: AtomicU64::new(0),
        }
    }
}

/// 管线线程 → 写回调的共享态：环形字节缓冲 + 进度 + 每样本字节数。
/// 回调以裸指针访问（userData），生命周期由管线线程与控制器各持一份
/// Arc 保证：renderer Release 之后不再有回调，随后 Arc 才释放。
struct PipeShared {
    ring: Mutex<RingInner>,
    progress: Arc<OhosProgress>,
    bytes_per_sample: AtomicU32,
}

struct RingInner {
    buf: VecDeque<u8>,
}

unsafe impl Send for PipeShared {}
unsafe impl Sync for PipeShared {}

// =========================================================================
// 运行时命令（对齐 android ExclusiveCommand 的共享子集）
// =========================================================================

enum OhosCommand {
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
    /// 直出切换在共享模式下仅作 DSP 旁路开关（对齐 android 共享路径行为）。
    SetBitPerfect(bool),
    SetSkipSilence {
        enabled: bool,
        threshold_db: f32,
        keep_ms: u32,
    },
    SetNext {
        path: String,
        stream_cache_url: Option<String>,
        /// 头部参数保留以对齐 android 管线签名；ohos 侧在线源不走无缝
        /// 拼接（prepare_next_source 直接拒绝），消费侧不解包。
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

struct OhosPlayback {
    tx: Sender<OhosCommand>,
    join_handle: Option<thread::JoinHandle<()>>,
    progress: Arc<OhosProgress>,
    device_name: String,
    /// DSP 旁路当前状态（供外部查询，工作线程持有同一 Arc）。
    bit_perfect: Arc<AtomicBool>,
    /// 工作线程是否仍在运行（false=播放结束/异常退出，供 Flutter 检测回退）。
    running: Arc<AtomicBool>,
    /// 工作线程退出原因（空=正常 Stop）。
    last_error: Arc<Mutex<Option<String>>>,
    /// USB 拉取模式：管线环形缓冲句柄，供 FFI（xianyu_ohos_usb_*）拉取；
    /// None = OHAudio 共享模式（ring 只在写回调内消费）。
    /// 生命周期：随 OhosPlayback 存续，Stop 先 join 管线线程再 drop，
    /// FFI 侧不会读到悬空指针。
    usb_ring: Option<Arc<PipeShared>>,
}

impl Drop for OhosPlayback {
    fn drop(&mut self) {
        let _ = self.tx.send(OhosCommand::Stop);
        if let Some(handle) = self.join_handle.take() {
            let _ = handle.join();
        }
    }
}

static INSTANCE: OnceLock<Mutex<Option<OhosPlayback>>> = OnceLock::new();

fn instance() -> &'static Mutex<Option<OhosPlayback>> {
    INSTANCE.get_or_init(|| Mutex::new(None))
}

// =========================================================================
// 公共 API（由 output/mod.rs 按 cfg 路由）
// =========================================================================

pub fn start_exclusive_playback(mut request: ExclusivePlayRequest) -> Result<String, String> {
    // shared = OHAudio 系统混音器；非 shared = USB 拉取独占（ArkTS claim UAC）。
    // USB 模式允许 bit-perfect（DSP 旁路），共享模式维持强制关闭。
    let usb_mode = !request.shared_mode;
    if !usb_mode {
        request.bit_perfect = false;
    }
    // SSRF 纵深：HTTP 直链为 IP 字面量且命中禁区时拒绝（对齐 android 路径）。
    // 放行本机回环——在线播放的 DSP 管线输入是 Dart 本地回环代理 URL。
    if request.path.starts_with("http://") || request.path.starts_with("https://") {
        crate::security::ssrf::validate_url_ip_literal_allow_loopback(&request.path)
            .map_err(|e| format!("播放链接校验失败: {e}"))?;
    }
    stop_exclusive_playback();
    take_decoder_error();

    let progress = Arc::new(OhosProgress::new());
    let (tx, rx) = mpsc::channel::<OhosCommand>();
    let (init_tx, init_rx) =
        mpsc::sync_channel::<Result<(String, u32, u16, Option<Arc<PipeShared>>), String>>(1);
    let progress_clone = progress.clone();
    let bit_perfect = Arc::new(AtomicBool::new(request.bit_perfect));
    let bit_perfect_clone = bit_perfect.clone();
    let running = Arc::new(AtomicBool::new(true));
    let running_clone = running.clone();
    let last_error: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));
    let last_error_clone = last_error.clone();

    let stream_cache = request.stream_cache_url.is_some();

    let handle = thread::Builder::new()
        .name("xy-ohos-audio".to_string())
        .spawn(move || {
            run_ohos_playback(
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
    let (device_name, usb_ring) = match init_rx.recv_timeout(init_wait) {
        Ok(Ok((name, sr, ch, ring))) => {
            progress.sample_rate.store(sr, Ordering::Relaxed);
            progress.channels.store(ch as u32, Ordering::Relaxed);
            (name, ring)
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

    let playback = OhosPlayback {
        tx,
        join_handle: Some(handle),
        progress,
        device_name: device_name.clone(),
        bit_perfect,
        running,
        last_error,
        usb_ring,
    };

    let mut guard = instance().lock().map_err(|e| e.to_string())?;
    *guard = Some(playback);

    Ok(device_name)
}

pub fn stop_exclusive_playback() {
    if let Ok(mut guard) = instance().lock() {
        if let Some(mut playback) = guard.take() {
            let _ = playback.tx.send(OhosCommand::Stop);
            if let Some(handle) = playback.join_handle.take() {
                let _ = handle.join();
            }
        }
    }
}

pub fn seek_exclusive(time_secs: f64, is_playing: bool) {
    if let Ok(guard) = instance().lock() {
        if let Some(playback) = guard.as_ref() {
            let _ = playback.tx.send(OhosCommand::Seek {
                time_secs,
                is_playing,
            });
        }
    }
}

pub fn set_exclusive_volume(volume: f32) {
    if let Ok(guard) = instance().lock() {
        if let Some(playback) = guard.as_ref() {
            let _ = playback.tx.send(OhosCommand::SetVolume(volume));
        }
    }
}

pub fn set_exclusive_volume_balance_gain(gain: f32) {
    if let Ok(guard) = instance().lock() {
        if let Some(playback) = guard.as_ref() {
            let _ = playback.tx.send(OhosCommand::SetVolumeBalanceGain(gain));
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
            let _ = playback.tx.send(OhosCommand::SetEqualizer(settings));
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
            let _ = playback.tx.send(OhosCommand::SetSoundEffect(settings));
        }
    }
    Ok(())
}

pub fn pause_exclusive() {
    if let Ok(guard) = instance().lock() {
        if let Some(playback) = guard.as_ref() {
            let _ = playback.tx.send(OhosCommand::Pause);
        }
    }
}

pub fn resume_exclusive() {
    if let Ok(guard) = instance().lock() {
        if let Some(playback) = guard.as_ref() {
            let _ = playback.tx.send(OhosCommand::Resume);
        }
    }
}

pub fn set_exclusive_bit_perfect(enabled: bool) {
    if let Ok(guard) = instance().lock() {
        if let Some(playback) = guard.as_ref() {
            let _ = playback.tx.send(OhosCommand::SetBitPerfect(enabled));
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
            let _ = playback.tx.send(OhosCommand::SetSkipSilence {
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
            let _ = playback.tx.send(OhosCommand::SetNext {
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
            let _ = playback.tx.send(OhosCommand::CancelNext);
        }
    }
}

pub fn set_exclusive_crossfade(ms: u32) {
    if let Ok(guard) = instance().lock() {
        if let Some(playback) = guard.as_ref() {
            let _ = playback.tx.send(OhosCommand::SetCrossfade(ms));
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
            let samples = playback.progress.samples_played.load(Ordering::Relaxed);
            let skipped = playback.progress.skipped_samples.load(Ordering::Relaxed);
            let rate = playback.progress.sample_rate.load(Ordering::Relaxed);
            let channels = playback.progress.channels.load(Ordering::Relaxed).max(1);
            if rate > 0 {
                // 位置 = (已消费 + 被跳过的静音) / 帧率：跳过静音后仍是原曲时间轴
                return (samples + skipped) as f64 / (rate as f64 * channels as f64);
            }
        }
    }
    0.0
}

pub fn get_exclusive_sample_rate() -> u32 {
    if let Ok(guard) = instance().lock() {
        if let Some(playback) = guard.as_ref() {
            return playback.progress.sample_rate.load(Ordering::Relaxed);
        }
    }
    0
}

pub fn get_exclusive_channels() -> u16 {
    if let Ok(guard) = instance().lock() {
        if let Some(playback) = guard.as_ref() {
            return playback.progress.channels.load(Ordering::Relaxed) as u16;
        }
    }
    0
}

pub fn get_exclusive_device_info() -> String {
    let (active, device_name, sample_rate, channels, bit_perfect, duration_ms, last_error, transition_seq) =
        if let Ok(guard) = instance().lock() {
            if let Some(playback) = guard.as_ref() {
                (
                    playback.running.load(Ordering::Relaxed),
                    playback.device_name.clone(),
                    playback.progress.sample_rate.load(Ordering::Relaxed),
                    playback.progress.channels.load(Ordering::Relaxed) as u16,
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
// 工作线程
// =========================================================================

/// 预排「下一首」采样来源（无缝拼接用），对齐 android 语义：仅本地文件与
/// 直链；在线源需 Dart 先预热流缓存，未预热时退回普通切歌。
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

/// 创建 OHAudio 渲染流（callback 模式）。F32 优先、S16 兜底，
/// 创建后按实际格式回读（系统可能改写请求格式）。
fn create_renderer(
    shared: &Arc<PipeShared>,
    sample_rate: u32,
    channels: u16,
) -> Result<(*mut OH_AudioRenderer, OutFormat, u32, u16), String> {
    // 裸指针随 builder 交给系统：renderer 存续期由管线线程与控制器的
    // Arc 克隆共同保证，Release 之后不再有回调。
    let user_data = Arc::as_ptr(shared) as *mut c_void;
    for &fmt in &[OutFormat::F32, OutFormat::S16] {
        unsafe {
            let mut builder: *mut OH_AudioStreamBuilder = std::ptr::null_mut();
            if OH_AudioStreamBuilder_Create(&mut builder, AUDIOSTREAM_TYPE_RENDERER)
                != AUDIOSTREAM_SUCCESS
                || builder.is_null()
            {
                continue;
            }
            OH_AudioStreamBuilder_SetSamplingRate(builder, sample_rate as c_int);
            OH_AudioStreamBuilder_SetChannelCount(builder, channels as c_int);
            OH_AudioStreamBuilder_SetSampleFormat(builder, fmt.ohos_format());
            // 音乐场景：常规延迟档（省电、走系统混音器完整通路）。
            OH_AudioStreamBuilder_SetLatencyMode(builder, AUDIOSTREAM_LATENCY_MODE_NORMAL);
            OH_AudioStreamBuilder_SetRendererInfo(builder, AUDIOSTREAM_USAGE_MUSIC);
            OH_AudioStreamBuilder_SetRendererWriteDataCallback(
                builder,
                Some(on_write_data),
                user_data,
            );
            let mut renderer: *mut OH_AudioRenderer = std::ptr::null_mut();
            let ret = OH_AudioStreamBuilder_GenerateRenderer(builder, &mut renderer);
            OH_AudioStreamBuilder_Destroy(builder);
            if ret != AUDIOSTREAM_SUCCESS || renderer.is_null() {
                continue;
            }
            let mut actual_fmt: c_int = 0;
            if OH_AudioRenderer_GetSampleFormat(renderer, &mut actual_fmt) == AUDIOSTREAM_SUCCESS {
                match OutFormat::of_ohos(actual_fmt) {
                    Some(f) => return Ok((renderer, f, read_back_rate(renderer, sample_rate), read_back_channels(renderer, channels))),
                    None => {
                        // 未知格式（S24/S32 等暂不做字节转换）：释放后试下一档
                        OH_AudioRenderer_Release(renderer);
                        continue;
                    }
                }
            }
            return Ok((renderer, fmt, read_back_rate(renderer, sample_rate), read_back_channels(renderer, channels)));
        }
    }
    Err("无法创建 OHAudio 渲染流（系统混音器拒绝 F32/S16 格式）".to_string())
}

unsafe fn read_back_rate(renderer: *mut OH_AudioRenderer, fallback: u32) -> u32 {
    let mut rate: c_int = 0;
    if OH_AudioRenderer_GetSamplingRate(renderer, &mut rate) == AUDIOSTREAM_SUCCESS && rate > 0 {
        rate as u32
    } else {
        fallback
    }
}

unsafe fn read_back_channels(renderer: *mut OH_AudioRenderer, fallback: u16) -> u16 {
    let mut ch: c_int = 0;
    if OH_AudioRenderer_GetChannelCount(renderer, &mut ch) == AUDIOSTREAM_SUCCESS && ch > 0 {
        ch as u16
    } else {
        fallback
    }
}

/// OHAudio 写回调（系统音频线程）：从环形缓冲搬运到设备缓冲，
/// 不足部分补零（欠载表现为瞬时静音，不撕裂时间轴）。
unsafe extern "C" fn on_write_data(
    _renderer: *mut OH_AudioRenderer,
    user_data: *mut c_void,
    audio_data: *mut c_void,
    audio_data_size: c_int,
) -> c_int {
    if user_data.is_null() || audio_data.is_null() || audio_data_size <= 0 {
        return AUDIO_DATA_CALLBACK_RESULT_VALID;
    }
    let shared = &*(user_data as *const PipeShared);
    let dst = audio_data as *mut u8;
    let want = audio_data_size as usize;
    let mut copied = 0usize;
    if let Ok(mut ring) = shared.ring.lock() {
        let take = want.min(ring.buf.len());
        if take > 0 {
            let (a, b) = ring.buf.as_slices();
            let n_a = take.min(a.len());
            std::ptr::copy_nonoverlapping(a.as_ptr(), dst, n_a);
            let n_b = (take - n_a).min(b.len());
            if n_b > 0 {
                std::ptr::copy_nonoverlapping(b.as_ptr(), dst.add(n_a), n_b);
            }
            ring.buf.drain(..take);
        }
        copied = take;
    }
    if copied < want {
        std::ptr::write_bytes(dst.add(copied), 0, want - copied);
    }
    if copied > 0 {
        let bps = shared.bytes_per_sample.load(Ordering::Relaxed).max(1) as usize;
        shared
            .progress
            .samples_played
            .fetch_add((copied / bps) as u64, Ordering::Relaxed);
    }
    AUDIO_DATA_CALLBACK_RESULT_VALID
}

fn run_ohos_playback(
    request: ExclusivePlayRequest,
    cmd_rx: Receiver<OhosCommand>,
    init_tx: SyncSender<Result<(String, u32, u16, Option<Arc<PipeShared>>), String>>,
    progress: Arc<OhosProgress>,
    bit_perfect: Arc<AtomicBool>,
    running: Arc<AtomicBool>,
    last_error: Arc<Mutex<Option<String>>>,
) {
    // 诊断残留清零：上一会话的死因注解不得泄入本会话
    reset_pipeline_diag();

    // USB 拉取模式：不建渲染流，ring 由外部（ArkTS）消费。
    let usb_mode = !request.shared_mode;

    // 1. 预构建流缓存直读 Reader（在线歌曲，对齐 android 共享路径）
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
                    if !running.load(Ordering::Relaxed)
                        || std::time::Instant::now() >= deadline
                    {
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
    let mut buffered = BufferedSource::new(producer, source_sample_rate, source_channels, total_duration);

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

    // 6. 输出通道：共享模式创建 OHAudio 渲染流并启动；USB 拉取模式只备好
    //    环形缓冲（固定 S16LE 交错 PCM，ArkTS 侧按 DAC alt setting 拉取）。
    let shared = Arc::new(PipeShared {
        ring: Mutex::new(RingInner {
            buf: VecDeque::new(),
        }),
        progress: progress.clone(),
        bytes_per_sample: AtomicU32::new(4),
    });
    let (renderer, device_format, stream_sample_rate, stream_channels);
    let mut renderer_started = false;
    if usb_mode {
        renderer = std::ptr::null_mut();
        device_format = OutFormat::S16;
        stream_sample_rate = source_sample_rate;
        stream_channels = playback_channels;
        shared.bytes_per_sample.store(2, Ordering::Relaxed);
    } else {
        let (r, fmt, sr, ch) = match create_renderer(&shared, source_sample_rate, playback_channels)
        {
            Ok(r) => r,
            Err(e) => {
                let _ = init_tx.send(Err(e));
                return;
            }
        };
        renderer = r;
        device_format = fmt;
        stream_sample_rate = sr;
        stream_channels = ch;
        shared
            .bytes_per_sample
            .store(fmt.bytes_per_sample() as u32, Ordering::Relaxed);
        // 启动渲染流（回调开始取数）
        let start_result = unsafe { OH_AudioRenderer_Start(renderer) };
        if start_result != AUDIOSTREAM_SUCCESS {
            let _ = init_tx.send(Err(format!("OHAudio 启动失败: code={start_result}")));
            unsafe {
                OH_AudioRenderer_Release(renderer);
            }
            return;
        }
        renderer_started = true;
    }
    let bytes_per_sample = device_format.bytes_per_sample();

    let effective_rate = sound_effect.effective_sample_rate();
    progress.sample_rate.store(effective_rate, Ordering::Relaxed);
    progress.channels.store(stream_channels as u32, Ordering::Relaxed);
    progress.duration_ms.store(
        total_duration.map(|d| d.as_millis() as u64).unwrap_or(0),
        Ordering::Relaxed,
    );
    progress.samples_played.store(
        (request.start_time_secs * source_sample_rate as f64 * playback_channels as f64) as u64,
        Ordering::Relaxed,
    );

    let visualizer = global_visualizer();
    visualizer.reset();

    let device_name = format!(
        "{} ({}Hz, {}ch){}",
        if usb_mode { "USB 独占" } else { "系统混音器 shared" },
        stream_sample_rate,
        stream_channels,
        if downmix_active {
            format!(" {}ch→2ch 下混", source_channels)
        } else {
            String::new()
        }
    );
    let _ = init_tx.send(Ok((
        device_name,
        stream_sample_rate,
        stream_channels,
        if usb_mode { Some(shared.clone()) } else { None },
    )));

    // 8. 产出循环：解码 → DSP → 字节 → 环形缓冲（回调侧消费）。
    // 环形缓冲上限 ~300ms，防管线跑太远拉高内存与 seek 延迟。
    let cap_bytes = (stream_sample_rate as usize
        * stream_channels as usize
        * bytes_per_sample
        * 3
        / 10)
    .max(1);
    let mut last_transition: u64 = 0;

    loop {
        match cmd_rx.try_recv() {
            Ok(OhosCommand::Stop) => break,
            Ok(OhosCommand::Seek {
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
                        progress.samples_played.store(
                            (time_secs * source_sample_rate as f64 * playback_channels as f64)
                                as u64,
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
                // 丢弃陈旧字节：不清会先回放 seek 前位置的样本
                if let Ok(mut ring) = shared.ring.lock() {
                    ring.buf.clear();
                }
                is_paused.store(!is_playing, Ordering::Relaxed);
                if !usb_mode && is_playing && !renderer_started {
                    let r = unsafe { OH_AudioRenderer_Start(renderer) };
                    renderer_started = r == AUDIOSTREAM_SUCCESS;
                } else if !usb_mode && !is_playing && renderer_started {
                    unsafe {
                        OH_AudioRenderer_Pause(renderer);
                    }
                    renderer_started = false;
                }
            }
            Ok(OhosCommand::Pause) => {
                if !usb_mode && renderer_started {
                    unsafe {
                        OH_AudioRenderer_Pause(renderer);
                    }
                    renderer_started = false;
                }
                is_paused.store(true, Ordering::Relaxed);
            }
            Ok(OhosCommand::Resume) => {
                is_paused.store(false, Ordering::Relaxed);
                if !usb_mode && !renderer_started {
                    let r = unsafe { OH_AudioRenderer_Start(renderer) };
                    renderer_started = r == AUDIOSTREAM_SUCCESS;
                }
            }
            Ok(OhosCommand::SetVolume(vol)) => {
                user_volume.store(vol.to_bits(), Ordering::Relaxed);
            }
            Ok(OhosCommand::SetVolumeBalanceGain(gain)) => {
                normalizer_handle.set_target_gain(gain);
            }
            Ok(OhosCommand::SetEqualizer(settings)) => {
                eq_handle.set_settings(settings);
            }
            Ok(OhosCommand::SetSoundEffect(settings)) => {
                sound_effect.set_settings(settings);
            }
            Ok(OhosCommand::SetBitPerfect(enabled)) => {
                bit_perfect.store(enabled, Ordering::Relaxed);
                if enabled {
                    normalizer.reset();
                    equalizer.reset();
                    sound_effect.reset();
                    if is_paused.load(Ordering::Relaxed) {
                        is_paused.store(false, Ordering::Relaxed);
                    }
                    if !usb_mode && !renderer_started {
                        let r = unsafe { OH_AudioRenderer_Start(renderer) };
                        renderer_started = r == AUDIOSTREAM_SUCCESS;
                    }
                }
            }
            Ok(OhosCommand::SetSkipSilence {
                enabled,
                threshold_db,
                keep_ms,
            }) => {
                skip_state.apply(enabled, threshold_db, keep_ms);
                record_pipeline_diag(&format!(
                    "skip_silence enabled={enabled} thr={threshold_db:.1}dB keep={keep_ms}ms"
                ));
            }
            Ok(OhosCommand::SetNext {
                path,
                stream_cache_url,
                // 头部参数保留以对齐 android 管线签名；ohos 侧在线源不走无缝拼接
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
            Ok(OhosCommand::CancelNext) => {
                if let Ok(mut g) = next_slot.lock() {
                    *g = None;
                }
            }
            Ok(OhosCommand::SetCrossfade(ms)) => {
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
            progress.samples_played.store(0, Ordering::Relaxed);
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
        if pending >= cap_bytes {
            thread::sleep(Duration::from_millis(5));
            continue;
        }

        // 读取一块样本；>2 声道先样本层下混为立体声（对齐桌面端共享模式）
        let block = match buffered.next_block() {
            Some(block) => block,
            None => {
                let played = progress.samples_played.load(Ordering::Relaxed);
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
                        "解码缓冲EOF(已播{played}样本, rate={source_sample_rate}){dec_err}{diag}{panic_note}{cache_note}{}",
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
        // 全关时同样旁路（软解是固定开销，无效果时逐样本 DSP 是纯浪费，
        // 低端机开无损可感知）。音量与限幅始终保留，对齐 android 共享路径
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

        // 格式转换（进度计数在回调侧按消费量累加）
        let mut byte_buf: Vec<u8> = Vec::with_capacity(effected.len() * bytes_per_sample);
        let mut chan_sum = 0.0f32;
        let mut chan_count = 0u32;
        for &sample in &effected {
            push_sample_bytes(&mut byte_buf, sample, device_format);
            chan_sum += sample;
            chan_count += 1;
            if chan_count >= stream_channels as u32 {
                visualizer.push_sample(chan_sum / chan_count as f32);
                chan_sum = 0.0;
                chan_count = 0;
            }
        }

        if let Ok(mut ring) = shared.ring.lock() {
            ring.buf.extend(byte_buf);
        }
    }

    // 9. 清理。running=false 供 Flutter 检测自然结束/异常退出。
    // USB 拉取模式无渲染流：ring 停止产出后外部拉取自然归零。
    running.store(false, Ordering::Relaxed);
    if !usb_mode {
        unsafe {
            if renderer_started {
                OH_AudioRenderer_Stop(renderer);
            }
            OH_AudioRenderer_Release(renderer);
        }
    }
}

// =========================================================================
// USB 拉取模式 FFI（仅 ohos；Dart 侧经 DynamicLibrary 直查符号调用，
// 不走 frb codegen——见 lib/src/player/usb_exclusive_service.dart）
// =========================================================================

/// 当前 USB 拉取会话的环形缓冲句柄（None = 无会话或 OHAudio 共享模式）。
fn usb_shared() -> Option<Arc<PipeShared>> {
    let guard = instance().lock().ok()?;
    guard.as_ref()?.usb_ring.clone()
}

/// 拉取环形缓冲中最多 `cap` 字节（不足不补零），返回实际读取字节数。
/// 读取量即视为已播放量（消费点计数，对齐 OHAudio 写回调语义）；
/// 欠载由调用方补零发送，位置不会虚走。
///
/// # Safety
/// `dst` 须指向调用方分配的 ≥`cap` 字节可写内存；仅在 USB 拉取会话
/// 存续期（startUsbExclusivePlayback 成功后、stop 前）调用。
#[cfg(target_env = "ohos")]
#[no_mangle]
pub extern "C" fn xianyu_ohos_usb_ring_read(dst: *mut u8, cap: usize) -> usize {
    if dst.is_null() || cap == 0 {
        return 0;
    }
    let Some(shared) = usb_shared() else {
        return 0;
    };
    let mut copied = 0usize;
    if let Ok(mut ring) = shared.ring.lock() {
        let take = cap.min(ring.buf.len());
        if take > 0 {
            let (a, b) = ring.buf.as_slices();
            let n_a = take.min(a.len());
            unsafe {
                std::ptr::copy_nonoverlapping(a.as_ptr(), dst, n_a);
                let n_b = (take - n_a).min(b.len());
                if n_b > 0 {
                    std::ptr::copy_nonoverlapping(b.as_ptr(), dst.add(n_a), n_b);
                }
            }
            ring.buf.drain(..take);
        }
        copied = take;
    }
    if copied > 0 {
        let bps = shared.bytes_per_sample.load(Ordering::Relaxed).max(1) as usize;
        shared
            .progress
            .samples_played
            .fetch_add((copied / bps) as u64, Ordering::Relaxed);
    }
    copied
}

/// 环形缓冲当前字节数（0 = 无会话或已耗尽，调用方补零维持时间轴）。
#[cfg(target_env = "ohos")]
#[no_mangle]
pub extern "C" fn xianyu_ohos_usb_ring_level() -> usize {
    usb_shared()
        .and_then(|s| s.ring.lock().ok().map(|r| r.buf.len()))
        .unwrap_or(0)
}

/// 输出格式 JSON（`{"sampleRate":..,"channels":..,"bytesPerSample":..}`），
/// 管线起播后可用。写入调用方缓冲并追加 '\0'，返回写入长度（0 = 未就绪）。
///
/// # Safety
/// `buf` 须指向调用方分配的 ≥`cap` 字节可写内存。
#[cfg(target_env = "ohos")]
#[no_mangle]
pub extern "C" fn xianyu_ohos_usb_format_json(buf: *mut u8, cap: usize) -> usize {
    if buf.is_null() || cap == 0 {
        return 0;
    }
    let Some(shared) = usb_shared() else {
        return 0;
    };
    let rate = shared.progress.sample_rate.load(Ordering::Relaxed);
    let ch = shared.progress.channels.load(Ordering::Relaxed);
    if rate == 0 || ch == 0 {
        return 0;
    }
    let json = serde_json::json!({
        "sampleRate": rate,
        "channels": ch,
        "bytesPerSample": shared.bytes_per_sample.load(Ordering::Relaxed),
    })
    .to_string();
    let bytes = json.as_bytes();
    let n = bytes.len().min(cap - 1);
    unsafe {
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), buf, n);
        *buf.add(n) = 0;
    }
    n
}
