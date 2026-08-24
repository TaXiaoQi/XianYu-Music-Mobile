//! 对外暴露给 Flutter（flutter_rust_bridge）的 API 层。
//!
//! flutter_rust_bridge 只扫描本模块，避免把内部实现细节拉进桥接。
//! 新增可被 Dart 调用的函数时，放在这里即可。
//!
//! 约定：复合类型参数/返回值统一用 JSON 字符串传递（serde camelCase），
//! 避免为每个内部结构体生成 Dart 绑定，Dart 侧用 `jsonDecode`/`jsonEncode` 转换。

use crate::music::lyrics::build_structured_lyrics_payload;
use crate::music::url_resolver::LxUrlSongInfo;

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
// 音乐源 URL 直链解析（第二批）
// =========================================================================

/// 解析 LX 音源播放直链。
///
/// - `song_info_json`：[`LxUrlSongInfo`] 的 JSON（camelCase）
/// - `quality`：音质（如 "128k"、"320k"、"flac" 等）
///
/// 返回 [`ResolvedUrl`] 的 JSON；解析失败返回 `"null"`。
pub async fn lx_resolve_url(
    song_info_json: String,
    quality: String,
    data_dir: Option<String>,
) -> Result<String, String> {
    let song_info: LxUrlSongInfo =
        serde_json::from_str(&song_info_json).map_err(|e| e.to_string())?;
    // 传入 data_dir 时优先用已导入的音源插件解析。
    let resolved = crate::music::url_resolver::resolve_lx_music_url_with_plugins(
        &song_info,
        &quality,
        data_dir.as_deref(),
    )
    .await;
    match resolved {
        Some(r) => serde_json::to_string(&r).map_err(|e| e.to_string()),
        None => Ok("null".to_string()),
    }
}

/// 搜索音乐源。`source` ∈ `kw`/`kg`/`tx`/`wy`/`mg`。
/// 返回 [`LxSearchItem`] 数组的 JSON；失败返回错误信息。
pub async fn lx_search(source: String, keyword: String, limit: u32) -> Result<String, String> {
    let items = crate::music::lx_search::lx_search(&source, &keyword, limit).await?;
    serde_json::to_string(&items).map_err(|e| e.to_string())
}

// =========================================================================
// 音源插件管理
// =========================================================================

/// 列出已安装的音源插件（返回 `PluginInfo[]` JSON）。
pub fn plugin_list(data_dir: String) -> Result<String, String> {
    let list = crate::plugins::manager::list_plugins(&data_dir);
    serde_json::to_string(&list).map_err(|e| e.to_string())
}

/// 从脚本文本安装音源插件。
///
/// 安装前会在 QuickJS 引擎中试运行，脚本无效时直接返回错误。
/// 返回安装后的 `PluginInfo` JSON。
pub async fn plugin_install_script(
    data_dir: String,
    script: String,
    origin: String,
) -> Result<String, String> {
    let info =
        crate::plugins::manager::install_plugin(&data_dir, &script, &origin).await?;
    serde_json::to_string(&info).map_err(|e| e.to_string())
}

/// 从本地文件安装音源插件（限 `.js`）。
pub async fn plugin_install_file(data_dir: String, path: String) -> Result<String, String> {
    let script = crate::plugins::read_plugin_file(path.clone())?;
    plugin_install_script(data_dir, script, path).await
}

/// 从订阅 URL 安装音源插件。
pub async fn plugin_install_url(data_dir: String, url: String) -> Result<String, String> {
    // 先下载（异步），再在阻塞线程内试运行安装。
    let resp = crate::plugins::plugin_http_request(
        "GET".to_string(),
        url.clone(),
        Some(std::collections::HashMap::from([(
            "User-Agent".to_string(),
            "lx-music request".to_string(),
        )])),
        None,
        Some(30),
        Some(5),
    )
    .await?;
    if resp.status != 200 {
        return Err(format!("下载脚本失败: HTTP {}", resp.status));
    }
    plugin_install_script(data_dir, resp.body, url).await
}

/// 启用或停用插件。
pub fn plugin_set_enabled(data_dir: String, id: String, enabled: bool) -> Result<(), String> {
    crate::plugins::manager::set_plugin_enabled(&data_dir, &id, enabled)
}

