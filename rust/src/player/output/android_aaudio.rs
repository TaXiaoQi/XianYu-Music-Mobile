//! AAudio 独占模式实现（仅 Android）。
//!
//! 移植自 RawS `native_audio_engine.cpp` 的 AAudio DIRECT 路径：
//! - `AAUDIO_SHARING_MODE_EXCLUSIVE` 绕过 Android 混音器
//! - `setDeviceId` 路由到 USB DAC
//! - 浮点 32bit / Int16 双格式协商
//! - 失败时返回明确错误，供调用方降级到 `just_audio`
//!
//! 动态加载 `libaaudio.so`（API 26+），低版本自动降级。

#![allow(dead_code)]

use crate::player::buffered_source::{BlockProducer, BufferedSource};
use crate::player::equalizer::{Equalizer, EqualizerHandle, EqualizerSettings};
use crate::player::loudness::VolumeNormalizer;
use crate::player::sound_effect::{SoundEffectBlockProcessor, SoundEffectSettings};
use crate::player::types::global_visualizer;
use crate::player::qmc2::{looks_like_qmc_encrypted, extract_ekey_from_footer, QmcCrypto, QmcDecryptReader};
use std::io::{Read, Seek, SeekFrom};
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver, Sender, SyncSender};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;
use std::time::Duration;

// =========================================================================
// AAudio FFI 常量
// =========================================================================

const AAUDIO_OK: i32 = 0;
const AAUDIO_ERROR_TIMEOUT: i32 = -13;
const AAUDIO_SHARING_MODE_EXCLUSIVE: i32 = 0;
const AAUDIO_SHARING_MODE_SHARED: i32 = 1;
const AAUDIO_FORMAT_INVALID: i32 = 0;
const AAUDIO_FORMAT_PCM_I16: i32 = 1;
const AAUDIO_FORMAT_PCM_FLOAT: i32 = 2;
const AAUDIO_PERFORMANCE_MODE_LOW_LATENCY: i32 = 4;
const AAUDIO_DIRECTION_OUTPUT: i32 = 0;

// =========================================================================
// AAudio FFI 类型
// =========================================================================

type AAudioStream = std::os::raw::c_void;
type AAudioStreamBuilder = std::os::raw::c_void;

// 函数指针类型
type FnCreateStreamBuilder = unsafe extern "C" fn(*mut *mut AAudioStreamBuilder) -> i32;
type FnBuilderDelete = unsafe extern "C" fn(*mut AAudioStreamBuilder) -> i32;
type FnBuilderSetDeviceId = unsafe extern "C" fn(*mut AAudioStreamBuilder, i32);
type FnBuilderSetSampleRate = unsafe extern "C" fn(*mut AAudioStreamBuilder, i32);
type FnBuilderSetChannelCount = unsafe extern "C" fn(*mut AAudioStreamBuilder, i32);
type FnBuilderSetFormat = unsafe extern "C" fn(*mut AAudioStreamBuilder, i32);
type FnBuilderSetSharingMode = unsafe extern "C" fn(*mut AAudioStreamBuilder, i32);
type FnBuilderSetPerformanceMode = unsafe extern "C" fn(*mut AAudioStreamBuilder, i32);
type FnBuilderSetBufferCapacity = unsafe extern "C" fn(*mut AAudioStreamBuilder, i32);
type FnBuilderSetDirection = unsafe extern "C" fn(*mut AAudioStreamBuilder, i32);
type FnBuilderOpenStream = unsafe extern "C" fn(*mut AAudioStreamBuilder, *mut *mut AAudioStream) -> i32;
type FnStreamRequestStart = unsafe extern "C" fn(*mut AAudioStream) -> i32;
type FnStreamRequestPause = unsafe extern "C" fn(*mut AAudioStream) -> i32;
type FnStreamRequestStop = unsafe extern "C" fn(*mut AAudioStream) -> i32;
type FnStreamClose = unsafe extern "C" fn(*mut AAudioStream) -> i32;
type FnStreamWrite = unsafe extern "C" fn(*mut AAudioStream, *const std::os::raw::c_void, i32, i64) -> i64;
type FnStreamGetAvailableFrames = unsafe extern "C" fn(*mut AAudioStream) -> i32;
type FnStreamGetXRunCount = unsafe extern "C" fn(*mut AAudioStream) -> i32;
type FnStreamGetSampleRate = unsafe extern "C" fn(*mut AAudioStream) -> i32;
type FnStreamGetChannelCount = unsafe extern "C" fn(*mut AAudioStream) -> i32;
type FnStreamGetFormat = unsafe extern "C" fn(*mut AAudioStream) -> i32;
type FnStreamGetBufferSize = unsafe extern "C" fn(*mut AAudioStream) -> i32;
type FnStreamGetTimestamp = unsafe extern "C" fn(
    *mut AAudioStream,
    *mut std::os::raw::c_int,
    *mut i64,
    *mut i64,
) -> i32;
type FnConvertResultToText = unsafe extern "C" fn(i32) -> *const std::os::raw::c_char;

