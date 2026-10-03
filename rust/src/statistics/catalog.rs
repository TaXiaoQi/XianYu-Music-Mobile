use super::*;

// =====================================================
// 播放历史与行为统计
// =====================================================

/// 时间范围（用于行为统计）
#[derive(Deserialize, Debug)]
#[serde(tag = "type")]
pub enum TimeRange {
    All,
    Days7,
    Days30,
    ThisYear,
}

impl TimeRange {
    pub(crate) fn to_timestamp_from(&self) -> Option<i64> {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs() as i64;

        match self {
            TimeRange::All => None,
            TimeRange::Days7 => Some(now - 7 * 24 * 60 * 60),
            TimeRange::Days30 => Some(now - 30 * 24 * 60 * 60),
            TimeRange::ThisYear => Some(now - 365 * 24 * 60 * 60),
        }
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RecentHistoryEntry {
    pub song_path: String,
    pub played_at: i64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RecentHistoryImportEntry {
    pub song_path: String,
    pub played_at: i64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RecentAlbumCatalogItem {
    pub key: String,
    pub name: String,
    pub artist: String,
    pub played_at: i64,
    pub first_song_path: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RecentPlaylistCatalogItem {
    pub id: String,
    pub name: String,
    pub count: u32,
    pub played_at: i64,
    pub first_song_path: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlaylistImportItem {
    pub id: String,
    pub name: String,
    pub song_paths: Vec<String>,
}

#[derive(Deserialize, Clone, Debug)]
#[serde(rename_all = "snake_case")]
pub enum SongPathSortMode {
    Title,
    Artist,
    AddedAt,
    AddedAtAsc,
    FileModifiedAt,
    FileModifiedAtAsc,
}

#[derive(Debug)]
pub(crate) struct SongCatalogRow {
    pub(crate) path: String,
    pub(crate) artist: String,
    pub(crate) artist_names: Vec<String>,
    pub(crate) effective_artist_names: Vec<String>,
    pub(crate) album: String,
    pub(crate) album_artist: String,
    pub(crate) album_key: String,
}

#[derive(Debug)]
pub(crate) struct SongViewRow {
    pub(crate) path: String,
    pub(crate) title: String,
    pub(crate) artist: String,
    pub(crate) artist_names: Vec<String>,
    pub(crate) effective_artist_names: Vec<String>,
    pub(crate) album: String,
    pub(crate) album_artist: String,
    pub(crate) album_key: String,
    pub(crate) added_at: Option<i64>,
    pub(crate) file_modified_at: Option<i64>,
}

pub(crate) fn deserialize_string_list(raw: Option<String>) -> Vec<String> {
    raw.and_then(|value| serde_json::from_str::<Vec<String>>(&value).ok())
        .unwrap_or_default()
}

pub(crate) fn preferred_artist_names(row: &SongCatalogRow) -> Vec<String> {
    if !row.effective_artist_names.is_empty() {
        return row.effective_artist_names.clone();
    }

    if !row.artist_names.is_empty() {
        return row.artist_names.clone();
    }

    vec![row.artist.clone()]
}

pub(crate) fn preferred_view_artist_names(row: &SongViewRow) -> Vec<String> {
    if !row.effective_artist_names.is_empty() {
        return row.effective_artist_names.clone();
    }

    if !row.artist_names.is_empty() {
        return row.artist_names.clone();
    }

    vec![row.artist.clone()]
}

pub(crate) fn resolve_album_key(row: &SongCatalogRow) -> String {
    if !row.album_key.trim().is_empty() {
        return row.album_key.clone();
    }

    let album = if row.album.trim().is_empty() {
        "unknown".to_string()
    } else {
        row.album.to_ascii_lowercase()
    };
    let artist = if row.album_artist.trim().is_empty() && row.artist.trim().is_empty() {
        "unknown".to_string()
    } else if row.album_artist.trim().is_empty() {
        row.artist.to_ascii_lowercase()
    } else {
        row.album_artist.to_ascii_lowercase()
    };

    format!("{}::{}", album, artist,)
}

pub(crate) fn resolve_view_album_key(row: &SongViewRow) -> String {
    if !row.album_key.trim().is_empty() {
        return row.album_key.clone();
    }

    let album = if row.album.trim().is_empty() {
        "unknown".to_string()
    } else {
        row.album.to_ascii_lowercase()
    };
    let artist = if row.album_artist.trim().is_empty() && row.artist.trim().is_empty() {
        "unknown".to_string()
    } else if row.album_artist.trim().is_empty() {
        row.artist.to_ascii_lowercase()
    } else {
        row.album_artist.to_ascii_lowercase()
    };

    format!("{album}::{artist}")
}

pub(crate) fn path_file_name(path: &str) -> String {
    std::path::Path::new(path)
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| path.to_string())
}

pub(crate) fn song_title_label(row: &SongViewRow) -> String {
    if row.title.trim().is_empty() {
        path_file_name(&row.path)
    } else {
        row.title.clone()
    }
}

pub(crate) fn song_matches_query(row: &SongViewRow, query: &str) -> bool {
    let lowered_query = query.trim().to_lowercase();
    if lowered_query.is_empty() {
        return true;
    }

    path_file_name(&row.path)
        .to_lowercase()
        .contains(&lowered_query)
        || row.title.to_lowercase().contains(&lowered_query)
        || row.artist.to_lowercase().contains(&lowered_query)
        || row.album.to_lowercase().contains(&lowered_query)
        || row.album_artist.to_lowercase().contains(&lowered_query)
        || preferred_view_artist_names(row)
            .iter()
            .any(|name| name.to_lowercase().contains(&lowered_query))
}

pub(crate) fn song_has_artist(row: &SongViewRow, artist_name: &str) -> bool {
    preferred_view_artist_names(row)
        .iter()
        .any(|name| name == artist_name)
}

pub(crate) fn sort_song_view_rows(rows: &mut [SongViewRow], sort_mode: &SongPathSortMode) {
    rows.sort_by(|left, right| match sort_mode {
        SongPathSortMode::Title => song_title_label(left)
            .to_lowercase()
            .cmp(&song_title_label(right).to_lowercase()),
        SongPathSortMode::Artist => left
            .artist
            .to_lowercase()
            .cmp(&right.artist.to_lowercase())
            .then_with(|| {
                song_title_label(left)
                    .to_lowercase()
                    .cmp(&song_title_label(right).to_lowercase())
            }),
        SongPathSortMode::AddedAt => right
            .added_at
            .unwrap_or_default()
            .cmp(&left.added_at.unwrap_or_default())
            .then_with(|| {
                song_title_label(left)
                    .to_lowercase()
                    .cmp(&song_title_label(right).to_lowercase())
            }),
        SongPathSortMode::AddedAtAsc => left
            .added_at
            .unwrap_or_default()
            .cmp(&right.added_at.unwrap_or_default())
            .then_with(|| {
                song_title_label(left)
                    .to_lowercase()
                    .cmp(&song_title_label(right).to_lowercase())
            }),
        SongPathSortMode::FileModifiedAt => right
            .file_modified_at
            .unwrap_or_default()
            .cmp(&left.file_modified_at.unwrap_or_default())
            .then_with(|| {
                song_title_label(left)
                    .to_lowercase()
                    .cmp(&song_title_label(right).to_lowercase())
            }),
        SongPathSortMode::FileModifiedAtAsc => left
            .file_modified_at
            .unwrap_or_default()
            .cmp(&right.file_modified_at.unwrap_or_default())
            .then_with(|| {
                song_title_label(left)
                    .to_lowercase()
                    .cmp(&song_title_label(right).to_lowercase())
            }),
    });
}

pub(crate) fn load_song_catalog_row(
    conn: &rusqlite::Connection,
    normalized_path: &str,
) -> Result<Option<SongCatalogRow>, String> {
    conn.query_row(
        "SELECT path, artist, artist_names, effective_artist_names, album, album_artist, album_key
         FROM songs
         WHERE path = ?1",
        [normalized_path],
        |row| {
            Ok(SongCatalogRow {
                path: row.get::<_, String>(0)?,
                artist: row.get::<_, Option<String>>(1)?.unwrap_or_default(),
                artist_names: deserialize_string_list(row.get::<_, Option<String>>(2)?),
                effective_artist_names: deserialize_string_list(row.get::<_, Option<String>>(3)?),
                album: row.get::<_, Option<String>>(4)?.unwrap_or_default(),
                album_artist: row.get::<_, Option<String>>(5)?.unwrap_or_default(),
                album_key: row.get::<_, Option<String>>(6)?.unwrap_or_default(),
            })
        },
    )
    .optional()
    .map_err(|e| e.to_string())
}

pub(crate) fn load_song_view_row(
    conn: &rusqlite::Connection,
    normalized_path: &str,
) -> Result<Option<SongViewRow>, String> {
    conn.query_row(
        "SELECT path, title, artist, artist_names, effective_artist_names, album, album_artist, album_key, added_at, file_modified_at
         FROM songs
         WHERE path = ?1",
        [normalized_path],
        |row| {
            Ok(SongViewRow {
                path: row.get::<_, String>(0)?,
                title: row.get::<_, Option<String>>(1)?.unwrap_or_default(),
                artist: row.get::<_, Option<String>>(2)?.unwrap_or_default(),
                artist_names: deserialize_string_list(row.get::<_, Option<String>>(3)?),
                effective_artist_names: deserialize_string_list(row.get::<_, Option<String>>(4)?),
                album: row.get::<_, Option<String>>(5)?.unwrap_or_default(),
                album_artist: row.get::<_, Option<String>>(6)?.unwrap_or_default(),
                album_key: row.get::<_, Option<String>>(7)?.unwrap_or_default(),
                added_at: row.get::<_, Option<i64>>(8)?,
                file_modified_at: row.get::<_, Option<i64>>(9)?,
            })
        },
    )
    .optional()
    .map_err(|e| e.to_string())
}

pub(crate) fn lookup_song_id(conn: &rusqlite::Connection, normalized_path: &str) -> Option<i64> {
    conn.query_row(
        "SELECT id FROM songs WHERE path = ?1",
        [normalized_path],
        |row| row.get(0),
    )
    .ok()
}

pub(crate) fn build_library_match_index(conn: &rusqlite::Connection) -> Result<LibraryMatchIndex, String> {
    let mut stmt = conn
        .prepare("SELECT path, title, artist, album, duration, track_number FROM songs")
        .map_err(|e| e.to_string())?;

    let rows = stmt
        .query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, Option<String>>(1)?.unwrap_or_default(),
                row.get::<_, Option<String>>(2)?.unwrap_or_default(),
                row.get::<_, Option<String>>(3)?.unwrap_or_default(),
                row.get::<_, Option<i64>>(4)?.unwrap_or_default(),
                row.get::<_, Option<String>>(5)?,
            ))
        })
        .map_err(|e| e.to_string())?;

    let mut index = LibraryMatchIndex::default();

    for row in rows.flatten() {
        let identity = resolve_song_identity(
            &row.1,
            &row.2,
            &row.3,
            row.4.max(0) * 1000,
            parse_track_number_value(row.5.as_deref()),
            Some(&row.0),
        );
        let candidate = LibraryMatchCandidate {
            path: row.0,
            identity: identity.clone(),
        };

        index
            .strict
            .entry(strict_identity_key(&identity))
            .or_default()
            .push(candidate.clone());
        index
            .weak_artist
            .entry(weak_artist_identity_key(&identity))
            .or_default()
            .push(candidate.clone());
        index
            .weak_title
            .entry(weak_title_identity_key(&identity))
            .or_default()
            .push(candidate);
    }

    Ok(index)
}

pub(crate) fn select_unique_candidate(
    map: &HashMap<String, Vec<LibraryMatchCandidate>>,
    key: &str,
) -> Option<LibraryMatchCandidate> {
    map.get(key).and_then(|candidates| {
        if candidates.len() == 1 {
            candidates.first().cloned()
        } else {
            None
        }
    })
}

pub(crate) fn match_song_identity(
    index: &LibraryMatchIndex,
    identity: &PortableSongIdentity,
) -> Option<LibraryMatchCandidate> {
    select_unique_candidate(&index.strict, &strict_identity_key(identity))
        .or_else(|| {
            select_unique_candidate(&index.weak_artist, &weak_artist_identity_key(identity))
        })
        .or_else(|| select_unique_candidate(&index.weak_title, &weak_title_identity_key(identity)))
}

pub(crate) fn rebuild_statistics_aggregates(conn: &rusqlite::Connection) -> Result<(), String> {
    clear_aggregate_statistics(conn)?;

    {
        // 使用 LEFT JOIN 以包含在线歌曲（song_id 为 NULL 的记录）
        // 对于在线歌曲，s.title/s.artist/s.album 等字段为 NULL，
        // resolve_song_identity 会用 song_path 作为 fallback 提取标题
        let mut stmt = conn
            .prepare(
                "SELECT ph.song_path, s.title, s.artist, s.album, s.duration, s.track_number, ph.played_at, ph.played_seconds, ph.event
                 FROM play_history ph
                 LEFT JOIN songs s ON ph.song_id = s.id
                 WHERE ph.event IN ('play', 'play_time')
                 ORDER BY ph.played_at ASC, ph.id ASC",
            )
            .map_err(|e| e.to_string())?;

        let rows = stmt
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, Option<String>>(1)?.unwrap_or_default(),
                    row.get::<_, Option<String>>(2)?.unwrap_or_default(),
                    row.get::<_, Option<String>>(3)?.unwrap_or_default(),
                    row.get::<_, Option<i64>>(4)?.unwrap_or_default(),
                    row.get::<_, Option<String>>(5)?,
                    row.get::<_, i64>(6)?,
                    row.get::<_, i64>(7).unwrap_or(0),
                    row.get::<_, String>(8)?,
                ))
            })
            .map_err(|e| e.to_string())?;

        for row in rows.flatten() {
            let identity = resolve_song_identity(
                &row.1,
                &row.2,
                &row.3,
                row.4.max(0) * 1000,
                parse_track_number_value(row.5.as_deref()),
                Some(&row.0),
            );
            let listened_ms = row.7.max(0) * 1000;
            let count_as_play = row.8 == "play";
            let (is_full_play, is_skip) = if count_as_play {
                derive_play_flags(listened_ms, identity.duration_ms)
            } else {
                (false, false)
            };
            record_aggregate_play(
                conn,
                &identity,
                row.6,
                listened_ms,
                is_full_play,
                is_skip,
                count_as_play,
            )?;
        }
    }

    set_statistics_meta(conn, "aggregates_backfilled", "1")?;
    Ok(())
}