/// 卸载插件。
pub fn plugin_remove(data_dir: String, id: String) -> Result<(), String> {
    crate::plugins::manager::remove_plugin(&data_dir, &id)
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
// WebDAV 云盘（第四批）
// =========================================================================

/// 解析 WebDAV 源 JSON 为凭据结构。
fn parse_remote_source(json: &str) -> Result<crate::remote::types::RemoteSourceCredentials, String> {
    serde_json::from_str(json).map_err(|e| format!("WebDAV 源 JSON 无效: {e}"))
}

/// 测试 WebDAV 连接（列出根目录）。
pub async fn webdav_test_connection(source_json: String) -> Result<(), String> {
    let source = parse_remote_source(&source_json)?;
    crate::remote::webdav::test_connection(&source).await
}

/// 已保存远程源的表单覆盖项（编辑时密码留空则沿用存储密码）。
#[derive(Default, serde::Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct WebdavSourceOverrides {
    pub base_url: Option<String>,
    pub username: Option<String>,
    pub root_path: Option<String>,
}

/// 按已保存远程源测试连接：读取存储凭证（含密码），叠加表单覆盖项后 PROPFIND 根目录。
///
/// 用于编辑场景：密码输入框留空表示沿用原密码，仅测试连接无需先保存。
pub async fn webdav_test_saved_source(
    db_path: String,
    source_id: String,
    overrides_json: String,
) -> Result<(), String> {
    let conn = open_scan_conn(&db_path)?;
    let mut source = crate::remote::repository::get_source(&conn, &source_id)?;
    let overrides: WebdavSourceOverrides = if overrides_json.trim().is_empty() {
        WebdavSourceOverrides::default()
    } else {
        serde_json::from_str(&overrides_json).map_err(|e| e.to_string())?
    };
    if let Some(base_url) = overrides.base_url {
        let trimmed = base_url.trim().trim_end_matches('/').to_string();
        if !trimmed.is_empty() {
            source.base_url = trimmed;
        }
    }
    if overrides.username.is_some() {
        source.username = overrides.username.filter(|v| !v.trim().is_empty());
    }
    if let Some(root_path) = overrides.root_path {
        let trimmed = root_path.trim().to_string();
        if !trimmed.is_empty() {
            source.root_path = trimmed;
        }
    }
    crate::remote::webdav::test_connection(&source).await
}

// =========================================================================
// 响度归一化（第四批）
// =========================================================================

/// 播放前直接读取文件 ReplayGain 标签并计算 Linear Gain（无 DB 缓存）。
///
/// 无标签 / 读取失败返回 1.0（原始音量播放）。
pub fn loudness_playback_gain_for_file(
    file_path: String,
    gain_offset_db: f32,
    prevent_clipping: bool,
) -> f32 {
    let path = std::path::Path::new(&file_path);
    let Some((tag_gain, tag_peak)) = crate::player::loudness::extract_replaygain_from_path(path)
    else {
        return 1.0;
    };
    let record = crate::player::loudness::LoudnessRecord {
        song_id: 0,
        song_path: file_path,
        loudness_lufs: None,
        estimated_loudness_lufs: None,
        sample_peak: None,
        true_peak: None,
        tag_track_gain_db: Some(tag_gain as f64),
        tag_track_peak: tag_peak.map(|p| p as f64),
        tag_album_gain_db: None,
        tag_album_peak: None,
        tag_r128_track_gain_db: None,
        tag_r128_album_gain_db: None,
        file_size: 0,
        file_modified_at: 0,
        scan_source: "tag_replaygain".to_string(),
        analyzer_name: None,
        analyzer_version: 1,
        scan_status: "scanned".to_string(),
        scanned_at: None,
        error_message: None,
    };
    crate::player::loudness::calculate_playback_gain(&record, gain_offset_db, prevent_clipping)
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

/// 从最近播放历史移除指定歌曲。
pub fn stats_remove_from_recent_history(
    db_path: String,
    song_paths: Vec<String>,
) -> Result<(), String> {
    let mut conn = open_stats_conn(&db_path)?;
    crate::statistics::remove_from_recent_history(&mut conn, song_paths)
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
    allowed_formats: Option<Vec<String>>,
) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    let db_conn = std::sync::Arc::new(std::sync::Mutex::new(conn));
    let options = crate::music::scanner::ScanOptions::new(
        minimum_duration_seconds,
        allowed_formats,
    );
    let songs = crate::music::scanner::scan_single_directory_internal(
        folder_path, db_conn, None, None, 1, 1, options,
    )?;
    serde_json::to_string(&songs).map_err(|e| e.to_string())
}

