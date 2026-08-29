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

/// QQ 专辑搜索（签名 Desktop 接口 search_type=2）。
/// 返回原始专辑条目数组的 JSON；失败返回错误信息。
pub async fn tx_search_albums(keyword: String, page: u32, limit: u32) -> Result<String, String> {
    let items = crate::music::lx_search::tx_search_albums(&keyword, page, limit).await?;
    serde_json::to_string(&items).map_err(|e| e.to_string())
}

/// QQ 专辑曲目（签名 AlbumSongList 接口，按 albumMid）。
/// 返回 [`LxSearchItem`] 数组的 JSON；失败返回错误信息。
pub async fn tx_album_songs(album_mid: String, page: u32, limit: u32) -> Result<String, String> {
    let items = crate::music::lx_search::tx_album_songs(&album_mid, page, limit).await?;
    serde_json::to_string(&items).map_err(|e| e.to_string())
}

/// 批量查询 QQ 歌曲时长（UniformRuleCtrl，按 songid，每批≤50）。
/// 入参为 songid 数组 JSON（如 `[123,456]`），返回 `{ "id": 秒 }` 的 JSON。
pub async fn tx_batch_track_interval(song_ids_json: String) -> Result<String, String> {
    let song_ids: Vec<String> = serde_json::from_str(&song_ids_json).map_err(|e| e.to_string())?;
    let map = crate::music::lx_search::tx_batch_track_interval(&song_ids).await?;
    serde_json::to_string(&map).map_err(|e| e.to_string())
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
    let info = crate::plugins::manager::install_plugin(&data_dir, &script, &origin).await?;
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
    let result = crate::music::lyric_fetcher::fetch_lyric_from_source(source, song_info).await?;
    match result {
        Some(r) => serde_json::to_string(&r).map_err(|e| e.to_string()),
        None => Ok("null".to_string()),
    }
}

// =========================================================================
// WebDAV 云盘（第四批）
// =========================================================================