pub(crate) fn ensure_statistics_aggregates(conn: &rusqlite::Connection) -> Result<(), String> {
    if get_statistics_meta(conn, "aggregates_backfilled")?
        .as_deref()
        .is_some_and(|value| value == "1")
    {
        return Ok(());
    }

    rebuild_statistics_aggregates(conn)
}

pub(crate) fn load_portable_export(file_path: &str) -> Result<PortableStatisticsExport, String> {
    let raw = fs::read_to_string(file_path).map_err(|e| e.to_string())?;
    let export: PortableStatisticsExport =
        serde_json::from_str(&raw).map_err(|_| "文件格式不正确或已损坏".to_string())?;

    if export.format != "xianyu-stats" {
        return Err("文件格式不正确或已损坏".to_string());
    }

    if export.version > SUPPORTED_STATS_VERSION {
        return Err("该统计文件版本过新，当前版本暂不支持".to_string());
    }

    Ok(export)
}

pub(crate) fn query_global_stats(conn: &rusqlite::Connection) -> Result<PortableGlobalStats, String> {
    let stats = conn
        .query_row(
            "SELECT total_play_count, total_play_time_ms, first_played_at, last_played_at
         FROM global_stats
         WHERE id = 1",
            [],
            |row| {
                Ok(PortableGlobalStats {
                    total_play_count: row.get::<_, i64>(0)?,
                    total_play_time_ms: row.get::<_, i64>(1)?,
                    first_played_at: row.get::<_, Option<String>>(2)?,
                    last_played_at: row.get::<_, Option<String>>(3)?,
                })
            },
        )
        .optional()
        .map_err(|e| e.to_string())?
        .unwrap_or(PortableGlobalStats {
            total_play_count: 0,
            total_play_time_ms: 0,
            first_played_at: None,
            last_played_at: None,
        });

    Ok(stats)
}

