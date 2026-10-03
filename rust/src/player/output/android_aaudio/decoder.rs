//! Symphonia 解码器：封装 FormatReader/Decoder 为 BlockProducer，含流缓存 MediaSource 适配。

use super::*;

// Symphonia 解码器（BlockProducer）
// =========================================================================

pub(crate) struct SymphoniaDecoder {
    format_reader: Box<dyn symphonia::core::formats::FormatReader>,
    decoder: Box<dyn symphonia::core::codecs::Decoder>,
    track_id: u32,
    sample_rate: u32,
    channels: u16,
    total_duration: Option<Duration>,
    sample_buf: Option<symphonia::core::audio::SampleBuffer<f32>>,
    sample_buf_frames: usize,
    leftover: Vec<f32>,
    eof: bool,
    /// 流缓存源持有 state：失败 seek 会污染 symphonia 内部状态（实测后续
    /// packet 直接报 EOF → 管线死亡），持 state 可整体重建解码器续播。
    stream_state: Option<crate::player::stream_cache::StreamingTempFileState>,
    /// 打开时的探测路径（供重建时复用扩展名提示）。
    hint_path: String,
}

/// 流缓存下载状态快照：Seek 诊断与死亡消息用，用于区分「symphonia 层失败」
/// 与「下载线程已死/断流」（真机 DLNA 实测 seek 失败后即 EOF，需看到下载态）。
pub(crate) struct CacheDiag {
    downloaded_bytes: Arc<std::sync::atomic::AtomicU64>,
    download_complete: Arc<AtomicBool>,
    download_failed: Arc<AtomicBool>,
    download_error: Arc<std::sync::Mutex<Option<String>>>,
}

impl CacheDiag {
    fn snapshot(&self) -> String {
        let err = self
            .download_error
            .lock()
            .ok()
            .and_then(|g| g.clone())
            .unwrap_or_default();
        format!(
            "流缓存[dl={}KB done={} fail={} err={}]",
            self.downloaded_bytes.load(Ordering::Relaxed) / 1024,
            self.download_complete.load(Ordering::Relaxed),
            self.download_failed.load(Ordering::Relaxed),
            if err.is_empty() { "-" } else { err.as_str() }
        )
    }
}

/// 流缓存 Reader 的 MediaSource 适配：`Box<dyn ReadSeek>` 不自动实现 Read/Seek
/// 超trait，用具体 newtype 转发以满足 symphonia 的 `MediaSource` blanket impl。
/// `total_shared` 为共享总长槽位（0 = 未知）：symphonia FLAC/MP3 demuxer 的
/// seek 依赖 `byte_len()` 提供二分上界，缺失时报 "stream is not seekable"
/// 导致 DMR/手动 seek 后管线死亡（2026-09-26 实锤）。
pub(crate) struct StreamCacheMediaReader {
    inner: Box<dyn crate::player::stream_cache::ReadSeek + Send + Sync>,
    total_shared: Option<Arc<std::sync::atomic::AtomicU64>>,
}

impl std::io::Read for StreamCacheMediaReader {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        self.inner.read(buf)
    }
}

impl std::io::Seek for StreamCacheMediaReader {
    fn seek(&mut self, pos: std::io::SeekFrom) -> std::io::Result<u64> {
        self.inner.seek(pos)
    }
}

impl symphonia::core::io::MediaSource for StreamCacheMediaReader {
    fn is_seekable(&self) -> bool {
        true
    }

    fn byte_len(&self) -> Option<u64> {
        let v = self
            .total_shared
            .as_ref()
            .map(|t| t.load(std::sync::atomic::Ordering::Relaxed))
            .unwrap_or(0);
        if v == 0 {
            None
        } else {
            Some(v)
        }
    }
}

