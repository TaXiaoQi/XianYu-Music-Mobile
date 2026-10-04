use super::*;

pub fn export_statistics_file(
    conn: &rusqlite::Connection,
    options: StatisticsExportOptions,
) -> Result<StatisticsExportResult, String> {
    ensure_statistics_aggregates(&conn)?;

    let exported_at = now_iso_timestamp()?;
    let export_id = format!("stats-{}-{}", now_unix_seconds(), now_unix_millis());
    let payload = PortableStatisticsExport {
        format: "xianyu-stats".to_string(),
        version: SUPPORTED_STATS_VERSION,
        exported_at: exported_at.clone(),
        app_version: env!("CARGO_PKG_VERSION").to_string(),
        export_id: export_id.clone(),
        library_fingerprint: None,
        stats: PortableStatisticsPayload {
            global: query_global_stats(&conn)?,
            songs: query_song_stats(&conn)?,
            daily: query_daily_stats(&conn)?,
            hourly: query_hourly_stats(&conn)?,
            recent_plays: if options.include_recent_plays {
                query_recent_plays(&conn)?
            } else {
                Vec::new()
            },
        },
    };

    let content = serde_json::to_string_pretty(&payload).map_err(|e| e.to_string())?;
    fs::write(&options.file_path, content).map_err(|e| e.to_string())?;

    Ok(StatisticsExportResult {
        file_path: options.file_path,
        export_id,
        exported_at,
    })
}

pub fn preview_statistics_import(
    conn: &rusqlite::Connection,
    options: StatisticsImportPreviewOptions,
) -> Result<StatisticsImportPreview, String> {
    let export = load_portable_export(&options.file_path)?;
    ensure_statistics_aggregates(&conn)?;
    let match_index = build_library_match_index(&conn)?;

    let matched_song_count = export
        .stats
        .songs
        .iter()
        .filter(|entry| match_song_identity(&match_index, &entry.song_identity).is_some())
        .count();
    let duplicate_import_detected = conn
        .query_row(
            "SELECT 1 FROM imported_exports_log WHERE export_id = ?1",
            [&export.export_id],
            |row| row.get::<_, i64>(0),
        )
        .optional()
        .map_err(|e| e.to_string())?
        .is_some();

    Ok(StatisticsImportPreview {
        version: export.version,
        exported_at: export.exported_at,
        app_version: export.app_version,
        export_id: export.export_id,
        song_stats_count: export.stats.songs.len(),
        daily_stats_count: export.stats.daily.len(),
        recent_plays_count: export.stats.recent_plays.len(),
        matched_song_count,
        unmatched_song_count: export.stats.songs.len().saturating_sub(matched_song_count),
        duplicate_import_detected,
    })
}

