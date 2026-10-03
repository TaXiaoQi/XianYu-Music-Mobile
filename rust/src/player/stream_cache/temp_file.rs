//! 流式临时文件读取器与状态机：包装缓存文件实现 Read+Seek，读取追上下载进度时阻塞等待。

use super::*;

/// 流式临时文件读取器：包装 File，实现 Read + Seek。
/// 读取位置接近下载进度时阻塞等待，直到数据就绪。
pub struct StreamingTempFileReader {
	file: File,
	downloaded_bytes: Arc<AtomicU64>,
	download_complete: Arc<AtomicBool>,
	download_failed: Arc<AtomicBool>,
	pos: u64,
	total_bytes: Option<u64>,
	/// When true, blocks reads until download thread finishes post-download QMC check/decryption
	post_check_pending: Option<Arc<AtomicBool>>,
}

impl Read for StreamingTempFileReader {
	fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
		loop {
			// Block reads if post-download QMC check/decryption is pending
			if let Some(ref flag) = self.post_check_pending {
				if flag.load(Ordering::Relaxed) {
					if self.download_failed.load(Ordering::Relaxed) {
						return Ok(0);
					}
					std::thread::sleep(Duration::from_millis(3));
					continue;
				}
			}

			let downloaded = self.downloaded_bytes.load(Ordering::Relaxed);
			if self.pos < downloaded {
				let max_read = (downloaded - self.pos).min(buf.len() as u64) as usize;
				let n = self.file.read(&mut buf[..max_read])?;
				self.pos += n as u64;
				return Ok(n);
			}
			if self.download_complete.load(Ordering::Relaxed)
				|| self.download_failed.load(Ordering::Relaxed)
			{
				return Ok(0);
			}
			// 注意：此 read() 在音频回调线程调用（经 rodio Decoder → Source::next()）。
			// 阻塞会导致音频 underrun → 卡音破音。用 3ms 短 sleep 让 cpal 输出缓冲
			// （通常 ≥50ms）能吸收单次等待。配合 timeBeginPeriod(1)（output/shared.rs
			// 初始化时调用）使 Windows sleep 真正达到毫秒精度，否则默认 ~15ms。
			std::thread::sleep(Duration::from_millis(3));
		}
	}
}

impl Seek for StreamingTempFileReader {
	fn seek(&mut self, pos: SeekFrom) -> std::io::Result<u64> {
		let target = match pos {
			SeekFrom::Start(n) => n,
			SeekFrom::Current(n) => (self.pos as i64 + n).max(0) as u64,
			SeekFrom::End(n) => {
				if self.total_bytes.is_some() || self.download_complete.load(Ordering::Relaxed) {
					return self.file.seek(SeekFrom::End(n)).map(|p| {
						self.pos = p;
						p
					});
				}
				return Err(std::io::Error::new(
					std::io::ErrorKind::Unsupported,
					"Cannot seek from end while download is in progress",
				));
			}
		};

		loop {
			let downloaded = self.downloaded_bytes.load(Ordering::Relaxed);
			if target < downloaded
				|| self.download_complete.load(Ordering::Relaxed)
				|| self.download_failed.load(Ordering::Relaxed)
			{
				self.pos = target;
				return self.file.seek(SeekFrom::Start(target)).map(|_| target);
			}
			// seek 通常在暂停态调用，阻塞影响小；仍用 3ms 短 sleep 保持一致。
			std::thread::sleep(Duration::from_millis(3));
		}
	}
}

/// 流式临时文件状态：在 AudioSource 中传递，设备切换恢复时重建 reader。
#[derive(Clone)]
pub struct StreamingTempFileState {
	pub path: String,
	pub downloaded_bytes: Arc<AtomicU64>,
	pub download_complete: Arc<AtomicBool>,
	pub download_failed: Arc<AtomicBool>,
	pub total_bytes: Option<u64>,
	/// QMC2 ekey (if provided by the plugin or extracted from JSON response).
	/// 使用 Arc<Mutex> 允许 download_thread 在运行时从 JSON 响应中提取并更新 ekey。
	pub ekey: Arc<std::sync::Mutex<Option<String>>>,
	/// CENC 内容密钥（汽水音乐等音源加密音轨），由插件从 PlayAuth 解密得到。
	/// 由播放/插件侧在解析歌曲时写入，供 new_reader_with_decryption 包装 CencDecryptReader。
	pub cek: Arc<std::sync::Mutex<Option<String>>>,
	/// CENC 流式解密元数据（moov 在文件头部时提前解析，供 reader 包装解密）
	pub cenc_metadata: Arc<std::sync::Mutex<Option<crate::player::cenc::CencMetadata>>>,
	/// CENC 流式解密是否已激活（true = reader 用 CencDecryptReader，false = 需整文件解密）
	pub cenc_streaming: Arc<AtomicBool>,
	/// When Some(true), blocks reads until download thread finishes post-download QMC check/decryption
	pub post_check_pending: Option<Arc<AtomicBool>>,
	/// 下载失败原因（供前端诊断）
	pub download_error: Arc<std::sync::Mutex<Option<String>>>,
	/// 共享总长槽位（字节，0 = 未知）：下载线程拿到 Content-Length 后实时回填。
	/// `total_bytes` 是 Clone 时刻快照（start_streaming_download 返回时必然 None），
	/// symphonia FLAC/MP3 demuxer 的 seek 依赖 `MediaSource::byte_len()`，必须实时可读。
	pub content_length_shared: Arc<AtomicU64>,
}