pub(crate) fn query_song_stats(conn: &rusqlite::Connection) -> Result<Vec<PortableSongStatsEntry>, String> {
    let mut stmt = conn
        .prepare(
            "SELECT title, artist, album, duration_ms, track_number,
                    play_count, play_time_ms, full_play_count, skip_count, first_played_at, last_played_at
             FROM song_stats
             ORDER BY play_count DESC, play_time_ms DESC, title COLLATE NOCASE ASC",
        )
        .map_err(|e| e.to_string())?;

    let rows = stmt
        .query_map([], |row| {
            Ok(PortableSongStatsEntry {
                song_identity: PortableSongIdentity {
                    title: row.get::<_, Option<String>>(0)?.unwrap_or_default(),
                    artist: row.get::<_, Option<String>>(1)?.unwrap_or_default(),
                    album: row.get::<_, Option<String>>(2)?.unwrap_or_default(),
                    duration_ms: row.get::<_, i64>(3).unwrap_or(0),
                    track_number: row.get::<_, Option<i64>>(4)?,
                },
                song_stats: PortableSongStats {
                    play_count: row.get::<_, i64>(5).unwrap_or(0),
                    play_time_ms: row.get::<_, i64>(6).unwrap_or(0),
                    full_play_count: row.get::<_, i64>(7).unwrap_or(0),
                    skip_count: row.get::<_, i64>(8).unwrap_or(0),
                    first_played_at: row.get::<_, Option<String>>(9)?,
                    last_played_at: row.get::<_, Option<String>>(10)?,
                },
            })
        })
        .map_err(|e| e.to_string())?;

    Ok(rows.filter_map(|row| row.ok()).collect())
}

