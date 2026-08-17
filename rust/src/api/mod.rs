//! 对外暴露给 Flutter（flutter_rust_bridge）的 API 层。
//!
//! flutter_rust_bridge 只扫描本模块，避免把内部实现细节拉进桥接。
//! 新增可被 Dart 调用的函数时，放在这里即可。
//!
//! 约定：复合类型参数/返回值统一用 JSON 字符串传递（serde camelCase），
//! 避免为每个内部结构体生成 Dart 绑定，Dart 侧用 `jsonDecode`/`jsonEncode` 转换。

use crate::music::lyrics::build_structured_lyrics_payload;
use crate::music::url_resolver::LxUrlSongInfo;
use crate::player::qmc2::QmcCrypto;
use crate::player::sound_effect::{SoundEffectBlockProcessor, SoundEffectSettings};
use crate::player::spectrum::build_frequency_bands;
use flutter_rust_bridge::frb;

// =========================================================================
// QMC 解密 / 频谱（第一批）
// =========================================================================

/// 对一整块 QMC 加密音频字节做解密，返回解密后的字节。
/// `ekey` 为 base64 编码的 QMC2 key（EncV2 已自动处理）。
pub fn qmc_decrypt_bytes(data: Vec<u8>, ekey: String) -> Result<Vec<u8>, String> {
    let crypto = QmcCrypto::from_ekey(&ekey)?;
    let mut buf = data;
    crypto.decrypt(0, &mut buf);
    Ok(buf)
}

/// 将 PCM 采样划分成指定数量的频带，返回每个频带的归一化能量。
pub fn spectrum_bands(samples: Vec<f32>, sample_rate: u32, band_count: usize) -> Vec<f32> {
    build_frequency_bands(&samples, sample_rate, band_count)
}

// =========================================================================
// 音效 DSP（第二批）
// =========================================================================

/// 对一块交错 PCM 应用音效 DSP 链。
///
/// - `samples`：交错 PCM（样本数应为 `channels` 的整数倍）
/// - `sample_rate`：采样率
/// - `channels`：声道数（1 或 2）
/// - `settings_json`：[`SoundEffectSettings`] 的 JSON（camelCase，可部分省略）
///
/// 返回处理后的交错 PCM。变调变速时输出样本数可能 ≠ 输入。
/// 所有音效关闭（含默认）时为无损直通。状态在单次调用内保持。
pub fn sound_effect_process(
    samples: Vec<f32>,
    sample_rate: u32,
    channels: u16,
    settings_json: String,
) -> Result<Vec<f32>, String> {
    let settings: SoundEffectSettings =
        serde_json::from_str(&settings_json).map_err(|e| e.to_string())?;
    let mut proc = SoundEffectBlockProcessor::new(sample_rate, channels);
    proc.set_settings(settings);
    Ok(proc.process_block(samples))
}

// =========================================================================
// 歌词解析（第三批）
// =========================================================================

/// 解析原始歌词文本（LRC/YRC/QRC/ESLRC/TTML/Lys 等），
/// 返回 [`StructuredLyricsPayload`] 的 JSON（camelCase）。
///
/// 包含 `document`（解析出的多轨结构）、`semanticLines`（语义行）和
/// `displayLines`（可直接用于逐行/逐字播放的展示行，含 translation/romaji）。
/// 解析失败或空文本时返回合法 JSON 结构而非错误。
pub fn parse_lyrics(raw_lyrics: String) -> String {
    serde_json::to_string(&build_structured_lyrics_payload(raw_lyrics))
        .unwrap_or_else(|_| "{}".to_string())
}

// =========================================================================
// 有状态音效处理器（第三批）
// =========================================================================

/// 有状态的音效 DSP 处理器（跨多块保持混响/延迟/包络状态）。
///
/// Flutter 侧先 `new` 创建实例，再反复 `processBlock` 逐块处理，
/// 最后 `dispose` 释放。`SoundEffectSettings` 以 JSON 传入。
#[frb(opaque)]
pub struct SoundEffectProcessor {
    inner: SoundEffectBlockProcessor,
}

impl SoundEffectProcessor {
    /// 创建处理器。`channels` 为 1 或 2。
    pub fn new(sample_rate: u32, channels: u16) -> Self {
        Self {
            inner: SoundEffectBlockProcessor::new(sample_rate, channels),
        }
    }

    /// 设置音效参数（camelCase JSON，可部分省略）。
    pub fn set_settings(&mut self, settings_json: String) -> Result<(), String> {
        let settings: SoundEffectSettings =
            serde_json::from_str(&settings_json).map_err(|e| e.to_string())?;
        self.inner.set_settings(settings);
        Ok(())
    }

    /// 处理一块交错 PCM，返回处理后的交错 PCM。
    pub fn process_block(&mut self, samples: Vec<f32>) -> Vec<f32> {
        self.inner.process_block(samples)
    }

    /// 清空内部延时/混响/包络状态。
    pub fn reset(&mut self) {
        self.inner.reset();
    }

    /// 当前实际（可能被变速改变的）采样率。
    pub fn effective_sample_rate(&self) -> u32 {
        self.inner.effective_sample_rate()
    }
}

// =========================================================================
// 音乐源 URL 直链解析（第二批）
// =========================================================================

/// 解析 LX 音源播放直链。
///
/// - `song_info_json`：[`LxUrlSongInfo`] 的 JSON（camelCase）
/// - `quality`：音质（如 "128k"、"320k"、"flac" 等）
///
/// 返回 [`ResolvedUrl`] 的 JSON；解析失败返回 `"null"`。
pub async fn lx_resolve_url(song_info_json: String, quality: String) -> Result<String, String> {
    let song_info: LxUrlSongInfo =
        serde_json::from_str(&song_info_json).map_err(|e| e.to_string())?;
    let resolved =
        crate::music::url_resolver::resolve_lx_music_url_inner(&song_info, &quality).await;
    match resolved {
        Some(r) => serde_json::to_string(&r).map_err(|e| e.to_string()),
        None => Ok("null".to_string()),
    }
}

/// 获取 LX 音源封面 URL，返回 URL 字符串；无封面返回 `#optional#` 空值。
pub async fn lx_get_cover(song_info_json: String) -> Option<String> {
    let song_info: LxUrlSongInfo = match serde_json::from_str(&song_info_json) {
        Ok(s) => s,
        Err(_) => return None,
    };
    crate::music::url_resolver::get_lx_cover_url(&song_info).await
}

/// 搜索音乐源。`source` ∈ `kw`/`kg`/`tx`/`wy`/`mg`。
/// 返回 [`LxSearchItem`] 数组的 JSON；失败返回错误信息。
pub async fn lx_search(source: String, keyword: String, limit: u32) -> Result<String, String> {
    let items = crate::music::lx_search::lx_search(&source, &keyword, limit).await?;
    serde_json::to_string(&items).map_err(|e| e.to_string())
}

/// 清除 LX 缓存（URL + 搜索）。
pub async fn lx_clear_cache() -> Result<(), String> {
    crate::music::lx_search::clear_lx_all_cache().await
}

// =========================================================================
// 歌词在线抓取（第三批）
// =========================================================================

/// 从指定音源抓取歌词（kg/kw/tx/wy）。
///
/// - `song_info_json`：[
/// `LyricSongInfo`] 的 JSON（camelCase）
///
/// 返回 [`LyricResult`]（含 lyric/tlyric/rlyric/lxlyric）的 JSON；
/// 该音源无歌词返回 `"null"`。
pub async fn fetch_lyric_from_source(
    source: String,
    song_info_json: String,
) -> Result<String, String> {
    let song_info: crate::music::lyric_fetcher::LyricSongInfo =
        serde_json::from_str(&song_info_json).map_err(|e| e.to_string())?;
    let result =
        crate::music::lyric_fetcher::fetch_lyric_from_source(source, song_info).await?;
    match result {
        Some(r) => serde_json::to_string(&r).map_err(|e| e.to_string()),
        None => Ok("null".to_string()),
    }
}

// =========================================================================
// 在线音频流式缓存（第三批）
// =========================================================================

/// 为在线音频 URL 创建流式缓存并启动后台下载。
///
/// - `headers_json`：可选 HTTP 头 JSON（对象，如 `{"Referer": "..."}`）
/// - `ekey`：可选 QMC2 加密 key（base64）
///
/// 返回缓存文件路径的 JSON（`{"path": "...", "downloadedBytes": n, "finished": bool}`）。
pub fn start_streaming_download(
    url: String,
    headers_json: String,
    user_agent: Option<String>,
    ekey: Option<String>,
) -> Result<String, String> {
    let headers: std::collections::HashMap<String, String> =
        if headers_json.trim().is_empty() {
            std::collections::HashMap::new()
        } else {
            serde_json::from_str(&headers_json).map_err(|e| e.to_string())?
        };
    let state =
        crate::player::stream_cache::start_streaming_download(&url, Some(&headers),
            user_agent.as_deref(), ekey.as_deref())?;
    let snapshot = serde_json::json!({
        "path": state.path,
        "downloadedBytes": state.downloaded_bytes(),
        "finished": state.is_download_finished(),
        "error": state.download_error(),
    });
    serde_json::to_string(&snapshot).map_err(|e| e.to_string())
}