pub fn import_statistics_file(
    conn: &mut rusqlite::Connection,
    options: StatisticsImportOptions,
) -> Result<StatisticsImportResult, String> {
    let export = load_portable_export(&options.file_path)?;
    ensure_statistics_aggregates(&conn)?;

    let already_imported = conn
        .query_row(
            "SELECT 1 FROM imported_exports_log WHERE export_id = ?1",
            [&export.export_id],
            |row| row.get::<_, i64>(0),
        )
        .optional()
        .map_err(|e| e.to_string())?
        .is_some();

    if already_imported && !options.continue_duplicate_import {
        return Err("该统计备份似乎已经导入过".to_string());
    }

    let match_index = build_library_match_index(&conn)?;
    let tx = conn.transaction().map_err(|e| e.to_string())?;

    if matches!(options.mode, StatisticsImportMode::Overwrite) {
        clear_aggregate_statistics(&tx)?;
        tx.execute("DELETE FROM imported_exports_log", [])
            .map_err(|e| e.to_string())?;
    }

    set_statistics_meta(&tx, "aggregates_backfilled", "1")?;
    merge_global_stats(&tx, &export.stats.global)?;

    let mut matched_song_count = 0usize;
    let mut unmatched_song_count = 0usize;
    let mut merged_song_count = 0usize;

    for entry in &export.stats.songs {
        let target_identity = match match_song_identity(&match_index, &entry.song_identity) {
            Some(candidate) => {
                matched_song_count += 1;
                candidate.identity
            }
            None => {
                unmatched_song_count += 1;
                entry.song_identity.clone()
            }
        };

        upsert_song_stats(&tx, &target_identity, &entry.song_stats)?;
        merged_song_count += 1;
    }

    for daily in &export.stats.daily {
        upsert_daily_stats(&tx, daily)?;
    }

    for hourly in &export.stats.hourly {
        upsert_hourly_stats(&tx, hourly)?;
    }

    let mut imported_recent_plays_count = 0usize;
    for entry in &export.stats.recent_plays {
        if insert_recent_play(&tx, entry)? {
            imported_recent_plays_count += 1;
        }
    }

    tx.execute(
        "INSERT OR REPLACE INTO imported_exports_log (export_id, imported_at) VALUES (?1, ?2)",
        rusqlite::params![export.export_id, now_iso_timestamp()?],
    )
    .map_err(|e| e.to_string())?;

    tx.commit().map_err(|e| e.to_string())?;

    Ok(StatisticsImportResult {
        mode: match options.mode {
            StatisticsImportMode::Overwrite => "overwrite".to_string(),
            StatisticsImportMode::Merge => "merge".to_string(),
        },
        matched_song_count,
        unmatched_song_count,
        merged_song_count,
        imported_recent_plays_count,
        duplicate_import_skipped: already_imported,
    })
}

/// 清零本地累计 + 每日听歌统计（服务端后台清零后下发，用于制裁违规用户）。
pub fn clear_listen_stats(conn: &rusqlite::Connection) -> Result<(), String> {
    conn.execute(
        "UPDATE global_stats SET total_play_count = 0, total_play_time_ms = 0,
            first_played_at = NULL, last_played_at = NULL WHERE id = 1",
        [],
    )
    .map_err(|e| e.to_string())?;
    conn.execute("DELETE FROM daily_stats", [])
        .map_err(|e| e.to_string())?;
    Ok(())
}

pub fn get_favorite_artist_catalog(
    conn: &rusqlite::Connection,
    favorite_paths: Vec<String>,
) -> Result<Vec<crate::music::types::ArtistCatalogItem>, String> {
    if favorite_paths.is_empty() {
        return Ok(Vec::new());
    }

    let mut map = HashMap::<String, (u32, String)>::new();

    for path in favorite_paths {
        let normalized_path = normalize_path(&path);
        if normalized_path.is_empty() {
            continue;
        }

        let Some(row) = load_song_catalog_row(&conn, &normalized_path)? else {
            continue;
        };

        for artist_name in preferred_artist_names(&row) {
            let key = if artist_name.trim().is_empty() {
                "Unknown".to_string()
            } else {
                artist_name
            };
            let entry = map.entry(key).or_insert((0, row.path.clone()));
            entry.0 = entry.0.saturating_add(1);
        }
    }

    let mut stmt = conn
        .prepare("SELECT id, avatar_path FROM artists WHERE name = ?")
        .map_err(|e| e.to_string())?;

    let mut result: Vec<crate::music::types::ArtistCatalogItem> = Vec::new();
    for (name, (count, first_song_path)) in map {
        let (id, avatar_path) = stmt
            .query_row([&name], |row| {
                Ok((row.get::<_, i64>(0)?, row.get::<_, Option<String>>(1)?))
            })
            .unwrap_or((0, None));

        result.push(crate::music::types::ArtistCatalogItem {
            id,
            name,
            count,
            first_song_path,
            avatar_path,
        });
    }

    result.sort_by(|a, b| {
        b.count
            .cmp(&a.count)
            .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
    });

    Ok(result)
}