pub(crate) fn query_daily_stats(conn: &rusqlite::Connection) -> Result<Vec<PortableDailyStats>, String> {
    let mut stmt = conn
        .prepare(
            "SELECT date, play_count, play_time_ms, unique_songs, unique_artists
             FROM daily_stats
             ORDER BY date ASC",
        )
        .map_err(|e| e.to_string())?;

    let rows = stmt
        .query_map([], |row| {
            Ok(PortableDailyStats {
                date: row.get(0)?,
                play_count: row.get::<_, i64>(1).unwrap_or(0),
                play_time_ms: row.get::<_, i64>(2).unwrap_or(0),
                unique_songs: row.get::<_, i64>(3).unwrap_or(0),
                unique_artists: row.get::<_, i64>(4).unwrap_or(0),
            })
        })
        .map_err(|e| e.to_string())?;

    Ok(rows.filter_map(|row| row.ok()).collect())
}

pub(crate) fn query_hourly_stats(conn: &rusqlite::Connection) -> Result<Vec<PortableHourlyStats>, String> {
    let mut buckets = vec![
        PortableHourlyStats {
            hour: 0,
            play_count: 0,
            play_time_ms: 0,
        };
        24
    ];

    for (index, bucket) in buckets.iter_mut().enumerate() {
        bucket.hour = index as i64;
    }

    let mut stmt = conn
        .prepare("SELECT hour, play_count, play_time_ms FROM hourly_stats")
        .map_err(|e| e.to_string())?;

    let rows = stmt
        .query_map([], |row| {
            Ok((
                row.get::<_, i64>(0)?,
                row.get::<_, i64>(1).unwrap_or(0),
                row.get::<_, i64>(2).unwrap_or(0),
            ))
        })
        .map_err(|e| e.to_string())?;

    for row in rows.flatten() {
        if (0..24).contains(&row.0) {
            buckets[row.0 as usize].play_count = row.1;
            buckets[row.0 as usize].play_time_ms = row.2;
        }
    }

    Ok(buckets)
}