/// 检查指定 URL 是否已缓存且下载完成。
pub fn is_url_cached(url: String) -> bool {
    crate::player::stream_cache::is_url_cached(&url)
}

/// 等待指定 URL 缓存下载完成（超时秒数）。
pub fn wait_url_complete(url: String, timeout_secs: u64) -> bool {
    crate::player::stream_cache::wait_url_complete(&url, timeout_secs)
}

/// 清理所有流缓存。
pub fn clear_stream_cache() {
    crate::player::stream_cache::clear_all();
}

// =========================================================================
// 10 段均衡器（第三批）
// =========================================================================

/// 有状态的 10 段均衡器（交错 PCM 缓冲级处理）。
///
/// Flutter 侧先 `new`，再反复 `processBlock` 逐块处理，`setSettings` 即时
/// 生效（带 50ms 参数平滑渐变），`dispose` 释放。
#[frb(opaque)]
pub struct EqualizerProcessor {
    inner: crate::player::equalizer::Equalizer,
}

impl EqualizerProcessor {
    /// 创建均衡器。`channels` 为 1 或 2。
    pub fn new(sample_rate: u32, channels: u16) -> Self {
        let handle =
            std::sync::Arc::new(crate::player::equalizer::EqualizerHandle::new(
                Default::default(),
            ));
        Self {
            inner: crate::player::equalizer::Equalizer::new(sample_rate, channels, handle),
        }
    }

    /// 设置均衡器参数（camelCase JSON：`{"enabled":bool,"preamp":dB,"gains":[10个dB]}`）。
    pub fn set_settings(&mut self, settings_json: String) -> Result<(), String> {
        #[derive(serde::Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct EqJson {
            enabled: bool,
            #[serde(default)]
            preamp: f32,
            #[serde(default)]
            gains: [f32; 10],
        }
        let e: EqJson = serde_json::from_str(&settings_json).map_err(|s| s.to_string())?;
        let settings = crate::player::equalizer::EqualizerSettings {
            enabled: e.enabled,
            preamp: e.preamp,
            gains: e.gains,
        };
        self.inner.set_settings(settings);
        Ok(())
    }

    /// 处理一块交错 PCM，返回处理后的交错 PCM。
    pub fn process_block(&mut self, samples: Vec<f32>) -> Vec<f32> {
        self.inner.process_block(&samples)
    }

    /// seek 时调用，清空滤波器状态防 click。
    pub fn reset(&mut self) {
        self.inner.reset();
    }
}

// =========================================================================
// 音频元数据 Tags（第三批）
// =========================================================================

/// 读取音频文件的文本元数据（标题/歌手/专辑/专辑歌手）。
///
/// 返回 camelCase JSON：
/// `{"title":"...","artist":"...","album":"...","albumArtist":"..."}`。
pub fn read_audio_metadata(file_path: String) -> Result<String, String> {
    let path = std::path::Path::new(&file_path);
    let tagged =
        crate::music::tags::read_tagged_file_from_path(path).map_err(|e| e.to_string())?;
    let text = crate::music::tags::extract_text_metadata(&tagged);
    let detail = crate::music::tags::extract_detail_metadata(&tagged);
    let lyrics = crate::music::tags::extract_embedded_lyrics(&tagged);
    let cover = crate::music::tags::find_embedded_picture(&tagged).map(|p| {
        let bytes = p.data().to_vec();
        let mime = p.mime_type().map(|m| m.to_string()).unwrap_or_default();
        let desc = p.description().unwrap_or_default().to_string();
        serde_json::json!({"data": bytes, "mime": mime, "description": desc})
    });
    serde_json::to_string(&serde_json::json!({
        "title": text.title,
        "artist": text.artist,
        "album": text.album,
        "albumArtist": text.album_artist,
        "genre": detail.genre,
        "year": detail.year,
        "trackNumber": detail.track_number,
        "discNumber": detail.disc_number,
        "comment": detail.comment,
        "lyrics": lyrics,
        "cover": cover,
    }))
    .map_err(|e| e.to_string())
}

/// 将元数据写入音频文件的 tag（ID3v2/Vorbis Comment/MP4 Atom 等）。
///
/// 仅写入请求中提供的非空字段，其余保持不变；无现有 tag 时按扩展名创建。
/// 请求为 camelCase JSON，可含：
/// `filePath`(必填)、`title`/`artist`/`album`/`albumArtist`/`year`/
/// `trackNumber`/`discNumber`(`String`)、`lyrics`(`String`)、
/// `coverData`(`Vec<u8>`)+`coverMime`(`String`)。
pub fn write_audio_metadata(request_json: String) -> Result<(), String> {
    let request: crate::music::tags::EmbedMetadataRequest =
        serde_json::from_str(&request_json).map_err(|e| e.to_string())?;
    crate::music::tags::write_metadata_to_file(&request)
}

// =========================================================================
// WebDAV 云盘（第四批）
// =========================================================================

/// 解析 WebDAV 源 JSON 为凭据结构。
fn parse_remote_source(json: &str) -> Result<crate::remote::types::RemoteSourceCredentials, String> {
    serde_json::from_str(json).map_err(|e| format!("WebDAV 源 JSON 无效: {e}"))
}

/// 列出 WebDAV 目录内容。
///
/// - `source_json`：WebDAV 源凭据（camelCase，含 `baseUrl`/`username`/`password`/`rootPath`）
/// - `path`：远程目录路径（如 `/` 或 `/专辑`）
///
/// 返回 [`RemoteFileEntry`] 数组的 JSON（camelCase，含 `remotePath`/`name`/`size`/`isDir`）。
pub async fn webdav_list_directory(
    source_json: String,
    path: String,
) -> Result<String, String> {
    let source = parse_remote_source(&source_json)?;
    let client = crate::remote::webdav::shared_client();
    let entries = crate::remote::webdav::list_directory(&client, &source, &path).await?;
    serde_json::to_string(&entries).map_err(|e| e.to_string())
}

/// 测试 WebDAV 连接（列出根目录）。
pub async fn webdav_test_connection(source_json: String) -> Result<(), String> {
    let source = parse_remote_source(&source_json)?;
    crate::remote::webdav::test_connection(&source).await
}

/// 递归扫描 WebDAV 源下的所有音频文件。
///
/// 返回 [`RemoteFileEntry`] 数组的 JSON（仅音频文件，不含目录）。
pub async fn webdav_collect_audio_files(source_json: String) -> Result<String, String> {
    let source = parse_remote_source(&source_json)?;
    let files = crate::remote::webdav::collect_audio_files(&source).await?;
    serde_json::to_string(&files).map_err(|e| e.to_string())
}

/// 从 WebDAV 断点续传下载文件到本地路径。
///
/// 目标文件已存在部分字节时从断点继续（RANGE 请求）。
pub async fn webdav_download_file(
    source_json: String,
    remote_path: String,
    target_path: String,
) -> Result<(), String> {
    let source = parse_remote_source(&source_json)?;
    crate::remote::webdav::download_file_to_path(
        &source,
        &remote_path,
        std::path::Path::new(&target_path),
        |_downloaded, _total| {},
    )
    .await
}

// =========================================================================
// 响度归一化（第四批）
// =========================================================================

/// 提取音频文件内置的 ReplayGain 标签。
///
/// 返回 JSON `{"gainDb": <f32>, "peakDb": <f32>|null}`；无标签返回 `"null"`。
pub fn extract_replaygain(file_path: String) -> Result<String, String> {
    match crate::player::loudness::extract_replaygain_from_path(std::path::Path::new(&file_path)) {
        Some((gain_db, peak)) => serde_json::to_string(&serde_json::json!({
            "gainDb": gain_db,
            "peakDb": peak,
        }))
        .map_err(|e| e.to_string()),
        None => Ok("null".to_string()),
    }
}

/// 计算实际应用的播放增益（Linear Gain 倍数）。
///
/// - `record_json`：[`LoudnessRecord`] 的 JSON（camelCase）
/// - `gain_offset_db`：用户手动增益偏移（dB）
/// - `prevent_clipping`：是否启用破音保护
pub fn loudness_calculate_playback_gain(
    record_json: String,
    gain_offset_db: f32,
    prevent_clipping: bool,
) -> f32 {
    let record: crate::player::loudness::LoudnessRecord = match serde_json::from_str(&record_json) {
        Ok(r) => r,
        Err(_) => return 1.0,
    };
    crate::player::loudness::calculate_playback_gain(&record, gain_offset_db, prevent_clipping)
}

/// 有状态的响度归一化处理器（交错 PCM 缓冲级，逐帧增益渐变防爆音）。
///
/// Flutter 侧先 `new`，再反复 `processBlock` 逐块处理，`setTargetGain` 即时生效
/// （带增益渐变），`dispose` 释放。
#[frb(opaque)]
pub struct VolumeNormalizerProcessor {
    inner: crate::player::loudness::VolumeNormalizer,
}

impl VolumeNormalizerProcessor {
    /// 创建处理器。`channels` 为 1 或 2；`initialGain` 为起始 Linear Gain；
    /// `rampMs` 为增益渐变时间（毫秒）。
    pub fn new(sample_rate: u32, channels: u16, initial_gain: f32, ramp_ms: u32) -> Self {
        let (proc, _handle) =
            crate::player::loudness::VolumeNormalizer::new(initial_gain, sample_rate, channels, ramp_ms);
        Self { inner: proc }
    }