pub fn get_favorite_album_catalog(
    conn: &rusqlite::Connection,
    favorite_paths: Vec<String>,
) -> Result<Vec<crate::music::types::AlbumCatalogItem>, String> {
    if favorite_paths.is_empty() {
        return Ok(Vec::new());
    }

    let mut map = HashMap::<String, crate::music::types::AlbumCatalogItem>::new();

    for path in favorite_paths {
        let normalized_path = normalize_path(&path);
        if normalized_path.is_empty() {
            continue;
        }

        let Some(row) = load_song_catalog_row(&conn, &normalized_path)? else {
            continue;
        };

        let key = resolve_album_key(&row);
        let existing = map
            .entry(key.clone())
            .or_insert(crate::music::types::AlbumCatalogItem {
                key,
                name: if row.album.trim().is_empty() {
                    "Unknown".to_string()
                } else {
                    row.album.clone()
                },
                count: 0,
                artist: if row.album_artist.trim().is_empty() {
                    if row.artist.trim().is_empty() {
                        "Unknown".to_string()
                    } else {
                        row.artist.clone()
                    }
                } else {
                    row.album_artist.clone()
                },
                first_song_path: row.path.clone(),
            });

        existing.count = existing.count.saturating_add(1);
    }

    let mut result: Vec<crate::music::types::AlbumCatalogItem> = map.into_values().collect();
    result.sort_by(|a, b| {
        b.count
            .cmp(&a.count)
            .then_with(|| a.artist.to_lowercase().cmp(&b.artist.to_lowercase()))
    });

    Ok(result)
}

pub fn get_recent_album_catalog(
    conn: &rusqlite::Connection,
    recent_entries: Vec<RecentHistoryImportEntry>,
) -> Result<Vec<RecentAlbumCatalogItem>, String> {
    if recent_entries.is_empty() {
        return Ok(Vec::new());
    }

    let mut map = HashMap::<String, RecentAlbumCatalogItem>::new();

    for entry in recent_entries {
        let normalized_path = normalize_path(&entry.song_path);
        if normalized_path.is_empty() {
            continue;
        }

        let Some(row) = load_song_catalog_row(&conn, &normalized_path)? else {
            continue;
        };

        let key = resolve_album_key(&row);
        let played_at = entry.played_at;

        match map.get_mut(&key) {
            Some(existing) if played_at > existing.played_at => {
                existing.played_at = played_at;
                existing.first_song_path = row.path.clone();
            }
            Some(_) => {}
            None => {
                map.insert(
                    key.clone(),
                    RecentAlbumCatalogItem {
                        key,
                        name: if row.album.trim().is_empty() {
                            "Unknown".to_string()
                        } else {
                            row.album.clone()
                        },
                        artist: if row.album_artist.trim().is_empty() {
                            if row.artist.trim().is_empty() {
                                "Unknown".to_string()
                            } else {
                                row.artist.clone()
                            }
                        } else {
                            row.album_artist.clone()
                        },
                        played_at,
                        first_song_path: row.path.clone(),
                    },
                );
            }
        }
    }

    let mut result: Vec<RecentAlbumCatalogItem> = map.into_values().collect();
    result.sort_by(|a, b| b.played_at.cmp(&a.played_at));
    Ok(result)
}

pub fn get_favorite_song_paths_view(
    conn: &rusqlite::Connection,
    favorite_paths: Vec<String>,
    query: Option<String>,
    sort_mode: SongPathSortMode,
    detail_filter_type: Option<String>,
    detail_filter_value: Option<String>,
) -> Result<Vec<String>, String> {
    if favorite_paths.is_empty() {
        return Ok(Vec::new());
    }

    let lowered_query = query.map(|value| value.trim().to_lowercase());
    let normalized_filter_type = detail_filter_type
        .map(|value| value.trim().to_lowercase())
        .filter(|value| !value.is_empty());
    let normalized_filter_value = detail_filter_value
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty());
    let mut rows: Vec<SongViewRow> = Vec::new();

    for path in favorite_paths {
        let normalized_path = normalize_path(&path);
        if normalized_path.is_empty() {
            continue;
        }

        let Some(row) = load_song_view_row(&conn, &normalized_path)? else {
            continue;
        };

        let matches_detail_filter = match (
            normalized_filter_type.as_deref(),
            normalized_filter_value.as_deref(),
        ) {
            (Some("artist"), Some(filter_value)) => song_has_artist(&row, filter_value),
            (Some("album"), Some(filter_value)) => resolve_view_album_key(&row) == filter_value,
            _ => true,
        };

        if !matches_detail_filter {
            continue;
        }

        let matches_search = lowered_query
            .as_deref()
            .map(|value| song_matches_query(&row, value))
            .unwrap_or(true);

        if matches_search {
            rows.push(row);
        }
    }

    sort_song_view_rows(&mut rows, &sort_mode);
    Ok(rows.into_iter().map(|row| row.path).collect())
}