/// 动态加载的 AAudio 函数表。
struct AAudioLib {
    _handle: *mut std::os::raw::c_void,
    create_stream_builder: FnCreateStreamBuilder,
    builder_delete: FnBuilderDelete,
    builder_set_device_id: FnBuilderSetDeviceId,
    builder_set_sample_rate: FnBuilderSetSampleRate,
    builder_set_channel_count: FnBuilderSetChannelCount,
    builder_set_format: FnBuilderSetFormat,
    builder_set_sharing_mode: FnBuilderSetSharingMode,
    builder_set_performance_mode: FnBuilderSetPerformanceMode,
    builder_set_buffer_capacity: FnBuilderSetBufferCapacity,
    builder_set_direction: FnBuilderSetDirection,
    builder_open_stream: FnBuilderOpenStream,
    stream_request_start: FnStreamRequestStart,
    stream_request_pause: FnStreamRequestPause,
    stream_request_stop: FnStreamRequestStop,
    stream_close: FnStreamClose,
    stream_write: FnStreamWrite,
    stream_get_available_frames: FnStreamGetAvailableFrames,
    stream_get_xrun_count: FnStreamGetXRunCount,
    stream_get_sample_rate: FnStreamGetSampleRate,
    stream_get_channel_count: FnStreamGetChannelCount,
    stream_get_format: FnStreamGetFormat,
    stream_get_buffer_size: FnStreamGetBufferSize,
    stream_get_timestamp: FnStreamGetTimestamp,
    convert_result_to_text: FnConvertResultToText,
}

unsafe impl Send for AAudioLib {}

impl AAudioLib {
    /// 动态加载 libaaudio.so。失败返回 None（API < 26 或库损坏）。
    fn load() -> Option<Self> {
        unsafe {
            let name = b"libaaudio.so\0".as_ptr();
            let handle = libc::dlopen(name as *const _, libc::RTLD_NOW);
            if handle.is_null() {
                return None;
            }

            macro_rules! sym {
                ($name:expr, $type:ty) => {
                    {
                        let sym_name = concat!($name, "\0").as_ptr();
                        let ptr = libc::dlsym(handle, sym_name as *const _);
                        if ptr.is_null() {
                            libc::dlclose(handle);
                            return None;
                        }
                        std::mem::transmute::<*mut std::os::raw::c_void, $type>(ptr)
                    }
                };
            }

            let lib = Self {
                _handle: handle,
                create_stream_builder: sym!("AAudio_createStreamBuilder", FnCreateStreamBuilder),
                builder_delete: sym!("AAudioStreamBuilder_delete", FnBuilderDelete),
                builder_set_device_id: sym!("AAudioStreamBuilder_setDeviceId", FnBuilderSetDeviceId),
                builder_set_sample_rate: sym!("AAudioStreamBuilder_setSampleRate", FnBuilderSetSampleRate),
                builder_set_channel_count: sym!("AAudioStreamBuilder_setChannelCount", FnBuilderSetChannelCount),
                builder_set_format: sym!("AAudioStreamBuilder_setFormat", FnBuilderSetFormat),
                builder_set_sharing_mode: sym!("AAudioStreamBuilder_setSharingMode", FnBuilderSetSharingMode),
                builder_set_performance_mode: sym!("AAudioStreamBuilder_setPerformanceMode", FnBuilderSetPerformanceMode),
                builder_set_buffer_capacity: sym!("AAudioStreamBuilder_setBufferCapacityInFrames", FnBuilderSetBufferCapacity),
                builder_set_direction: sym!("AAudioStreamBuilder_setDirection", FnBuilderSetDirection),
                builder_open_stream: sym!("AAudioStreamBuilder_openStream", FnBuilderOpenStream),
                stream_request_start: sym!("AAudioStream_requestStart", FnStreamRequestStart),
                stream_request_pause: sym!("AAudioStream_requestPause", FnStreamRequestPause),
                stream_request_stop: sym!("AAudioStream_requestStop", FnStreamRequestStop),
                stream_close: sym!("AAudioStream_close", FnStreamClose),
                stream_write: sym!("AAudioStream_write", FnStreamWrite),
                stream_get_available_frames: sym!("AAudioStream_getAvailableFrames", FnStreamGetAvailableFrames),
                stream_get_xrun_count: sym!("AAudioStream_getXRunCount", FnStreamGetXRunCount),
                stream_get_sample_rate: sym!("AAudioStream_getSampleRate", FnStreamGetSampleRate),
                stream_get_channel_count: sym!("AAudioStream_getChannelCount", FnStreamGetChannelCount),
                stream_get_format: sym!("AAudioStream_getFormat", FnStreamGetFormat),
                stream_get_buffer_size: sym!("AAudioStream_getBufferSizeInFrames", FnStreamGetBufferSize),
                stream_get_timestamp: sym!("AAudioStream_getTimestamp", FnStreamGetTimestamp),
                convert_result_to_text: sym!("AAudio_convertResultToText", FnConvertResultToText),
            };
            Some(lib)
        }
    }