/// Android SAF：从一个已被 Android 侧通过 ContentResolver 打开的 fd 解析单个音频，
/// 返回曲库 [`Song`] JSON。读取走 `/proc/self/fd/<fd>`，解析逻辑与路径扫描完全一致。
pub fn parse_audio_from_fd_android(
    fd: i32,
    file_name: String,
    path_key: String,
    format: String,
) -> Result<String, String> {
    let song = crate::music::scanner::parse_song_from_fd(fd, &file_name, &path_key, &format)
        .ok_or_else(|| format!("无法解析音频（fd={fd}）"))?;
    serde_json::to_string(&song).map_err(|e| e.to_string())
}

/// Android SAF：把一批已解析歌曲增量提交到 `folder_key`（SAF tree documentId）名下。
/// 复用桌面同款增量 diff，保证新增/变更/删除在库内一致。
pub fn scan_saf_songs_commit(
    db_path: String,
    folder_key: String,
    songs_json: String,
    minimum_duration_seconds: Option<u32>,
) -> Result<String, String> {
    let songs: Vec<crate::music::types::Song> =
        serde_json::from_str(&songs_json).map_err(|e| e.to_string())?;
    let mut conn = open_scan_conn(&db_path)?;
    let options = crate::music::scanner::ScanOptions::new(minimum_duration_seconds, None);
    crate::music::scanner::commit_saf_scan_songs(&mut conn, &folder_key, songs, &options)?;
    Ok("ok".to_string())
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

// =========================================================================
// 账号认证（第八批）
// =========================================================================

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

/// 设置 API 签名密钥。
pub fn auth_set_api_secret(data_dir: String, api_secret: String) -> Result<(), String> {
    crate::music::auth::set_auth_api_secret(std::path::Path::new(&data_dir), api_secret)
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

/// 递归构建音乐库文件夹目录树（返回 `FolderNode[]` JSON）。
pub fn get_library_hierarchy(db_path: String) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    let tree = crate::music::library::get_library_hierarchy(&conn)?;
    serde_json::to_string(&tree).map_err(|e| e.to_string())
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

// =========================================================================
// 文件操作（第十一批）
// =========================================================================

/// 读取并解析歌曲歌词（返回 `StructuredLyricsPayload` JSON）。
pub async fn get_song_lyrics_payload(db_path: String, path: String) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    let db_conn = std::sync::Arc::new(std::sync::Mutex::new(conn));
    crate::music::files::get_song_lyrics_payload(path, db_conn).await
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

/// 读取歌曲详情（返回 `SongDetail` JSON）。
pub fn get_song_detail(db_path: String, path: String) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    crate::music::files::get_song_detail(&conn, path)
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

/// 运行时更新独占管线的音量平衡（ReplayGain）目标增益（平滑渐变不断音）。
pub fn set_usb_exclusive_volume_balance_gain(gain: f32) {
    crate::player::output::set_exclusive_volume_balance_gain(gain);
}

/// 更新 EQ 设置（camelCase JSON）。
pub fn set_usb_exclusive_equalizer(settings_json: String) -> Result<(), String> {
    crate::player::output::set_exclusive_equalizer(settings_json)
}

/// 更新音效设置（camelCase JSON）。
pub fn set_usb_exclusive_sound_effect(settings_json: String) -> Result<(), String> {
    crate::player::output::set_exclusive_sound_effect(settings_json)
}

/// 获取当前播放位置（秒）。
pub fn get_usb_exclusive_position_secs() -> f64 {
    crate::player::output::get_exclusive_position_secs()
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

/// 独立解密 QMC 加密文件（用户手动选择文件的工具入口）。
///
/// 支持三档策略：ekey 直供 / footer 自动提取 → QMC2；QMC1 老格式扩展名 → 固定密钥解密。
/// 解密成功后按内容修正扩展名。返回 JSON
/// `{"status":"decrypted"|"not_encrypted","outputPath":...,"renamedTo":...,"crypto":...}`。
pub fn decrypt_qmc_file_standalone(
    file_path: String,
    ekey: Option<String>,
) -> Result<String, String> {
    crate::toolbox::decrypt_qmc_file_standalone(file_path, ekey)
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

/// 获取公告（返回解析出的 data JSON 字符串）。
pub async fn fetch_announcement() -> Result<String, String> {
    crate::toolbox::fetch_announcement().await
}

// =========================================================================
// 插件 / 识曲（第十四批）
// =========================================================================

/// 读取插件/文本文件内容（限 `.js/.json/.txt/.m3u/.m3u8`）。
pub fn read_plugin_file(path: String) -> Result<String, String> {
    crate::plugins::read_plugin_file(path)
}

/// 代理图片请求（自动添加 Referer，返回 data URL）。
pub async fn proxy_image(url: String, referer: Option<String>) -> Result<String, String> {
    crate::plugins::proxy_image(url, referer).await
}

// =========================================================================
// 插件引擎（QuickJS 沙箱，移植自桌面端 plugin_host）
// =========================================================================

/// 初始化全局插件引擎（首次调用时以 `data_dir` 建立 Cookie/Storage 存储）。
pub fn plugin_engine_init(data_dir: String) -> Result<(), String> {
    crate::plugin_host::global_engine(&data_dir);
    Ok(())
}

/// 加载 LX 格式插件，返回 `EngineLoadResult` JSON（`ok`/`error`/`metadata`/`logs`）。
pub async fn plugin_engine_load_lx(
    data_dir: String,
    plugin_id: String,
    script: String,
    script_info_json: String,
) -> Result<String, String> {
    let engine = crate::plugin_host::global_engine(&data_dir);
    let result = engine.load_lx(&plugin_id, &script, &script_info_json).await;
    serde_json::to_string(&result).map_err(|e| e.to_string())
}

/// 加载 MusicFree 格式插件，返回 `EngineLoadResult` JSON。
pub async fn plugin_engine_load_musicfree(
    data_dir: String,
    plugin_id: String,
    script: String,
    user_vars_json: String,
) -> Result<String, String> {
    let engine = crate::plugin_host::global_engine(&data_dir);
    let result = engine.load_musicfree(&plugin_id, &script, &user_vars_json).await;
    serde_json::to_string(&result).map_err(|e| e.to_string())
}

/// 调用插件方法，返回 `EngineCallResult` JSON（`ok`/`error`/`data`/`logs`）。
pub async fn plugin_engine_call(
    data_dir: String,
    plugin_id: String,
    method: String,
    args_json: String,
    user_vars_json: Option<String>,
    timeout_ms: u64,
) -> Result<String, String> {
    let engine = crate::plugin_host::global_engine(&data_dir);
    let result = engine
        .call(&plugin_id, &method, &args_json, user_vars_json.as_deref(), timeout_ms)
        .await;
    serde_json::to_string(&result).map_err(|e| e.to_string())
}

/// 销毁指定插件的沙箱实例。
pub async fn plugin_engine_destroy(data_dir: String, plugin_id: String) -> Result<(), String> {
    let engine = crate::plugin_host::global_engine(&data_dir);
    engine.unload(&plugin_id).await;
    Ok(())
}

/// 销毁全部插件沙箱实例。
pub async fn plugin_engine_destroy_all(data_dir: String) -> Result<(), String> {
    let engine = crate::plugin_host::global_engine(&data_dir);
    engine.unload_all().await;
    Ok(())
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

// =========================================================================
// 在线播放流式缓存（常规 → 存储空间）
// 与桌面端 SettingsGeneral 的「存储空间」分组对齐。
// =========================================================================

/// 设置在线播放缓存上限（字节）。
pub fn set_stream_cache_max_size_bytes(bytes: u64) {
    crate::player::stream_cache::set_max_cache_size(bytes);
}

/// 当前在线播放缓存占用（字节）。
pub fn stream_cache_current_bytes() -> u64 {
    crate::player::stream_cache::current_cache_size()
}

/// 在线播放缓存上限（字节）。
pub fn stream_cache_max_bytes() -> u64 {
    crate::player::stream_cache::max_cache_size()
}

/// 清空在线播放缓存。
pub fn clear_stream_cache() {
    crate::player::stream_cache::clear_all();
}