pub fn get_recent_song_paths_view(
    conn: &rusqlite::Connection,
    recent_entries: Vec<RecentHistoryImportEntry>,
    query: Option<String>,
    sort_mode: SongPathSortMode,
) -> Result<Vec<String>, String> {
    if recent_entries.is_empty() {
        return Ok(Vec::new());
    }

    let lowered_query = query.map(|value| value.trim().to_lowercase());
    let mut latest_entries = HashMap::<String, i64>::new();

    for entry in recent_entries {
        let normalized_path = normalize_path(&entry.song_path);
        if normalized_path.is_empty() {
            continue;
        }

        let existing = latest_entries
            .entry(normalized_path)
            .or_insert(entry.played_at);
        if entry.played_at > *existing {
            *existing = entry.played_at;
        }
    }

    let mut rows: Vec<SongViewRow> = Vec::new();
    for normalized_path in latest_entries.into_keys() {
        let Some(row) = load_song_view_row(&conn, &normalized_path)? else {
            continue;
        };

        let matches_search = lowered_query
            .as_deref()
            .map(|value| song_matches_query(&row, value))
            .unwrap_or(true);

        if matches_search {
            rows.push(row);
        }
    }

    sort_song_view_rows(&mut rows, &sort_mode);
    Ok(rows.into_iter().map(|row| row.path).collect())
}

pub fn get_recent_playlist_catalog(
    playlists: Vec<PlaylistImportItem>,
    recent_entries: Vec<RecentHistoryImportEntry>,
) -> Result<Vec<RecentPlaylistCatalogItem>, String> {
    if playlists.is_empty() || recent_entries.is_empty() {
        return Ok(Vec::new());
    }

    let mut latest_played_at_by_path = HashMap::<String, i64>::new();
    for entry in recent_entries {
        let normalized_path = normalize_path(&entry.song_path);
        if normalized_path.is_empty() {
            continue;
        }

        let existing = latest_played_at_by_path
            .entry(normalized_path)
            .or_insert(entry.played_at);
        if entry.played_at > *existing {
            *existing = entry.played_at;
        }
    }

    let mut result = Vec::new();

    for playlist in playlists {
        let mut last_played_time = 0;

        for path in &playlist.song_paths {
            let normalized_path = normalize_path(path);
            if let Some(played_at) = latest_played_at_by_path.get(&normalized_path) {
                if *played_at > last_played_time {
                    last_played_time = *played_at;
                }
            }
        }

        if last_played_time <= 0 {
            continue;
        }

        result.push(RecentPlaylistCatalogItem {
            id: playlist.id,
            name: playlist.name,
            count: playlist.song_paths.len().min(u32::MAX as usize) as u32,
            played_at: last_played_time,
            first_song_path: playlist.song_paths.first().cloned().unwrap_or_default(),
        });
    }

    result.sort_by(|a, b| b.played_at.cmp(&a.played_at));
    Ok(result)
}