    unsafe fn result_text(&self, result: i32) -> String {
        let ptr = (self.convert_result_to_text)(result);
        if ptr.is_null() {
            return format!("AAudio error {}", result);
        }
        let cstr = std::ffi::CStr::from_ptr(ptr);
        cstr.to_string_lossy().into_owned()
    }
}

// =========================================================================
// 设备格式
// =========================================================================

#[derive(Clone, Copy, PartialEq)]
enum DeviceFormat {
    Float32,
    Int16,
}

impl DeviceFormat {
    fn aaudio_format(self) -> i32 {
        match self {
            Self::Float32 => AAUDIO_FORMAT_PCM_FLOAT,
            Self::Int16 => AAUDIO_FORMAT_PCM_I16,
        }
    }

    fn bytes_per_sample(self) -> usize {
        match self {
            Self::Float32 => 4,
            Self::Int16 => 2,
        }
    }
}

/// f32 → 设备格式字节（小端 LE）。
fn push_sample_bytes(buf: &mut Vec<u8>, sample: f32, fmt: DeviceFormat) {
    let clamped = sample.clamp(-1.0, 1.0);
    match fmt {
        DeviceFormat::Float32 => {
            buf.extend_from_slice(&clamped.to_le_bytes());
        }
        DeviceFormat::Int16 => {
            let val = (clamped * 32767.0) as i16;
            buf.extend_from_slice(&val.to_le_bytes());
        }
    }
}

// =========================================================================
// Symphonia 解码器（BlockProducer）
// =========================================================================

struct SymphoniaDecoder {
    format_reader: Box<dyn symphonia::core::formats::FormatReader>,
    decoder: Box<dyn symphonia::core::codecs::Decoder>,
    track_id: u32,
    sample_rate: u32,
    channels: u16,
    total_duration: Option<Duration>,
    sample_buf: Option<symphonia::core::audio::RawSampleBuffer<f32>>,
    sample_buf_frames: usize,
    leftover: Vec<f32>,
    eof: bool,
}