/// 解析 WebDAV 源 JSON 为凭据结构。
fn parse_remote_source(
    json: &str,
) -> Result<crate::remote::types::RemoteSourceCredentials, String> {
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

/// 查询指定歌曲的响度分析缓存记录（LUFS/峰值等），返回 `LoudnessRecord` JSON。
/// 无记录返回 `"null"`。
pub fn get_track_loudness_info(db_path: String, song_id: i64) -> Result<String, String> {
    let conn = open_stats_conn(&db_path)?;
    let record = crate::player::loudness::get_song_loudness_record(&conn, song_id)?;
    match record {
        Some(r) => serde_json::to_string(&r).map_err(|e| e.to_string()),
        None => Ok("null".to_string()),
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
    crate::database::migrations::run_migrations(&conn)?;
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
pub fn stats_get_behavior_stats(
    db_path: String,
    time_range_json: String,
) -> Result<String, String> {
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
pub fn stats_export_statistics_file(
    db_path: String,
    options_json: String,
) -> Result<String, String> {
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
pub fn stats_import_statistics_file(
    db_path: String,
    options_json: String,
) -> Result<String, String> {
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
    crate::database::migrations::run_migrations(&conn)?;
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
    let options =
        crate::music::scanner::ScanOptions::new(minimum_duration_seconds, allowed_formats);
    let songs = crate::music::scanner::scan_single_directory_internal(
        folder_path,
        db_conn,
        None,
        None,
        1,
        1,
        options,
    )?;
    serde_json::to_string(&songs).map_err(|e| e.to_string())
}

/// 批量解析一组音频文件的元数据（不写库），返回 `Song[]` JSON。对齐桌面端 `parse_audio_files`。
pub fn parse_audio_files(
    paths: Vec<String>,
    minimum_duration_seconds: Option<u32>,
) -> Result<String, String> {
    let songs = crate::music::scanner::parse_audio_files(paths, minimum_duration_seconds)?;
    serde_json::to_string(&songs).map_err(|e| e.to_string())
}

/// 递归扫描文件夹内全部受支持音频并解析元数据（不写库），返回 `Song[]` JSON。
/// 对齐桌面端 `parse_music_folder`。
pub fn parse_music_folder(
    folder_path: String,
    minimum_duration_seconds: Option<u32>,
) -> Result<String, String> {
    let songs = crate::music::scanner::parse_music_folder(folder_path, minimum_duration_seconds)?;
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

/// Android SAF：从已物化到应用内部存储的真实文件路径解析单个音频。
///
/// 解析逻辑与路径扫描完全一致，`path_key` 仍为稳定的 SAF content URI，作为
/// 曲库 [`Song`].path 主键；`file_name` 用于派生展示用 name/title。
/// 相比读取 `/proc/self/fd/{fd}`，真实路径读取在部分机型/提供方下更可靠。
pub fn parse_audio_from_path_android(
    file_path: String,
    file_name: String,
    path_key: String,
    format: String,
) -> Result<String, String> {
    let path = std::path::Path::new(&file_path);
    let song =
        crate::music::scanner::parse_song_from_file_with_name(path, &file_name, &path_key, &format)
            .ok_or_else(|| format!("无法解析音频（file={file_path}）"))?;
    serde_json::to_string(&song).map_err(|e| e.to_string())
}

/// Android SAF：从物化后的真实文件路径提取内嵌封面，缓存别名按 `source_key`（content URI）。
pub fn extract_song_cover_thumbnail_from_path(
    cache_root: String,
    source_key: String,
    real_path: String,
) -> Result<String, String> {
    let cache_dir = crate::music::covers::get_cover_cache_dir(std::path::Path::new(&cache_root));
    std::thread::spawn(move || {
        crate::music::covers::get_or_create_thumbnail_from_path(
            &source_key,
            std::path::Path::new(&real_path),
            &cache_dir,
        )
    })
    .join()
    .map_err(|_| "缩略图生成线程异常".to_string())?
    .ok_or_else(|| "无内嵌封面".to_string())
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
    let result =
        crate::remote::scanner::sync_source(std::path::Path::new(&cache_root), db_conn, source)
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
    let body: serde_json::Value = serde_json::from_str(&body_json).map_err(|e| e.to_string())?;
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
    let user: serde_json::Value = serde_json::from_str(&user_json).map_err(|e| e.to_string())?;
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

/// 扫描 SAF 歌曲时从已打开的 fd 提取内嵌封面并写入封面缓存。
///
/// 读文件走 `/proc/self/fd/{fd}`，按 content URI 路径哈希写别名，使列表展示时
/// `get_song_cover_thumbnail` 能直接命中缓存而无需再读 content URI。返回缓存路径。
pub fn extract_song_cover_thumbnail_from_fd(
    cache_root: String,
    path: String,
    fd: i32,
) -> Result<String, String> {
    let cache_dir = crate::music::covers::get_cover_cache_dir(std::path::Path::new(&cache_root));
    std::thread::spawn(move || {
        crate::music::covers::get_or_create_thumbnail_from_fd(&path, fd, &cache_dir)
    })
    .join()
    .map_err(|_| "缩略图生成线程异常".to_string())?
    .ok_or_else(|| "无内嵌封面".to_string())
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

/// 读取歌曲完整歌词（内嵌标签 → 侧边 LRC，远程歌曲走源 + 缓存），返回原始歌词文本。
pub async fn get_song_lyrics(db_path: String, path: String) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    let db_conn = std::sync::Arc::new(std::sync::Mutex::new(conn));
    crate::music::files::get_song_lyrics(path, db_conn).await
}

/// 读取用户主动选择的 .lrc 歌词文件源码（返回解码后的歌词文本）。
pub fn read_lyrics_file(path: String) -> Result<String, String> {
    crate::music::files::read_lyrics_file(path)
}

/// 保存歌曲背景图到背景根目录下 `song_backgrounds/` 并写入数据库，返回保存后的背景图路径。
pub fn save_song_background(
    db_path: String,
    song_backgrounds_root: String,
    song_path: String,
    background_path: String,
) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    crate::music::files::save_song_background(
        &conn,
        std::path::Path::new(&song_backgrounds_root),
        song_path,
        background_path,
    )
}

/// 查询歌曲背景图路径，无则返回 JSON `null`。
pub fn get_song_background(db_path: String, song_path: String) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    let result = crate::music::files::get_song_background(&conn, song_path)?;
    serde_json::to_string(&result).map_err(|e| e.to_string())
}

/// 清除歌曲背景图（删除本地文件 + 数据库记录）。
pub fn clear_song_background(
    db_path: String,
    song_backgrounds_root: String,
    song_path: String,
) -> Result<(), String> {
    let conn = open_scan_conn(&db_path)?;
    crate::music::files::clear_song_background(
        &conn,
        std::path::Path::new(&song_backgrounds_root),
        song_path,
    )
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

/// 只读查询当前播放会话状态（读内存权威状态），返回 `PlaybackSessionData` JSON。
pub fn session_get_playback_session(db_path: String) -> Result<String, String> {
    let conn = open_stats_conn(&db_path)?;
    global_playback_session().load_from_db(&conn)?;
    serde_json::to_string(&global_playback_session().get_playback_session())
        .map_err(|e| e.to_string())
}

/// 强制将当前播放会话内存状态持久化到 SQLite（定时刷新或退出时调用）。
pub fn session_flush_playback_session(db_path: String) -> Result<(), String> {
    let conn = open_stats_conn(&db_path)?;
    global_playback_session().flush_playback_session(&conn)
}
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
    let songs =
        crate::toolbox::refresh_folder_songs(db_conn, folder_path, minimum_duration_seconds)?;
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
        directory,
        title,
        artist,
        album,
        url,
        quality,
        keep_source_filename,
        file_name_style,
        overwrite_existing,
    )
}

// =========================================================================
// USB 独占音频输出（仅 Android）
// =========================================================================

/// 启动 USB 独占播放。返回设备名或错误信息。
/// `device_id` = AAudio 设备 ID（USB DAC），-1 = 默认设备。
/// `bit_perfect` = Bit-perfect 直出（绕过响度/EQ/音效/音量，按源位深整数直出）。
/// `dsd_native_passthrough` = DSD(.dsf/.dff) 原生 DoP 直通开关。
pub fn start_usb_exclusive_playback(
    path: String,
    device_id: i32,
    volume: f32,
    start_time_secs: f64,
    is_playing: bool,
    volume_balance_gain: f32,
    equalizer_settings_json: String,
    sound_effect_settings_json: String,
    bit_perfect: bool,
    dsd_native_passthrough: bool,
) -> Result<String, String> {
    crate::player::commands::dispatch_playback_command(
        crate::player::commands::PlaybackCommand::Play {
            path,
            device_id,
            volume,
            start_time_secs,
            is_playing,
            volume_balance_gain,
            equalizer_settings_json,
            sound_effect_settings_json,
            bit_perfect,
            dsd_native_passthrough,
        },
    )
}

/// 停止 USB 独占播放并释放设备。
pub fn stop_usb_exclusive_playback() {
    crate::player::commands::dispatch_playback_command(
        crate::player::commands::PlaybackCommand::Stop,
    )
    .ok();
}

/// 暂停 USB 独占播放（保持进度，等待 resume 恢复）。
pub fn pause_usb_exclusive() {
    crate::player::commands::dispatch_playback_command(
        crate::player::commands::PlaybackCommand::Pause,
    )
    .ok();
}

/// 从暂停恢复 USB 独占播放。
pub fn resume_usb_exclusive() {
    crate::player::commands::dispatch_playback_command(
        crate::player::commands::PlaybackCommand::Resume,
    )
    .ok();
}

/// 跳转到指定位置（秒）。
pub fn seek_usb_exclusive(time_secs: f64, is_playing: bool) {
    crate::player::commands::dispatch_playback_command(
        crate::player::commands::PlaybackCommand::Seek {
            time_secs,
            is_playing,
        },
    )
    .ok();
}

/// 设置用户音量（0.0–1.0）。
pub fn set_usb_exclusive_volume(volume: f32) {
    crate::player::commands::dispatch_playback_command(
        crate::player::commands::PlaybackCommand::SetVolume(volume),
    )
    .ok();
}

/// 运行时更新独占管线的音量平衡（ReplayGain）目标增益（平滑渐变不断音）。
pub fn set_usb_exclusive_volume_balance_gain(gain: f32) {
    crate::player::commands::dispatch_playback_command(
        crate::player::commands::PlaybackCommand::SetVolumeBalanceGain(gain),
    )
    .ok();
}

/// 更新 EQ 设置（camelCase JSON）。
pub fn set_usb_exclusive_equalizer(settings_json: String) -> Result<(), String> {
    crate::player::commands::dispatch_playback_command(
        crate::player::commands::PlaybackCommand::SetEqualizer(settings_json),
    )
    .map(|_| ())
}

/// 更新音效设置（camelCase JSON）。
pub fn set_usb_exclusive_sound_effect(settings_json: String) -> Result<(), String> {
    crate::player::commands::dispatch_playback_command(
        crate::player::commands::PlaybackCommand::SetSoundEffect(settings_json),
    )
    .map(|_| ())
}

/// 运行时切换 Bit-perfect 直出：开启绕过响度/EQ/音效/音量，关闭恢复 DSP 链。
pub fn set_usb_exclusive_bit_perfect(enabled: bool) {
    crate::player::commands::dispatch_playback_command(
        crate::player::commands::PlaybackCommand::SetBitPerfect(enabled),
    )
    .ok();
}

/// 当前独占播放是否处于 Bit-perfect 直出状态。
pub fn get_usb_exclusive_bit_perfect() -> bool {
    crate::player::output::is_exclusive_bit_perfect()
}

/// 查询当前独占播放输出设备/格式信息（JSON），用于前端展示已选输出设备。
pub fn get_usb_exclusive_device_info() -> String {
    crate::player::output::get_exclusive_device_info()
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
    let headers: std::collections::HashMap<String, String> = if headers_json.trim().is_empty() {
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

/// 读取本地图片文件为 base64，返回 JSON `{"mime":..., "base64":...}`（分享封面上传用）。
pub fn read_image_base64(path: String) -> Result<String, String> {
    crate::plugins::read_image_base64(path)
}

/// 将插件解析得到的视频流式写入 `video-background` 缓存，返回缓存文件完整路径。
/// `cache_dir` 为应用缓存根目录（如 Flutter getApplicationCacheDirectory()）。
pub async fn download_video_to_cache(
    cache_dir: String,
    url: String,
    headers: Option<std::collections::HashMap<String, String>>,
) -> Result<String, String> {
    crate::plugins::download_video_to_cache(cache_dir, url, headers).await
}

/// 清理本功能创建的后台视频缓存文件。
/// `cache_dir` 必须与下载时传入的缓存根目录一致。
pub async fn remove_cached_background_video(cache_dir: String, path: String) -> Result<(), String> {
    crate::plugins::remove_cached_background_video(cache_dir, path).await
}

// =========================================================================
// 宿主端平台签名/加密 + 兜底模块验签（移植自桌面端 host_crypto / fallback_verify）
// 供插件脚本 / 前端调用，对齐桌面端同名 Tauri 命令。
// =========================================================================

/// QQ 音乐 zzcSign 签名。
pub fn host_zzc_sign(text: String) -> String {
    crate::host_crypto::zzc_sign(&text)
}

/// 酷狗参数签名（`platform` 为 `"web"` 用 web 盐，其余用 android 盐）。
pub fn host_kugou_sign(params: String, platform: String, body: Option<String>) -> String {
    crate::host_crypto::kugou_sign(&params, &platform, body.as_deref().unwrap_or(""))
}

/// 酷狗请求密钥（android 盐）。
pub fn host_kugou_request_key() -> String {
    crate::host_crypto::KG_SALT_ANDROID.to_string()
}

/// 咪咕搜索签名。返回 JSON `{"sign":..., "deviceId":...}`。
pub fn host_migu_sign(text: String, time: String) -> String {
    let (sign, device_id) = crate::host_crypto::migu_sign(&text, &time);
    serde_json::json!({ "sign": sign, "deviceId": device_id }).to_string()
}

/// 网易云 linuxapi 加密（AES-128-ECB PKCS7 → hex 大写）。
pub fn host_linuxapi_encrypt(payload: String) -> String {
    crate::host_crypto::linuxapi_encrypt(&payload)
}

/// 网易云 weapi 加密。返回 JSON `{"params":..., "encSecKey":...}`。
pub fn host_weapi_encrypt(payload: String) -> String {
    let (params, enc_sec_key) = crate::host_crypto::weapi_encrypt(&payload);
    serde_json::json!({ "params": params, "encSecKey": enc_sec_key }).to_string()
}

/// 通用 SHA-256 hex（插件脚本哈希等）。
pub fn host_sha256_hex(text: String) -> String {
    crate::host_crypto::sha256_hex(&text)
}

/// 校验服务端下发的兜底模块签名（ed25519）。返回 true 表示签名有效可执行。
pub fn verify_fallback_module_signature(
    module_key: String,
    version: i64,
    code: String,
    signature: String,
) -> Result<bool, String> {
    crate::fallback_verify::verify_fallback_module_signature(
        &module_key,
        version,
        &code,
        &signature,
    )
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
    let result = engine
        .load_musicfree(&plugin_id, &script, &user_vars_json)
        .await;
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
        .call(
            &plugin_id,
            &method,
            &args_json,
            user_vars_json.as_deref(),
            timeout_ms,
        )
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

// =========================================================================
// 统计分布 / 重置（对齐桌面端 statistics）
// =========================================================================

/// 读取音质分布（返回 [`QualityDistribution`] JSON）。
pub fn stats_get_quality_distribution(db_path: String) -> Result<String, String> {
    let conn = open_stats_conn(&db_path)?;
    let v = crate::statistics::get_quality_distribution(&conn)?;
    serde_json::to_string(&v).map_err(|e| e.to_string())
}

/// 读取格式分布（返回 [`FormatDistribution`] JSON）。
pub fn stats_get_format_distribution(db_path: String) -> Result<String, String> {
    let conn = open_stats_conn(&db_path)?;
    let v = crate::statistics::get_format_distribution(&conn)?;
    serde_json::to_string(&v).map_err(|e| e.to_string())
}

/// 读取曲库统计（歌曲/歌手/专辑数等，返回 [`LibraryStats`] JSON）。
pub fn stats_get_library_stats(db_path: String) -> Result<String, String> {
    let conn = open_stats_conn(&db_path)?;
    let v = crate::statistics::get_library_stats(&conn)?;
    serde_json::to_string(&v).map_err(|e| e.to_string())
}

/// 重置本地听歌统计（清空播放计数/时长等，不清收藏与下载）。
pub fn stats_reset_local_statistics(db_path: String) -> Result<(), String> {
    let conn = open_stats_conn(&db_path)?;
    crate::statistics::reset_local_statistics(&conn)
}

// =========================================================================
// 收藏 / 近期目录（对齐桌面端 get_favorite_*/get_recent_*）
// =========================================================================

/// 收藏歌手目录：`favorite_paths` 为收藏的歌曲路径数组。
/// 返回 [`ArtistCatalogItem[]`] JSON。
pub fn stats_get_favorite_artist_catalog(
    db_path: String,
    favorite_paths: Vec<String>,
) -> Result<String, String> {
    let conn = open_stats_conn(&db_path)?;
    let v = crate::statistics::get_favorite_artist_catalog(&conn, favorite_paths)?;
    serde_json::to_string(&v).map_err(|e| e.to_string())
}

/// 收藏专辑目录：`favorite_paths` 为收藏的歌曲路径数组。
/// 返回 [`AlbumCatalogItem[]`] JSON。
pub fn stats_get_favorite_album_catalog(
    db_path: String,
    favorite_paths: Vec<String>,
) -> Result<String, String> {
    let conn = open_stats_conn(&db_path)?;
    let v = crate::statistics::get_favorite_album_catalog(&conn, favorite_paths)?;
    serde_json::to_string(&v).map_err(|e| e.to_string())
}

/// 收藏歌曲路径视图：`favorite_paths` 为收藏的歌曲路径数组。
/// 返回排序过滤后的 `String[]`（歌曲路径）。`sort_mode` 为 [`SongPathSortMode`] 的 snake_case 字符串。
pub fn stats_get_favorite_song_paths_view(
    db_path: String,
    favorite_paths: Vec<String>,
    query: Option<String>,
    sort_mode: String,
    detail_filter_type: Option<String>,
    detail_filter_value: Option<String>,
) -> Result<String, String> {
    let sort: crate::statistics::SongPathSortMode =
        serde_json::from_str(&sort_mode).map_err(|e| e.to_string())?;
    let conn = open_stats_conn(&db_path)?;
    let v = crate::statistics::get_favorite_song_paths_view(
        &conn,
        favorite_paths,
        query,
        sort,
        detail_filter_type,
        detail_filter_value,
    )?;
    serde_json::to_string(&v).map_err(|e| e.to_string())
}

/// 近期专辑目录：`recent_entries_json` 为 [`RecentHistoryImportEntry[]`] 的 camelCase JSON。
/// 返回 [`RecentAlbumCatalogItem[]`] JSON。
pub fn stats_get_recent_album_catalog(
    db_path: String,
    recent_entries_json: String,
) -> Result<String, String> {
    let entries: Vec<crate::statistics::RecentHistoryImportEntry> =
        serde_json::from_str(&recent_entries_json).map_err(|e| e.to_string())?;
    let conn = open_stats_conn(&db_path)?;
    let v = crate::statistics::get_recent_album_catalog(&conn, entries)?;
    serde_json::to_string(&v).map_err(|e| e.to_string())
}

/// 近期歌曲路径视图：`recent_entries_json` 为 [`RecentHistoryImportEntry[]`] 的 camelCase JSON。
/// 返回排序过滤后的 `String[]`。
pub fn stats_get_recent_song_paths_view(
    db_path: String,
    recent_entries_json: String,
    query: Option<String>,
    sort_mode: String,
) -> Result<String, String> {
    let entries: Vec<crate::statistics::RecentHistoryImportEntry> =
        serde_json::from_str(&recent_entries_json).map_err(|e| e.to_string())?;
    let sort: crate::statistics::SongPathSortMode =
        serde_json::from_str(&sort_mode).map_err(|e| e.to_string())?;
    let conn = open_stats_conn(&db_path)?;
    let v = crate::statistics::get_recent_song_paths_view(&conn, entries, query, sort)?;
    serde_json::to_string(&v).map_err(|e| e.to_string())
}

/// 近期歌单目录：`playlists_json` 为 [`PlaylistImportItem[]`] 的 camelCase JSON，
/// `recent_entries_json` 为 [`RecentHistoryImportEntry[]`] 的 camelCase JSON。
/// 返回 [`RecentPlaylistCatalogItem[]`] JSON。
pub fn stats_get_recent_playlist_catalog(
    playlists_json: String,
    recent_entries_json: String,
) -> Result<String, String> {
    let playlists: Vec<crate::statistics::PlaylistImportItem> =
        serde_json::from_str(&playlists_json).map_err(|e| e.to_string())?;
    let entries: Vec<crate::statistics::RecentHistoryImportEntry> =
        serde_json::from_str(&recent_entries_json).map_err(|e| e.to_string())?;
    let v = crate::statistics::get_recent_playlist_catalog(playlists, entries)?;
    serde_json::to_string(&v).map_err(|e| e.to_string())
}

// =========================================================================
// 封面缓存清理（对齐桌面端 music::covers::clear_cover_cache）
// =========================================================================

/// 清空封面缓存目录。
pub fn clear_cover_cache(cache_dir: String) -> Result<(), String> {
    crate::music::covers::clear_cover_cache(std::path::Path::new(&cache_dir))
}

// =========================================================================
// LX 音源解析辅助（对齐桌面端 get_lx_cover / 换源 / 音质回退 / 缓存清理）
// =========================================================================

/// 获取 LX 音乐源封面 URL。`song_info_json` 为 [`LxUrlSongInfo`] 的 camelCase JSON。
pub async fn get_lx_cover(song_info_json: String) -> Result<String, String> {
    let song_info: LxUrlSongInfo =
        serde_json::from_str(&song_info_json).map_err(|e| e.to_string())?;
    let url = crate::music::url_resolver::get_lx_cover(song_info).await?;
    serde_json::to_string(&url).map_err(|e| e.to_string())
}

/// 清除 LX 音源 URL 直链缓存。
pub async fn clear_lx_url_cache() -> Result<(), String> {
    crate::music::url_resolver::clear_lx_url_cache().await
}

/// 清除 LX 音源全部缓存（URL 直链 + 搜索结果）。
pub async fn clear_lx_all_cache() -> Result<(), String> {
    if crate::music::url_resolver::clear_lx_url_cache()
        .await
        .is_err()
    {
        return Err("清除 URL 缓存失败".to_string());
    }
    crate::music::lx_search::clear_lx_all_cache().await
}

/// 换源：在其他落雪平台搜索同名同歌手歌曲。
/// 返回 [`AlternativeSourceResult`] JSON 或 "null"。
pub async fn find_alternative_lx_source(
    song_name: String,
    song_artist: String,
    song_duration: f64,
    failed_sources: Vec<String>,
    qualities: Vec<String>,
) -> Result<String, String> {
    let v = crate::music::url_resolver::find_alternative_lx_source(
        song_name,
        song_artist,
        song_duration,
        failed_sources,
        qualities,
    )
    .await?;
    serde_json::to_string(&v).map_err(|e| e.to_string())
}

/// 按音质顺序回退解析播放直链（返回 [`ResolvedUrl`] JSON 或 "null"）。
pub async fn resolve_lx_with_quality_fallback(
    song_info_json: String,
    qualities: Vec<String>,
) -> Result<String, String> {
    let song_info: LxUrlSongInfo =
        serde_json::from_str(&song_info_json).map_err(|e| e.to_string())?;
    let v =
        crate::music::url_resolver::resolve_lx_with_quality_fallback(song_info, qualities).await?;
    serde_json::to_string(&v).map_err(|e| e.to_string())
}

// =========================================================================
// 远程源管理增强（对齐桌面端 test_remote_source / precache / list_directory）
// =========================================================================

/// 测试远程源连通性。`source_json` 为 [`RemoteSourceInput`] 的 camelCase JSON。
/// 返回 `{"ok":bool,"message":String}` JSON。
pub async fn test_remote_source(source_json: String) -> Result<String, String> {
    #[derive(serde::Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct TestInput {
        id: Option<String>,
        name: String,
        provider: String,
        base_url: String,
        username: Option<String>,
        password: Option<String>,
        root_path: Option<String>,
    }
    let input: TestInput = serde_json::from_str(&source_json).map_err(|e| e.to_string())?;
    if input.provider != "webdav" {
        return Err("第一版仅支持 WebDAV".to_string());
    }
    let creds = crate::remote::types::RemoteSourceCredentials {
        id: input.id.unwrap_or_else(|| "test".to_string()),
        name: input.name,
        provider: input.provider,
        base_url: input.base_url.trim().trim_end_matches('/').to_string(),
        username: input.username,
        password: input.password,
        root_path: input.root_path.unwrap_or_else(|| "/".to_string()),
        enabled: true,
        last_sync_at: None,
        last_sync_error: None,
        created_at: crate::remote::now_seconds(),
        updated_at: crate::remote::now_seconds(),
    };
    match crate::remote::webdav::test_connection(&creds).await {
        Ok(()) => Ok(serde_json::json!({ "ok": true, "message": "连接成功" }).to_string()),
        Err(error) => Ok(serde_json::json!({ "ok": false, "message": error }).to_string()),
    }
}

/// 预缓存远程歌曲到本地缓存（`remote_uri` 形如 `remote://<source_id>/<path>`）。
pub async fn precache_remote_song(
    db_path: String,
    cache_root: String,
    remote_uri: String,
) -> Result<(), String> {
    if !crate::remote::cache::is_remote_uri(&remote_uri) {
        return Ok(());
    }
    let db_conn = std::sync::Arc::new(std::sync::Mutex::new(open_scan_conn(&db_path)?));
    crate::remote::cache::ensure_cached_path(
        std::path::Path::new(&cache_root),
        db_conn,
        &remote_uri,
    )
    .await
    .map(|_| ())
}

/// 列出远程源指定目录下的条目（返回 [`RemoteFileEntry[]`] JSON）。
pub async fn list_remote_directory(
    db_path: String,
    source_id: String,
    path: String,
) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    let source = crate::remote::repository::get_source(&conn, &source_id)?;
    let entries = crate::remote::webdav::list_directory(
        crate::remote::webdav::shared_client(),
        &source,
        &path,
    )
    .await?;
    serde_json::to_string(&entries).map_err(|e| e.to_string())
}

// =========================================================================
// 下载工具链（对齐桌面端 probe_url_size / write_text / fetch_image /
// embed_metadata / finalize_extras）
// =========================================================================

/// 用 `Range: bytes=0-0` 探测直链文件大小（返回 [`ProbeUrlInfo`] JSON）。
pub async fn probe_url_size(url: String) -> Result<String, String> {
    let info = crate::toolbox::probe_url_size(url).await?;
    serde_json::to_string(&info).map_err(|e| e.to_string())
}

/// 写入文本文件（自动创建父目录），返回目标路径。
pub async fn write_text_file(content: String, dest_path: String) -> Result<String, String> {
    crate::toolbox::write_text_file(content, dest_path).await
}

/// 下载图片二进制（绕过 WebView CORS），返回 `{"data":String,"mime":String}` JSON（data 为 base64）。
pub async fn fetch_image_bytes(url: String) -> Result<String, String> {
    let img = crate::toolbox::fetch_image_bytes(url).await?;
    serde_json::to_string(&img).map_err(|e| e.to_string())
}

/// 将歌曲元数据写入音频文件 tag。`request_json` 为 [`EmbedMetadataRequest`] 的 camelCase JSON。
pub async fn embed_audio_metadata(request_json: String) -> Result<(), String> {
    let request: crate::music::tags::EmbedMetadataRequest =
        serde_json::from_str(&request_json).map_err(|e| e.to_string())?;
    crate::toolbox::embed_audio_metadata(request).await
}

// =========================================================================
// 曲库 / 文件 / 下载管理补齐（对齐桌面端 library/files/toolbox）
// =========================================================================

/// 判断路径是否为目录。
pub fn is_directory(path: String) -> bool {
    crate::music::files::is_directory(path)
}

/// 保存歌手头像到封面目录，并可选写入该歌手所有歌曲标签。
/// 返回头像路径（`save_artist_avatar_response.avatar_path` 的 JSON 字符串）。
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

/// 音乐库「全部歌曲」视图（支持查询过滤、歌手/专辑过滤、排序），返回 `String[]` 路径。
pub fn get_library_song_paths_for_all_view(
    db_path: String,
    query: Option<String>,
    artist_filter: Option<String>,
    album_filter: Option<String>,
    sort_mode: String,
) -> Result<String, String> {
    let mode: crate::music::library::LibrarySongSortMode =
        serde_json::from_str(&sort_mode).map_err(|e| e.to_string())?;
    let conn = open_scan_conn(&db_path)?;
    let paths = crate::music::library::get_library_song_paths_for_all_view(
        &conn,
        query,
        artist_filter,
        album_filter,
        mode,
    )?;
    serde_json::to_string(&paths).map_err(|e| e.to_string())
}

/// 扫描音乐库下所有已添加文件夹，返回全部 `LibrarySong[]`。
pub fn scan_library(
    db_path: String,
    minimum_duration_seconds: Option<u32>,
) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    let shared = std::sync::Arc::new(std::sync::Mutex::new(conn));
    let songs = crate::music::library::scan_library(shared, minimum_duration_seconds)?;
    serde_json::to_string(&songs).map_err(|e| e.to_string())
}

/// 获取文件夹的直接子目录节点（返回 `FolderNode[]`）。
pub fn get_folder_children(db_path: String, folder_path: String) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    let nodes = crate::music::library::get_folder_children(&conn, folder_path)?;
    serde_json::to_string(&nodes).map_err(|e| e.to_string())
}

/// 递归查找某文件夹下的第一首歌曲路径（用于文件夹视图预览）。
pub fn get_folder_first_song(db_path: String, folder_path: String) -> Result<String, String> {
    let conn = open_scan_conn(&db_path)?;
    let path = crate::music::scanner::find_first_song_in_folder(&conn, &folder_path);
    serde_json::to_string(&path).map_err(|e| e.to_string())
}

/// 在父目录下创建新文件夹，返回新文件夹路径。
pub fn create_folder(parent_path: String, folder_name: String) -> Result<String, String> {
    crate::music::files::create_folder(parent_path, folder_name)
}

/// 删除文件夹（递归删除目录下所有内容）。注意：真删，不会进回收站。
pub fn delete_folder(path: String) -> Result<(), String> {
    crate::music::files::delete_folder(path)
}

/// 移动文件到目标文件夹（同步数据库中的歌曲路径）。
pub fn move_file_to_folder(
    db_path: String,
    source_path: String,
    target_folder: String,
) -> Result<(), String> {
    let mut conn = open_scan_conn(&db_path)?;
    crate::music::files::move_file_to_folder(&mut conn, source_path, target_folder)
}

/// 批量移动音乐文件到目标文件夹（返回 `BatchMoveMusicFilesResult` JSON）。
pub fn batch_move_music_files(
    db_path: String,
    paths: Vec<String>,
    target_folder: String,
) -> Result<String, String> {
    let mut conn = open_scan_conn(&db_path)?;
    let result = crate::music::files::batch_move_music_files(&mut conn, paths, target_folder)?;
    serde_json::to_string(&result).map_err(|e| e.to_string())
}

/// 移动单个音乐文件到新路径（同步数据库路径）。
pub fn move_music_file(db_path: String, old_path: String, new_path: String) -> Result<(), String> {
    let mut conn = open_scan_conn(&db_path)?;
    crate::music::files::move_music_file(&mut conn, old_path, new_path)
}

/// 删除音乐文件（真删，不回收）。
pub fn delete_music_file(path: String) -> Result<(), String> {
    crate::music::files::delete_music_file(path)
}

/// 从最近播放历史与统计中批量移除歌曲。
pub fn remove_songs_from_history_and_statistics(
    db_path: String,
    song_paths: Vec<String>,
) -> Result<(), String> {
    let mut conn = open_stats_conn(&db_path)?;
    crate::statistics::remove_songs_from_history_and_statistics(&mut conn, song_paths)
}

/// 解析下载目标路径：目录 + 文件名，`overwrite_existing` 为 false 时自动追加 `(1)`/`(2)` 避免冲突。
pub fn resolve_download_path(
    directory: String,
    file_name: String,
    overwrite_existing: bool,
) -> Result<String, String> {
    crate::toolbox::resolve_download_path(directory, file_name, overwrite_existing)
}

/// 按命名风格构建下载文件基名（不含扩展名）。
pub fn build_download_basename(
    title: String,
    artist: String,
    album: String,
    file_name_style: String,
) -> String {
    crate::toolbox::build_download_basename(title, artist, album, file_name_style)
}

/// 写入原始下载字节到目标路径（创建父目录），返回目标路径。
pub async fn save_download_bytes(data: Vec<u8>, dest_path: String) -> Result<String, String> {
    crate::toolbox::save_download_bytes(data, dest_path).await
}

/// 保存下载歌词文本到目标路径（创建父目录），返回目标路径。
pub async fn save_download_lyrics(content: String, dest_path: String) -> Result<String, String> {
    crate::toolbox::save_download_lyrics(content, dest_path).await
}

// =========================================================================
// 流缓存增强（对齐桌面端 get_stream_cache_info/is_stream_cached/
// copy_stream_cache/wait_stream_complete）
// =========================================================================

/// 获取流缓存信息，返回 `{"current":u64,"max":u64}` JSON。
pub fn get_stream_cache_info() -> String {
    serde_json::json!({
        "current": crate::player::stream_cache::current_cache_size(),
        "max": crate::player::stream_cache::max_cache_size(),
    })
    .to_string()
}

/// 判断某个 URL 是否已缓存完整。
pub fn is_stream_cached(url: String) -> bool {
    crate::player::stream_cache::is_url_cached(&url)
}

/// 将已缓存的 URL 文件复制到目标路径，返回实际写入字节数。
pub fn copy_stream_cache(url: String, dest_path: String) -> Result<u64, String> {
    crate::player::stream_cache::copy_cache_to(&url, &dest_path)
}

/// 等待某个 URL 缓存下载完成（超时秒数），完成返回 true。
pub async fn wait_stream_complete(url: String, timeout_secs: u64) -> bool {
    tokio::task::spawn_blocking(move || {
        crate::player::stream_cache::wait_url_complete(&url, timeout_secs)
    })
    .await
    .unwrap_or(false)
}

// =========================================================================
// 响度目标设置 + 云端时长合并（对齐桌面端 update_loudness_settings /
// merge_cloud_listen_duration）
// =========================================================================

/// 在播放前评估/更新响度元数据并计算目标线性增益。
/// `enabled` 为 true 时按 `gain_offset_db`（dB）与 `prevent_clipping` 计算，
/// 返回 `ProcessLoudnessResult` JSON；`enabled` 为 false 时返回 1.0（原始音量）。
pub fn update_loudness_settings(
    db_path: String,
    enabled: bool,
    song_id: Option<i64>,
    song_path: Option<String>,
    gain_offset_db: f32,
    prevent_clipping: bool,
) -> Result<String, String> {
    let conn = open_stats_conn(&db_path)?;
    let gain = if enabled {
        if song_id.is_none() || song_path.is_none() {
            return Ok(serde_json::json!({ "enabled": true, "targetGain": 1.0 }).to_string());
        }
        let record = crate::player::loudness::process_song_on_play(
            &conn,
            song_id.unwrap(),
            song_path.as_ref().unwrap(),
        )?;
        crate::player::loudness::calculate_playback_gain(&record, gain_offset_db, prevent_clipping)
    } else {
        1.0
    };
    Ok(serde_json::json!({ "enabled": enabled, "targetGain": gain }).to_string())
}

/// 将云端累计总听歌时长合并进本地（取较大值），返回 [`CloudMergeResult`] JSON。
pub fn merge_cloud_listen_duration(db_path: String, total_seconds: i64) -> Result<String, String> {
    let conn = open_stats_conn(&db_path)?;
    let result = crate::statistics::merge_cloud_listen_duration(&conn, total_seconds)?;
    serde_json::to_string(&result).map_err(|e| e.to_string())
}

/// 导出全局 + 每日听歌统计快照（JSON），用于上传服务端跨设备同步。
pub fn stats_export_listen_snapshot(db_path: String) -> Result<String, String> {
    let conn = open_stats_conn(&db_path)?;
    let v = crate::statistics::export_listen_stats_snapshot(&conn)?;
    serde_json::to_string(&v).map_err(|e| e.to_string())
}

/// 导入（MAX 合并）服务端听歌统计快照（JSON），返回 [`ListenStatsSyncResult`] JSON。
pub fn stats_import_listen_snapshot(
    db_path: String,
    snapshot_json: String,
) -> Result<String, String> {
    let snapshot: crate::statistics::ListenStatsSnapshot =
        serde_json::from_str(&snapshot_json).map_err(|e| e.to_string())?;
    let mut conn = open_stats_conn(&db_path)?;
    let result = crate::statistics::import_listen_stats_snapshot(&mut conn, &snapshot)?;
    serde_json::to_string(&result).map_err(|e| e.to_string())
}

/// 导入（累加合并）服务端听歌统计快照（JSON），返回 [`ListenStatsSyncResult`] JSON。
pub fn stats_import_listen_snapshot_add(
    db_path: String,
    snapshot_json: String,
) -> Result<String, String> {
    let snapshot: crate::statistics::ListenStatsSnapshot =
        serde_json::from_str(&snapshot_json).map_err(|e| e.to_string())?;
    let mut conn = open_stats_conn(&db_path)?;
    let result = crate::statistics::import_listen_stats_snapshot_add(&mut conn, &snapshot)?;
    serde_json::to_string(&result).map_err(|e| e.to_string())
}

/// 清零本地累计 + 每日听歌统计（服务端后台清零后下发）。
pub fn stats_clear_listen_stats(db_path: String) -> Result<(), String> {
    let conn = open_stats_conn(&db_path)?;
    crate::statistics::clear_listen_stats(&conn)
}

// =========================================================================
// 插件引擎会话增强（对齐桌面端 store_import / cookie_header_for_domain /
// store_snapshot）
// =========================================================================

/// 导入插件引擎店铺会话（cookie + storage），仅补缺不覆盖。
pub async fn plugin_engine_store_import(
    data_dir: String,
    payload_json: String,
) -> Result<(), String> {
    #[derive(serde::Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct StoreImportPayload {
        cookies: std::collections::HashMap<String, crate::plugin_host::CookieEntry>,
        storage: std::collections::HashMap<String, String>,
    }
    let payload: StoreImportPayload =
        serde_json::from_str(&payload_json).map_err(|e| e.to_string())?;
    let engine = crate::plugin_host::global_engine(&data_dir);
    engine
        .store()
        .import_local(payload.cookies, payload.storage);
    Ok(())
}

/// 获取某个域名的 cookie header（分号分隔的 `name=value` 字符串）。
pub async fn plugin_engine_cookie_header_for_domain(
    data_dir: String,
    domain: String,
) -> Result<String, String> {
    let engine = crate::plugin_host::global_engine(&data_dir);
    Ok(engine.store().cookie_header_for_domain(&domain))
}

/// 获取插件引擎会话快照，返回 `{"cookies":..., "storage":...}` JSON。
pub async fn plugin_engine_store_snapshot(data_dir: String) -> Result<String, String> {
    let engine = crate::plugin_host::global_engine(&data_dir);
    let result = serde_json::json!({
        "cookies": engine.store().cookie_snapshot(),
        "storage": engine.store().storage_snapshot(),
    });
    serde_json::to_string(&result).map_err(|e| e.to_string())
}
