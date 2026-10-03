//! 在线音频流式缓存模块
//!
//! 核心思路：把在线音乐流式下载到本地缓存文件，同时用 StreamingTempFileReader
//! 包装该文件供本地引擎（rodio Decoder）播放。这样所有音乐都走统一的
//! File::open + Decoder 路径，设备切换恢复天然支持，无需维护 RemoteRangeReader。
//!
//! 流程：
//! 1. start_streaming_download 创建缓存文件 + 启动后台下载线程
//! 2. 下载够最小缓冲（512KB）后即可开始播放
//! 3. StreamingTempFileReader 在读取追上下载进度时阻塞等待
//! 4. 下载完成后标记 complete，reader 正常读到 EOF
//! 5. 缓存持久化到 app_data_dir，重启后自动扫描重建索引
//! 6. LRU 策略淘汰旧缓存，上限用户可配置
//!
//! 拆分说明：临时文件读取见 temp_file，URL 探测见 url_probe，下载执行见 download。

pub(crate) use sha2::{Digest, Sha256};
pub(crate) use std::collections::HashMap;
pub(crate) use std::fs::{File, OpenOptions};
pub(crate) use std::io::{Read, Seek, SeekFrom, Write};
pub(crate) use std::path::PathBuf;
pub(crate) use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
pub(crate) use std::sync::{Arc, Mutex, OnceLock};
pub(crate) use std::time::{Duration, SystemTime};

mod download;
mod temp_file;
mod url_probe;

pub use download::*;
pub use temp_file::*;
pub(crate) use url_probe::*;

/// 清洗插件传入的 URL：移除首尾的反引号、引号、逗号等脏字符。
///
/// 前端虽有 sanitizeMediaUrl，但部分插件返回的 URL 包装字符可能穿透到 Rust 端，
/// 导致 reqwest 无法解析 URL 或请求到错误的地址。此处做最后一道防线。
pub(crate) fn sanitize_stream_url(raw: &str) -> String {
	let trimmed = raw.trim();
	// 找到 http:// 或 https:// 的最早起始位置
	// 注意：必须同时搜索两者并取最小位置，避免 https:// URL 路径中包含 http:// 时匹配错误
	let http_idx = trimmed.find("http://");
	let https_idx = trimmed.find("https://");
	let start = match (http_idx, https_idx) {
		(Some(h), Some(s)) => h.min(s),
		(Some(h), None) => h,
		(None, Some(s)) => s,
		(None, None) => return trimmed.to_string(),
	};
	let candidate = &trimmed[start..];
	// 从 URL 起始处截断到第一个出现的包装符/空白
	let end =
		candidate
			.find(|c: char| {
				matches!(
					c,
					'`'
						| '\'' | '"'
						| '<' | '>'
						| ' ' | '\t'
						| '\n' | '\r'
						| '\u{2018}'
						| '\u{2019}'
						| '\u{201c}'
						| '\u{201d}'
						| '\u{ff02}'
						| '\u{ff07}'
				)
			})
			.unwrap_or(candidate.len());
	let mut result = candidate[..end].to_string();
	// 循环移除尾部逗号、分号、反引号等
	loop {
		let trimmed_end = result.trim_end_matches(|c: char| {
			matches!(
				c,
				','
					| '，'
					| ';' | '；'
					| '`' | '\''
					| '"' | ' '
					| '\u{2018}'
					| '\u{2019}'
					| '\u{201c}'
					| '\u{201d}'
					| '\u{ff02}'
					| '\u{ff07}'
			)
		});
		if trimmed_end.len() == result.len() {
			break;
		}
		result = trimmed_end.to_string();
	}
	result
}

/// Combined Read + Seek trait for use in trait objects (Rust 不允许 dyn 中出现多个非 auto trait)。
pub trait ReadSeek: Read + Seek {}
impl<T: Read + Seek> ReadSeek for T {}