    /// 处理一块交错 PCM，返回乘以逐帧渐增增益后的交错 PCM。
    pub fn process_block(&mut self, samples: Vec<f32>) -> Vec<f32> {
        self.inner.process_block(&samples)
    }

    /// 重置增益渐变状态。
    pub fn reset(&mut self) {
        self.inner.reset();
    }
}

// =========================================================================
// 缓冲播放监控（第四批）
// =========================================================================

/// 缓冲播放看门狗用的饥饿/补充状态句柄。
///
/// 由 Rust 播放引擎在创建 [`BufferedSource`] 时写入，Flutter 侧只读轮询，
/// 用于实现「自动暂停 → 缓冲 → 自动恢复」降级策略。
#[frb(opaque)]
pub struct BufferedMonitorHandle {
    inner: std::sync::Arc<crate::player::buffered_source::BufferedMonitor>,
}

impl BufferedMonitorHandle {
    /// 创建新的监控句柄。
    pub fn new() -> Self {
        Self {
            inner: std::sync::Arc::new(crate::player::buffered_source::BufferedMonitor::new()),
        }
    }

    /// 是否处于缓冲饥饿状态（消费线程取不到样本块）。
    pub fn is_starved(&self) -> bool {
        self.inner
            .starved
            .load(std::sync::atomic::Ordering::Relaxed)
    }

    /// 自上次调用以来是否已补充缓冲（读取后清除）。
    pub fn consume_produced(&self) -> bool {
        self.inner
            .produced
            .swap(false, std::sync::atomic::Ordering::Relaxed)
    }
}

impl Default for BufferedMonitorHandle {
    fn default() -> Self {
        Self::new()
    }
}

// =========================================================================
// 听歌统计（第五批）
// =========================================================================

/// 打开统计数据库连接并确保 schema 存在。
fn open_stats_conn(db_path: &str) -> Result<rusqlite::Connection, String> {
    let conn = rusqlite::Connection::open(db_path).map_err(|e| e.to_string())?;
    crate::database::schema::configure_connection(&conn)?;
    crate::database::schema::ensure_base_schema(&conn)?;
    Ok(conn)
}

/// 记录一次播放事件（含聚合统计与播放历史）。
///
/// - `db_path`：SQLite 数据库文件路径
/// - `payload_json`：[`RecordPlayPayload`] 的 JSON（camelCase，如
///   `{"songPath":"...","listenedMs":30000,"durationMs":195000,"title":"...","artist":"..."}`）
pub fn stats_record_play(db_path: String, payload_json: String) -> Result<(), String> {
    let payload: crate::statistics::RecordPlayPayload =
        serde_json::from_str(&payload_json).map_err(|e| e.to_string())?;
    let mut conn = open_stats_conn(&db_path)?;
    crate::statistics::record_play(&mut conn, payload)
}

/// 获取三个周期的听歌时长（日/周/总），返回 JSON 秒数。
pub fn stats_get_listen_durations(db_path: String) -> Result<String, String> {
    let conn = open_stats_conn(&db_path)?;
    let v = crate::statistics::get_listen_durations(&conn)?;
    serde_json::to_string(&v).map_err(|e| e.to_string())
}

/// 获取行为统计（Top 歌曲/歌手/专辑、时段分布、近期活跃）。
///
/// - `time_range_json`：[`TimeRange`] 的 JSON（如 `{"type":"Days30"}`）
pub fn stats_get_behavior_stats(db_path: String, time_range_json: String) -> Result<String, String> {
    let tr: crate::statistics::TimeRange =
        serde_json::from_str(&time_range_json).map_err(|e| e.to_string())?;
    let conn = open_stats_conn(&db_path)?;
    let v = crate::statistics::get_behavior_stats(&conn, tr)?;
    serde_json::to_string(&v).map_err(|e| e.to_string())
}

/// 获取曲库统计（歌曲/专辑/歌手数、总时长、无损比例等）。
pub fn stats_get_library_stats(db_path: String) -> Result<String, String> {
    let conn = open_stats_conn(&db_path)?;
    let v = crate::statistics::get_library_stats(&conn)?;
    serde_json::to_string(&v).map_err(|e| e.to_string())
}

/// 获取文件格式分布。
pub fn stats_get_format_distribution(db_path: String) -> Result<String, String> {
    let conn = open_stats_conn(&db_path)?;
    let v = crate::statistics::get_format_distribution(&conn)?;
    serde_json::to_string(&v).map_err(|e| e.to_string())
}

/// 获取音质分布（Hi-Res / 无损 / 高码率 / 其他）。
pub fn stats_get_quality_distribution(db_path: String) -> Result<String, String> {
    let conn = open_stats_conn(&db_path)?;
    let v = crate::statistics::get_quality_distribution(&conn)?;
    serde_json::to_string(&v).map_err(|e| e.to_string())
}

/// 获取最近播放历史（去重，按播放时间倒序）。
pub fn stats_get_recent_history(db_path: String, limit: Option<usize>) -> Result<String, String> {
    let conn = open_stats_conn(&db_path)?;
    let v = crate::statistics::get_recent_history(&conn, limit)?;
    serde_json::to_string(&v).map_err(|e| e.to_string())
}

/// 添加一条最近播放记录。
pub fn stats_add_to_history(db_path: String, song_path: String) -> Result<(), String> {
    let conn = open_stats_conn(&db_path)?;
    crate::statistics::add_to_history(&conn, song_path)
}

/// 清空最近播放历史。
pub fn stats_clear_recent_history(db_path: String) -> Result<(), String> {
    let conn = open_stats_conn(&db_path)?;
    crate::statistics::clear_recent_history(&conn)
}

/// 重置所有本地听歌统计（含播放历史与聚合统计）。
pub fn stats_reset_local_statistics(db_path: String) -> Result<(), String> {
    let conn = open_stats_conn(&db_path)?;
    crate::statistics::reset_local_statistics(&conn)
}

/// 批量导入最近播放历史。
///
/// - `entries_json`：[`RecentHistoryImportEntry`] 数组的 JSON（camelCase）
pub fn stats_import_recent_history(db_path: String, entries_json: String) -> Result<(), String> {
    let entries: Vec<crate::statistics::RecentHistoryImportEntry> =
        serde_json::from_str(&entries_json).map_err(|e| e.to_string())?;
    let mut conn = open_stats_conn(&db_path)?;
    crate::statistics::import_recent_history(&mut conn, entries)
}

/// 从最近播放/收藏路径构建歌手目录。
pub fn stats_get_favorite_artist_catalog(
    db_path: String,
    favorite_paths: Vec<String>,
) -> Result<String, String> {
    let conn = open_stats_conn(&db_path)?;
    let v = crate::statistics::get_favorite_artist_catalog(&conn, favorite_paths)?;
    serde_json::to_string(&v).map_err(|e| e.to_string())
}

/// 从最近播放/收藏路径构建专辑目录。
pub fn stats_get_favorite_album_catalog(
    db_path: String,
    favorite_paths: Vec<String>,
) -> Result<String, String> {
    let conn = open_stats_conn(&db_path)?;
    let v = crate::statistics::get_favorite_album_catalog(&conn, favorite_paths)?;
    serde_json::to_string(&v).map_err(|e| e.to_string())
}

/// 从最近播放记录构建最近专辑目录。
pub fn stats_get_recent_album_catalog(
    db_path: String,
    entries_json: String,
) -> Result<String, String> {
    let entries: Vec<crate::statistics::RecentHistoryImportEntry> =
        serde_json::from_str(&entries_json).map_err(|e| e.to_string())?;
    let conn = open_stats_conn(&db_path)?;
    let v = crate::statistics::get_recent_album_catalog(&conn, entries)?;
    serde_json::to_string(&v).map_err(|e| e.to_string())
}

/// 从收藏路径构建排序后的歌曲路径列表。
///
/// - `sort_mode`：`"title"`/`"artist"`/`"addedAt"`/`"addedAtAsc"`/`"fileModifiedAt"`/`"fileModifiedAtAsc"`
pub fn stats_get_favorite_song_paths_view(
    db_path: String,
    favorite_paths: Vec<String>,
    query: Option<String>,
    sort_mode: String,
    detail_filter_type: Option<String>,
    detail_filter_value: Option<String>,
) -> Result<String, String> {
    let conn = open_stats_conn(&db_path)?;
    let mode = parse_song_path_sort_mode(&sort_mode)?;
    let v = crate::statistics::get_favorite_song_paths_view(
        &conn,
        favorite_paths,
        query,
        mode,
        detail_filter_type,
        detail_filter_value,
    )?;
    serde_json::to_string(&v).map_err(|e| e.to_string())
}

/// 从最近播放记录构建排序后的歌曲路径列表。
pub fn stats_get_recent_song_paths_view(
    db_path: String,
    entries_json: String,
    query: Option<String>,
    sort_mode: String,
) -> Result<String, String> {
    let entries: Vec<crate::statistics::RecentHistoryImportEntry> =
        serde_json::from_str(&entries_json).map_err(|e| e.to_string())?;
    let conn = open_stats_conn(&db_path)?;
    let mode = parse_song_path_sort_mode(&sort_mode)?;
    let v = crate::statistics::get_recent_song_paths_view(&conn, entries, query, mode)?;
    serde_json::to_string(&v).map_err(|e| e.to_string())
}