impl SymphoniaDecoder {
    /// `stream_reader`：预构建的流缓存 Reader（在线直读，对齐桌面端
    /// StreamingTempFile 模型）。Some 时跳过文件/HTTP 源构造，`path` 仅用于
    /// 扩展名探测提示（应为流缓存直链 URL）。
    fn open(
        path: &str,
        stream_reader: Option<Box<dyn crate::player::stream_cache::ReadSeek + Send + Sync>>,
        stream_state: Option<crate::player::stream_cache::StreamingTempFileState>,
    ) -> Result<Self, String> {
        use symphonia::core::codecs::{CODEC_TYPE_NULL, DecoderOptions};
        use symphonia::core::formats::FormatOptions;
        use symphonia::core::io::MediaSourceStream;
        use symphonia::core::meta::MetadataOptions;
        use symphonia::core::probe::Hint;

        // HTTP 流式源（本地回环代理转发的在线歌曲）：跳过本地文件相关检查，
        // 扩展名从 URL 路径提取（去掉 query）供格式探测。
        let is_http = stream_reader.is_none()
            && (path.starts_with("http://") || path.starts_with("https://"));

        let mut hint = Hint::new();
        let mss: MediaSourceStream = if let Some(reader) = stream_reader {
            // 流缓存直读：数据已由下载线程落盘（≥最小缓冲），探测头立即可读
            if let Some(ext) = url_path_extension(path) {
                hint.with_extension(&ext);
            }
            MediaSourceStream::new(
                Box::new(StreamCacheMediaReader {
                    inner: reader,
                    total_shared: stream_state
                        .as_ref()
                        .map(|s| s.content_length_shared.clone()),
                }),
                Default::default(),
            )
        } else if is_http {
            if let Some(ext) = url_path_extension(path) {
                hint.with_extension(&ext);
            }
            let reader = crate::player::http_source::HttpSeekableReader::open(path)?;
            MediaSourceStream::new(Box::new(reader), Default::default())
        } else {
            let mut file = std::fs::File::open(path).map_err(|e| e.to_string())?;

            // 检查 QMC2 加密
            let mut header = [0u8; 8];
            let header_len = file.read(&mut header).unwrap_or(0);
            file.seek(SeekFrom::Start(0)).map_err(|e| e.to_string())?;

            let is_qmc = header_len >= 4 && looks_like_qmc_encrypted(&header[..header_len]);

            // 动态分发：普通文件 vs QMC 解密包装
            if is_qmc {
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
            }
        };

        if !is_http {
            if let Some(ext) = std::path::Path::new(path).extension().and_then(|e| e.to_str()) {
                hint.with_extension(ext);
            }
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
            stream_state,
            hint_path: path.to_string(),
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

        use symphonia::core::audio::SampleBuffer;

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
                    record_decoder_error(&format!(
                        "IO UnexpectedEof(可能是自然EOF，也可能是上游断流): {e} (leftover={})",
                        self.leftover.len()
                    ));
                    self.eof = true;
                    return None;
                }
                Err(e) => {
                    record_decoder_error(&format!("解码器错误: {e}"));
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
                self.sample_buf = Some(SampleBuffer::<f32>::new(frames as u64, spec));
                self.sample_buf_frames = frames;
            }

            if let Some(ref mut buf) = self.sample_buf {
                buf.copy_interleaved_ref(decoded);
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
        // 转发到固有的重建式 seek 实现（方法解析优先命中固有方法）
        SymphoniaDecoder::try_seek(self, pos)
    }
}

impl SymphoniaDecoder {
    /// （非 trait）seek + 重建兜底：symphonia seek 失败且为流缓存源时整体
    /// 重建解码器后重试，避免状态污染导致管线死亡。
    fn try_seek(&mut self, pos: Duration) -> Result<(), String> {
        self.try_seek_inner(pos, true)
    }

    /// `allow_rebuild=false` 供重建后的新解码器复入，防止持久性失败无限递归。
    fn try_seek_inner(&mut self, pos: Duration, allow_rebuild: bool) -> Result<(), String> {
        use symphonia::core::formats::{SeekMode, SeekTo};
        use symphonia::core::units::Time;

        // 越界防护：symphonia WAV 允许 ts==n_frames（seek_pos=data_end_pos），
        // seek 后 next_packet 立即报 end of stream → 生产者退出 → 管线死亡。
        // 钳制在结尾前 250ms，保证 seek 后仍有数据可读。
        let mut pos = pos;
        if let Some(total) = self.total_duration {
            let guard = Duration::from_millis(250);
            if total > guard && pos + guard >= total {
                pos = total - guard;
            }
        }

        let seek_to = SeekTo::Time {
            time: Time::new(pos.as_secs(), 0.0),
            track_id: Some(self.track_id),
        };

        match self.format_reader.seek(SeekMode::Accurate, seek_to) {
            Ok(_seeked) => {
                self.decoder.reset();
                self.leftover.clear();
                self.eof = false;
                Ok(())
            }
            Err(e) => {
                // 失败的 seek 可能污染 symphonia 内部状态（DLNA 真机实测：
                // seek 失败后 next_packet 立即报 end of stream → 管线死亡）。
                // 流缓存源整体重建：新 reader 的 seek 自带「等下载追上目标」
                // 语义，重建后从目标位置续解码；非流缓存源无重建能力，原样上报。
                if !allow_rebuild {
                    return Err(e.to_string());
                }
                let state = self.stream_state.clone().ok_or_else(|| e.to_string())?;
                let fresh_reader = state
                    .new_reader_with_decryption()
                    .map_err(|ie| format!("{e}; 重建reader失败: {ie}"))?;
                let mut fresh = Self::open(&self.hint_path, Some(fresh_reader), Some(state))
                    .map_err(|ie| format!("{e}; 重建解码器失败: {ie}"))?;
                fresh
                    .try_seek_inner(pos, false)
                    .map_err(|ie| format!("{e}; 重建后seek仍失败: {ie}"))?;
                self.format_reader = fresh.format_reader;
                self.decoder = fresh.decoder;
                self.track_id = fresh.track_id;
                self.sample_rate = fresh.sample_rate;
                self.channels = fresh.channels;
                self.total_duration = fresh.total_duration;
                self.sample_buf = None;
                self.sample_buf_frames = 0;
                self.leftover.clear();
                self.eof = false;
                Ok(())
            }
        }
    }
}

// =========================================================================
// 进度跟踪
// =========================================================================

/// 记录/读取解码线程最近一次错误（诊断用：音频线程 EOF 退出时读出，
/// 随 status 的 lastError 上报 Flutter）。Symphonia 把网络读失败与自然
/// EOF 都折叠成 produce()==None，这里负责保留真实死因。
pub(crate) static DECODER_LAST_ERROR: OnceLock<Mutex<Option<String>>> = OnceLock::new();

pub(crate) fn record_decoder_error(msg: &str) {
    let slot = DECODER_LAST_ERROR.get_or_init(|| Mutex::new(None));
    if let Ok(mut guard) = slot.lock() {
        *guard = Some(msg.to_string());
    }
}

pub(crate) fn take_decoder_error() -> Option<String> {
    let slot = DECODER_LAST_ERROR.get_or_init(|| Mutex::new(None));
    slot.lock().ok().and_then(|mut g| g.take())
}