/// 对已完整下载的缓存文件执行 CENC 后处理解密（就地，长度不变）。
/// 若文件不是 CENC 加密则直接返回成功（无操作）。
pub fn decrypt_cenc_file(path: &std::path::Path, cek: &str) -> Result<(), String> {
	let mut data = std::fs::read(path).map_err(|e| format!("读取缓存文件失败: {}", e))?;
	let key = crate::player::cenc::cek_to_key(cek).map_err(|e| e.to_string())?;
	let decrypted = crate::player::cenc::decrypt_cenc_in_place(&mut data, &key)
		.map_err(|e| format!("CENC 解密失败: {}", e))?;
	if decrypted {
		// 就地写回：不截断（长度不变），避免破坏已打开的 reader 句柄
		let mut f = OpenOptions::new()
			.write(true)
			.open(path)
			.map_err(|e| format!("打开缓存文件写回失败: {}", e))?;
		f.seek(SeekFrom::Start(0))
			.map_err(|e| format!("定位缓存文件失败: {}", e))?;
		f.write_all(&data)
			.map_err(|e| format!("写回解密文件失败: {}", e))?;
		f.set_len(data.len() as u64)
			.map_err(|e| format!("设置文件长度失败: {}", e))?;
		f.flush().map_err(|e| format!("刷新文件失败: {}", e))?;
	}
	Ok(())
}

/// 最小缓冲字节数：下载够这个量后才开始播放，避免起播立即卡顿。
/// 256KB ≈ 16s @ 128kbps / 6.4s @ 320kbps，加快起播、减少慢速 CDN 等待（对齐桌面端）。
/// 配合 StreamingTempFileReader 的阻塞等待机制，即使播放追上下载进度也能平滑等待。
pub const MIN_BUFFER_BYTES: u64 = 256 * 1024;

pub(crate) struct CacheEntry {
	path: PathBuf,
	size: u64,
	last_accessed: SystemTime,
	downloaded_bytes: Arc<AtomicU64>,
	download_complete: Arc<AtomicBool>,
	download_failed: Arc<AtomicBool>,
	/// 响应头里的 Content-Length（下载中即上报，供代理伺服 206 用）
	content_length: Option<u64>,
	/// 共享总长槽位（字节，0 = 未知）：下载线程回填，state/reader 实时读。
	/// 同一 URL 的 start_streaming_download 复用路径必须拿到同一线程写的槽。
	content_length_shared: Arc<AtomicU64>,
	/// 下载线程句柄（detach，不阻塞；线程结束后自然回收）
	_download_handle: Option<std::thread::JoinHandle<()>>,
}

pub(crate) struct StreamCacheManager {
	/// key = url_hash（文件名，也是持久化到磁盘的标识）
	entries: HashMap<String, CacheEntry>,
	max_size_bytes: u64,
	current_size: u64,
}

impl StreamCacheManager {
	fn evict_if_needed(&mut self) {
		while self.current_size > self.max_size_bytes && !self.entries.is_empty() {
			// 只淘汰下载已结束（完成或失败）的条目：正在下载的文件被写入线程持有，
			// 删除会导致已下载字节作废、Windows 上文件残留，且其 size 尚未记账。
			let oldest_key = self
				.entries
				.iter()
				.filter(|(_, entry)| {
					entry.download_complete.load(Ordering::Relaxed)
						|| entry.download_failed.load(Ordering::Relaxed)
				})
				.min_by_key(|(_, entry)| entry.last_accessed)
				.map(|(k, _)| k.clone());

			if let Some(key) = oldest_key {
				if let Some(entry) = self.entries.remove(&key) {
					let _ = std::fs::remove_file(&entry.path);
					self.current_size = self.current_size.saturating_sub(entry.size);
				}
			} else {
				break;
			}
		}
	}

	fn update_size(&mut self, hash: &str, new_size: u64) {
		if let Some(entry) = self.entries.get_mut(hash) {
			self.current_size = self.current_size.saturating_sub(entry.size);
			entry.size = new_size;
			self.current_size += new_size;
		}
	}