/// 从播放列表与最近播放记录构建最近播放列表目录。
pub fn stats_get_recent_playlist_catalog(
    _db_path: String,
    playlists_json: String,
    entries_json: String,
) -> Result<String, String> {
    let playlists: Vec<crate::statistics::PlaylistImportItem> =
        serde_json::from_str(&playlists_json).map_err(|e| e.to_string())?;
    let entries: Vec<crate::statistics::RecentHistoryImportEntry> =
        serde_json::from_str(&entries_json).map_err(|e| e.to_string())?;
    let v = crate::statistics::get_recent_playlist_catalog(playlists, entries)?;
    serde_json::to_string(&v).map_err(|e| e.to_string())
}

/// 从最近播放历史移除指定歌曲。
pub fn stats_remove_from_recent_history(
    db_path: String,
    song_paths: Vec<String>,
) -> Result<(), String> {
    let mut conn = open_stats_conn(&db_path)?;
    crate::statistics::remove_from_recent_history(&mut conn, song_paths)
}

/// 从历史与统计中彻底移除指定歌曲。
pub fn stats_remove_songs_from_history_and_statistics(
    db_path: String,
    song_paths: Vec<String>,
) -> Result<(), String> {
    let mut conn = open_stats_conn(&db_path)?;
    crate::statistics::remove_songs_from_history_and_statistics(&mut conn, song_paths)
}

/// 导出统计备份到 JSON 文件。
///
/// - `options_json`：[`StatisticsExportOptions`] 的 JSON（camelCase，含 `filePath`/`includeRecentPlays`）
pub fn stats_export_statistics_file(db_path: String, options_json: String) -> Result<String, String> {
    let options: crate::statistics::StatisticsExportOptions =
        serde_json::from_str(&options_json).map_err(|e| e.to_string())?;
    let conn = open_stats_conn(&db_path)?;
    let v = crate::statistics::export_statistics_file(&conn, options)?;
    serde_json::to_string(&v).map_err(|e| e.to_string())
}

/// 预览统计备份导入（不写库）。
pub fn stats_preview_statistics_import(
    db_path: String,
    options_json: String,
) -> Result<String, String> {
    let options: crate::statistics::StatisticsImportPreviewOptions =
        serde_json::from_str(&options_json).map_err(|e| e.to_string())?;
    let conn = open_stats_conn(&db_path)?;
    let v = crate::statistics::preview_statistics_import(&conn, options)?;
    serde_json::to_string(&v).map_err(|e| e.to_string())
}

/// 导入统计备份。
///
/// - `options_json`：[`StatisticsImportOptions`] 的 JSON（camelCase，
///   含 `filePath`/`mode`("overwrite"|"merge")/`continueDuplicateImport`）
pub fn stats_import_statistics_file(db_path: String, options_json: String) -> Result<String, String> {
    let options: crate::statistics::StatisticsImportOptions =
        serde_json::from_str(&options_json).map_err(|e| e.to_string())?;
    let mut conn = open_stats_conn(&db_path)?;
    let v = crate::statistics::import_statistics_file(&mut conn, options)?;
    serde_json::to_string(&v).map_err(|e| e.to_string())
}

/// 解析歌曲路径排序模式字符串到枚举。
fn parse_song_path_sort_mode(s: &str) -> Result<crate::statistics::SongPathSortMode, String> {
    use crate::statistics::SongPathSortMode::*;
    match s {
        "title" => Ok(Title),
        "artist" => Ok(Artist),
        "addedAt" => Ok(AddedAt),
        "addedAtAsc" => Ok(AddedAtAsc),
        "fileModifiedAt" => Ok(FileModifiedAt),
        "fileModifiedAtAsc" => Ok(FileModifiedAtAsc),
        other => Err(format!("未知排序模式: {other}")),
    }
}

/// 打开扫描/曲库数据库连接并确保 schema 存在。
fn open_scan_conn(db_path: &str) -> Result<rusqlite::Connection, String> {
    let conn = rusqlite::Connection::open(db_path).map_err(|e| e.to_string())?;
    crate::database::schema::configure_connection(&conn)?;
    crate::database::schema::ensure_base_schema(&conn)?;
    Ok(conn)
}

// =========================================================================
// 音乐库扫描（第六批）
// =========================================================================

/// 增量扫描一个音乐文件夹，将新增/更新/删除写入数据库，返回该文件夹全部歌曲 JSON。
///
/// - `db_path`：SQLite 数据库文件路径
/// - `folder_path`：要扫描的文件夹路径
/// - `minimum_duration_seconds`：低于该时长的歌曲被过滤（0 表示不过滤）
pub fn scan_music_folder(
    db_path: String,
    folder_path: String,
    minimum_duration_seconds: Option<u32>,
) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    let db_conn = std::sync::Arc::new(std::sync::Mutex::new(conn));
    let options = crate::music::scanner::ScanOptions::from_minimum_duration_seconds(
        minimum_duration_seconds,
    );
    let songs = crate::music::scanner::scan_single_directory_internal(
        folder_path, db_conn, None, None, 1, 1, options,
    )?;
    serde_json::to_string(&songs).map_err(|e| e.to_string())
}

/// 解析指定音频文件路径并返回歌曲（不写库）。
///
/// - `paths_json`：路径数组的 JSON，如 `["/music/a.flac","/music/b.mp3"]`
pub fn parse_audio_files(paths_json: String, minimum_duration_seconds: Option<u32>) -> Result<String, String> {
    let paths: Vec<String> = serde_json::from_str(&paths_json).map_err(|e| e.to_string())?;
    let songs = crate::music::scanner::parse_audio_files_public(paths, minimum_duration_seconds)?;
    serde_json::to_string(&songs).map_err(|e| e.to_string())
}

/// 递归解析文件夹内所有受支持音频文件并返回歌曲（不写库）。
pub fn parse_music_folder(
    folder_path: String,
    minimum_duration_seconds: Option<u32>,
) -> Result<String, String> {
    let songs =
        crate::music::scanner::parse_music_folder_internal(&folder_path, minimum_duration_seconds)?;
    serde_json::to_string(&songs).map_err(|e| e.to_string())
}

/// 将歌曲列表按父文件夹分组为播放列表。
///
/// - `songs_json`：歌曲数组的 JSON
pub fn group_songs_as_playlists(songs_json: String) -> Result<String, String> {
    let songs: Vec<crate::music::types::Song> =
        serde_json::from_str(&songs_json).map_err(|e| e.to_string())?;
    let folders = crate::music::scanner::group_songs_as_playlists(songs);
    serde_json::to_string(&folders).map_err(|e| e.to_string())
}

/// 查找文件夹内（含子目录）第一首歌曲路径，用于展示封面。
pub fn find_first_song_recursive(db_path: String, folder_path: String) -> Result<Option<String>, String> {
    let conn = open_scan_conn(&db_path)?;
    Ok(crate::music::scanner::find_first_song_recursive(
        std::path::Path::new(&folder_path),
        &conn,
    ))
}

/// 递归构建文件夹目录树（含每层歌曲数/封面）。
///
/// - `max_depth`：最大递归深度
pub fn scan_folder_tree(
    db_path: String,
    folder_path: String,
    max_depth: u32,
) -> Result<Option<String>, String> {
    let conn = open_scan_conn(&db_path)?;
    let node = crate::music::scanner::scan_folder_recursive(
        std::path::PathBuf::from(&folder_path),
        0,
        max_depth,
        &conn,
    );
    match node {
        Some(node) => serde_json::to_string(&node).map(Some).map_err(|e| e.to_string()),
        None => Ok(None),
    }
}

// =========================================================================
// WebDAV 远程源管理（第七批）
// =========================================================================

/// 列出全部远程源（返回 [`RemoteSource`] 数组 JSON）。
pub fn list_remote_sources(db_path: String) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    let sources = crate::remote::repository::list_sources(&conn)?;
    serde_json::to_string(&sources).map_err(|e| e.to_string())
}

/// 新增或更新远程源（按 `RemoteSourceInput` JSON，缺 id 则新增）。
pub fn save_remote_source(db_path: String, source_json: String) -> Result<String, String> {
    let input: crate::remote::types::RemoteSourceInput =
        serde_json::from_str(&source_json).map_err(|e| e.to_string())?;
    let conn = open_scan_conn(&db_path)?;
    let source = crate::remote::repository::save_source(&conn, input)?;
    serde_json::to_string(&source).map_err(|e| e.to_string())
}

/// 删除远程源及其关联歌曲。
pub fn remove_remote_source(db_path: String, source_id: String) -> Result<(), String> {
    let mut conn = open_scan_conn(&db_path)?;
    crate::remote::repository::remove_source(&mut conn, &source_id)
}

