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

use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::fs::{File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, SystemTime};

/// 清洗插件传入的 URL：移除首尾的反引号、引号、逗号等脏字符。
///
/// 前端虽有 sanitizeMediaUrl，但部分插件返回的 URL 包装字符可能穿透到 Rust 端，
/// 导致 reqwest 无法解析 URL 或请求到错误的地址。此处做最后一道防线。
fn sanitize_stream_url(raw: &str) -> String {
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
    let end = candidate
        .find(|c: char| matches!(c, '`' | '\'' | '"' | '<' | '>' | ' ' | '\t' | '\n' | '\r' | '\u{2018}' | '\u{2019}' | '\u{201c}' | '\u{201d}' | '\u{ff02}' | '\u{ff07}'))
        .unwrap_or(candidate.len());
    let mut result = candidate[..end].to_string();
    // 循环移除尾部逗号、分号、反引号等
    loop {
        let trimmed_end = result.trim_end_matches(|c: char| matches!(c, ',' | '，' | ';' | '；' | '`' | '\'' | '"' | ' ' | '\u{2018}' | '\u{2019}' | '\u{201c}' | '\u{201d}' | '\u{ff02}' | '\u{ff07}'));
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

/// 最小缓冲字节数：下载够这个量后才开始播放，避免起播立即卡顿。
/// 512KB ≈ 32s @ 128kbps / 12.8s @ 320kbps，平衡起播速度和播放流畅度。
/// 配合 StreamingTempFileReader 的阻塞等待机制，即使播放追上下载进度也能平滑等待。
pub const MIN_BUFFER_BYTES: u64 = 512 * 1024;

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
                if self.total_bytes.is_some()
                    || self.download_complete.load(Ordering::Relaxed)
                {
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
    /// When Some(true), blocks reads until download thread finishes post-download QMC check/decryption
    pub post_check_pending: Option<Arc<AtomicBool>>,
    /// 下载失败原因（供前端诊断）
    pub download_error: Arc<std::sync::Mutex<Option<String>>>,
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
                &self
                    .ekey
                    .lock()
                    .map(|e| e.is_some())
                    .unwrap_or(false),
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

    /// 创建 reader，若 ekey 存在则自动包装 QmcDecryptReader 进行流式解密。
    /// 返回 Box<dyn> 以统一有/无 ekey 两种情况的具体类型。
    pub fn new_reader_with_decryption(
        &self,
    ) -> std::io::Result<Box<dyn ReadSeek + Send + Sync + 'static>> {
        let reader = self.new_reader()?;
        let ekey = self.ekey();
        if let Some(ekey_str) = ekey {
            match crate::player::qmc2::QmcCrypto::from_ekey(&ekey_str) {
                Ok(crypto) => {
                    Ok(Box::new(crate::player::qmc2::QmcDecryptReader::new(
                        reader, crypto,
                    )))
                }
                Err(_) => {
                    Ok(Box::new(reader))
                }
            }
        } else {
            Ok(Box::new(reader))
        }
    }

    pub fn is_download_finished(&self) -> bool {
        self.download_complete.load(Ordering::Relaxed)
            || self.download_failed.load(Ordering::Relaxed)
    }

    pub fn downloaded_bytes(&self) -> u64 {
        self.downloaded_bytes.load(Ordering::Relaxed)
    }

    /// 返回下载失败原因（供前端诊断）
    pub fn download_error(&self) -> Option<String> {
        self.download_error.lock().ok().and_then(|e| e.clone())
    }
}

struct CacheEntry {
    path: PathBuf,
    size: u64,
    last_accessed: SystemTime,
    downloaded_bytes: Arc<AtomicU64>,
    download_complete: Arc<AtomicBool>,
    download_failed: Arc<AtomicBool>,
    /// 下载线程句柄（detach，不阻塞；线程结束后自然回收）
    _download_handle: Option<std::thread::JoinHandle<()>>,
}

struct StreamCacheManager {
    /// key = url_hash（文件名，也是持久化到磁盘的标识）
    entries: HashMap<String, CacheEntry>,
    max_size_bytes: u64,
    current_size: u64,
}

impl StreamCacheManager {
    fn evict_if_needed(&mut self) {
        while self.current_size > self.max_size_bytes && !self.entries.is_empty() {
            let oldest_key = self
                .entries
                .iter()
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
                    _download_handle: None,
                },
            );
            self.current_size += size;
        }

        self.evict_if_needed();
    }
}