impl std::fmt::Debug for StreamingTempFileState {
	fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
		f.debug_struct("StreamingTempFileState")
			.field("path", &self.path)
			.field(
				"downloaded_bytes",
				&self.downloaded_bytes.load(Ordering::Relaxed),
			)
			.field(
				"download_complete",
				&self.download_complete.load(Ordering::Relaxed),
			)
			.field(
				"download_failed",
				&self.download_failed.load(Ordering::Relaxed),
			)
			.field("total_bytes", &self.total_bytes)
			.field(
				"ekey",
				&self.ekey.lock().map(|e| e.is_some()).unwrap_or(false),
			)
			.field(
				"cek",
				&self.cek.lock().map(|c| c.is_some()).unwrap_or(false),
			)
			.field(
				"cenc_streaming",
				&self.cenc_streaming.load(Ordering::Relaxed),
			)
			.finish()
	}
}

impl StreamingTempFileState {
	pub fn new_reader(&self) -> std::io::Result<StreamingTempFileReader> {
		let file = File::open(&self.path)?;
		Ok(StreamingTempFileReader {
			file,
			downloaded_bytes: self.downloaded_bytes.clone(),
			download_complete: self.download_complete.clone(),
			download_failed: self.download_failed.clone(),
			pos: 0,
			total_bytes: self.total_bytes,
			post_check_pending: self.post_check_pending.clone(),
		})
	}

	/// Returns the ekey for QMC2 decryption, if available.
	pub fn ekey(&self) -> Option<String> {
		self.ekey.lock().ok().and_then(|e| e.clone())
	}

	/// Returns the cek for CENC decryption, if available.
	pub fn cek(&self) -> Option<String> {
		self.cek.lock().ok().and_then(|c| c.clone())
	}

	/// 创建 reader，根据加密类型自动包装解密层：
	/// - CENC 流式：CencDecryptReader（moov 在头部时，按样本 AES-CTR 流式解密 + 虚拟 enca→mp4a 补丁）
	/// - QMC 流式：QmcDecryptReader（纯位置流密码，任意位置独立解密）
	/// - 无加密：裸 StreamingTempFileReader
	pub fn new_reader_with_decryption(
		&self,
	) -> std::io::Result<Box<dyn ReadSeek + Send + Sync + 'static>> {
		let reader = self.new_reader()?;

		// CENC 流式解密：moov 在头部时已由下载线程预解析元数据
		if self.cenc_streaming.load(Ordering::Relaxed) {
			if let Ok(md_lock) = self.cenc_metadata.lock() {
				if let Some(ref metadata) = *md_lock {
					if let Some(cek_str) = self.cek() {
						if let Ok(key) = crate::player::cenc::cek_to_key(&cek_str) {
							return Ok(Box::new(crate::player::cenc::CencDecryptReader::new(
								reader,
								key,
								metadata.clone(),
							)));
						}
					}
				}
			}
		}

		// QMC 流式解密
		let ekey = self.ekey();
		if let Some(ekey_str) = ekey {
			match crate::player::qmc2::QmcCrypto::from_ekey(&ekey_str) {
				Ok(crypto) => Ok(Box::new(crate::player::qmc2::QmcDecryptReader::new(
					reader, crypto,
				))),
				Err(_) => Ok(Box::new(reader)),
			}
		} else {
			Ok(Box::new(reader))
		}
	}

	pub fn is_download_finished(&self) -> bool {
		self.download_complete.load(Ordering::Relaxed) || self.download_failed.load(Ordering::Relaxed)
	}

	pub fn downloaded_bytes(&self) -> u64 {
		self.downloaded_bytes.load(Ordering::Relaxed)
	}

	/// 返回下载失败原因（供前端诊断）
	pub fn download_error(&self) -> Option<String> {
		self.download_error.lock().ok().and_then(|e| e.clone())
	}

	/// 共享总长（字节）：下载线程回填 Content-Length 后实时可读，未知返回 None。
	/// symphonia FLAC/MP3 demuxer 的 seek 依赖 MediaSource::byte_len() 提供二分上界。
	pub fn shared_total_bytes(&self) -> Option<u64> {
		let v = self.content_length_shared.load(Ordering::Relaxed);
		if v == 0 {
			None
		} else {
			Some(v)
		}
	}
}