pub fn remove_from_recent_history(
    conn: &mut rusqlite::Connection,
    song_paths: Vec<String>,
) -> Result<(), String> {
    if song_paths.is_empty() {
        return Ok(());
    }

    let tx = conn.transaction().map_err(|e| e.to_string())?;
    let mut stmt = tx
        .prepare("DELETE FROM play_history WHERE event = 'recent' AND song_path = ?1")
        .map_err(|e| e.to_string())?;

    for song_path in song_paths {
        let normalized_path = normalize_path(&song_path);
        if normalized_path.is_empty() {
            continue;
        }
        stmt.execute([normalized_path]).map_err(|e| e.to_string())?;
    }

    drop(stmt);
    tx.commit().map_err(|e| e.to_string())
}

pub fn remove_songs_from_history_and_statistics(
    conn: &mut rusqlite::Connection,
    song_paths: Vec<String>,
) -> Result<(), String> {
    if song_paths.is_empty() {
        return Ok(());
    }

    let tx = conn.transaction().map_err(|e| e.to_string())?;

    {
        let mut stmt = tx
            .prepare("DELETE FROM play_history WHERE song_path = ?1")
            .map_err(|e| e.to_string())?;

        for song_path in song_paths {
            let normalized_path = normalize_path(&song_path);
            if normalized_path.is_empty() {
                continue;
            }
            stmt.execute([normalized_path]).map_err(|e| e.to_string())?;
        }
    }

    rebuild_statistics_aggregates(&tx)?;
    tx.commit().map_err(|e| e.to_string())
}

pub fn clear_recent_history(conn: &rusqlite::Connection) -> Result<(), String> {
    conn.execute("DELETE FROM play_history WHERE event = 'recent'", [])
        .map_err(|e| e.to_string())?;
    Ok(())
}

/// 重置所有本地听歌统计数据（包括播放历史、聚合统计等），从零开始
pub fn reset_local_statistics(conn: &rusqlite::Connection) -> Result<(), String> {
    // 清空所有播放历史
    conn.execute("DELETE FROM play_history", [])
        .map_err(|e| e.to_string())?;
    // 清空聚合统计
    clear_aggregate_statistics(&conn)?;
    Ok(())
}

/// 记录一次播放事件（通过 song_path 查找 song_id）
pub fn record_play(
    conn: &mut rusqlite::Connection,
    payload: RecordPlayPayload,
) -> Result<(), String> {
    let tx = conn.transaction().map_err(|e| e.to_string())?;

    // 规范化路径，确保与数据库中的路径格式一致
    let normalized_path = normalize_path(&payload.song_path);

    // 通过 path 查找 song_id（本地歌曲在 songs 表中可找到，在线歌曲找不到）
    let song_id: Option<i64> = tx
        .query_row(
            "SELECT id FROM songs WHERE path = ?1",
            [&normalized_path],
            |row| row.get(0),
        )
        .ok();

    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64;

    let played_seconds = (payload.listened_ms.max(0) / 1000).max(0);

    // 定时刷写只累计时长；同一次实际播放仅保留一条 event='play' 记录。
    let count_as_play = payload.count_as_play.unwrap_or(true);
    let history_event = if count_as_play { "play" } else { "play_time" };
    tx.execute(
        "INSERT INTO play_history (song_path, song_id, played_at, played_seconds, event) VALUES (?1, ?2, ?3, ?4, ?5)",
        rusqlite::params![&normalized_path, song_id, now, played_seconds, history_event],
    )
    .map_err(|e| e.to_string())?;

    // 无论歌曲是否在本地曲库中，都记录聚合统计（全局统计、歌曲统计、每日/每小时统计等）
    let identity = resolve_song_identity(
        &payload.title,
        &payload.artist,
        &payload.album,
        payload.duration_ms,
        parse_track_number_value(payload.track_number.as_deref()),
        Some(&payload.song_path),
    );
    let (is_full_play, is_skip) = derive_play_flags(payload.listened_ms, payload.duration_ms);
    record_aggregate_play(
        &tx,
        &identity,
        now,
        payload.listened_ms,
        is_full_play,
        is_skip,
        count_as_play,
    )?;

    tx.commit().map_err(|e| e.to_string())
}