	/// 扫描持久化缓存目录，重建 LRU 索引。
	/// 使用文件修改时间作为 last_accessed，使 LRU 跨重启仍然有效。
	fn init_from_disk(&mut self) {
		let dir = cache_dir();
		let read_dir = match std::fs::read_dir(&dir) {
			Ok(rd) => rd,
			Err(_) => return,
		};

		for entry in read_dir.flatten() {
			let path = entry.path();
			if path.extension().and_then(|s| s.to_str()) != Some("dat") {
				continue;
			}

			let hash = match path.file_stem().and_then(|s| s.to_str()) {
				Some(h) => h.to_string(),
				None => continue,
			};

			if self.entries.contains_key(&hash) {
				continue;
			}

			let metadata = match entry.metadata() {
				Ok(m) => m,
				Err(_) => continue,
			};

			let size = metadata.len();
			if size == 0 {
				let _ = std::fs::remove_file(&path);
				continue;
			}
			let last_modified = metadata.modified().ok().unwrap_or_else(SystemTime::now);

			self.entries.insert(
				hash,
				CacheEntry {
					path: path.clone(),
					size,
					last_accessed: last_modified,
					downloaded_bytes: Arc::new(AtomicU64::new(size)),
					download_complete: Arc::new(AtomicBool::new(true)),
					download_failed: Arc::new(AtomicBool::new(false)),
					content_length: Some(size),
					content_length_shared: Arc::new(AtomicU64::new(size)),
					_download_handle: None,
				},
			);
			self.current_size += size;
		}

		self.evict_if_needed();
	}
}

static STREAM_CACHE: OnceLock<Mutex<StreamCacheManager>> = OnceLock::new();

pub(crate) fn cache() -> &'static Mutex<StreamCacheManager> {
	STREAM_CACHE.get_or_init(|| {
		let mut mgr = StreamCacheManager {
			entries: HashMap::new(),
			max_size_bytes: 500 * 1024 * 1024,
			current_size: 0,
		};
		mgr.init_from_disk();
		Mutex::new(mgr)
	})
}

/// 设置缓存上限（用户可配置）
pub fn set_max_cache_size(bytes: u64) {
	let mut mgr = cache().lock().unwrap_or_else(|e| e.into_inner());
	mgr.max_size_bytes = bytes;
	mgr.evict_if_needed();
}

/// 获取当前缓存大小
pub fn current_cache_size() -> u64 {
	cache()
		.lock()
		.unwrap_or_else(|e| e.into_inner())
		.current_size
}

/// 获取缓存上限
pub fn max_cache_size() -> u64 {
	cache()
		.lock()
		.unwrap_or_else(|e| e.into_inner())
		.max_size_bytes
}

/// 缓存目录覆盖（移动端由 Dart 启动时传入 app 数据目录下的 stream_cache；
/// 默认 temp_dir 在 Android 不可持久，且该函数在 cache() 初始化前必须生效）。
static CACHE_DIR_OVERRIDE: OnceLock<Mutex<Option<PathBuf>>> = OnceLock::new();

/// 设置缓存目录覆盖。须在首次触碰流缓存（cache() 初始化）之前调用。
pub fn set_cache_dir_override(path: String) {
	let dir = PathBuf::from(&path);
	let _ = std::fs::create_dir_all(&dir);
	let cell = CACHE_DIR_OVERRIDE.get_or_init(|| Mutex::new(None));
	if let Ok(mut guard) = cell.lock() {
		*guard = Some(dir);
	}
}

/// 持久化缓存目录：
/// 优先使用 Dart 侧设置的覆盖目录；
/// Windows: %APPDATA%\com.xymusic.desktop\stream_cache\
/// 其他平台: ~/com.xymusic.desktop/stream_cache/（回退 temp_dir）
pub(crate) fn cache_dir() -> PathBuf {
	if let Some(cell) = CACHE_DIR_OVERRIDE.get() {
		if let Ok(guard) = cell.lock() {
			if let Some(dir) = guard.as_ref() {
				let _ = std::fs::create_dir_all(dir);
				return dir.clone();
			}
		}
	}
	#[cfg(target_os = "windows")]
	{
		if let Some(appdata) = std::env::var_os("APPDATA") {
			let dir = PathBuf::from(appdata)
				.join("com.xymusic.desktop")
				.join("stream_cache");
			let _ = std::fs::create_dir_all(&dir);
			return dir;
		}
	}

	let dir = std::env::temp_dir().join("xy-music-stream-cache");
	let _ = std::fs::create_dir_all(&dir);
	dir
}

