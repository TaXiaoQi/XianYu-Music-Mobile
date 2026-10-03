use super::*;

pub(crate) fn aggregate_behavior_stats(conn: &rusqlite::Connection) -> Result<BehaviorStats, String> {
    ensure_statistics_aggregates(conn)?;

    let global = query_global_stats(conn)?;
    let song_entries = query_song_stats(conn)?;
    let index = build_library_match_index(conn)?;

    let mut top_songs = Vec::new();
    let mut seen_paths = HashSet::new();
    for entry in song_entries
        .iter()
        .filter(|entry| entry.song_stats.play_count > 0)
    {
        let Some(candidate) = match_song_identity(&index, &entry.song_identity) else {
            continue;
        };
        if !seen_paths.insert(candidate.path.clone()) {
            continue;
        }
        top_songs.push(TopSong {
            song_path: candidate.path,
            play_count: entry.song_stats.play_count,
            value: entry.song_stats.play_count,
        });
        if top_songs.len() >= 5 {
            break;
        }
    }

    let mut duration_entries = song_entries.clone();
    duration_entries.sort_by(|left, right| {
        right
            .song_stats
            .play_time_ms
            .cmp(&left.song_stats.play_time_ms)
            .then_with(|| right.song_stats.play_count.cmp(&left.song_stats.play_count))
    });

    let mut top_songs_by_duration = Vec::new();
    let mut seen_duration_paths = HashSet::new();
    for entry in duration_entries
        .iter()
        .filter(|entry| entry.song_stats.play_time_ms > 0)
    {
        let Some(candidate) = match_song_identity(&index, &entry.song_identity) else {
            continue;
        };
        if !seen_duration_paths.insert(candidate.path.clone()) {
            continue;
        }
        top_songs_by_duration.push(TopSong {
            song_path: candidate.path,
            play_count: entry.song_stats.play_count,
            value: entry.song_stats.play_time_ms / 1000,
        });
        if top_songs_by_duration.len() >= 5 {
            break;
        }
    }

    let mut artist_map = HashMap::<String, i64>::new();
    let mut album_map = HashMap::<String, i64>::new();
    for entry in &song_entries {
        if !is_invalid_name(&entry.song_identity.artist) {
            *artist_map
                .entry(entry.song_identity.artist.clone())
                .or_default() += entry.song_stats.play_count;
        }
        if !is_invalid_name(&entry.song_identity.album) {
            *album_map
                .entry(entry.song_identity.album.clone())
                .or_default() += entry.song_stats.play_count;
        }
    }

    let mut top_artists: Vec<TopArtist> = artist_map
        .into_iter()
        .map(|(artist, play_count)| TopArtist { artist, play_count })
        .collect();
    top_artists.sort_by(|a, b| {
        b.play_count
            .cmp(&a.play_count)
            .then_with(|| a.artist.to_lowercase().cmp(&b.artist.to_lowercase()))
    });
    top_artists.truncate(5);

    let mut top_albums: Vec<TopAlbum> = album_map
        .into_iter()
        .map(|(album, play_count)| TopAlbum { album, play_count })
        .collect();
    top_albums.sort_by(|a, b| {
        b.play_count
            .cmp(&a.play_count)
            .then_with(|| a.album.to_lowercase().cmp(&b.album.to_lowercase()))
    });
    top_albums.truncate(5);

    let hourly_rows = query_hourly_stats(conn)?;
    let mut hour_distribution = vec![0; 24];
    for row in hourly_rows {
        if (0..24).contains(&row.hour) {
            hour_distribution[row.hour as usize] = row.play_count;
        }
    }

    let mut recent_activity = vec![0; 7];

    let mut stmt = conn
        .prepare(
            "SELECT CAST(julianday(date) - julianday(date('now', 'localtime')) AS INTEGER) AS day_offset,
                    play_time_ms
             FROM daily_stats
             WHERE date >= date('now', 'localtime', '-6 day')",
        )
        .map_err(|e| e.to_string())?;
    let rows = stmt
        .query_map([], |row| {
            Ok((
                row.get::<_, i64>(0).unwrap_or(0),
                row.get::<_, i64>(1).unwrap_or(0),
            ))
        })
        .map_err(|e| e.to_string())?;
    for row in rows.flatten() {
        if (-6..=0).contains(&row.0) {
            recent_activity[(row.0 + 6) as usize] = row.1 / 1000;
        }
    }

    Ok(BehaviorStats {
        total_plays: global.total_play_count,
        total_duration: global.total_play_time_ms / 1000,
        top_songs,
        top_songs_by_duration,
        top_artists,
        top_albums,
        hour_distribution,
        recent_activity,
    })
}

pub(crate) fn insert_history_event(
    conn: &rusqlite::Connection,
    normalized_path: &str,
    played_at: i64,
    played_seconds: i64,
    event: &str,
) -> Result<(), String> {
    // song_id 允许为空（在线歌曲 lx:///plugin:// 不在本地 songs 表），
    // 对齐 record_play：无条件写历史，缺失时 song_id 落 NULL，否则最近播放对在线歌曲失效。
    let song_id = lookup_song_id(conn, normalized_path);

    conn.execute(
        "INSERT INTO play_history (song_path, song_id, played_at, played_seconds, event) VALUES (?1, ?2, ?3, ?4, ?5)",
        rusqlite::params![normalized_path, song_id, played_at, played_seconds, event],
    )
    .map_err(|e| e.to_string())?;

    Ok(())
}

pub fn add_to_history(conn: &rusqlite::Connection, song_path: String) -> Result<(), String> {
    let normalized_path = normalize_path(&song_path);
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64;

    insert_history_event(&conn, &normalized_path, now, 0, "recent")
}

pub fn import_recent_history(
    conn: &mut rusqlite::Connection,
    entries: Vec<RecentHistoryImportEntry>,
) -> Result<(), String> {
    if entries.is_empty() {
        return Ok(());
    }

    let mut deduped = std::collections::HashMap::<String, i64>::new();
    for entry in entries {
        let normalized_path = normalize_path(&entry.song_path);
        if normalized_path.is_empty() {
            continue;
        }

        let existing = deduped.entry(normalized_path).or_insert(entry.played_at);
        if entry.played_at > *existing {
            *existing = entry.played_at;
        }
    }

    let tx = conn.transaction().map_err(|e| e.to_string())?;

    for (song_path, played_at) in deduped {
        insert_history_event(&tx, &song_path, played_at, 0, "recent")?;
    }

    tx.commit().map_err(|e| e.to_string())
}

pub fn get_recent_history(
    conn: &rusqlite::Connection,
    limit: Option<usize>,
) -> Result<Vec<RecentHistoryEntry>, String> {
    let max_rows = limit.unwrap_or(1000).clamp(1, 5000) as i64;

    // 直接按 song_path 分组，不 JOIN songs：在线歌曲（lx:///plugin://）song_id
    // 为 NULL 且不在 songs 表，INNER JOIN 会把它们过滤掉，导致最近播放只显示本地歌。
    let mut stmt = conn
        .prepare(
            "SELECT ph.song_path, MAX(ph.played_at) AS played_at
             FROM play_history ph
             WHERE ph.event = 'recent'
             GROUP BY ph.song_path
             ORDER BY played_at DESC
             LIMIT ?1",
        )
        .map_err(|e| e.to_string())?;

    let rows = stmt
        .query_map([max_rows], |row| {
            Ok(RecentHistoryEntry {
                song_path: row.get(0)?,
                played_at: row.get::<_, i64>(1)? * 1000,
            })
        })
        .map_err(|e| e.to_string())?;

    Ok(rows.filter_map(|row| row.ok()).collect())
}