/// 同步远程源：扫描远程目录、增量解析并写入音乐库。
///
/// - `cache_root`：远程音频缓存根目录（调用方传入 app 缓存目录）
/// - `source_id`：远程源 id
///
/// 返回 [`RemoteSyncResult`] JSON。
pub async fn sync_remote_source(
    db_path: String,
    cache_root: String,
    source_id: String,
) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    let source = crate::remote::repository::get_source(&conn, &source_id)?;
    let db_conn = std::sync::Arc::new(std::sync::Mutex::new(conn));
    let result = crate::remote::scanner::sync_source(
        std::path::Path::new(&cache_root),
        db_conn,
        source,
        None,
    )
    .await?;
    serde_json::to_string(&result).map_err(|e| e.to_string())
}

/// 查询远程音频缓存占用（返回 [`RemoteCacheUsage`] JSON）。
pub fn get_remote_cache_usage(cache_root: String) -> Result<String, String> {
    let usage = crate::remote::cache::cache_usage(std::path::Path::new(&cache_root))?;
    serde_json::to_string(&usage).map_err(|e| e.to_string())
}

/// 清空远程音频缓存（返回清空后 [`RemoteCacheUsage`] JSON）。
pub fn clear_remote_cache(cache_root: String) -> Result<String, String> {
    let usage = crate::remote::cache::clear_cache(std::path::Path::new(&cache_root))?;
    serde_json::to_string(&usage).map_err(|e| e.to_string())
}

/// 解析远程音乐播放来源：已缓存返回本地路径，未缓存返回直链流。
///
/// 返回 `{"kind":"cached","path":...}` 或 `{"kind":"stream","url":...,...}` JSON。
pub fn remote_playback_source(db_path: String, remote_uri: String) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    let source = crate::remote::cache::remote_playback_source(&conn, &remote_uri)?;
    serde_json::to_string(&source).map_err(|e| e.to_string())
}

/// 预下载远程文件到缓存并回写 `songs.cache_path`。
pub async fn precache_remote_song(
    db_path: String,
    cache_root: String,
    remote_uri: String,
) -> Result<(), String> {
    if !crate::remote::cache::is_remote_uri(&remote_uri) {
        return Ok(());
    }
    let conn = open_scan_conn(&db_path)?;
    let db_conn = std::sync::Arc::new(std::sync::Mutex::new(conn));
    crate::remote::cache::ensure_cached_path(
        std::path::Path::new(&cache_root),
        db_conn,
        &remote_uri,
        None,
    )
    .await?;
    Ok(())
}

// =========================================================================
// 调色板 / 侧边栏 / 账号认证（第八批）
// =========================================================================

/// 从封面提取主色调调色板（返回 `["hsl(...)"]` 数组 JSON）。
///
/// `source` 可为本地路径、`http(s)` 直链或 `data:` URI。
/// 纯 CPU 运算，宿主应在后台线程调用。
pub fn extract_palette(
    source: String,
    count: usize,
    color_boost: f64,
    depth: f64,
) -> Result<String, String> {
    let palette = crate::music::palette::extract_palette(source, count, color_boost, depth)?;
    serde_json::to_string(&palette).map_err(|e| e.to_string())
}

/// 读取侧边栏文件夹（废弃兼容，返回 `SidebarFolder[]` JSON）。
pub fn get_sidebar_folders(db_path: String) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    let folders = crate::music::sidebar::get_sidebar_folders(&conn)?;
    serde_json::to_string(&folders).map_err(|e| e.to_string())
}

/// 新增侧边栏文件夹（废弃兼容）。
pub fn add_sidebar_folder(db_path: String, path: String) -> Result<(), String> {
    let conn = open_scan_conn(&db_path)?;
    crate::music::sidebar::add_sidebar_folder(&conn, path)
}

/// 删除侧边栏文件夹（废弃兼容）。
pub fn remove_sidebar_folder(db_path: String, path: String) -> Result<(), String> {
    let conn = open_scan_conn(&db_path)?;
    crate::music::sidebar::remove_sidebar_folder(&conn, path)
}

/// 侧边栏目录树（废弃兼容，返回 `FolderNode[]` JSON）。
pub fn get_sidebar_hierarchy(db_path: String) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    let tree = crate::music::sidebar::get_sidebar_hierarchy(&conn)?;
    serde_json::to_string(&tree).map_err(|e| e.to_string())
}

/// 向账号 API 发起带签名的 POST 请求（返回响应 JSON）。
pub async fn auth_authed_request(
    data_dir: String,
    action: String,
    body_json: String,
    fetch_timeout_ms: Option<u64>,
) -> Result<String, String> {
    let body: serde_json::Value =
        serde_json::from_str(&body_json).map_err(|e| e.to_string())?;
    let payload = crate::music::auth::authed_request(
        std::path::Path::new(&data_dir),
        action,
        body,
        fetch_timeout_ms,
    )
    .await?;
    serde_json::to_string(&payload).map_err(|e| e.to_string())
}

/// 向任意 URL 发起带签名的 POST 请求（壁纸等非账号端点）。
pub async fn auth_signed_post_json(
    data_dir: String,
    url: String,
    body_json: String,
    fetch_timeout_ms: Option<u64>,
) -> Result<String, String> {
    let body: serde_json::Value =
        serde_json::from_str(&body_json).map_err(|e| e.to_string())?;
    let payload = crate::music::auth::signed_post_json(
        std::path::Path::new(&data_dir),
        url,
        body,
        fetch_timeout_ms,
    )
    .await?;
    serde_json::to_string(&payload).map_err(|e| e.to_string())
}

/// 保存认证凭证（token + user JSON 写入 auth 目录）。
pub fn auth_save_credentials(
    data_dir: String,
    token: String,
    user_json: String,
) -> Result<(), String> {
    let user: serde_json::Value =
        serde_json::from_str(&user_json).map_err(|e| e.to_string())?;
    crate::music::auth::save_auth_credentials(std::path::Path::new(&data_dir), token, user)
}

/// 读取认证凭证（返回 `AuthCredentials` JSON 或 null）。
pub fn auth_get_credentials(data_dir: String) -> Result<String, String> {
    let credentials = crate::music::auth::get_auth_credentials(std::path::Path::new(&data_dir))?;
    serde_json::to_string(&credentials).map_err(|e| e.to_string())
}

/// 清除认证凭证。
pub fn auth_clear_credentials(data_dir: String) -> Result<(), String> {
    crate::music::auth::clear_auth_credentials(std::path::Path::new(&data_dir))
}

/// 设置 API 基地址。
pub fn auth_set_base_url(data_dir: String, base_url: String) -> Result<(), String> {
    crate::music::auth::set_auth_base_url(std::path::Path::new(&data_dir), base_url)
}

/// 获取 API 基地址。
pub fn auth_get_base_url(data_dir: String) -> Result<String, String> {
    crate::music::auth::get_auth_base_url(std::path::Path::new(&data_dir))
}

/// 设置 API 签名密钥。
pub fn auth_set_api_secret(data_dir: String, api_secret: String) -> Result<(), String> {
    crate::music::auth::set_auth_api_secret(std::path::Path::new(&data_dir), api_secret)
}

/// 获取 API 签名密钥。
pub fn auth_get_api_secret(data_dir: String) -> Result<String, String> {
    crate::music::auth::get_auth_api_secret(std::path::Path::new(&data_dir))
}

// =========================================================================
// 音乐库管理（第九批）
// =========================================================================

/// 读取音乐库文件夹（返回 `LibraryFolder[]` JSON，含歌曲数）。
pub fn get_library_folders(db_path: String) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    let folders = crate::music::library::get_library_folders(&conn)?;
    serde_json::to_string(&folders).map_err(|e| e.to_string())
}

/// 新增音乐库文件夹。
pub fn add_library_folder(db_path: String, path: String) -> Result<(), String> {
    let conn = open_scan_conn(&db_path)?;
    crate::music::library::add_library_folder(&conn, path)
}

/// 移除音乐库文件夹及其后代歌曲。
pub fn remove_library_folder(db_path: String, path: String) -> Result<(), String> {
    let mut conn = open_scan_conn(&db_path)?;
    crate::music::library::remove_library_folder(&mut conn, path)
}

/// 读取全部本地曲库歌曲（返回 `LibrarySong[]` JSON）。
pub fn get_library_songs_cached(db_path: String) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    let songs = crate::music::library::get_library_songs_cached(&conn)?;
    serde_json::to_string(&songs).map_err(|e| e.to_string())
}

/// 按路径批量查询歌曲（返回 `LibrarySong[]` JSON）。
pub fn get_library_songs_by_paths(db_path: String, paths: Vec<String>) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    let songs = crate::music::library::get_library_songs_by_paths(&conn, paths)?;
    serde_json::to_string(&songs).map_err(|e| e.to_string())
}

/// 搜索本地音乐库（返回 `LibrarySong[]` JSON）。
pub fn search_library_songs(
    db_path: String,
    query: String,
    limit: Option<usize>,
) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    let songs = crate::music::library::search_library_songs(&conn, query, limit)?;
    serde_json::to_string(&songs).map_err(|e| e.to_string())
}

/// 读取歌手目录（返回 `ArtistCatalogItem[]` JSON）。
pub fn get_library_artist_catalog(db_path: String) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    let items = crate::music::library::get_library_artist_catalog(&conn)?;
    serde_json::to_string(&items).map_err(|e| e.to_string())
}