impl SymphoniaDecoder {
    fn open(path: &str) -> Result<Self, String> {
        use symphonia::core::codecs::{CODEC_TYPE_NULL, DecoderOptions};
        use symphonia::core::formats::FormatOptions;
        use symphonia::core::io::MediaSourceStream;
        use symphonia::core::meta::MetadataOptions;
        use symphonia::core::probe::Hint;

        let mut file = std::fs::File::open(path).map_err(|e| e.to_string())?;

        // 检查 QMC2 加密
        let mut header = [0u8; 8];
        let header_len = file.read(&mut header).unwrap_or(0);
        file.seek(SeekFrom::Start(0)).map_err(|e| e.to_string())?;

        let is_qmc = header_len >= 4 && looks_like_qmc_encrypted(&header[..header_len]);

        // 动态分发：普通文件 vs QMC 解密包装
        let mss: MediaSourceStream = if is_qmc {
            // 读取文件末尾 1024 字节提取 ekey
            let file_size = file.seek(SeekFrom::End(0)).map_err(|e| e.to_string())?;
            let tail_size = (file_size.min(1024)) as usize;
            file.seek(SeekFrom::End(-(tail_size as i64))).map_err(|e| e.to_string())?;
            let mut tail = vec![0u8; tail_size];
            file.read_exact(&mut tail).ok();
            file.seek(SeekFrom::Start(0)).map_err(|e| e.to_string())?;

            let crypto = if let Some(ekey) = extract_ekey_from_footer(&tail) {
                QmcCrypto::from_ekey(&ekey).unwrap_or_else(|_| QmcCrypto::qmc1())
            } else {
                QmcCrypto::qmc1()
            };
            let reader = QmcDecryptReader::new(file, crypto);
            MediaSourceStream::new(Box::new(reader), Default::default())
        } else {
            MediaSourceStream::new(Box::new(file), Default::default())
        };

        let mut hint = Hint::new();
        if let Some(ext) = std::path::Path::new(path).extension().and_then(|e| e.to_str()) {
            hint.with_extension(ext);
        }

        let probed = symphonia::default::get_probe()
            .format(&hint, mss, &FormatOptions::default(), &MetadataOptions::default())
            .map_err(|e| e.to_string())?;

        let track = probed
            .format
            .tracks()
            .iter()
            .find(|t| t.codec_params.codec != CODEC_TYPE_NULL)
            .ok_or("未找到音频轨道")?;

        let track_id = track.id;
        let sample_rate = track.codec_params.sample_rate.unwrap_or(44100);
        let channels = track
            .codec_params
            .channels
            .map(|c| c.count())
            .unwrap_or(2) as u16;

        let total_duration = track
            .codec_params
            .time_base
            .and_then(|tb| track.codec_params.n_frames.map(|n| tb.calc_time(n)))
            .map(|t| Duration::from_secs(t.seconds));

        let decoder = symphonia::default::get_codecs()
            .make(&track.codec_params, &DecoderOptions::default())
            .map_err(|e| e.to_string())?;

        Ok(Self {
            format_reader: probed.format,
            decoder,
            track_id,
            sample_rate,
            channels,
            total_duration,
            sample_buf: None,
            sample_buf_frames: 0,
            leftover: Vec::new(),
            eof: false,
        })
    }
}

impl BlockProducer for SymphoniaDecoder {
    fn produce(&mut self, max_samples: usize) -> Option<Vec<f32>> {
        if self.eof {
            return None;
        }

        // 先消费上次剩余的样本
        if !self.leftover.is_empty() {
            let take = self.leftover.len().min(max_samples);
            let out = self.leftover.drain(..take).collect::<Vec<_>>();
            return Some(out);
        }

        use symphonia::core::audio::RawSampleBuffer;

        loop {
            let packet = match self.format_reader.next_packet() {
                Ok(p) => p,
                Err(symphonia::core::errors::Error::ResetRequired) => {
                    self.decoder.reset();
                    continue;
                }
                Err(symphonia::core::errors::Error::IoError(ref e))
                    if e.kind() == std::io::ErrorKind::UnexpectedEof =>
                {
                    self.eof = true;
                    return None;
                }
                Err(_) => {
                    self.eof = true;
                    return None;
                }
            };

            let decoded = match self.decoder.decode(&packet) {
                Ok(d) => d,
                Err(_) => continue,
            };

            let frames = decoded.frames();
            if frames == 0 {
                continue;
            }

            let spec = *decoded.spec();
            if self.sample_buf.is_none() || self.sample_buf_frames < frames {
                self.sample_buf = Some(RawSampleBuffer::<f32>::new(frames as u64, spec));
                self.sample_buf_frames = frames;
            }

            if let Some(ref mut buf) = self.sample_buf {
                buf.copy_interleaved_ref(&decoded);
                let samples = buf.samples().to_vec();
                if samples.len() > max_samples {
                    self.leftover = samples[max_samples..].to_vec();
                    return Some(samples[..max_samples].to_vec());
                }
                return Some(samples);
            }
        }
    }