pub(crate) fn url_hash(url: &str) -> String {
	let mut hasher = Sha256::new();
	hasher.update(url.as_bytes());
	hex::encode(&hasher.finalize()[..16])
}

/// 等待最小缓冲就绪（在 commands.rs 的 async 上下文中用 tokio::time::sleep 轮询）
pub fn is_buffer_ready(state: &StreamingTempFileState) -> bool {
	// Wait for post-download QMC check/decryption if pending
	if let Some(ref flag) = state.post_check_pending {
		if flag.load(Ordering::Relaxed) {
			return false;
		}
	}
	state.downloaded_bytes() >= MIN_BUFFER_BYTES || state.is_download_finished()
}

/// 检查指定 URL 是否已缓存且下载完成。
/// 用于播放前探测：若已缓存则直接复用，跳过插件重复请求（Baka 等前置请求易失败的音源）。
pub fn is_url_cached(url: &str) -> bool {
	let hash = url_hash(url);
	let mgr = cache().lock().unwrap_or_else(|e| e.into_inner());
	if let Some(entry) = mgr.entries.get(&hash) {
		return entry.download_complete.load(Ordering::Relaxed)
			&& !entry.download_failed.load(Ordering::Relaxed)
			&& entry.size > 0;
	}
	false
}

/// 将指定 URL 的播放缓存复制为目标下载文件。
/// 仅当该 URL 已完整缓存且未失败（download_complete && !download_failed && size > 0）时执行复制，
/// 避免重复下载。返回写入的字节数。
pub fn copy_cache_to(url: &str, dest_path: &str) -> Result<u64, String> {
	let hash = url_hash(url);
	let src_path = {
		let mut mgr = cache().lock().map_err(|e| e.to_string())?;
		let entry = mgr
			.entries
			.get_mut(&hash)
			.ok_or_else(|| "缓存不存在".to_string())?;
		if !entry.download_complete.load(Ordering::Relaxed)
			|| entry.download_failed.load(Ordering::Relaxed)
			|| entry.size == 0
		{
			return Err("缓存未下载完成".to_string());
		}
		// 刷新访问时间，避免复制期间被 LRU 淘汰
		entry.last_accessed = SystemTime::now();
		entry.path.clone()
	};
	std::fs::copy(&src_path, dest_path).map_err(|e| format!("复制缓存文件失败: {}", e))
}

/// 等待指定 URL 缓存下载完成（轮询，供前端 'wait' 失败行为使用）。
/// 返回最终是否完成且有效（未失败且字节数 > 0）。
pub fn wait_url_complete(url: &str, timeout_secs: u64) -> bool {
	let hash = url_hash(url);
	let deadline = std::time::Instant::now() + Duration::from_secs(timeout_secs);
	loop {
		let finished = {
			let mgr = cache().lock().unwrap_or_else(|e| e.into_inner());
			if let Some(entry) = mgr.entries.get(&hash) {
				entry.download_complete.load(Ordering::Relaxed)
					|| entry.download_failed.load(Ordering::Relaxed)
			} else {
				// URL 不在缓存中（从未下载或已被淘汰），无法等待
				return false;
			}
		};
		if finished {
			let mgr = cache().lock().unwrap_or_else(|e| e.into_inner());
			if let Some(entry) = mgr.entries.get(&hash) {
				return entry.download_complete.load(Ordering::Relaxed)
					&& !entry.download_failed.load(Ordering::Relaxed)
					&& entry.size > 0;
			}
			return false;
		}
		if std::time::Instant::now() >= deadline {
			return false;
		}
		std::thread::sleep(Duration::from_millis(200));
	}
}

/// 清理所有缓存
pub fn clear_all() {
	if let Some(mgr) = STREAM_CACHE.get() {
		if let Ok(mut mgr) = mgr.lock() {
			for (_, entry) in mgr.entries.drain() {
				let _ = std::fs::remove_file(&entry.path);
			}
			mgr.current_size = 0;
		}
	}
}

