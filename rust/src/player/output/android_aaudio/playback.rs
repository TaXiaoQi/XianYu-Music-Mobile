//! 独占播放状态机：进度/命令通道、控制面 API 与后台播放循环。

use super::*;

pub(crate) struct ExclusiveProgress {
    pub(crate) samples_played: AtomicU64,
    pub(crate) sample_rate: AtomicU32,
    pub(crate) channels: AtomicU32,
    /// 源总时长（毫秒），供 Flutter 侧在 DSP 管线播放时更新进度条。
    duration_ms: AtomicU64,
    /// 跳过静音累计丢弃的交错样本数（与 SilenceSkipProducer 共享同一计数器）。
    /// 位置上报要把它加回去，UI 才停留在原曲时间轴上。
    skipped_samples: Arc<AtomicU64>,
    /// 无缝拼接次数：Dart 轮询到变化即知「已经切到下一首了」。
    transition_seq: AtomicU64,
}

impl ExclusiveProgress {
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

// =========================================================================
// 运行时命令
// =========================================================================

pub(crate) enum ExclusiveCommand {
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
    /// Bit-perfect 直出运行时切换：开启即绕过响度/EQ/音效/音量。
    SetBitPerfect(bool),
    /// 跳过静音运行时切换（开关 + 阈值 + 保留时长），无需重启管线。
    SetSkipSilence {
        enabled: bool,
        threshold_db: f32,
        keep_ms: u32,
    },
    /// 预排下一首：格式与当前流一致时，当前曲 EOF 处直接接上（无缝）。
    SetNext {
        path: String,
        stream_cache_url: Option<String>,
        stream_cache_headers_json: Option<String>,
    },
    /// 取消预排（手动切歌/插队/seek 越界时用）。
    CancelNext,
    /// 设置曲间交叉淡入淡出时长（毫秒，0 = 关闭），运行期可改。
    SetCrossfade(u32),
}

// =========================================================================
// 独占播放控制器
// =========================================================================

pub(crate) struct AndroidExclusivePlayback {
    tx: Sender<ExclusiveCommand>,
    join_handle: Option<thread::JoinHandle<()>>,
    progress: Arc<ExclusiveProgress>,
    device_name: String,
    /// Bit-perfect 直出当前状态（供外部查询，工作线程持有同一 Arc）。
    bit_perfect: Arc<AtomicBool>,
    /// 工作线程是否仍在运行（true=设备连接中且在播放循环内；
    /// false=USB DAC 断开或播放结束已退出，供 Flutter 侧检测热插拔并自动回退）。
    running: Arc<AtomicBool>,
    /// 工作线程退出原因（供 Flutter 侧日志诊断；空=正常 Stop）。
    last_error: Arc<Mutex<Option<String>>>,
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

pub(crate) static INSTANCE: OnceLock<Mutex<Option<AndroidExclusivePlayback>>> = OnceLock::new();

pub(crate) fn instance() -> &'static Mutex<Option<AndroidExclusivePlayback>> {
    INSTANCE.get_or_init(|| Mutex::new(None))
}

// =========================================================================
// 公共 API
// =========================================================================

pub fn start_exclusive_playback(
    mut request: ExclusivePlayRequest,
) -> Result<String, String> {
    // 共享模式（日常 DSP 管线）不涉及 Bit-perfect 直出。
    if request.shared_mode {
        request.bit_perfect = false;
    }
    // SSRF 纵深：HTTP 直链为 IP 字面量且命中禁区时拒绝（对齐桌面端 play_audio
    // 入口校验）。放行本机回环——在线播放的 DSP 管线输入是 Dart 本地回环代理
    // URL（插件头注入/缓存伺服），属进程内合法链路；云元数据/私网等仍拒绝。
    if request.path.starts_with("http://") || request.path.starts_with("https://") {
        crate::security::ssrf::validate_url_ip_literal_allow_loopback(&request.path)
            .map_err(|e| format!("播放链接校验失败: {e}"))?;
    }
    // 先停止已有实例
    stop_exclusive_playback();
    // 清空上一会话的解码线程错误记录
    take_decoder_error();

    let progress = Arc::new(ExclusiveProgress::new());
    let (tx, rx) = mpsc::channel::<ExclusiveCommand>();
    let (init_tx, init_rx) = mpsc::sync_channel::<Result<(String, u32, u16), String>>(1);
    let progress_clone = progress.clone();
    let bit_perfect = Arc::new(AtomicBool::new(request.bit_perfect));
    let bit_perfect_clone = bit_perfect.clone();
    let running = Arc::new(AtomicBool::new(true));
    let running_clone = running.clone();
    let last_error: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));
    let last_error_clone = last_error.clone();

    // 共享模式标记先取出：request 即将整体 move 进播放线程。
    let shared_mode = request.shared_mode;
    // 流缓存直读路径：播放线程需等最小缓冲（≤8s）+ 探测 + 初始 seek 追下载进度，
    // 放宽初始化等待窗口；超时仍由调用方回退 ExoPlayer。
    let stream_cache = request.stream_cache_url.is_some();

    let handle = thread::Builder::new()
        .name("xy-aaudio-exclusive".to_string())
        .spawn(move || {
            run_exclusive_playback(
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

    // 等待初始化结果。共享模式（在线流）需经代理向上游 CDN 拉取探测头，
    // 网络耗时高于本地文件，放宽到 6s；流缓存直读路径（在线直读）含最小
    // 缓冲等待与初始 seek 追下载，放宽到 15s；超时由调用方回退 ExoPlayer。
    let init_wait = if stream_cache {
        Duration::from_secs(15)
    } else if shared_mode {
        Duration::from_secs(6)
    } else {
        Duration::from_secs(3)
    };
    let device_name = match init_rx.recv_timeout(init_wait) {
        Ok(Ok((name, sr, ch))) => {
            progress.sample_rate.store(sr, Ordering::Relaxed);
            progress.channels.store(ch as u32, Ordering::Relaxed);
            name
        }
        Ok(Err(e)) => {
            let _ = handle.join();
            return Err(e);
        }
        Err(_) => {
            let _ = handle.join();
            return Err("AAudio 管线初始化超时".to_string());
        }
    };

    let playback = AndroidExclusivePlayback {
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
            let _ = playback.tx.send(ExclusiveCommand::Stop);
            // join_handle 是 Option<JoinHandle>，用 take() 取出避免从
            // 实现了 Drop 的 AndroidExclusivePlayback 中部分 move 字段。
            if let Some(handle) = playback.join_handle.take() {
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

/// 运行时更新独占管线的音量平衡（ReplayGain）目标增益，平滑渐变不中断播放。
pub fn set_exclusive_volume_balance_gain(gain: f32) {
    if let Ok(guard) = instance().lock() {
        if let Some(playback) = guard.as_ref() {
            let _ = playback.tx.send(ExclusiveCommand::SetVolumeBalanceGain(gain));
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

/// 暂停独占播放（保持进度，等待 resume 恢复）。
pub fn pause_exclusive() {
    if let Ok(guard) = instance().lock() {
        if let Some(playback) = guard.as_ref() {
            let _ = playback.tx.send(ExclusiveCommand::Pause);
        }
    }
}

/// 从暂停恢复独占播放。
pub fn resume_exclusive() {
    if let Ok(guard) = instance().lock() {
        if let Some(playback) = guard.as_ref() {
            let _ = playback.tx.send(ExclusiveCommand::Resume);
        }
    }
}

/// 运行时切换 Bit-perfect 直出。开启时 DSP 全部旁通、音量置 1.0；
/// 关闭时恢复当前响度/EQ/音效/音量。
pub fn set_exclusive_bit_perfect(enabled: bool) {
    if let Ok(guard) = instance().lock() {
        if let Some(playback) = guard.as_ref() {
            let _ = playback.tx.send(ExclusiveCommand::SetBitPerfect(enabled));
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

/// 运行时切换跳过静音（开关 + 阈值 + 保留时长），不需要重启管线。
pub fn set_exclusive_skip_silence(enabled: bool, threshold_db: f32, keep_ms: u32) {
    if let Ok(guard) = instance().lock() {
        if let Some(playback) = guard.as_ref() {
            let _ = playback.tx.send(ExclusiveCommand::SetSkipSilence {
                enabled,
                threshold_db,
                keep_ms,
            });
        }
    }
}

/// 预排下一首用于无缝拼接；格式不一致或准备失败时自动退回普通切歌。
pub fn set_exclusive_next(
    path: String,
    stream_cache_url: Option<String>,
    stream_cache_headers_json: Option<String>,
) {
    if let Ok(guard) = instance().lock() {
        if let Some(playback) = guard.as_ref() {
            let _ = playback.tx.send(ExclusiveCommand::SetNext {
                path,
                stream_cache_url,
                stream_cache_headers_json,
            });
        }
    }
}

/// 取消预排（手动切歌 / 插队 / seek 越界时调用）。
pub fn cancel_exclusive_next() {
    if let Ok(guard) = instance().lock() {
        if let Some(playback) = guard.as_ref() {
            let _ = playback.tx.send(ExclusiveCommand::CancelNext);
        }
    }
}

/// 设置曲间交叉淡入淡出时长（毫秒，0 = 关闭）。运行期可改，不用重启管线。
pub fn set_exclusive_crossfade(ms: u32) {
    if let Ok(guard) = instance().lock() {
        if let Some(playback) = guard.as_ref() {
            let _ = playback.tx.send(ExclusiveCommand::SetCrossfade(ms));
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
                // 位置 = (已输出 + 被跳过的静音) / 帧率：跳过静音后仍是原曲时间轴
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

/// 查询当前独占播放输出设备/格式信息（用于前端展示已选输出）。
/// `active` 反映工作线程真实运行态：USB DAC 拔出或播放结束后为 false，
/// 供前端检测热插拔断开并自动回退到普通播放。
/// 返回 `{"active":bool,"deviceName":String,"sampleRate":u32,"channels":u16,"bitPerfect":bool}` JSON。
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

/// 准备「下一首」的采样来源（无缝拼接用）。
///
/// 目前只处理本地文件与直链：在线源需要 Dart 侧先解析直链并预热流缓存，
/// 未预热时这里不阻塞等待（等不到反而拖慢切歌），直接退回普通切歌。
pub(crate) fn prepare_next_source(
    path: &str,
    stream_cache_url: Option<&str>,
    _stream_cache_headers: Option<&std::collections::HashMap<String, String>>,
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

pub(crate) fn run_exclusive_playback(
    request: ExclusivePlayRequest,
    cmd_rx: Receiver<ExclusiveCommand>,
    init_tx: SyncSender<Result<(String, u32, u16), String>>,
    progress: Arc<ExclusiveProgress>,
    bit_perfect: Arc<AtomicBool>,
    running: Arc<AtomicBool>,
    last_error: Arc<Mutex<Option<String>>>,
) {
    // 诊断残留清零：上一会话的死因注解不得泄入本会话
    reset_pipeline_diag();

    // 1. 加载 AAudio 库
    let lib = match AAudioLib::load() {
        Ok(l) => l,
        Err(e) => {
            let _ = init_tx.send(Err(format!("无法加载 libaaudio.so（需要 Android API 26+）: {e}")));
            return;
        }
    };

    // 1.5 DSD（dsf/dff）原生 DoP 直出：仅当打开「DSD 原生直通」且当前处于
    // Bit-perfect 直出状态才走 DoP 打包（绕过解码器与 DSP，逐帧打包 24-bit）。
    // 关闭直通时 DSD 容器降级为 PCM 解码，走常规 DSP 管线。
    // 共享模式不走 DoP（系统混音器无法透传 DSD）；流缓存直读（在线）同理。
    if request.dsd_native_passthrough
        && !request.shared_mode
        && request.stream_cache_url.is_none()
        && is_dsd_path(&request.path)
    {
        run_dsd_passthrough(
            request,
            lib,
            cmd_rx,
            init_tx,
            progress,
            bit_perfect,
            running,
            last_error,
        );
        return;
    }

    // 1.6 预构建流缓存直读 Reader（在线歌曲对齐桌面端 StreamingTempFile 模型）：
    // 复用/启动 start_streaming_download 下载线程（与 Dart 侧预热按 URL 命中
    // 同一条目，维持单上游连接），等最小缓冲（256KB）就绪后交解码器探测。
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
                // 下载态留档：Seek 诊断与死亡消息可引用，定位断流类死因。
                cache_diag = Some(CacheDiag {
                    downloaded_bytes: state.downloaded_bytes.clone(),
                    download_complete: state.download_complete.clone(),
                    download_failed: state.download_failed.clone(),
                    download_error: state.download_error.clone(),
                });
                cache_state = Some(state.clone());
                // 等待最小缓冲就绪；超时/失败交上层回退 ExoPlayer（代理路径）。
                // 预热命中时这里近乎立即通过。
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

    // 2. 打开 symphonia 解码器（流缓存 Reader / 代理 URL / 本地文件）
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

    // 对齐桌面端策略：共享模式走系统混音器，>2 声道流（伪 6ch 全景声等）
    // 混音器不做声道映射会直接破音，样本层下混为立体声（ITU BS.775）；
    // 独占模式仍按源声道直出（USB DAC 支持时），失败照旧回退。
    let playback_channels: u16 = if request.shared_mode && source_channels > 2 {
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

    // 3. 创建 BufferedSource（后台预读取）
    // 解码器外面套两层：
    //  - SilenceSkipProducer：静音段压到保留时长，位置按「已输出+已跳过」折算；
    //  - QueueProducer：当前曲 EOF 时把预排好的下一首直接接上（无缝拼接）。
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
    // 交叉淡入淡出的共享句柄：时长由 Dart 经运行期命令下发（默认 0 = 只做无缝）
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

    // 5. 装配 DSP 链。
    // Bit-perfect 直出：绕过响度归一化/EQ/音效，音量恒为 1.0，仅保留安全限幅；
    // 仍构造链对象以便运行时关闭直出后无缝恢复。
    let initial_bit_perfect = request.bit_perfect;
    let (mut normalizer, normalizer_handle) = VolumeNormalizer::new(
        if initial_bit_perfect {
            1.0
        } else {
            request.volume_balance_gain
        },
        source_sample_rate,
        playback_channels,
        100,
    );

    let eq_settings: EqualizerSettings = if initial_bit_perfect {
        EqualizerSettings::default()
    } else if request.equalizer_settings_json.is_empty() {
        EqualizerSettings::default()
    } else {
        serde_json::from_str(&request.equalizer_settings_json).unwrap_or_default()
    };
    let eq_handle = Arc::new(EqualizerHandle::new(eq_settings));
    let mut equalizer = Equalizer::new(source_sample_rate, playback_channels, eq_handle.clone());

    let mut sound_effect = SoundEffectBlockProcessor::new(source_sample_rate, playback_channels);
    if !initial_bit_perfect && !request.sound_effect_settings_json.is_empty() {
        if let Ok(se_settings) =
            serde_json::from_str::<SoundEffectSettings>(&request.sound_effect_settings_json)
        {
            sound_effect.set_settings(se_settings);
        }
    }

    // 用户主音量（50ms 渐变消除 zipper noise）+ 最终安全限幅（对齐桌面端链路）。
    let mut user_volume_source = UserVolumeSource::new(request.volume, source_sample_rate);
    let mut clip_guard = ClipGuardSource::new();

    let user_volume = Arc::new(AtomicU32::new(request.volume.to_bits()));
    let is_paused = Arc::new(AtomicBool::new(!request.is_playing));

    // 6. 创建 AAudio 流。
    // 共享模式：SHARED 共享流走系统混音器（全效果链生效），输出到所选设备
    //（-1 = 系统默认设备，对齐桌面端共享模式可选输出设备）。
    // 独占 Bit-perfect 时优先按源位深协商整数格式（≤16bit→Int16，>16bit→Int24，
    // 深层浮点回退），实现「按源位深整数直出」；常规独占仍 Float32→Int16。
    let (stream, device_format, stream_sample_rate, stream_channels) = if request.shared_mode {
        match create_aaudio_stream(&lib, request.device_id, source_sample_rate, playback_channels, true) {
            Ok(result) => result,
            Err(e) => {
                let _ = init_tx.send(Err(e));
                return;
            }
        }
    } else if initial_bit_perfect {
        let depth = probe_source_bit_depth(&request.path);
        match create_aaudio_stream_bitperfect(
            &lib,
            request.device_id,
            source_sample_rate,
            source_channels,
            depth,
        ) {
            Ok(result) => result,
            Err(e) => {
                let _ = init_tx.send(Err(e));
                return;
            }
        }
    } else {
        match create_aaudio_stream(&lib, request.device_id, source_sample_rate, source_channels, false)
        {
            Ok(result) => result,
            Err(e) => {
                let _ = init_tx.send(Err(e));
                return;
            }
        }
    };

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

    // 7. 启动流
    let start_result = unsafe { (lib.stream_request_start)(stream) };
    if start_result != AAUDIO_OK {
        let msg = unsafe { lib.result_text(start_result) };
        let _ = init_tx.send(Err(format!("AAudio 启动失败: {msg}")));
        unsafe { (lib.stream_close)(stream) };
        return;
    }

    // 8. 通知初始化成功
    let device_name = if request.shared_mode {
        format!(
            "系统混音器 ({}Hz, {}ch shared){}",
            stream_sample_rate,
            stream_channels,
            if downmix_active {
                format!(" {}ch→2ch 下混", source_channels)
            } else {
                String::new()
            }
        )
    } else {
        format!(
            "USB DAC ({}Hz, {}ch, {}bit exclusive)",
            stream_sample_rate,
            stream_channels,
            match device_format {
                DeviceFormat::Float32 => 32,
                DeviceFormat::Int16 => 16,
                DeviceFormat::I24Packed => 24,
            }
        )
    };
    let _ = init_tx.send(Ok((device_name, stream_sample_rate, stream_channels)));

    // 9. 轮询循环
    let timeout_ns: i64 = 20_000_000; // 20ms
    let bytes_per_sample = device_format.bytes_per_sample();
    // 无缝拼接次数（本地镜像），用于把「已切到下一首」通报给 Dart
    let mut last_transition: u64 = 0;

    loop {
        // 检查命令
        match cmd_rx.try_recv() {
            Ok(ExclusiveCommand::Stop) => break,
            Ok(ExclusiveCommand::Seek { time_secs, is_playing }) => {
                let _ = unsafe { (lib.stream_request_pause)(stream) };
                let seek_res = buffered.try_seek(Duration::from_secs_f64(time_secs));
                match &seek_res {
                    Ok(()) => record_pipeline_diag(&format!("seek t={time_secs:.3}s ok=true")),
                    Err(e) => {
                        // 超时/失败也排空陈旧块：生产者（含重建路径）稍后补新
                        // 位置的块，不排空会先回放 seek 前位置的样本。
                        buffered.drain_stale();
                        record_pipeline_diag(&format!(
                            "seek t={time_secs:.3}s ok=false err={e}{}",
                            cache_diag
                                .as_ref()
                                .map(|c| format!(" {}", c.snapshot()))
                                .unwrap_or_default()
                        ));
                    }
                }
                if seek_res.is_ok() {
                    normalizer.reset();
                    equalizer.reset();
                    sound_effect.reset();
                    progress.samples_played.store(
                        (time_secs * source_sample_rate as f64 * playback_channels as f64) as u64,
                        Ordering::Relaxed,
                    );
                    // 位置已改写到新点，跳过的静音计数要一起清零，
                    // 否则位置会被上一段的跳过量抬高。
                    progress.skipped_samples.store(0, Ordering::Relaxed);
                    visualizer.reset();
                }
                is_paused.store(!is_playing, Ordering::Relaxed);
                if is_playing {
                    let _ = unsafe { (lib.stream_request_start)(stream) };
                }
            }
            Ok(ExclusiveCommand::Pause) => {
                let _ = unsafe { (lib.stream_request_pause)(stream) };
                is_paused.store(true, Ordering::Relaxed);
            }
            Ok(ExclusiveCommand::Resume) => {
                is_paused.store(false, Ordering::Relaxed);
                let _ = unsafe { (lib.stream_request_start)(stream) };
            }
            Ok(ExclusiveCommand::SetVolume(vol)) => {
                // Bit-perfect 直出时音量被旁通，仅记录供关闭直出后恢复。
                user_volume.store(vol.to_bits(), Ordering::Relaxed);
            }
            Ok(ExclusiveCommand::SetVolumeBalanceGain(gain)) => {
                // ReplayGain 目标增益：Normalizer 内部 100ms 渐变防爆音。
                normalizer_handle.set_target_gain(gain);
            }
            Ok(ExclusiveCommand::SetEqualizer(settings)) => {
                eq_handle.set_settings(settings);
            }
            Ok(ExclusiveCommand::SetSoundEffect(settings)) => {
                sound_effect.set_settings(settings);
            }
            Ok(ExclusiveCommand::SetBitPerfect(enabled)) => {
                bit_perfect.store(enabled, Ordering::Relaxed);
                if enabled {
                    // 进入直出：清空 DSP 内部状态，避免关闭直出时的历史中间值。
                    normalizer.reset();
                    equalizer.reset();
                    sound_effect.reset();
                    if is_paused.load(Ordering::Relaxed) {
                        let _ = unsafe { (lib.stream_request_start)(stream) };
                    }
                    is_paused.store(false, Ordering::Relaxed);
                }
                // 关闭直出：仅恢复绕过的 DSP 链，不改变暂停状态。
            }
            Ok(ExclusiveCommand::SetSkipSilence {
                enabled,
                threshold_db,
                keep_ms,
            }) => {
                skip_state.apply(enabled, threshold_db, keep_ms);
                record_pipeline_diag(&format!(
                    "skip_silence enabled={enabled} thr={threshold_db:.1}dB keep={keep_ms}ms"
                ));
            }
            Ok(ExclusiveCommand::SetNext {
                path,
                stream_cache_url,
                stream_cache_headers_json,
            }) => {
                // 开解码器是 I/O（本地文件也要读头部），不能在音频线程做：
                // 丢到后台线程准备，就绪后写进交接槽，预读线程到 EOF 时取用。
                let slot = next_slot.clone();
                let skip_state = skip_state.clone();
                let expect_rate = source_sample_rate;
                let expect_channels = source_channels;
                std::thread::spawn(move || {
                    let headers: Option<std::collections::HashMap<String, String>> =
                        stream_cache_headers_json
                            .as_deref()
                            .and_then(|s| serde_json::from_str(s).ok());
                    match prepare_next_source(
                        &path,
                        stream_cache_url.as_deref(),
                        headers.as_ref(),
                        &skip_state,
                    ) {
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
                                // 格式不一致只能普通切歌：不放槽，Dart 走曲终流程
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
            Ok(ExclusiveCommand::CancelNext) => {
                if let Ok(mut g) = next_slot.lock() {
                    *g = None;
                }
            }
            Ok(ExclusiveCommand::SetCrossfade(ms)) => {
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

        // 检查可写空间
        let available = unsafe { lib.available_frames(stream) };
        if available <= 0 {
            thread::sleep(Duration::from_millis(5));
            continue;
        }

        // 读取一块样本；共享模式多声道先在样本层下混为立体声（对齐桌面端）
        let block = match buffered.next_block() {
            Some(block) => block,
            None => {
                // EOF：区分「播完自然结束」与「解码/拉流从未产出数据」
                let played = progress.samples_played.load(Ordering::Relaxed);
                let dec_err = take_decoder_error()
                    .map(|e| format!(" ← 解码线程死因: {e}"))
                    .unwrap_or_default();
                let diag = {
                    let d = take_pipeline_diag();
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
                set_exit_reason!(last_error, format!(
                    "解码缓冲EOF(已播{played}样本, rate={source_sample_rate}){dec_err}{diag}{panic_note}{cache_note}{}",
                    if played == 0 { " ← 从未产出数据，拉流/解码失败" } else { "" }
                ));
                break;
            }
        };
        let block = if downmix_active {
            crate::player::channel_downmix::downmix_block(&block, source_channels)
        } else {
            block
        };

        // DSP 链处理。Bit-perfect 直出：绕过响度/EQ/音效/主音量，仅保留安全限幅（对齐桌面端）。
        let do_bypass = bit_perfect.load(Ordering::Relaxed);
        let mut effected = if do_bypass {
            block
        } else {
            let normalized = normalizer.process_block(&block);
            let eq_applied = equalizer.process_block(&normalized);
            sound_effect.process_block(eq_applied)
        };

        // 用户音量渐变（直出时旁通，对齐桌面端 bit-perfect 分支）+ 最终安全限幅。
        if !do_bypass {
            user_volume_source.process_block(&mut effected, playback_channels, &user_volume);
        }
        clip_guard.process_block(&mut effected);

        // 格式转换（音量/限幅已在缓冲级应用）
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
            set_exit_reason!(last_error, format!(
                "stream_write错误({} 已播{}样本)",
                unsafe { lib.result_text(frames_written as i32) },
                progress.samples_played.load(Ordering::Relaxed)
            ));
            break;
        }

        // 如果写入的帧数少于请求的帧数，等待一下
        if frames_written < (effected.len() / stream_channels as usize) as i64 {
            thread::sleep(Duration::from_millis(5));
        }
    }

    // 10. 清理。设置 running=false 供 Flutter 检测设备断开/自然结束，
    // 仅在工作线程真正退出时置位（Stop 命令 / USB DAC 拔出 / EOF）。
    running.store(false, Ordering::Relaxed);
    unsafe {
        (lib.stream_request_stop)(stream);
        (lib.stream_close)(stream);
    }
}