    fn try_seek(&mut self, pos: Duration) -> Result<(), String> {
        use symphonia::core::formats::{SeekMode, SeekTo};
        use symphonia::core::units::Time;

        let seek_to = SeekTo::Time {
            time: Time::new(pos.as_secs(), 0.0),
            track_id: Some(self.track_id),
        };

        self.format_reader
            .seek(SeekMode::Accurate, seek_to)
            .map_err(|e| e.to_string())?;

        self.decoder.reset();
        self.leftover.clear();
        self.eof = false;
        Ok(())
    }
}

// =========================================================================
// 进度跟踪
// =========================================================================

struct ExclusiveProgress {
    samples_played: AtomicU64,
    sample_rate: AtomicU32,
    channels: AtomicU32,
}

impl ExclusiveProgress {
    fn new() -> Self {
        Self {
            samples_played: AtomicU64::new(0),
            sample_rate: AtomicU32::new(0),
            channels: AtomicU32::new(0),
        }
    }
}

// =========================================================================
// 运行时命令
// =========================================================================

enum ExclusiveCommand {
    Seek {
        time_secs: f64,
        is_playing: bool,
    },
    Stop,
    SetVolume(f32),
    SetEqualizer(EqualizerSettings),
    SetSoundEffect(SoundEffectSettings),
}

// =========================================================================
// 独占播放控制器
// =========================================================================

struct AndroidExclusivePlayback {
    tx: Sender<ExclusiveCommand>,
    join_handle: Option<thread::JoinHandle<()>>,
    progress: Arc<ExclusiveProgress>,
    device_name: String,
}

impl Drop for AndroidExclusivePlayback {
    fn drop(&mut self) {
        let _ = self.tx.send(ExclusiveCommand::Stop);
        if let Some(handle) = self.join_handle.take() {
            let _ = handle.join();
        }
    }
}

// =========================================================================
// 全局实例
// =========================================================================

static INSTANCE: OnceLock<Mutex<Option<AndroidExclusivePlayback>>> = OnceLock::new();

fn instance() -> &'static Mutex<Option<AndroidExclusivePlayback>> {
    INSTANCE.get_or_init(|| Mutex::new(None))
}

// =========================================================================
// 公共 API
// =========================================================================

pub fn start_exclusive_playback(
    request: super::ExclusivePlayRequest,
) -> Result<String, String> {
    // 先停止已有实例
    stop_exclusive_playback();

    let progress = Arc::new(ExclusiveProgress::new());
    let (tx, rx) = mpsc::channel::<ExclusiveCommand>();
    let (init_tx, init_rx) = mpsc::sync_channel::<Result<(String, u32, u16), String>>(1);
    let progress_clone = progress.clone();

    let handle = thread::Builder::new()
        .name("xy-aaudio-exclusive".to_string())
        .spawn(move || {
            run_exclusive_playback(request, rx, init_tx, progress_clone);
        })
        .map_err(|e| e.to_string())?;

    // 等待初始化结果（3s 超时）
    let (device_name, sample_rate, channels) = match init_rx.recv_timeout(Duration::from_secs(3)) {
        Ok(Ok((name, sr, ch))) => {
            progress.sample_rate.store(sr, Ordering::Relaxed);
            progress.channels.store(ch as u32, Ordering::Relaxed);
            (name, sr, ch)
        }
        Ok(Err(e)) => {
            let _ = handle.join();
            return Err(e);
        }
        Err(_) => {
            let _ = handle.join();
            return Err("AAudio 独占模式初始化超时".to_string());
        }
    };

    let playback = AndroidExclusivePlayback {
        tx,
        join_handle: Some(handle),
        progress,
        device_name: device_name.clone(),
    };

    let mut guard = instance().lock().map_err(|e| e.to_string())?;
    *guard = Some(playback);

    Ok(device_name)
}

pub fn stop_exclusive_playback() {
    if let Ok(mut guard) = instance().lock() {
        if let Some(playback) = guard.take() {
            let _ = playback.tx.send(ExclusiveCommand::Stop);
            if let Some(handle) = playback.join_handle {
                let _ = handle.join();
            }
        }
    }
}

pub fn seek_exclusive(time_secs: f64, is_playing: bool) {
    if let Ok(guard) = instance().lock() {
        if let Some(playback) = guard.as_ref() {
            let _ = playback.tx.send(ExclusiveCommand::Seek {
                time_secs,
                is_playing,
            });
        }
    }
}