// =========================================================================
// 代理伺服支持（移动端 AudioProxyServer 对齐桌面端在线播放磁盘缓存）
// =========================================================================

/// URL 缓存状态快照（供代理伺服决策）。
pub struct UrlCacheStatus {
	pub exists: bool,
	pub complete: bool,
	pub failed: bool,
	pub downloaded_bytes: u64,
	pub total_bytes: Option<u64>,
}

/// 查询 URL 缓存状态（内部自动清洗 URL，与 begin/read 键一致）。
pub fn url_cache_status(url: &str) -> UrlCacheStatus {
	let hash = url_hash(&sanitize_stream_url(url));
	let mgr = cache().lock().unwrap_or_else(|e| e.into_inner());
	match mgr.entries.get(&hash) {
		Some(entry) => {
			let failed = entry.download_failed.load(Ordering::Relaxed);
			let complete = entry.download_complete.load(Ordering::Relaxed) && !failed;
			UrlCacheStatus {
				exists: true,
				complete,
				failed,
				downloaded_bytes: entry.downloaded_bytes.load(Ordering::Relaxed),
				// 完成用实际文件大小；下载中用响应头 Content-Length
				total_bytes: if complete {
					Some(entry.size)
				} else {
					entry.content_length
				},
			}
		}
		None => UrlCacheStatus {
			exists: false,
			complete: false,
			failed: false,
			downloaded_bytes: 0,
			total_bytes: None,
		},
	}
}

/// 启动/复用该 URL 的流式下载（供代理预热缓存写入）。
/// 已存在时复用（并刷新 LRU 访问时间），失败条目会被移除并重下。
pub fn begin_url_download(
	url: &str,
	headers: &std::collections::HashMap<String, String>,
) -> Result<(), String> {
	let cleaned = sanitize_stream_url(url);
	start_streaming_download(&cleaned, Some(headers), None, None, None).map(|_| ())
}

/// 供代理按区间读取缓存：阻塞直到 offset 处有数据可读或下载结束。
/// 返回空切片表示 EOF（完成/失败/无缓存）。单次最多读取 max_len 字节。
pub fn read_url_range(url: &str, offset: u64, max_len: u32) -> Vec<u8> {
	let cleaned = sanitize_stream_url(url);
	let hash = url_hash(&cleaned);
	let (path, downloaded, complete, failed) = {
		let mgr = cache().lock().unwrap_or_else(|e| e.into_inner());
		match mgr.entries.get(&hash) {
			Some(entry) => (
				entry.path.clone(),
				entry.downloaded_bytes.clone(),
				entry.download_complete.clone(),
				entry.download_failed.clone(),
			),
			None => return Vec::new(),
		}
	};
	let max_len = (max_len as u64).max(1);
	// 等数据超时：后台（如澎湃节流）下载器可能长时间不推进，
	// 无限阻塞会让代理卡死在缓存伺服；超时返回空，由代理回退直连。
	let deadline = std::time::Instant::now() + Duration::from_secs(2);
	loop {
		let avail = downloaded.load(Ordering::Relaxed);
		if offset < avail {
			let want = (avail - offset).min(max_len) as usize;
			let mut file = match File::open(&path) {
				Ok(f) => f,
				Err(_) => return Vec::new(),
			};
			if file.seek(SeekFrom::Start(offset)).is_err() {
				return Vec::new();
			}
			let mut buf = vec![0u8; want];
			let mut filled = 0usize;
			while filled < want {
				match file.read(&mut buf[filled..]) {
					Ok(0) => break,
					Ok(n) => filled += n,
					Err(_) => break,
				}
			}
			buf.truncate(filled);
			return buf;
		}
		if complete.load(Ordering::Relaxed) || failed.load(Ordering::Relaxed) {
			return Vec::new();
		}
		if std::time::Instant::now() >= deadline {
			return Vec::new();
		}
		std::thread::sleep(Duration::from_millis(10));
	}
}
