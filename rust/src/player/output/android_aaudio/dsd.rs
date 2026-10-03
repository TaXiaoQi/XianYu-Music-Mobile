//! DSD（dsf/dff）DoP 直通输出路径。

use super::*;

/// 是否为 DSD 容器文件（dsf/dff）。
pub(crate) fn is_dsd_path(path: &str) -> bool {
    let lower = path.to_ascii_lowercase();
    lower.ends_with(".dsf") || lower.ends_with(".dff") || lower.ends_with(".dsd")
}

/// 从 URL 提取小写扩展名（去掉 query/fragment），供流式源格式探测。
/// 无扩展名返回 None（此时 symphonia 依赖嗅探）。
pub(crate) fn url_path_extension(url: &str) -> Option<String> {
    let path = url.split(['?', '#']).next()?;
    let file = path.rsplit('/').next()?;
    let ext = file.rsplit('.').next()?;
    if ext.is_empty() || ext.len() == file.len() {
        return None;
    }
    let lower = ext.to_ascii_lowercase();
    // 仅接受合理扩展名形态（字母数字），排除版本号类路径段。
    if !lower.chars().all(|c| c.is_ascii_alphanumeric()) {
        return None;
    }
    Some(lower)
}

/// DSD 原生 DoP 直出：读 1-bit DSD 流按 DoP 1.0 打包成 24-bit 帧，
/// 直接写入支持 DoP 的 DSD-DAC（AAudio 独占 I24），绕过音量/EQ/音效 DSP。
pub(crate) fn run_dsd_passthrough(
    request: ExclusivePlayRequest,
    lib: AAudioLib,
    cmd_rx: Receiver<ExclusiveCommand>,
    init_tx: SyncSender<Result<(String, u32, u16), String>>,
    progress: Arc<ExclusiveProgress>,
    bit_perfect: Arc<AtomicBool>,
    running: Arc<AtomicBool>,
    last_error: Arc<Mutex<Option<String>>>,
) {
    let dsd = match parse_dsd_info(&request.path) {
        Ok(info) => info,
        Err(e) => {
            let _ = init_tx.send(Err(format!("DSD 头解析失败: {e}")));
            return;
        }
    };
    if dsd.is_dst {
        let _ = init_tx.send(Err("DST 压缩 DSD 暂不支持直出，请转未压缩 DSD 后再试".to_string()));
        return;
    }
    let dop_rate = match crate::player::dsd_dop::dop_pcm_rate(dsd.dsd_rate) {
        Some(r) => r,
        None => {
            let _ = init_tx.send(Err(format!("DSD 采样率 {} 不适用于 DoP 打包", dsd.dsd_rate)));
            return;
        }
    };
    let channels = dsd.channels.max(1);

    // 打开 DoP DAC：仅尝试 24-bit packed 独占流。
    let (stream, stream_rate, stream_channels) = match unsafe {
        try_open_stream(&lib, request.device_id, dop_rate, channels, DeviceFormat::I24Packed, false)
    } {
        Ok(s) => {
            let actual_rate = unsafe { (lib.stream_get_sample_rate)(s) } as u32;
            let actual_channels = unsafe { (lib.stream_get_channel_count)(s) } as u16;
            (s, actual_rate, actual_channels)
        }
        Err(e) => {
            let _ = init_tx.send(Err(format!("无法打开 DoP 音频流（{dop_rate}Hz/24bit 独占）: {e}")));
            return;
        }
    };

    let mut dop = match DopStreamSource::open(&request.path, &dsd) {
        Ok(d) => d,
        Err(e) => {
            let _ = init_tx.send(Err(format!("打开 DSD 数据区失败: {e}")));
            unsafe { (lib.stream_close)(stream) };
            return;
        }
    };

    progress.sample_rate.store(dop_rate, Ordering::Relaxed);
    progress.channels.store(stream_channels as u32, Ordering::Relaxed);
    progress.samples_played.store(
        (request.start_time_secs * dop_rate as f64 * stream_channels as f64) as u64,
        Ordering::Relaxed,
    );

    if request.start_time_secs > 0.0 {
        let target = (request.start_time_secs * dop_rate as f64) as u64;
        let _ = dop.seek_to_frame(target);
    }

    let start_result = unsafe { (lib.stream_request_start)(stream) };
    if start_result != AAUDIO_OK {
        let msg = unsafe { lib.result_text(start_result) };
        let _ = init_tx.send(Err(format!("AAudio 启动失败: {msg}")));
        unsafe { (lib.stream_close)(stream) };
        return;
    }

    let device_name = format!(
        "DSD {}/DoP ({}Hz, {}ch, 24bit)",
        dsd.dsd_rate, stream_rate, stream_channels
    );
    let _ = init_tx.send(Ok((device_name, stream_rate, stream_channels)));

    let timeout_ns: i64 = 20_000_000; // 20ms
    let mut is_paused = !request.is_playing;

    loop {
        match cmd_rx.try_recv() {
            Ok(ExclusiveCommand::Stop) => break,
            Ok(ExclusiveCommand::Seek { time_secs, is_playing: play }) => {
                let _ = unsafe { (lib.stream_request_pause)(stream) };
                let target = (time_secs * dop_rate as f64) as u64;
                let _ = dop.seek_to_frame(target);
                is_paused = !play;
                progress.samples_played.store(
                    (time_secs * dop_rate as f64 * stream_channels as f64) as u64,
                    Ordering::Relaxed,
                );
                let _ = if play {
                    unsafe { (lib.stream_request_start)(stream) }
                } else {
                    AAUDIO_OK
                };
            }
            Ok(ExclusiveCommand::Pause) => {
                let _ = unsafe { (lib.stream_request_pause)(stream) };
                is_paused = true;
            }
            Ok(ExclusiveCommand::Resume) => {
                is_paused = false;
                let _ = unsafe { (lib.stream_request_start)(stream) };
            }
            Ok(ExclusiveCommand::SetBitPerfect(_)) => {
                // DSD 原生直出天然 bit-perfect，保持状态开启。
                bit_perfect.store(true, Ordering::Relaxed);
            }
            // DSD 直出下音量、增益、EQ、音效、跳过静音与无缝预排均被绕过，
            // 命令直接忽略（DoP 直通要求样本逐帧对齐，剪静音/拼接都会破坏）。
            Ok(ExclusiveCommand::SetVolume(_))
            | Ok(ExclusiveCommand::SetVolumeBalanceGain(_))
            | Ok(ExclusiveCommand::SetEqualizer(_))
            | Ok(ExclusiveCommand::SetSoundEffect(_))
            | Ok(ExclusiveCommand::SetSkipSilence { .. })
            | Ok(ExclusiveCommand::SetNext { .. })
            | Ok(ExclusiveCommand::CancelNext)
            | Ok(ExclusiveCommand::SetCrossfade(_)) => {}
            Err(mpsc::TryRecvError::Empty) => {}
            Err(mpsc::TryRecvError::Disconnected) => break,
        }

        if is_paused {
            thread::sleep(Duration::from_millis(10));
            continue;
        }

        let available = unsafe { lib.available_frames(stream) };
        if available <= 0 {
            thread::sleep(Duration::from_millis(5));
            continue;
        }

        let max_frames = (available as usize).min(4096);
        let mut dop_buf: Vec<u8> = Vec::with_capacity(max_frames * stream_channels as usize * 3);
        let produced = match dop.next_frames(&mut dop_buf, max_frames) {
            Ok(n) => n,
            Err(e) => {
                set_exit_reason!(last_error, format!("DoP生成错误({e})"));
                break;
            }
        };
        if produced == 0 {
            // EOF
            set_exit_reason!(last_error, format!(
                "DoP EOF(已播{}样本)",
                progress.samples_played.load(Ordering::Relaxed)
            ));
            break;
        }
        progress
            .samples_played
            .fetch_add(produced as u64 * stream_channels as u64, Ordering::Relaxed);

        let written = unsafe {
            (lib.stream_write)(
                stream,
                dop_buf.as_ptr() as *const std::os::raw::c_void,
                produced as i32,
                timeout_ns,
            )
        };
        if written < 0 {
            set_exit_reason!(last_error, format!(
                "DoP stream_write错误({} 已播{}样本)",
                unsafe { lib.result_text(written as i32) },
                progress.samples_played.load(Ordering::Relaxed)
            ));
            break;
        }
        if written < produced as i64 {
            thread::sleep(Duration::from_millis(5));
        }
    }

    running.store(false, Ordering::Relaxed);
    unsafe {
        (lib.stream_request_stop)(stream);
        (lib.stream_close)(stream);
    }
}
