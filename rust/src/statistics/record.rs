use super::*;

// =====================================================
// 辅助函数
// =====================================================

/// 判断是否为无效的专辑/歌手名（用于统计时排除）
pub(crate) fn is_invalid_name(name: &str) -> bool {
    let normalized = name.trim().to_lowercase();
    normalized.is_empty()
        || normalized == "未知"
        || normalized == "未知专辑"
        || normalized == "未知歌手"
        || normalized == "unknown"
        || normalized == "unknown album"
        || normalized == "unknown artist"
}

/// 判断是否为 Hi-Res (24bit + >=48kHz)
pub(crate) fn is_hires(bit_depth: Option<i64>, sample_rate: i64) -> bool {
    bit_depth.unwrap_or(0) >= 24 && sample_rate >= 48000
}

pub(crate) const SUPPORTED_STATS_VERSION: i64 = 1;
pub(crate) const RECENT_PLAY_LIMIT: i64 = 300;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PortableSongIdentity {
    pub title: String,
    pub artist: String,
    pub album: String,
    pub duration_ms: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub track_number: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PortableSongStats {
    pub play_count: i64,
    pub play_time_ms: i64,
    pub full_play_count: i64,
    pub skip_count: i64,
    pub first_played_at: Option<String>,
    pub last_played_at: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PortableSongStatsEntry {
    pub song_identity: PortableSongIdentity,
    pub song_stats: PortableSongStats,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PortableGlobalStats {
    pub total_play_count: i64,
    pub total_play_time_ms: i64,
    pub first_played_at: Option<String>,
    pub last_played_at: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PortableDailyStats {
    pub date: String,
    pub play_count: i64,
    pub play_time_ms: i64,
    pub unique_songs: i64,
    pub unique_artists: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PortableHourlyStats {
    pub hour: i64,
    pub play_count: i64,
    pub play_time_ms: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PortableRecentPlay {
    pub played_at: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub duration_ms: i64,
    pub listened_ms: i64,
    pub is_full_play: bool,
    pub is_skip: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PortableStatisticsPayload {
    pub global: PortableGlobalStats,
    pub songs: Vec<PortableSongStatsEntry>,
    pub daily: Vec<PortableDailyStats>,
    pub hourly: Vec<PortableHourlyStats>,
    #[serde(default)]
    pub recent_plays: Vec<PortableRecentPlay>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PortableStatisticsExport {
    pub format: String,
    pub version: i64,
    pub exported_at: String,
    pub app_version: String,
    pub export_id: String,
    pub library_fingerprint: Option<String>,
    pub stats: PortableStatisticsPayload,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StatisticsExportOptions {
    pub file_path: String,
    pub include_recent_plays: bool,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StatisticsImportPreviewOptions {
    pub file_path: String,
}

#[derive(Debug, Deserialize, Clone, Copy)]
#[serde(rename_all = "camelCase")]
pub enum StatisticsImportMode {
    Overwrite,
    Merge,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StatisticsImportOptions {
    pub file_path: String,
    pub mode: StatisticsImportMode,
    pub continue_duplicate_import: bool,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StatisticsExportResult {
    pub file_path: String,
    pub export_id: String,
    pub exported_at: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StatisticsImportPreview {
    pub version: i64,
    pub exported_at: String,
    pub app_version: String,
    pub export_id: String,
    pub song_stats_count: usize,
    pub daily_stats_count: usize,
    pub recent_plays_count: usize,
    pub matched_song_count: usize,
    pub unmatched_song_count: usize,
    pub duplicate_import_detected: bool,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StatisticsImportResult {
    pub mode: String,
    pub matched_song_count: usize,
    pub unmatched_song_count: usize,
    pub merged_song_count: usize,
    pub imported_recent_plays_count: usize,
    pub duplicate_import_skipped: bool,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RecordPlayPayload {
    pub song_path: String,
    pub listened_ms: i64,
    pub duration_ms: i64,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub track_number: Option<String>,
    pub count_as_play: Option<bool>,
}

#[derive(Debug, Clone)]
pub(crate) struct LibraryMatchCandidate {
    pub(crate) path: String,
    pub(crate) identity: PortableSongIdentity,
}

#[derive(Default)]
pub(crate) struct LibraryMatchIndex {
    pub(crate) strict: HashMap<String, Vec<LibraryMatchCandidate>>,
    pub(crate) weak_artist: HashMap<String, Vec<LibraryMatchCandidate>>,
    pub(crate) weak_title: HashMap<String, Vec<LibraryMatchCandidate>>,
}

pub(crate) fn now_unix_seconds() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}

pub(crate) fn now_unix_millis() -> i128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i128
}

pub(crate) fn now_iso_timestamp() -> Result<String, String> {
    OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .map_err(|e| e.to_string())
}

pub(crate) fn unix_seconds_to_iso(timestamp: i64) -> Result<String, String> {
    OffsetDateTime::from_unix_timestamp(timestamp)
        .map_err(|e| e.to_string())?
        .format(&Rfc3339)
        .map_err(|e| e.to_string())
}

pub(crate) fn normalize_identity_text(value: &str) -> String {
    value
        .trim()
        .to_lowercase()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

pub(crate) fn parse_track_number_value(value: Option<&str>) -> Option<i64> {
    value
        .unwrap_or_default()
        .split(['/', '\\'])
        .next()
        .and_then(|raw| {
            let digits: String = raw.chars().take_while(|ch| ch.is_ascii_digit()).collect();
            if digits.is_empty() {
                None
            } else {
                digits.parse::<i64>().ok()
            }
        })
}

pub(crate) fn strict_identity_key(identity: &PortableSongIdentity) -> String {
    format!(
        "{}|{}|{}|{}",
        normalize_identity_text(&identity.title),
        normalize_identity_text(&identity.artist),
        normalize_identity_text(&identity.album),
        identity.duration_ms.max(0),
    )
}

pub(crate) fn weak_artist_identity_key(identity: &PortableSongIdentity) -> String {
    format!(
        "{}|{}|{}",
        normalize_identity_text(&identity.title),
        normalize_identity_text(&identity.artist),
        identity.duration_ms.max(0),
    )
}

pub(crate) fn weak_title_identity_key(identity: &PortableSongIdentity) -> String {
    format!(
        "{}|{}",
        normalize_identity_text(&identity.title),
        identity.duration_ms.max(0),
    )
}

pub(crate) fn recent_play_dedupe_key(entry: &PortableRecentPlay) -> String {
    format!(
        "{}|{}|{}|{}",
        entry.played_at,
        normalize_identity_text(&entry.title),
        normalize_identity_text(&entry.artist),
        entry.duration_ms.max(0),
    )
}

pub(crate) fn resolve_song_identity(
    title: &str,
    artist: &str,
    album: &str,
    duration_ms: i64,
    track_number: Option<i64>,
    fallback_path: Option<&str>,
) -> PortableSongIdentity {
    let fallback_title = fallback_path
        .and_then(|path| Path::new(path).file_stem())
        .map(|value| value.to_string_lossy().into_owned())
        .unwrap_or_else(|| "Unknown".to_string());

    PortableSongIdentity {
        title: if title.trim().is_empty() {
            fallback_title
        } else {
            title.trim().to_string()
        },
        artist: artist.trim().to_string(),
        album: album.trim().to_string(),
        duration_ms: duration_ms.max(0),
        track_number,
    }
}

pub(crate) fn derive_play_flags(listened_ms: i64, duration_ms: i64) -> (bool, bool) {
    if listened_ms <= 0 || duration_ms <= 0 {
        return (false, false);
    }

    let full_threshold = ((duration_ms as f64) * 0.9).round() as i64;
    let skip_threshold = ((duration_ms as f64) * 0.5).round() as i64;
    let is_full_play = listened_ms >= full_threshold.max(duration_ms - 5_000);
    let is_skip = !is_full_play && listened_ms < skip_threshold.min(30_000);
    (is_full_play, is_skip)
}

pub(crate) fn sqlite_local_date(conn: &rusqlite::Connection, played_at: i64) -> Result<String, String> {
    conn.query_row(
        "SELECT strftime('%Y-%m-%d', ?1, 'unixepoch', 'localtime')",
        [played_at],
        |row| row.get(0),
    )
    .map_err(|e| e.to_string())
}

pub(crate) fn sqlite_local_hour(conn: &rusqlite::Connection, played_at: i64) -> Result<i64, String> {
    conn.query_row(
        "SELECT CAST(strftime('%H', ?1, 'unixepoch', 'localtime') AS INTEGER)",
        [played_at],
        |row| row.get(0),
    )
    .map_err(|e| e.to_string())
}

pub(crate) fn get_statistics_meta(conn: &rusqlite::Connection, key: &str) -> Result<Option<String>, String> {
    conn.query_row(
        "SELECT value FROM statistics_meta WHERE key = ?1",
        [key],
        |row| row.get(0),
    )
    .optional()
    .map_err(|e| e.to_string())
}

pub(crate) fn set_statistics_meta(conn: &rusqlite::Connection, key: &str, value: &str) -> Result<(), String> {
    conn.execute(
        "INSERT INTO statistics_meta (key, value)
         VALUES (?1, ?2)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        rusqlite::params![key, value],
    )
    .map_err(|e| e.to_string())?;
    Ok(())
}

pub(crate) fn clear_aggregate_statistics(conn: &rusqlite::Connection) -> Result<(), String> {
    conn.execute("DELETE FROM global_stats", [])
        .map_err(|e| e.to_string())?;
    conn.execute("DELETE FROM song_stats", [])
        .map_err(|e| e.to_string())?;
    conn.execute("DELETE FROM daily_stats", [])
        .map_err(|e| e.to_string())?;
    conn.execute("DELETE FROM hourly_stats", [])
        .map_err(|e| e.to_string())?;
    conn.execute("DELETE FROM daily_unique_song_entries", [])
        .map_err(|e| e.to_string())?;
    conn.execute("DELETE FROM daily_unique_artist_entries", [])
        .map_err(|e| e.to_string())?;
    conn.execute("DELETE FROM recent_plays", [])
        .map_err(|e| e.to_string())?;
    Ok(())
}

pub(crate) fn merge_global_stats(
    conn: &rusqlite::Connection,
    global: &PortableGlobalStats,
) -> Result<(), String> {
    conn.execute(
        "INSERT INTO global_stats (id, total_play_count, total_play_time_ms, first_played_at, last_played_at)
         VALUES (1, ?1, ?2, ?3, ?4)
         ON CONFLICT(id) DO UPDATE SET
           total_play_count = global_stats.total_play_count + excluded.total_play_count,
           total_play_time_ms = global_stats.total_play_time_ms + excluded.total_play_time_ms,
           first_played_at = CASE
             WHEN global_stats.first_played_at IS NULL THEN excluded.first_played_at
             WHEN excluded.first_played_at IS NULL THEN global_stats.first_played_at
             WHEN excluded.first_played_at < global_stats.first_played_at THEN excluded.first_played_at
             ELSE global_stats.first_played_at
           END,
           last_played_at = CASE
             WHEN global_stats.last_played_at IS NULL THEN excluded.last_played_at
             WHEN excluded.last_played_at IS NULL THEN global_stats.last_played_at
             WHEN excluded.last_played_at > global_stats.last_played_at THEN excluded.last_played_at
             ELSE global_stats.last_played_at
           END",
        rusqlite::params![
            global.total_play_count,
            global.total_play_time_ms,
            global.first_played_at,
            global.last_played_at,
        ],
    )
    .map_err(|e| e.to_string())?;
    Ok(())
}

pub(crate) fn upsert_song_stats(
    conn: &rusqlite::Connection,
    identity: &PortableSongIdentity,
    stats: &PortableSongStats,
) -> Result<(), String> {
    let strict_key = strict_identity_key(identity);
    conn.execute(
        "INSERT INTO song_stats (
            strict_identity_key, title, artist, album, duration_ms, track_number,
            play_count, play_time_ms, full_play_count, skip_count, first_played_at, last_played_at
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
         ON CONFLICT(strict_identity_key) DO UPDATE SET
            title = excluded.title,
            artist = excluded.artist,
            album = excluded.album,
            duration_ms = excluded.duration_ms,
            track_number = excluded.track_number,
            play_count = song_stats.play_count + excluded.play_count,
            play_time_ms = song_stats.play_time_ms + excluded.play_time_ms,
            full_play_count = song_stats.full_play_count + excluded.full_play_count,
            skip_count = song_stats.skip_count + excluded.skip_count,
            first_played_at = CASE
              WHEN song_stats.first_played_at IS NULL THEN excluded.first_played_at
              WHEN excluded.first_played_at IS NULL THEN song_stats.first_played_at
              WHEN excluded.first_played_at < song_stats.first_played_at THEN excluded.first_played_at
              ELSE song_stats.first_played_at
            END,
            last_played_at = CASE
              WHEN song_stats.last_played_at IS NULL THEN excluded.last_played_at
              WHEN excluded.last_played_at IS NULL THEN song_stats.last_played_at
              WHEN excluded.last_played_at > song_stats.last_played_at THEN excluded.last_played_at
              ELSE song_stats.last_played_at
            END",
        rusqlite::params![
            strict_key,
            identity.title,
            identity.artist,
            identity.album,
            identity.duration_ms,
            identity.track_number,
            stats.play_count,
            stats.play_time_ms,
            stats.full_play_count,
            stats.skip_count,
            stats.first_played_at,
            stats.last_played_at,
        ],
    )
    .map_err(|e| e.to_string())?;
    Ok(())
}

pub(crate) fn upsert_daily_stats(
    conn: &rusqlite::Connection,
    daily: &PortableDailyStats,
) -> Result<(), String> {
    conn.execute(
        "INSERT INTO daily_stats (date, play_count, play_time_ms, unique_songs, unique_artists)
         VALUES (?1, ?2, ?3, ?4, ?5)
         ON CONFLICT(date) DO UPDATE SET
            play_count = daily_stats.play_count + excluded.play_count,
            play_time_ms = daily_stats.play_time_ms + excluded.play_time_ms,
            unique_songs = MAX(daily_stats.unique_songs, excluded.unique_songs),
            unique_artists = MAX(daily_stats.unique_artists, excluded.unique_artists)",
        rusqlite::params![
            daily.date,
            daily.play_count,
            daily.play_time_ms,
            daily.unique_songs,
            daily.unique_artists,
        ],
    )
    .map_err(|e| e.to_string())?;
    Ok(())
}

pub(crate) fn upsert_hourly_stats(
    conn: &rusqlite::Connection,
    hourly: &PortableHourlyStats,
) -> Result<(), String> {
    conn.execute(
        "INSERT INTO hourly_stats (hour, play_count, play_time_ms)
         VALUES (?1, ?2, ?3)
         ON CONFLICT(hour) DO UPDATE SET
            play_count = hourly_stats.play_count + excluded.play_count,
            play_time_ms = hourly_stats.play_time_ms + excluded.play_time_ms",
        rusqlite::params![hourly.hour, hourly.play_count, hourly.play_time_ms],
    )
    .map_err(|e| e.to_string())?;
    Ok(())
}

pub(crate) fn prune_recent_plays(conn: &rusqlite::Connection) -> Result<(), String> {
    conn.execute(
        "DELETE FROM recent_plays
         WHERE id NOT IN (
           SELECT id FROM recent_plays ORDER BY played_at DESC, id DESC LIMIT ?1
         )",
        [RECENT_PLAY_LIMIT],
    )
    .map_err(|e| e.to_string())?;
    Ok(())
}

pub(crate) fn insert_recent_play(
    conn: &rusqlite::Connection,
    entry: &PortableRecentPlay,
) -> Result<bool, String> {
    let affected = conn
        .execute(
            "INSERT OR IGNORE INTO recent_plays (
                recent_dedupe_key, played_at, title, artist, album, duration_ms, listened_ms, is_full_play, is_skip
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
            rusqlite::params![
                recent_play_dedupe_key(entry),
                entry.played_at,
                entry.title,
                entry.artist,
                entry.album,
                entry.duration_ms,
                entry.listened_ms,
                if entry.is_full_play { 1 } else { 0 },
                if entry.is_skip { 1 } else { 0 },
            ],
        )
        .map_err(|e| e.to_string())?;
    prune_recent_plays(conn)?;
    Ok(affected > 0)
}

pub(crate) fn record_unique_daily_entries(
    conn: &rusqlite::Connection,
    date: &str,
    identity: &PortableSongIdentity,
) -> Result<(bool, bool), String> {
    let song_added = conn
        .execute(
            "INSERT OR IGNORE INTO daily_unique_song_entries (date, song_identity_key) VALUES (?1, ?2)",
            rusqlite::params![date, strict_identity_key(identity)],
        )
        .map_err(|e| e.to_string())?
        > 0;

    let artist_key = normalize_identity_text(&identity.artist);
    let artist_added = if artist_key.is_empty() {
        false
    } else {
        conn.execute(
            "INSERT OR IGNORE INTO daily_unique_artist_entries (date, artist_key) VALUES (?1, ?2)",
            rusqlite::params![date, artist_key],
        )
        .map_err(|e| e.to_string())?
            > 0
    };

    Ok((song_added, artist_added))
}

pub(crate) fn record_aggregate_play(
    conn: &rusqlite::Connection,
    identity: &PortableSongIdentity,
    played_at: i64,
    listened_ms: i64,
    is_full_play: bool,
    is_skip: bool,
    count_as_play: bool,
) -> Result<(), String> {
    let play_count = if count_as_play { 1 } else { 0 };
    let played_at_iso = unix_seconds_to_iso(played_at)?;
    merge_global_stats(
        conn,
        &PortableGlobalStats {
            total_play_count: play_count,
            total_play_time_ms: listened_ms.max(0),
            first_played_at: Some(played_at_iso.clone()),
            last_played_at: Some(played_at_iso.clone()),
        },
    )?;

    upsert_song_stats(
        conn,
        identity,
        &PortableSongStats {
            play_count,
            play_time_ms: listened_ms.max(0),
            full_play_count: if count_as_play && is_full_play { 1 } else { 0 },
            skip_count: if count_as_play && is_skip { 1 } else { 0 },
            first_played_at: Some(played_at_iso.clone()),
            last_played_at: Some(played_at_iso.clone()),
        },
    )?;

    let date = sqlite_local_date(conn, played_at)?;
    let (is_new_song, is_new_artist) = record_unique_daily_entries(conn, &date, identity)?;
    upsert_daily_stats(
        conn,
        &PortableDailyStats {
            date,
            play_count,
            play_time_ms: listened_ms.max(0),
            unique_songs: if is_new_song { 1 } else { 0 },
            unique_artists: if is_new_artist { 1 } else { 0 },
        },
    )?;

    let hour = sqlite_local_hour(conn, played_at)?;
    upsert_hourly_stats(
        conn,
        &PortableHourlyStats {
            hour,
            play_count,
            play_time_ms: listened_ms.max(0),
        },
    )?;

    if count_as_play {
        insert_recent_play(
            conn,
            &PortableRecentPlay {
                played_at: played_at_iso,
                title: identity.title.clone(),
                artist: identity.artist.clone(),
                album: identity.album.clone(),
                duration_ms: identity.duration_ms,
                listened_ms: listened_ms.max(0),
                is_full_play,
                is_skip,
            },
        )?;
    }

    Ok(())
}