static STREAM_CACHE: OnceLock<Mutex<StreamCacheManager>> = OnceLock::new();

fn cache() -> &'static Mutex<StreamCacheManager> {
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

/// 持久化缓存目录：
/// Windows: %APPDATA%\com.xymusic.desktop\stream_cache\
/// 其他平台: ~/com.xymusic.desktop/stream_cache/（回退 temp_dir）
fn cache_dir() -> PathBuf {
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

fn url_hash(url: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(url.as_bytes());
    hex::encode(&hasher.finalize()[..16])
}

/// 为在线音频创建流式缓存文件并启动后台下载。
/// 如果同一 URL 的缓存已存在（下载完成），直接复用。
pub fn start_streaming_download(
    url: &str,
    headers: Option<&std::collections::HashMap<String, String>>,
    user_agent: Option<&str>,
    ekey: Option<&str>,
) -> Result<StreamingTempFileState, String> {
    // Rust 端 URL 清洗：移除插件可能返回的反引号、引号、逗号等脏字符
    let cleaned_url = sanitize_stream_url(url);
    let url = cleaned_url.as_str();
    let hash = url_hash(url);
    let mut mgr = cache().lock().map_err(|e| e.to_string())?;

    // 已有缓存：检查是否下载完成
    if let Some(entry) = mgr.entries.get(&hash) {
        if entry.download_failed.load(Ordering::Relaxed) {
            if let Some(failed) = mgr.entries.remove(&hash) {
                let _ = std::fs::remove_file(&failed.path);
                mgr.current_size = mgr.current_size.saturating_sub(failed.size);
            }
        }
    }

    if let Some(entry) = mgr.entries.get_mut(&hash) {
        entry.last_accessed = SystemTime::now();
        if entry.download_complete.load(Ordering::Relaxed)
            && !entry.download_failed.load(Ordering::Relaxed)
        {
            let downloaded = entry.size;
            return Ok(StreamingTempFileState {
                path: entry.path.to_string_lossy().to_string(),
                downloaded_bytes: Arc::new(AtomicU64::new(downloaded)),
                download_complete: Arc::new(AtomicBool::new(true)),
                download_failed: Arc::new(AtomicBool::new(false)),
                total_bytes: Some(downloaded),
                ekey: Arc::new(std::sync::Mutex::new(ekey.map(|s| s.to_string()))),
                post_check_pending: None,
                download_error: Arc::new(std::sync::Mutex::new(None)),
            });
        }
        // 下载进行中：复用同一个文件和下载状态
        return Ok(StreamingTempFileState {
            path: entry.path.to_string_lossy().to_string(),
            downloaded_bytes: entry.downloaded_bytes.clone(),
            download_complete: entry.download_complete.clone(),
            download_failed: entry.download_failed.clone(),
            total_bytes: None,
            ekey: Arc::new(std::sync::Mutex::new(ekey.map(|s| s.to_string()))),
            post_check_pending: None,
            download_error: Arc::new(std::sync::Mutex::new(None)),
        });
    }

    // 创建缓存文件
    let temp_path = cache_dir().join(format!("{}.dat", hash));

    let file = OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .open(&temp_path)
        .map_err(|e| format!("创建缓存文件失败: {}", e))?;
    drop(file);

    let downloaded_bytes = Arc::new(AtomicU64::new(0));
    let download_complete = Arc::new(AtomicBool::new(false));
    let download_failed = Arc::new(AtomicBool::new(false));
    let post_check_pending = Arc::new(AtomicBool::new(false));
    let shared_ekey = Arc::new(std::sync::Mutex::new(ekey.map(|s| s.to_string())));
    let download_error: Arc<std::sync::Mutex<Option<String>>> = Arc::new(std::sync::Mutex::new(None));

    // 启动后台下载线程
    let url_clone = url.to_string();
    let hash_clone = hash.clone();
    let headers_clone = headers.cloned();
    let ua_clone = user_agent.map(|s| s.to_string());
    let path_clone = temp_path.clone();
    let dl_bytes = downloaded_bytes.clone();
    let dl_complete = download_complete.clone();
    let dl_failed = download_failed.clone();
    let dl_post_check = post_check_pending.clone();
    let dl_ekey = shared_ekey.clone();
    let dl_error = download_error.clone();

    let handle = std::thread::spawn(move || {
        download_thread(
            &url_clone,
            &hash_clone,
            headers_clone.as_ref(),
            ua_clone.as_deref(),
            path_clone,
            dl_bytes,
            dl_complete,
            dl_failed,
            dl_post_check,
            dl_ekey,
            dl_error,
        );
    });

    mgr.entries.insert(
        hash,
        CacheEntry {
            path: temp_path.clone(),
            size: 0,
            last_accessed: SystemTime::now(),
            downloaded_bytes: downloaded_bytes.clone(),
            download_complete: download_complete.clone(),
            download_failed: download_failed.clone(),
            _download_handle: Some(handle),
        },
    );
    mgr.evict_if_needed();

    Ok(StreamingTempFileState {
        path: temp_path.to_string_lossy().to_string(),
        downloaded_bytes,
        download_complete,
        download_failed,
        total_bytes: None,
        ekey: shared_ekey,
        post_check_pending: Some(post_check_pending),
        download_error,
    })
}

/// 从 JSON 响应文本中递归提取音频 URL 和 ekey。
/// 优先检查常见字段名（url, data, musicUrl, audioUrl, src, link, file, path），
/// 然后递归搜索任意层级的字符串值中以 http:// 或 https:// 开头且含音频扩展名的链接。
/// 最后回退到任意 HTTP URL（不检查音频特征），并搜索 ekey 字段。
fn extract_audio_info_from_json(body: &str) -> Option<(String, Option<String>)> {
    // 处理双重编码 JSON：有些 API 返回 JSON 字符串包裹的 JSON
    let value: serde_json::Value = match serde_json::from_str(body) {
        Ok(v) => v,
        Err(_) => {
            // 尝试去掉外层引号后重新解析
            let trimmed = body.trim().trim_matches('"');
            if trimmed != body.trim() {
                if let Ok(v) = serde_json::from_str(trimmed) {
                    v
                } else {
                    return None;
                }
            } else {
                return None;
            }
        }
    };

    // 优先字段名列表（按常见 API 返回格式排序）
    let priority_keys = [
        "url", "musicUrl", "audioUrl", "playUrl", "play_url", "music_url",
        "link", "src", "file", "fileUrl", "file_url",
        "data", "result", "music", "audio",
        "source", "sourceUrl", "source_url", "media", "mediaUrl",
        "stream", "streamUrl", "stream_url", "cdn", "cdnUrl",
        "play", "download", "downloadUrl", "download_url",
    ];

    // 第一轮：检查优先字段名（接受任何 http/https URL，不检查音频特征）
    for key in &priority_keys {
        if let Some(found) = find_url_by_key(&value, key) {
            let ekey = find_ekey_in_json(&value);
            return Some((found, ekey));
        }
    }

    // 第二轮：递归搜索任意看起来像音频 URL 的字符串
    if let Some(url) = find_any_audio_url(&value) {
        let ekey = find_ekey_in_json(&value);
        return Some((url, ekey));
    }

    // 第三轮：回退到任意 HTTP/HTTPS URL（不检查音频特征）
    // 某些 CDN URL 没有标准音频扩展名，但仍可播放
    if let Some(url) = find_any_http_url(&value) {
        let ekey = find_ekey_in_json(&value);
        return Some((url, ekey));
    }

    None
}

fn sanitize_extracted_audio_url(url: &str) -> String {
    url.trim()
        .trim_matches(|c: char| {
            c.is_whitespace()
                || matches!(
                    c,
                    '`' | '\'' | '"' | ',' | '，' | ';' | '；' | '‘' | '’' | '“' | '”'
                )
        })
        .to_string()
}

/// 从非音频文本响应中提取真实音频 URL。
///
/// 部分插件返回的播放地址其实是 API 端点，服务端可能以 `text/plain`
/// 返回真实直链，也可能 Content-Type 不准但正文是 JSON 或 HTML。
/// 提取策略（按优先级）：
///   1. 解析 JSON（含双重编码处理）
///   2. 纯文本直链（去掉引号后以 http 开头）
///   3. 从任意文本中扫描 HTTP URL（处理 HTML/错误页等）
fn extract_audio_info_from_text(body: &str) -> Option<(String, Option<String>)> {
    // 策略 1：尝试 JSON 解析
    if let Some(info) = extract_audio_info_from_json(body) {
        return Some(info);
    }

    // 策略 2：纯文本直链（去掉外层引号/空白后以 http 开头）
    let trimmed = sanitize_extracted_audio_url(body);
    if trimmed.starts_with("http://") || trimmed.starts_with("https://") {
        // 音频特征检查宽松化：只要不是明显非音频 URL 就接受
        if looks_like_audio_url(&trimmed) || !is_obviously_non_audio_url(&trimmed) {
            return Some((trimmed, None));
        }
    }

    // 策略 3：从任意文本中扫描第一个 HTTP URL（处理 HTML/错误页等）
    if let Some(url) = extract_url_from_raw_text(body) {
        return Some((url, None));
    }

    None
}

/// 在 JSON 中搜索 ekey 字段
fn find_ekey_in_json(value: &serde_json::Value) -> Option<String> {
    let ekey_keys = ["ekey", "eKey", "encryptKey", "encryptionKey"];
    find_string_by_keys(value, &ekey_keys)
}

/// 在 JSON 中按指定 key 列表搜索非空字符串值
fn find_string_by_keys(value: &serde_json::Value, keys: &[&str]) -> Option<String> {
    match value {
        serde_json::Value::Object(map) => {
            for &key in keys {
                if let Some(v) = map.get(key) {
                    if let Some(s) = v.as_str() {
                        if !s.is_empty() {
                            return Some(s.to_string());
                        }
                    }
                }
            }
            for v in map.values() {
                if let Some(found) = find_string_by_keys(v, keys) {
                    return Some(found);
                }
            }
            None
        }
        serde_json::Value::Array(arr) => {
            for v in arr {
                if let Some(found) = find_string_by_keys(v, keys) {
                    return Some(found);
                }
            }
            None
        }
        _ => None,
    }
}

/// 在 JSON 值中查找指定 key 对应的 URL 字符串
fn find_url_by_key(value: &serde_json::Value, key: &str) -> Option<String> {
    match value {
        serde_json::Value::Object(map) => {
            if let Some(v) = map.get(key) {
                if let Some(s) = v.as_str() {
                    let clean = sanitize_extracted_audio_url(s);
                    if clean.starts_with("http://") || clean.starts_with("https://") {
                        return Some(clean);
                    }
                }
                // 嵌套对象/数组中继续查找同一 key
                if let Some(found) = find_url_by_key(v, key) {
                    return Some(found);
                }
            }
            // 在其他字段中继续查找
            for v in map.values() {
                if let Some(found) = find_url_by_key(v, key) {
                    return Some(found);
                }
            }
            None
        }
        serde_json::Value::Array(arr) => {
            for v in arr {
                if let Some(found) = find_url_by_key(v, key) {
                    return Some(found);
                }
            }
            None
        }
        _ => None,
    }
}

/// 递归搜索 JSON 中任意以 http 开头且看起来像音频 URL 的字符串
fn find_any_audio_url(value: &serde_json::Value) -> Option<String> {
    match value {
        serde_json::Value::String(s) => {
            let clean = sanitize_extracted_audio_url(s);
            if (clean.starts_with("http://") || clean.starts_with("https://"))
                && looks_like_audio_url(&clean)
            {
                Some(clean)
            } else {
                None
            }
        }
        serde_json::Value::Object(map) => {
            for v in map.values() {
                if let Some(found) = find_any_audio_url(v) {
                    return Some(found);
                }
            }
            None
        }
        serde_json::Value::Array(arr) => {
            for v in arr {
                if let Some(found) = find_any_audio_url(v) {
                    return Some(found);
                }
            }
            None
        }
        _ => None,
    }
}

/// 递归搜索 JSON 中任意以 http 开头的 URL 字符串（不检查音频特征）。
/// 作为最后回退手段：某些 CDN 音频 URL 没有标准扩展名或已知域名。
/// 跳过明显非音频的 URL（如 .html、.htm、图片扩展名、CSS/JS 等）。
fn find_any_http_url(value: &serde_json::Value) -> Option<String> {
    match value {
        serde_json::Value::String(s) => {
            let clean = sanitize_extracted_audio_url(s);
            if clean.starts_with("http://") || clean.starts_with("https://") {
                if !is_obviously_non_audio_url(&clean) {
                    return Some(clean);
                }
            }
            // 处理协议相对 URL：//cdn.example.com/path
            if s.starts_with("//") {
                let full = format!("https:{}", s);
                if !is_obviously_non_audio_url(&full) {
                    return Some(full);
                }
            }
            None
        }
        serde_json::Value::Object(map) => {
            for v in map.values() {
                if let Some(found) = find_any_http_url(v) {
                    return Some(found);
                }
            }
            None
        }
        serde_json::Value::Array(arr) => {
            for v in arr {
                if let Some(found) = find_any_http_url(v) {
                    return Some(found);
                }
            }
            None
        }
        _ => None,
    }
}

/// 判断 URL 明显不是音频链接（排除 HTML、图片、CSS、JS 等）
fn is_obviously_non_audio_url(url: &str) -> bool {
    let lower = url.to_lowercase();
    lower.contains(".html")
        || lower.contains(".htm")
        || lower.contains(".php")
        || lower.contains(".asp")
        || lower.contains(".aspx")
        || lower.contains(".jsp")
        || lower.contains(".css")
        || lower.contains(".js")
        || lower.contains(".png")
        || lower.contains(".jpg")
        || lower.contains(".jpeg")
        || lower.contains(".gif")
        || lower.contains(".svg")
        || lower.contains(".webp")
        || lower.contains(".ico")
        || lower.contains(".woff")
        || lower.contains(".ttf")
        || lower.contains(".pdf")
        || lower.contains(".zip")
        || lower.contains(".rar")
        || lower.contains(".doc")
        || lower.contains(".docx")
}

/// 使用正则从任意文本（非 JSON）中提取第一个 HTTP/HTTPS URL。
/// 用于处理 HTML 响应、错误页面、或格式异常的文本中隐藏的音频 URL。
fn extract_url_from_raw_text(text: &str) -> Option<String> {
    // 简单扫描：查找 http:// 或 https:// 开头的子串
    for prefix in &["https://", "http://"] {
        if let Some(start) = text.find(prefix) {
            // 从起始位置截取到下一个空白字符或引号
            let rest = &text[start..];
            let end = rest
                .find(|c: char| c.is_whitespace() || c == '"' || c == '\'' || c == '<' || c == '>' || c == ',' || c == '}')
                .unwrap_or(rest.len());
            let url = &rest[..end];
            if url.len() > 10 && !is_obviously_non_audio_url(url) {
                return Some(sanitize_extracted_audio_url(url));
            }
        }
    }
    None
}

/// 判断 URL 是否看起来像音频链接（包含常见音频扩展名或路径特征）
fn looks_like_audio_url(url: &str) -> bool {
    let lower = url.to_lowercase();
    // 检查常见音频扩展名
    lower.contains(".mp3")
        || lower.contains(".flac")
        || lower.contains(".m4a")
        || lower.contains(".aac")
        || lower.contains(".ogg")
        || lower.contains(".wav")
        || lower.contains(".wma")
        || lower.contains(".opus")
        || lower.contains(".mga")
        || lower.contains(".mgg")
        // QQ音乐/酷狗/酷我/网易云等流媒体域名
        || lower.contains("stream.qqmusic")
        || lower.contains("ws.stream.qqmusic")
        || lower.contains("dl.stream.qqmusic")
        || lower.contains("isure.stream")
        || lower.contains("trackmedia")
        || lower.contains("music.126.net")
        || lower.contains("m.kugou")
        || lower.contains("track.kg")
        || lower.contains("trackercdn.kugou")
        || lower.contains("fsandroid.kugou")
        || lower.contains("fsm.kugou")
        || lower.contains("mobilesdk.kugou")
        || lower.contains("kuwo")
        || lower.contains("car-lv.kuwo")
        || lower.contains("nmobi.kuwo")
        || lower.contains("sr.kuwo")
        || lower.contains("antiserver")
        // 咪咕音乐
        || lower.contains("migu.cn")
        || lower.contains("miguvideo")
        // 第三方 API 代理域名
        || lower.contains("haitangw")
        || lower.contains("musicapi")
        // 没有明确扩展名但路径中含 music/song/track/play 等关键词
        || (lower.contains("/music") || lower.contains("/song") || lower.contains("/track") || lower.contains("/play"))
}

/// 检查文件头魔数是否为已知音频格式。
/// 支持 MP3 (含 ID3 标签)、FLAC、RIFF/WAV、OGG、M4A/MP4、AAC ADTS、AIFF。
fn is_valid_audio_header(bytes: &[u8]) -> bool {
    if bytes.len() < 4 {
        return false;
    }

    // MP3: ID3 标签开头
    if &bytes[..3] == b"ID3" {
        return true;
    }

    // MP3: 同步字 (第一字节 0xFF，第二字节高3位为 111)
    if bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0 {
        return true;
    }

    // FLAC
    if &bytes[..4] == b"fLaC" {
        return true;
    }

    // RIFF (WAV)
    if &bytes[..4] == b"RIFF" {
        return true;
    }

    // OGG
    if &bytes[..4] == b"OggS" {
        return true;
    }

    // AIFF
    if &bytes[..4] == b"FORM" {
        return true;
    }

    // M4A/MP4: bytes 4-7 为 "ftyp"
    if bytes.len() >= 8 && &bytes[4..8] == b"ftyp" {
        return true;
    }

    false
}

fn apply_stream_request_headers(
    mut req: reqwest::blocking::RequestBuilder,
    headers: Option<&std::collections::HashMap<String, String>>,
    user_agent: Option<&str>,
) -> reqwest::blocking::RequestBuilder {
    let has_plugin_user_agent = headers
        .map(|hdrs| hdrs.keys().any(|key| key.eq_ignore_ascii_case("user-agent")))
        .unwrap_or(false);

    // 插件提供的 User-Agent 必须优先。JOOX 等音源会严格校验 UA；
    // 如果先设置默认 UA 再追加插件 UA，最终请求可能携带重复 User-Agent，
    // 服务端会直接返回 403。
    if !has_plugin_user_agent {
        if let Some(ua) = user_agent {
            req = req.header(reqwest::header::USER_AGENT, ua);
        }
    }

    if let Some(hdrs) = headers {
        for (key, value) in hdrs {
            if !key.trim().is_empty() && !value.trim().is_empty() {
                if let (Ok(name), Ok(val)) = (
                    reqwest::header::HeaderName::from_bytes(key.as_bytes()),
                    reqwest::header::HeaderValue::from_str(value),
                ) {
                    req = req.header(name, val);
                }
            }
        }
    }
    req
}

fn download_thread(
    url: &str,
    hash: &str,
    headers: Option<&std::collections::HashMap<String, String>>,
    user_agent: Option<&str>,
    path: PathBuf,
    downloaded_bytes: Arc<AtomicU64>,
    download_complete: Arc<AtomicBool>,
    download_failed: Arc<AtomicBool>,
    _post_check_pending: Arc<AtomicBool>,
    ekey: Arc<std::sync::Mutex<Option<String>>>,
    download_error: Arc<std::sync::Mutex<Option<String>>>,
) {
    let fail_download = |reason: &str, bytes_written: u64| {
        downloaded_bytes.store(bytes_written, Ordering::Relaxed);
        download_failed.store(true, Ordering::Relaxed);
        if let Ok(mut err) = download_error.lock() {
            *err = Some(reason.to_string());
        }
        if let Ok(mut mgr) = cache().lock() {
            mgr.update_size(hash, bytes_written);
        }
    };

    let client = match reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(120))
        .connect_timeout(Duration::from_secs(10))
        .gzip(true)
        .brotli(true)
        .deflate(true)
        .build()
    {
        Ok(c) => c,
        Err(e) => {
            fail_download(&format!("创建 HTTP 客户端失败: {}", e), 0);
            return;
        }
    };

    let req = apply_stream_request_headers(client.get(url), headers, user_agent);

    let mut response = match req.send() {
        Ok(r) => r,
        Err(e) => {
            fail_download(&format!("下载请求失败: {}", e), 0);
            return;
        }
    };

    if !response.status().is_success() {
        fail_download(&format!("HTTP {}", response.status()), 0);
        return;
    }

    // 检查 Content-Type
    let content_type = response
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .to_lowercase();
    let is_non_audio = content_type.contains("text/html")
        || content_type.contains("application/json")
        || content_type.contains("text/plain")
        || content_type.contains("application/xml")
        || content_type.contains("text/xml");
    if is_non_audio {
        // 部分 Baka 插件的 getMediaSource 返回的是 API 端点 URL（如酷狗 PHP 接口），
        // 响应可能是 JSON、text/plain 直链、甚至 HTML 页面。
        // 对所有非音频内容类型统一尝试解析正文提取 URL 并重试下载。
        let body_text: String = response.text().unwrap_or_default();
        if let Some((real_url, json_ekey)) = extract_audio_info_from_text(&body_text) {
            // 如果 JSON 中包含 ekey，更新共享 ekey 字段供后续 QMC 解密使用
            if let Some(ref ek) = json_ekey {
                if let Ok(mut ekey_guard) = ekey.lock() {
                    if ekey_guard.is_none() {
                        *ekey_guard = Some(ek.clone());
                    }
                }
            }
            // 用提取到的 URL 重新请求
            let retry_req = apply_stream_request_headers(client.get(&real_url), headers, user_agent);
            match retry_req.send() {
                Ok(retry_resp) if retry_resp.status().is_success() => {
                    let retry_ct = retry_resp
                        .headers()
                        .get(reqwest::header::CONTENT_TYPE)
                        .and_then(|v| v.to_str().ok())
                        .unwrap_or("")
                        .to_lowercase();
                    if retry_ct.contains("text/html")
                        || retry_ct.contains("application/json")
                        || retry_ct.contains("text/plain")
                        || retry_ct.contains("application/xml")
                        || retry_ct.contains("text/xml")
                    {
                        // 二次提取：重试 URL 仍返回非音频内容，尝试再次提取
                        let retry_body: String = retry_resp.text().unwrap_or_default();
                        if let Some((real_url2, _)) = extract_audio_info_from_text(&retry_body) {
                            // 用二次提取的 URL 再次请求
                            let resp2_req = apply_stream_request_headers(
                                client.get(&real_url2),
                                headers,
                                user_agent,
                            );
                            match resp2_req.send() {
                                Ok(resp2) if resp2.status().is_success() => {
                                    let ct2 = resp2
                                        .headers()
                                        .get(reqwest::header::CONTENT_TYPE)
                                        .and_then(|v| v.to_str().ok())
                                        .unwrap_or("")
                                        .to_lowercase();
                                    if ct2.contains("text/html")
                                        || ct2.contains("application/json")
                                        || ct2.contains("text/plain")
                                    {
                                        fail_download(
                                            &format!(
                                                "二次提取的 URL 仍返回非音频内容 (Content-Type: {})",
                                                ct2
                                            ),
                                            0,
                                        );
                                        return;
                                    }
                                    response = resp2;
                                }
                                Ok(resp2) => {
                                    fail_download(
                                        &format!("二次提取的 URL 返回 HTTP {}", resp2.status()),
                                        0,
                                    );
                                    return;
                                }
                                Err(e) => {
                                    fail_download(
                                        &format!("二次提取的 URL 请求失败: {}", e),
                                        0,
                                    );
                                    return;
                                }
                            }
                        } else {
                            fail_download(
                                &format!(
                                    "提取的 URL 仍返回非音频内容 (Content-Type: {})，二次提取失败",
                                    retry_ct
                                ),
                                0,
                            );
                            return;
                        }
                    } else {
                        // 重试 URL 返回的是音频内容，直接使用
                        response = retry_resp;
                    }
                }
                Ok(retry_resp) => {
                    fail_download(
                        &format!("提取的 URL 返回 HTTP {}", retry_resp.status()),
                        0,
                    );
                    return;
                }
                Err(e) => {
                    fail_download(&format!("提取的 URL 请求失败: {}", e), 0);
                    return;
                }
            }
        } else {
            fail_download(
                &format!("服务器返回非音频内容 (Content-Type: {})，URL提取失败", content_type),
                0,
            );
            return;
        }
    }

    let total_bytes = response
        .headers()
        .get(reqwest::header::CONTENT_LENGTH)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.parse::<u64>().ok());

    let mut file = match OpenOptions::new().write(true).open(&path) {
        Ok(f) => f,
        Err(e) => {
            fail_download(&format!("打开缓存文件写入失败: {}", e), 0);
            return;
        }
    };

    let mut buf = [0u8; 64 * 1024];
    let mut bytes_written = 0u64;
    let mut error: Option<String> = None;

    loop {
        match response.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => {
                if let Err(e) = file.write_all(&buf[..n]) {
                    error = Some(format!("写入缓存文件失败: {}", e));
                    break;
                }
                bytes_written += n as u64;
                downloaded_bytes.store(bytes_written, Ordering::Relaxed);
            }
            Err(e) => {
                error = Some(format!("下载流读取错误: {}", e));
                break;
            }
        }
    }

    let _ = file.flush();

    if let Some(error) = error {
        fail_download(&error, bytes_written);
        return;
    }

    if let Some(total) = total_bytes {
        if bytes_written != total {
            fail_download(
                &format!("下载字节数不完整: {} / {}", bytes_written, total),
                bytes_written,
            );
            return;
        }
    }

    // 验证下载内容的文件头魔数，防止 CDN 返回错误页/加密数据等非音频内容
    // 即使 Content-Type 为 audio/mpeg，仍可能返回非音频数据（如 vkey 过期时的错误响应）
    // 注意：当 ekey 存在时（QMC 加密音源），文件头是加密数据而非有效音频头，跳过此验证
    let has_ekey = ekey.lock().map(|e| e.is_some()).unwrap_or(false);
    if !has_ekey {
        if let Ok(mut verify_file) = File::open(&path) {
            let mut header = [0u8; 16];
            let header_len = verify_file.read(&mut header).unwrap_or(0);
            if header_len >= 4 && !is_valid_audio_header(&header[..header_len]) {
                let header_hex: String = header[..header_len]
                    .iter()
                    .map(|b| format!("{:02x}", b))
                    .collect::<Vec<_>>()
                    .join(" ");
                fail_download(
                    &format!("下载内容非有效音频格式 (header: {})", header_hex),
                    bytes_written,
                );
                return;
            }
        }
    }

    download_complete.store(true, Ordering::Relaxed);

    // 更新缓存大小
    if let Ok(mut mgr) = cache().lock() {
        mgr.update_size(hash, bytes_written);
    }
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