pub fn set_exclusive_volume(volume: f32) {
    if let Ok(guard) = instance().lock() {
        if let Some(playback) = guard.as_ref() {
            let _ = playback.tx.send(ExclusiveCommand::SetVolume(volume));
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
            let _ = playback.tx.send(ExclusiveCommand::SetEqualizer(settings));
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
            let _ = playback.tx.send(ExclusiveCommand::SetSoundEffect(settings));
        }
    }
    Ok(())
}

pub fn is_exclusive_active() -> bool {
    if let Ok(guard) = instance().lock() {
        guard.is_some()
    } else {
        false
    }
}

pub fn get_exclusive_position_secs() -> f64 {
    if let Ok(guard) = instance().lock() {
        if let Some(playback) = guard.as_ref() {
            let samples = playback.progress.samples_played.load(Ordering::Relaxed);
            let rate = playback.progress.sample_rate.load(Ordering::Relaxed);
            let channels = playback.progress.channels.load(Ordering::Relaxed).max(1);
            if rate > 0 {
                return samples as f64 / (rate as f64 * channels as f64);
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

// =========================================================================
// 工作线程
// =========================================================================

fn run_exclusive_playback(
    request: super::ExclusivePlayRequest,
    cmd_rx: Receiver<ExclusiveCommand>,
    init_tx: SyncSender<Result<(String, u32, u16), String>>,
    progress: Arc<ExclusiveProgress>,
) {
    // 1. 加载 AAudio 库
    let lib = match AAudioLib::load() {
        Some(l) => l,
        None => {
            let _ = init_tx.send(Err("无法加载 libaaudio.so（需要 Android API 26+）".to_string()));
            return;
        }
    };

    // 2. 打开 symphonia 解码器
    let decoder = match SymphoniaDecoder::open(&request.path) {
        Ok(d) => d,
        Err(e) => {
            let _ = init_tx.send(Err(format!("打开音频文件失败: {e}")));
            return;
        }
    };

    let source_sample_rate = decoder.sample_rate;
    let source_channels = decoder.channels;
    let total_duration = decoder.total_duration;

    // 3. 创建 BufferedSource（后台预读取）
    let mut buffered = BufferedSource::new(
        decoder,
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

    // 5. 装配 DSP 链
    let (mut normalizer, _normalizer_handle) =
        VolumeNormalizer::new(request.volume_balance_gain, source_sample_rate, source_channels, 100);

    let eq_settings: EqualizerSettings = if request.equalizer_settings_json.is_empty() {
        EqualizerSettings::default()
    } else {
        serde_json::from_str(&request.equalizer_settings_json).unwrap_or_default()
    };
    let eq_handle = Arc::new(EqualizerHandle::new(eq_settings));
    let mut equalizer = Equalizer::new(source_sample_rate, source_channels, eq_handle);

    let mut sound_effect = SoundEffectBlockProcessor::new(source_sample_rate, source_channels);
    if !request.sound_effect_settings_json.is_empty() {
        if let Ok(se_settings) = serde_json::from_str::<SoundEffectSettings>(&request.sound_effect_settings_json) {
            sound_effect.set_settings(se_settings);
        }
    }

    let user_volume = Arc::new(AtomicU32::new(request.volume.to_bits()));
    let is_paused = Arc::new(AtomicBool::new(!request.is_playing));

    // 6. 创建 AAudio 独占流
    let (stream, device_format, stream_sample_rate, stream_channels) =
        match create_aaudio_stream(&lib, request.device_id, source_sample_rate, source_channels) {
            Ok(result) => result,
            Err(e) => {
                let _ = init_tx.send(Err(e));
                return;
            }
        };

    let effective_rate = sound_effect.effective_sample_rate();
    progress.sample_rate.store(effective_rate, Ordering::Relaxed);
    progress.channels.store(stream_channels as u32, Ordering::Relaxed);
    progress.samples_played.store(
        (request.start_time_secs * source_sample_rate as f64 * source_channels as f64) as u64,
        Ordering::Relaxed,
    );

    let visualizer = global_visualizer();
    visualizer.reset();

    // 7. 启动流
    let start_result = unsafe { (lib.stream_request_start)(stream) };
    if start_result != AAUDIO_OK {
        let msg = unsafe { lib.result_text(start_result) };
        let _ = init_tx.send(Err(format!("AAudio 启动失败: {msg}")));
        unsafe { (lib.stream_close)(stream) };
        return;
    }

    // 8. 通知初始化成功
    let device_name = format!(
        "USB DAC ({}Hz, {}ch, {}bit exclusive)",
        stream_sample_rate,
        stream_channels,
        match device_format {
            DeviceFormat::Float32 => 32,
            DeviceFormat::Int16 => 16,
        }
    );
    let _ = init_tx.send(Ok((device_name, stream_sample_rate, stream_channels)));

    // 9. 轮询循环
    let timeout_ns: i64 = 20_000_000; // 20ms
    let bytes_per_sample = device_format.bytes_per_sample();
    let frame_bytes = bytes_per_sample * stream_channels as usize;

    loop {
        // 检查命令
        match cmd_rx.try_recv() {
            Ok(ExclusiveCommand::Stop) => break,
            Ok(ExclusiveCommand::Seek { time_secs, is_playing }) => {
                let _ = unsafe { (lib.stream_request_pause)(stream) };
                if let Err(e) = buffered.try_seek(Duration::from_secs_f64(time_secs)) {
                    let _ = e;
                }
                normalizer.reset();
                equalizer.reset();
                sound_effect.reset();
                progress.samples_played.store(
                    (time_secs * source_sample_rate as f64 * source_channels as f64) as u64,
                    Ordering::Relaxed,
                );
                visualizer.reset();
                is_paused.store(!is_playing, Ordering::Relaxed);
                if is_playing {
                    let _ = unsafe { (lib.stream_request_start)(stream) };
                }
            }
            Ok(ExclusiveCommand::SetVolume(vol)) => {
                user_volume.store(vol.to_bits(), Ordering::Relaxed);
            }
            Ok(ExclusiveCommand::SetEqualizer(settings)) => {
                eq_handle.set_settings(settings);
            }
            Ok(ExclusiveCommand::SetSoundEffect(settings)) => {
                sound_effect.set_settings(settings);
            }
            Err(mpsc::TryRecvError::Empty) => {}
            Err(mpsc::TryRecvError::Disconnected) => break,
        }

        if is_paused.load(Ordering::Relaxed) {
            thread::sleep(Duration::from_millis(10));
            continue;
        }

        // 检查可写空间
        let available = unsafe { (lib.stream_get_available_frames)(stream) };
        if available <= 0 {
            thread::sleep(Duration::from_millis(5));
            continue;
        }

        // 读取一块样本
        let frames_to_write = available.min(2048) as usize;
        let samples_needed = frames_to_write * source_channels as usize;

        let raw_block = match buffered.next_block() {
            Some(block) => block,
            None => {
                // EOF
                break;
            }
        };

        // DSP 链处理
        let block = if raw_block.len() >= samples_needed {
            raw_block
        } else {
            raw_block
        };

        let normalized = normalizer.process_block(&block);
        let eq_applied = equalizer.process_block(&normalized);
        let effected = sound_effect.process_block(eq_applied);

        // 应用用户音量 + clip guard + 格式转换
        let vol = f32::from_bits(user_volume.load(Ordering::Relaxed));
        let mut byte_buf: Vec<u8> = Vec::with_capacity(effected.len() * bytes_per_sample);

        let mut chan_sum = 0.0f32;
        let mut chan_count = 0u32;

        for &sample in &effected {
            let amplified = sample * vol;
            push_sample_bytes(&mut byte_buf, amplified, device_format);

            chan_sum += amplified;
            chan_count += 1;
            if chan_count >= stream_channels as u32 {
                visualizer.push_sample(chan_sum / chan_count as f32);
                chan_sum = 0.0;
                chan_count = 0;
            }
        }

        progress
            .samples_played
            .fetch_add(effected.len() as u64, Ordering::Relaxed);

        // 写入 AAudio
        let frames_written = unsafe {
            (lib.stream_write)(
                stream,
                byte_buf.as_ptr() as *const std::os::raw::c_void,
                (effected.len() / stream_channels as usize) as i32,
                timeout_ns,
            )
        };

        if frames_written < 0 {
            // 写入错误，可能是设备断开
            break;
        }

        // 如果写入的帧数少于请求的帧数，等待一下
        if frames_written < (effected.len() / stream_channels as usize) as i64 {
            thread::sleep(Duration::from_millis(5));
        }
    }

    // 10. 清理
    unsafe {
        (lib.stream_request_stop)(stream);
        (lib.stream_close)(stream);
    }
}

/// 协商创建 AAudio 独占流。先试 Float32 独占，失败再试 Int16 独占。
fn create_aaudio_stream(
    lib: &AAudioLib,
    device_id: i32,
    sample_rate: u32,
    channels: u16,
) -> Result<(*mut AAudioStream, DeviceFormat, u32, u16), String> {
    let formats = [DeviceFormat::Float32, DeviceFormat::Int16];

    for &fmt in &formats {
        let stream = unsafe { try_open_stream(lib, device_id, sample_rate, channels, fmt) };
        match stream {
            Ok(s) => {
                let actual_rate = unsafe { (lib.stream_get_sample_rate)(s) } as u32;
                let actual_channels = unsafe { (lib.stream_get_channel_count)(s) } as u16;
                return Ok((s, fmt, actual_rate, actual_channels));
            }
            Err(_e) => continue,
        }
    }

    Err("无法创建 AAudio 独占流（设备不支持独占模式或已被占用）".to_string())
}

unsafe fn try_open_stream(
    lib: &AAudioLib,
    device_id: i32,
    sample_rate: u32,
    channels: u16,
    fmt: DeviceFormat,
) -> Result<*mut AAudioStream, String> {
    let mut builder: *mut AAudioStreamBuilder = std::ptr::null_mut();
    let result = (lib.create_stream_builder)(&mut builder);
    if result != AAUDIO_OK || builder.is_null() {
        return Err(lib.result_text(result));
    }

    (lib.builder_set_direction)(builder, AAUDIO_DIRECTION_OUTPUT);
    if device_id >= 0 {
        (lib.builder_set_device_id)(builder, device_id);
    }
    (lib.builder_set_sample_rate)(builder, sample_rate as i32);
    (lib.builder_set_channel_count)(builder, channels as i32);
    (lib.builder_set_format)(builder, fmt.aaudio_format());
    (lib.builder_set_sharing_mode)(builder, AAUDIO_SHARING_MODE_EXCLUSIVE);
    (lib.builder_set_performance_mode)(builder, AAUDIO_PERFORMANCE_MODE_LOW_LATENCY);
    (lib.builder_set_buffer_capacity)(builder, 4096);

    let mut stream: *mut AAudioStream = std::ptr::null_mut();
    let result = (lib.builder_open_stream)(builder, &mut stream);
    (lib.builder_delete)(builder);

    if result != AAUDIO_OK || stream.is_null() {
        return Err(lib.result_text(result));
    }

    // 验证实际格式
    let actual_format = (lib.stream_get_format)(stream);
    if actual_format != fmt.aaudio_format() {
        (lib.stream_close)(stream);
        return Err("设备拒绝了请求的格式".to_string());
    }

    Ok(stream)
}

// =========================================================================
// 测试
// =========================================================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn push_sample_bytes_float32_roundtrip() {
        let mut buf = Vec::new();
        push_sample_bytes(&mut buf, 0.5, DeviceFormat::Float32);
        assert_eq!(buf.len(), 4);
        let val = f32::from_le_bytes([buf[0], buf[1], buf[2], buf[3]]);
        assert!((val - 0.5).abs() < 1e-6);
    }

    #[test]
    fn push_sample_bytes_int16_range() {
        let mut buf = Vec::new();
        push_sample_bytes(&mut buf, 1.0, DeviceFormat::Int16);
        let val = i16::from_le_bytes([buf[0], buf[1]]);
        assert_eq!(val, 32767);

        let mut buf = Vec::new();
        push_sample_bytes(&mut buf, -1.0, DeviceFormat::Int16);
        let val = i16::from_le_bytes([buf[0], buf[1]]);
        assert_eq!(val, -32767);
    }

    #[test]
    fn push_sample_bytes_clamps_overflow() {
        let mut buf = Vec::new();
        push_sample_bytes(&mut buf, 2.0, DeviceFormat::Float32);
        let val = f32::from_le_bytes([buf[0], buf[1], buf[2], buf[3]]);
        assert!((val - 1.0).abs() < 1e-6);
    }

    #[test]
    fn device_format_bytes_per_sample() {
        assert_eq!(DeviceFormat::Float32.bytes_per_sample(), 4);
        assert_eq!(DeviceFormat::Int16.bytes_per_sample(), 2);
    }
}