pub(crate) fn query_recent_plays(conn: &rusqlite::Connection) -> Result<Vec<PortableRecentPlay>, String> {
    let mut stmt = conn
        .prepare(
            "SELECT played_at, title, artist, album, duration_ms, listened_ms, is_full_play, is_skip
             FROM recent_plays
             ORDER BY played_at DESC, id DESC
             LIMIT ?1",
        )
        .map_err(|e| e.to_string())?;

    let rows = stmt
        .query_map([RECENT_PLAY_LIMIT], |row| {
            Ok(PortableRecentPlay {
                played_at: row.get(0)?,
                title: row.get::<_, Option<String>>(1)?.unwrap_or_default(),
                artist: row.get::<_, Option<String>>(2)?.unwrap_or_default(),
                album: row.get::<_, Option<String>>(3)?.unwrap_or_default(),
                duration_ms: row.get::<_, i64>(4).unwrap_or(0),
                listened_ms: row.get::<_, i64>(5).unwrap_or(0),
                is_full_play: row.get::<_, i64>(6).unwrap_or(0) > 0,
                is_skip: row.get::<_, i64>(7).unwrap_or(0) > 0,
            })
        })
        .map_err(|e| e.to_string())?;

    Ok(rows.filter_map(|row| row.ok()).collect())
}