/// 读取专辑目录（返回 `AlbumCatalogItem[]` JSON）。
pub fn get_library_album_catalog(db_path: String) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    let items = crate::music::library::get_library_album_catalog(&conn)?;
    serde_json::to_string(&items).map_err(|e| e.to_string())
}

/// 按歌手名获取歌曲路径列表。
pub fn get_library_song_paths_by_artist(
    db_path: String,
    artist_name: String,
) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    let paths = crate::music::library::get_library_song_paths_by_artist(&conn, artist_name)?;
    serde_json::to_string(&paths).map_err(|e| e.to_string())
}

/// 按专辑 key 获取歌曲路径列表。
pub fn get_library_song_paths_by_album(
    db_path: String,
    album_key: String,
) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    let paths = crate::music::library::get_library_song_paths_by_album(&conn, album_key)?;
    serde_json::to_string(&paths).map_err(|e| e.to_string())
}

/// 全部歌曲视图的路径列表（支持查询/歌手/专辑过滤与排序）。
///
/// - `sort_mode`：`"title"`/`"artist"`/`"addedAt"`/`"addedAtAsc"`/
///   `"fileModifiedAt"`/`"fileModifiedAtAsc"`
pub fn get_library_song_paths_for_all_view(
    db_path: String,
    query: Option<String>,
    artist_filter: Option<String>,
    album_filter: Option<String>,
    sort_mode: String,
) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    let mode = crate::music::library::parse_library_song_sort_mode(&sort_mode)?;
    let paths = crate::music::library::get_library_song_paths_for_all_view(
        &conn,
        query,
        artist_filter,
        album_filter,
        mode,
    )?;
    serde_json::to_string(&paths).map_err(|e| e.to_string())
}

/// 文件夹视图的歌曲路径列表（支持查询过滤与排序）。
///
/// - `sort_mode`：`"title"`/`"name"`/`"artist"`/`"addedAt"`/`"addedAtAsc"`/`"trackNumber"`
pub fn get_library_song_paths_for_folder_view(
    db_path: String,
    folder_path: String,
    query: Option<String>,
    sort_mode: String,
) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    let mode = crate::music::library::parse_folder_song_sort_mode(&sort_mode)?;
    let paths = crate::music::library::get_library_song_paths_for_folder_view(
        &conn,
        folder_path,
        query,
        mode,
    )?;
    serde_json::to_string(&paths).map_err(|e| e.to_string())
}

/// 扫描所有音乐库文件夹并返回全部歌曲（返回 `LibrarySong[]` JSON）。
pub fn scan_library(
    db_path: String,
    minimum_duration_seconds: Option<u32>,
) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    let db_conn = std::sync::Arc::new(std::sync::Mutex::new(conn));
    let songs = crate::music::library::scan_library(db_conn, minimum_duration_seconds)?;
    serde_json::to_string(&songs).map_err(|e| e.to_string())
}

/// 递归构建音乐库文件夹目录树（返回 `FolderNode[]` JSON）。
pub fn get_library_hierarchy(db_path: String) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    let tree = crate::music::library::get_library_hierarchy(&conn)?;
    serde_json::to_string(&tree).map_err(|e| e.to_string())
}

/// 列出指定文件夹的直接子目录节点（返回 `FolderNode[]` JSON）。
pub fn get_folder_children(db_path: String, folder_path: String) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    let children = crate::music::library::get_folder_children(&conn, folder_path)?;
    serde_json::to_string(&children).map_err(|e| e.to_string())
}

// =========================================================================
// 封面缓存管理（第十批）
// =========================================================================

/// 获取歌曲缩略图封面（远程 URI 先缓存到本地），返回缓存路径字符串。
pub async fn get_song_cover_thumbnail(
    db_path: String,
    cache_root: String,
    path: String,
) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    let db_conn = std::sync::Arc::new(std::sync::Mutex::new(conn));
    crate::music::covers::get_song_cover_thumbnail(
        std::path::PathBuf::from(&cache_root),
        db_conn,
        path,
    )
    .await
}

/// 获取歌曲高清封面（远程 URI 先缓存到本地），返回缓存路径字符串。
pub async fn get_song_cover(
    db_path: String,
    cache_root: String,
    path: String,
) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    let db_conn = std::sync::Arc::new(std::sync::Mutex::new(conn));
    crate::music::covers::get_song_cover(std::path::PathBuf::from(&cache_root), db_conn, path).await
}

/// 后台清理封面缓存（超过 4GB 时按访问时间淘汰最旧文件）。
pub fn run_cover_cache_cleanup(cache_root: String) {
    let cache_dir = crate::music::covers::get_cover_cache_dir(std::path::Path::new(&cache_root));
    crate::music::covers::run_cache_cleanup(&cache_dir);
}

/// 清空封面缓存目录。
pub fn clear_cover_cache(cache_root: String) -> Result<(), String> {
    let cache_dir = crate::music::covers::get_cover_cache_dir(std::path::Path::new(&cache_root));
    crate::music::covers::clear_cover_cache(&cache_dir)
}

/// 保存自动提取的歌手头像字节到封面目录，返回规范化路径。
pub fn save_artist_avatar_auto(
    bytes: Vec<u8>,
    covers_root: String,
) -> Result<String, String> {
    let covers_dir = std::path::PathBuf::from(&covers_root);
    crate::music::covers::save_artist_avatar_auto(&bytes, &covers_dir)
        .ok_or_else(|| "无法保存歌手头像".to_string())
}

// =========================================================================
// 文件操作（第十一批）
// =========================================================================

/// 读取歌曲歌词（内嵌优先，其次侧边 LRC；远程先查缓存/远程 LRC）。
pub async fn get_song_lyrics(db_path: String, path: String) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    let db_conn = std::sync::Arc::new(std::sync::Mutex::new(conn));
    crate::music::files::get_song_lyrics(path, db_conn).await
}

/// 读取并解析歌曲歌词（返回 `StructuredLyricsPayload` JSON）。
pub async fn get_song_lyrics_payload(db_path: String, path: String) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    let db_conn = std::sync::Arc::new(std::sync::Mutex::new(conn));
    crate::music::files::get_song_lyrics_payload(path, db_conn).await
}

/// 读取用户选择的 LRC 文件（自动解码 UTF-8/UTF-16/GBK）。
pub fn read_lyrics_file(path: String) -> Result<String, String> {
    crate::music::files::read_lyrics_file(path)
}

/// 读取歌曲歌词用于编辑（返回 `SongLyricsForEdit` JSON）。
pub async fn get_song_lyrics_for_edit(path: String) -> Result<String, String> {
    crate::music::files::get_song_lyrics_for_edit(path).await
}

/// 保存歌曲歌词（内嵌或侧边 LRC），返回 `SongLyricsForEdit` JSON。
pub async fn save_song_lyrics(
    path: String,
    lyrics: String,
    source: crate::music::types::LyricsStorageSource,
    source_path: Option<String>,
) -> Result<String, String> {
    crate::music::files::save_song_lyrics(path, lyrics, source, source_path).await
}

/// 保存歌曲信息标签（返回 `SaveSongInfoResponse` JSON）。
pub fn save_song_info(
    db_path: String,
    path: String,
    payload_json: String,
) -> Result<String, String> {
    let mut conn = open_scan_conn(&db_path)?;
    let payload: crate::music::types::SongInfoEditPayload =
        serde_json::from_str(&payload_json).map_err(|e| e.to_string())?;
    crate::music::files::save_song_info(&mut conn, path, payload)
}

/// 保存歌曲背景图（返回存储路径）。
pub fn save_song_background(
    db_path: String,
    data_root: String,
    song_path: String,
    background_path: String,
) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    crate::music::files::save_song_background(
        &conn,
        std::path::Path::new(&data_root),
        song_path,
        background_path,
    )
}

/// 读取歌曲背景图路径。
pub fn get_song_background(db_path: String, song_path: String) -> Result<Option<String>, String> {
    let conn = open_scan_conn(&db_path)?;
    crate::music::files::get_song_background(&conn, song_path)
}

/// 清除歌曲背景图。
pub fn clear_song_background(
    db_path: String,
    data_root: String,
    song_path: String,
) -> Result<(), String> {
    let conn = open_scan_conn(&db_path)?;
    crate::music::files::clear_song_background(
        &conn,
        std::path::Path::new(&data_root),
        song_path,
    )
}

/// 读取歌曲详情（返回 `SongDetail` JSON）。
pub fn get_song_detail(db_path: String, path: String) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    crate::music::files::get_song_detail(&conn, path)
}

/// 批量移动歌曲文件并同步数据库（返回 `BatchMoveMusicFilesResult` JSON）。
pub fn batch_move_music_files(
    db_path: String,
    paths: Vec<String>,
    target_folder: String,
) -> Result<String, String> {
    let mut conn = open_scan_conn(&db_path)?;
    crate::music::files::batch_move_music_files(&mut conn, paths, target_folder)
}

/// 移动单个歌曲文件并同步数据库。
pub fn move_music_file(
    db_path: String,
    old_path: String,
    new_path: String,
) -> Result<(), String> {
    let mut conn = open_scan_conn(&db_path)?;
    crate::music::files::move_music_file(&mut conn, old_path, new_path)
}

/// 在系统文件管理器中定位文件。
pub fn show_in_folder(path: String) -> Result<(), String> {
    crate::music::files::show_in_folder(path)
}

/// 删除音乐文件。
pub fn delete_music_file(path: String) -> Result<(), String> {
    crate::music::files::delete_music_file(path)
}

/// 删除文件夹（递归）。
pub fn delete_folder(path: String) -> Result<(), String> {
    crate::music::files::delete_folder(path)
}

/// 创建文件夹，返回规范化新路径。
pub fn create_folder(parent_path: String, folder_name: String) -> Result<String, String> {
    crate::music::files::create_folder(parent_path, folder_name)
}

/// 移动文件到目标文件夹并同步数据库。
pub fn move_file_to_folder(
    db_path: String,
    source_path: String,
    target_folder: String,
) -> Result<(), String> {
    let mut conn = open_scan_conn(&db_path)?;
    crate::music::files::move_file_to_folder(&mut conn, source_path, target_folder)
}

/// 判断路径是否为目录。
pub fn is_directory(path: String) -> bool {
    crate::music::files::is_directory(path)
}

/// 保存歌手头像（可选写入歌曲标签），返回 `SaveArtistAvatarResponse` JSON。
pub fn save_artist_avatar(
    db_path: String,
    covers_root: String,
    artist_id: i64,
    image_path: String,
    write_to_tags: bool,
) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    crate::music::files::save_artist_avatar(
        &conn,
        std::path::Path::new(&covers_root),
        artist_id,
        image_path,
        write_to_tags,
    )
}

// =========================================================================
// 播放会话（第十二批）
// =========================================================================

use crate::player::session::PlaybackSessionState;
use crate::player::types::PlaybackSessionData;

fn global_playback_session() -> &'static PlaybackSessionState {
    static SESSION: std::sync::OnceLock<PlaybackSessionState> = std::sync::OnceLock::new();
    SESSION.get_or_init(PlaybackSessionState::new)
}

/// 保存完整播放会话状态（写入内存 + SQLite）。
pub fn save_playback_session(db_path: String, session_json: String) -> Result<(), String> {
    let conn = open_stats_conn(&db_path)?;
    let session: PlaybackSessionData =
        serde_json::from_str(&session_json).map_err(|e| e.to_string())?;
    global_playback_session().save_playback_session(&conn, session)
}

/// 获取当前播放会话状态（内存权威），返回 `PlaybackSessionData` JSON。
pub fn get_playback_session() -> String {
    serde_json::to_string(&global_playback_session().get_playback_session())
        .unwrap_or_else(|_| "{}".to_string())
}

/// 从 SQLite 加载播放会话到内存，返回 `PlaybackSessionData` JSON。
pub fn load_playback_session(db_path: String) -> Result<String, String> {
    let conn = open_stats_conn(&db_path)?;
    global_playback_session().load_from_db(&conn)?;
    serde_json::to_string(&global_playback_session().get_playback_session())
        .map_err(|e| e.to_string())
}

/// 高频更新播放进度（防抖写 SQLite）。
pub fn update_playback_position(
    db_path: String,
    position_secs: f64,
    is_playing: bool,
) -> Result<(), String> {
    let conn = open_stats_conn(&db_path)?;
    global_playback_session().update_playback_position(&conn, position_secs, is_playing)
}

/// 强制将内存播放会话持久化到 SQLite。
pub fn flush_playback_session(db_path: String) -> Result<(), String> {
    let conn = open_stats_conn(&db_path)?;
    global_playback_session().flush_playback_session(&conn)
}

/// 获取可视化频谱原始采样（返回 `f32[]` JSON）。
pub fn get_visualizer_snapshot() -> Result<String, String> {
    let samples = crate::player::types::global_visualizer().snapshot();
    serde_json::to_string(&samples).map_err(|e| e.to_string())
}

/// 向全局可视化器写入一个 PCM 采样（Flutter 播放线程调用）。
pub fn push_visualizer_sample(sample: f32) {
    crate::player::types::global_visualizer().push_sample(sample);
}

/// 重置全局可视化器。
pub fn reset_visualizer() {
    crate::player::types::global_visualizer().reset();
}

// =========================================================================
// 工具箱（第十三批）
// =========================================================================

/// 预览批量重命名（返回 `RenamePreview[]` JSON）。
///
/// - `config_json`：[`RenameConfig`] 的 JSON（camelCase，含 `mode`/`template`/
///   `removeTrackPrefix`/`removeSourcePrefix`）
pub fn preview_rename(root_path: String, config_json: String) -> Result<String, String> {
    let config: crate::toolbox::RenameConfig =
        serde_json::from_str(&config_json).map_err(|e| e.to_string())?;
    let previews = crate::toolbox::preview_rename(root_path, config)?;
    serde_json::to_string(&previews).map_err(|e| e.to_string())
}

/// 执行批量重命名（返回成功数）。
///
/// - `operations_json`：[`RenameOperation`] 数组的 JSON（camelCase，含 `originalPath`/`newName`）
pub fn apply_rename(operations_json: String) -> Result<u32, String> {
    let operations: Vec<crate::toolbox::RenameOperation> =
        serde_json::from_str(&operations_json).map_err(|e| e.to_string())?;
    crate::toolbox::apply_rename(operations)
}

/// 刷新指定文件夹歌曲（增量扫描并写库，返回该文件夹全部歌曲 JSON）。
pub fn refresh_folder_songs(
    db_path: String,
    folder_path: String,
    minimum_duration_seconds: Option<u32>,
) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    let db_conn = std::sync::Arc::new(std::sync::Mutex::new(conn));
    let songs = crate::toolbox::refresh_folder_songs(
        db_conn,
        folder_path,
        minimum_duration_seconds,
    )?;
    serde_json::to_string(&songs).map_err(|e| e.to_string())
}

/// 判断路径是否为存在的文件。
pub fn file_exists(path: String) -> bool {
    crate::toolbox::file_exists(path)
}

/// 在目标目录解析非冲突下载文件路径（已存在时自动追加 ` (1)`/` (2)`…）。
pub fn resolve_download_path(
    directory: String,
    file_name: String,
    overwrite_existing: bool,
) -> Result<String, String> {
    crate::toolbox::resolve_download_path(directory, file_name, overwrite_existing)
}

/// 根据歌曲信息构建下载文件名并解析非冲突完整路径（单次调用）。
pub fn resolve_download_full_path(
    directory: String,
    title: String,
    artist: String,
    album: String,
    url: String,
    quality: String,
    keep_source_filename: bool,
    file_name_style: String,
    overwrite_existing: bool,
) -> Result<String, String> {
    crate::toolbox::resolve_download_full_path(
        directory, title, artist, album, url, quality,
        keep_source_filename, file_name_style, overwrite_existing,
    )
}

/// 构建下载附件（歌词/封面）的清洗后文件名基名（不含扩展名）。
pub fn build_download_basename(
    title: String,
    artist: String,
    album: String,
    file_name_style: String,
) -> String {
    crate::toolbox::build_download_basename(title, artist, album, file_name_style)
}

// =========================================================================
// USB 独占音频输出（仅 Android）
// =========================================================================

/// 启动 USB 独占播放。返回设备名或错误信息。
/// `device_id` = AAudio 设备 ID（USB DAC），-1 = 默认设备。
pub fn start_usb_exclusive_playback(
    path: String,
    device_id: i32,
    volume: f32,
    start_time_secs: f64,
    is_playing: bool,
    volume_balance_gain: f32,
    equalizer_settings_json: String,
    sound_effect_settings_json: String,
) -> Result<String, String> {
    let request = crate::player::output::ExclusivePlayRequest {
        path,
        device_id,
        volume,
        start_time_secs,
        is_playing,
        volume_balance_gain,
        equalizer_settings_json,
        sound_effect_settings_json,
    };
    crate::player::output::start_exclusive_playback(request)
}

/// 停止 USB 独占播放并释放设备。
pub fn stop_usb_exclusive_playback() {
    crate::player::output::stop_exclusive_playback();
}

/// 跳转到指定位置（秒）。
pub fn seek_usb_exclusive(time_secs: f64, is_playing: bool) {
    crate::player::output::seek_exclusive(time_secs, is_playing);
}

/// 设置用户音量（0.0–1.0）。
pub fn set_usb_exclusive_volume(volume: f32) {
    crate::player::output::set_exclusive_volume(volume);
}

/// 更新 EQ 设置（camelCase JSON）。
pub fn set_usb_exclusive_equalizer(settings_json: String) -> Result<(), String> {
    crate::player::output::set_exclusive_equalizer(settings_json)
}

/// 更新音效设置（camelCase JSON）。
pub fn set_usb_exclusive_sound_effect(settings_json: String) -> Result<(), String> {
    crate::player::output::set_exclusive_sound_effect(settings_json)
}

/// USB 独占播放是否活跃。
pub fn is_usb_exclusive_active() -> bool {
    crate::player::output::is_exclusive_active()
}

/// 获取当前播放位置（秒）。
pub fn get_usb_exclusive_position_secs() -> f64 {
    crate::player::output::get_exclusive_position_secs()
}

/// 获取当前播放采样率。
pub fn get_usb_exclusive_sample_rate() -> u32 {
    crate::player::output::get_exclusive_sample_rate()
}

/// 获取当前声道数。
pub fn get_usb_exclusive_channels() -> u16 {
    crate::player::output::get_exclusive_channels()
}

/// 检查 GitHub Release 最新版本（返回原始 JSON）。
pub async fn check_update_by_rust(owner: String, repo: String) -> Result<String, String> {
    crate::toolbox::check_update_by_rust(owner, repo).await
}

/// 下载在线歌曲真实音源直链到指定路径（流式写入 + QMC2 解密），返回最终路径。
///
/// - `headers_json`：可选 HTTP 头 JSON（对象）
/// - `ekey`：可选 QMC2 加密 key（base64）
pub async fn download_online_song(
    url: String,
    dest_path: String,
    ekey: Option<String>,
    headers_json: String,
) -> Result<String, String> {
    let headers: std::collections::HashMap<String, String> =
        if headers_json.trim().is_empty() {
            std::collections::HashMap::new()
        } else {
            serde_json::from_str(&headers_json).map_err(|e| e.to_string())?
        };
    crate::toolbox::download_online_song(url, dest_path, ekey, Some(headers)).await
}

/// 原地解密 QMC2 加密文件，返回是否解密成功。
pub fn decrypt_qmc_file(file_path: String, ekey: Option<String>) -> Result<bool, String> {
    crate::toolbox::decrypt_qmc_file(file_path, ekey)
}

/// 保存歌词文本到指定文件（自动创建父目录），返回规范化路径。
pub async fn save_download_lyrics(content: String, dest_path: String) -> Result<String, String> {
    crate::toolbox::save_download_lyrics(content, dest_path).await
}

/// 将文本内容写入指定路径（自动创建父目录），返回规范化路径。
pub async fn write_text_file(content: String, dest_path: String) -> Result<String, String> {
    crate::toolbox::write_text_file(content, dest_path).await
}

/// 通过 reqwest 下载图片二进制（返回 `{"data":[...],"mime":"..."}` JSON）。
pub async fn fetch_image_bytes(url: String) -> Result<String, String> {
    let img = crate::toolbox::fetch_image_bytes(url).await?;
    serde_json::to_string(&img).map_err(|e| e.to_string())
}

/// 将前端已下载的字节数据写入目标文件，返回规范化路径。
pub async fn save_download_bytes(data: Vec<u8>, dest_path: String) -> Result<String, String> {
    crate::toolbox::save_download_bytes(data, dest_path).await
}

/// 将歌曲元数据写入音频文件 tag。
///
/// - `request_json`：[`EmbedMetadataRequest`] 的 JSON（camelCase，含 `filePath` 及可选字段）
pub async fn embed_audio_metadata(request_json: String) -> Result<(), String> {
    let request: crate::music::tags::EmbedMetadataRequest =
        serde_json::from_str(&request_json).map_err(|e| e.to_string())?;
    crate::toolbox::embed_audio_metadata(request).await
}

/// 下载后收尾编排：歌词保存 + 封面下载保存 + 元数据嵌入。
///
/// - `request_json`：[`FinalizeDownloadExtrasRequest`] 的 JSON（camelCase）
///
/// 返回 [`FinalizeDownloadExtrasResult`] JSON（camelCase）。
pub async fn finalize_download_extras(request_json: String) -> Result<String, String> {
    let request: crate::toolbox::FinalizeDownloadExtrasRequest =
        serde_json::from_str(&request_json).map_err(|e| e.to_string())?;
    let result = crate::toolbox::finalize_download_extras(request).await?;
    serde_json::to_string(&result).map_err(|e| e.to_string())
}

/// 读取下载记录 JSON 文本（文件不存在或损坏时返回 `"{}"`）。
pub async fn read_download_history(data_dir: String) -> Result<String, String> {
    crate::toolbox::read_download_history(std::path::Path::new(&data_dir)).await
}

/// 写入下载记录 JSON 文本（整体覆盖，自动创建父目录）。
pub async fn write_download_history(data_dir: String, content: String) -> Result<(), String> {
    crate::toolbox::write_download_history(std::path::Path::new(&data_dir), content).await
}

/// 用 `Range: bytes=0-0` 探测直链文件大小（返回 `ProbeUrlInfo` JSON）。
pub async fn probe_url_size(url: String) -> Result<String, String> {
    let info = crate::toolbox::probe_url_size(url).await?;
    serde_json::to_string(&info).map_err(|e| e.to_string())
}

/// 获取公告（返回解析出的 data JSON 字符串）。
pub async fn fetch_announcement() -> Result<String, String> {
    crate::toolbox::fetch_announcement().await
}

/// 将 JSON 字符串写入 `{data_dir}/state/{key}.json`。
pub async fn write_state_json(data_dir: String, key: String, value: String) -> Result<(), String> {
    crate::toolbox::write_state_json(std::path::Path::new(&data_dir), key, value).await
}

/// 从 `{data_dir}/state/{key}.json` 读取 JSON 字符串（不存在返回 null）。
pub async fn read_state_json(data_dir: String, key: String) -> Result<Option<String>, String> {
    crate::toolbox::read_state_json(std::path::Path::new(&data_dir), key).await
}

// =========================================================================
// 插件 / 识曲 / 歌词字体（第十四批）
// =========================================================================

/// 解析可选 HTTP 头 JSON 字符串（空串返回空表）。
fn parse_headers_json(headers_json: String) -> Result<std::collections::HashMap<String, String>, String> {
    if headers_json.trim().is_empty() {
        Ok(std::collections::HashMap::new())
    } else {
        serde_json::from_str(&headers_json).map_err(|e| e.to_string())
    }
}

/// 异步 HTTP 请求（返回 `PluginHttpResponse` JSON：`status`/`url`/`headers`/`body`）。
pub async fn plugin_http_request(
    method: String,
    url: String,
    headers_json: String,
    body: Option<String>,
    timeout: Option<u64>,
    follow: Option<u32>,
) -> Result<String, String> {
    let headers = parse_headers_json(headers_json)?;
    let resp = crate::plugins::plugin_http_request(method, url, Some(headers), body, timeout, follow).await?;
    serde_json::to_string(&resp).map_err(|e| e.to_string())
}

/// 异步二进制 HTTP 请求（返回 `PluginHttpBinaryResponse` JSON，body 为 base64）。
pub async fn plugin_http_request_binary(
    method: String,
    url: String,
    headers_json: String,
    body: Option<String>,
    timeout: Option<u64>,
    follow: Option<u32>,
) -> Result<String, String> {
    let headers = parse_headers_json(headers_json)?;
    let resp = crate::plugins::plugin_http_request_binary(method, url, Some(headers), body, timeout, follow).await?;
    serde_json::to_string(&resp).map_err(|e| e.to_string())
}

/// 读取插件/文本文件内容（限 `.js/.json/.txt/.m3u/.m3u8`）。
pub fn read_plugin_file(path: String) -> Result<String, String> {
    crate::plugins::read_plugin_file(path)
}

/// 将插件脚本保存到 `{data_dir}/plugins/{id}.js`，返回保存后的完整路径。
pub fn save_plugin_script(data_dir: String, id: String, script: String) -> Result<String, String> {
    crate::plugins::save_plugin_script(std::path::Path::new(&data_dir), id, script)
}

/// 读取本地文件二进制内容（base64 编码返回，限 `.json/.zip/.lxmc`）。
pub fn read_file_bytes(path: String) -> Result<String, String> {
    crate::plugins::read_file_bytes(path)
}

/// 代理图片请求（自动添加 Referer，返回 data URL）。
pub async fn proxy_image(url: String, referer: Option<String>) -> Result<String, String> {
    crate::plugins::proxy_image(url, referer).await
}

/// 异步下载音频到临时文件，返回本地文件路径。
pub async fn download_audio_to_temp(url: String, headers_json: String) -> Result<String, String> {
    let headers = parse_headers_json(headers_json)?;
    crate::plugins::download_audio_to_temp(url, Some(headers)).await
}

/// 取消正在进行的音频识别。
pub fn cancel_recognize_system_audio() -> Result<(), String> {
    crate::recognize::cancel_recognize_system_audio()
}

/// 使用自定义 PCM 数据识别歌曲（8000Hz/16bit/单声道），返回 `RecognizeResponse` JSON。
pub async fn recognize_with_pcm(pcm: Vec<u8>) -> Result<String, String> {
    let resp = crate::recognize::recognize_with_pcm(pcm).await?;
    serde_json::to_string(&resp).map_err(|e| e.to_string())
}

/// 导入歌词字体，返回 `ImportedLyricsFont` JSON（camelCase）。
pub fn import_lyrics_font(data_root: String, source_path: String) -> Result<String, String> {
    let font = crate::custom_fonts::import_lyrics_font(std::path::Path::new(&data_root), source_path)?;
    serde_json::to_string(&font).map_err(|e| e.to_string())
}

/// 读取已导入歌词字体为 data URL。
pub fn read_lyrics_font_data_url(data_root: String, font_path: String) -> Result<String, String> {
    crate::custom_fonts::read_lyrics_font_data_url(std::path::Path::new(&data_root), font_path)
}