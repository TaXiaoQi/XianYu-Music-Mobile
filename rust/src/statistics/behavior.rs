use super::*;

/// 行为统计结果
#[derive(Serialize)]
pub struct BehaviorStats {
    pub total_plays: i64,
    pub total_duration: i64,
    pub top_songs: Vec<TopSong>,
    pub top_songs_by_duration: Vec<TopSong>,
    pub top_artists: Vec<TopArtist>,
    pub top_albums: Vec<TopAlbum>,
    pub hour_distribution: Vec<i64>,
    pub recent_activity: Vec<i64>,
}

#[derive(Serialize)]
pub struct TopSong {
    pub song_path: String,
    pub play_count: i64,
    pub value: i64,
}

#[derive(Serialize)]
pub struct TopArtist {
    pub artist: String,
    pub play_count: i64,
}

#[derive(Serialize)]
pub struct TopAlbum {
    pub album: String,
    pub play_count: i64,
}

/// 获取行为统计（全库，JOIN songs 表过滤有效歌曲）
pub fn get_behavior_stats(
    conn: &rusqlite::Connection,
    time_range: TimeRange,
) -> Result<BehaviorStats, String> {
    if matches!(time_range, TimeRange::All) {
        return aggregate_behavior_stats(&conn);
    }

    // 构建时间条件
    let time_condition = match time_range.to_timestamp_from() {
        Some(from) => format!("AND ph.played_at >= {}", from),
        None => String::new(),
    };

    // 只统计 song_id 非空且在 songs 表中存在的记录
    let base_join = "FROM play_history ph INNER JOIN songs s ON ph.song_id = s.id";

    // 指标 A1: 播放次数
    let sql_plays = format!(
        "SELECT COUNT(*) {} WHERE ph.event = 'play' AND ph.song_id IS NOT NULL {}",
        base_join, time_condition
    );
    let total_plays: i64 = conn
        .query_row(&sql_plays, [], |row| row.get(0))
        .unwrap_or(0);

    // 指标 A2: 播放总时长
    let sql_duration = format!(
        "SELECT COALESCE(SUM(ph.played_seconds), 0) {} WHERE ph.event IN ('play', 'play_time') AND ph.song_id IS NOT NULL {}",
        base_join, time_condition
    );
    let total_duration: i64 = conn
        .query_row(&sql_duration, [], |row| row.get(0))
        .unwrap_or(0);

    // 指标 B1: Top 5 歌曲 (按次数)
    let sql_top_plays = format!(
        "SELECT s.path, COUNT(*) as cnt 
         {} 
         WHERE ph.event = 'play' AND ph.song_id IS NOT NULL {} 
         GROUP BY ph.song_id 
         ORDER BY cnt DESC 
         LIMIT 5",
        base_join, time_condition
    );
    let mut top_songs: Vec<TopSong> = Vec::new();
    {
        let mut stmt = conn.prepare(&sql_top_plays).map_err(|e| e.to_string())?;
        let rows = stmt
            .query_map([], |row| {
                let count: i64 = row.get(1)?;
                Ok(TopSong {
                    song_path: row.get(0)?,
                    play_count: count,
                    value: count,
                })
            })
            .map_err(|e| e.to_string())?;
        for row in rows.flatten() {
            top_songs.push(row);
        }
    }

    // 指标 B2: Top 5 歌曲 (按时长)
    let sql_top_duration = format!(
        "SELECT s.path, COALESCE(SUM(ph.played_seconds), 0) as duration 
         {} 
         WHERE ph.event IN ('play', 'play_time') AND ph.song_id IS NOT NULL {}
         GROUP BY ph.song_id 
         ORDER BY duration DESC 
         LIMIT 5",
        base_join, time_condition
    );
    let mut top_songs_by_duration: Vec<TopSong> = Vec::new();
    {
        let mut stmt = conn.prepare(&sql_top_duration).map_err(|e| e.to_string())?;
        let rows = stmt
            .query_map([], |row| {
                let duration: i64 = row.get(1)?;
                Ok(TopSong {
                    song_path: row.get(0)?,
                    play_count: 0,
                    value: duration,
                })
            })
            .map_err(|e| e.to_string())?;
        for row in rows.flatten() {
            top_songs_by_duration.push(row);
        }
    }

    // 指标 C: 小时分布
    let sql_hours = format!(
        "SELECT CAST(strftime('%H', ph.played_at, 'unixepoch', 'localtime') AS INTEGER) as hour, 
                COUNT(*) as cnt 
         {} 
         WHERE ph.event = 'play' AND ph.song_id IS NOT NULL {} 
         GROUP BY hour",
        base_join, time_condition
    );
    let mut hour_distribution: Vec<i64> = vec![0; 24];
    {
        let mut stmt = conn.prepare(&sql_hours).map_err(|e| e.to_string())?;
        let rows = stmt
            .query_map([], |row| Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?)))
            .map_err(|e| e.to_string())?;
        for row in rows.flatten() {
            if row.0 >= 0 && row.0 < 24 {
                hour_distribution[row.0 as usize] = row.1;
            }
        }
    }

    // 指标 D1: Top 5 歌手
    let sql_top_artists = format!(
        "SELECT TRIM(s.artist) as artist, COUNT(*) as cnt 
         {} 
         WHERE ph.event = 'play' AND ph.song_id IS NOT NULL {} 
           AND s.artist IS NOT NULL 
           AND TRIM(s.artist) != '' 
           AND LOWER(TRIM(s.artist)) NOT IN ('未知', '未知歌手', 'unknown', 'unknown artist') 
         GROUP BY TRIM(s.artist) 
         ORDER BY cnt DESC 
         LIMIT 5",
        base_join, time_condition
    );
    let mut top_artists: Vec<TopArtist> = Vec::new();
    {
        let mut stmt = conn.prepare(&sql_top_artists).map_err(|e| e.to_string())?;
        let rows = stmt
            .query_map([], |row| {
                Ok(TopArtist {
                    artist: row.get(0)?,
                    play_count: row.get(1)?,
                })
            })
            .map_err(|e| e.to_string())?;
        for row in rows.flatten() {
            top_artists.push(row);
        }
    }

    // 指标 D2: Top 5 专辑
    let sql_top_albums = format!(
        "SELECT TRIM(s.album) as album, COUNT(*) as cnt 
         {} 
         WHERE ph.event = 'play' AND ph.song_id IS NOT NULL {} 
           AND s.album IS NOT NULL 
           AND TRIM(s.album) != '' 
           AND LOWER(TRIM(s.album)) NOT IN ('未知', '未知专辑', 'unknown', 'unknown album') 
         GROUP BY TRIM(s.album) 
         ORDER BY cnt DESC 
         LIMIT 5",
        base_join, time_condition
    );
    let mut top_albums: Vec<TopAlbum> = Vec::new();
    {
        let mut stmt = conn.prepare(&sql_top_albums).map_err(|e| e.to_string())?;
        let rows = stmt
            .query_map([], |row| {
                Ok(TopAlbum {
                    album: row.get(0)?,
                    play_count: row.get(1)?,
                })
            })
            .map_err(|e| e.to_string())?;
        for row in rows.flatten() {
            top_albums.push(row);
        }
    }

    // 指标 E: 最近 7 天播放趋势 (Timeline)
    // 即使 time_range 不是 7Days，我们也始终返回最近 7 天的趋势供 UI 显示
    let mut recent_activity: Vec<i64> = vec![0; 7];
    {
        // 算出 7 天前的零点时间戳 (简化处理，按 24h 倒推)
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs() as i64;
        let day_seconds = 24 * 60 * 60;
        let start_time = now - 7 * day_seconds;

        // 查询最近 7 天的每一天的播放时长
        // Output: day_offset (0-6), total_duration
        let sql_activity = format!(
            "SELECT CAST((ph.played_at - {}) / {} AS INTEGER) as day_offset, 
                    COALESCE(SUM(ph.played_seconds), 0) as duration 
             FROM play_history ph 
             INNER JOIN songs s ON ph.song_id = s.id 
             WHERE ph.played_at >= {} AND ph.event IN ('play', 'play_time') AND ph.song_id IS NOT NULL
             GROUP BY day_offset",
            start_time, day_seconds, start_time
        );

        let mut stmt = conn.prepare(&sql_activity).map_err(|e| e.to_string())?;
        let rows = stmt
            .query_map([], |row| Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?)))
            .map_err(|e| e.to_string())?;

        for row in rows.flatten() {
            let offset = row.0;
            if offset >= 0 && offset < 7 {
                recent_activity[offset as usize] = row.1;
            }
        }
    }

    Ok(BehaviorStats {
        total_plays,
        total_duration,
        top_songs,
        top_songs_by_duration,
        top_artists,
        top_albums,
        hour_distribution,
        recent_activity,
    })
}

/// 听歌时长（按周期），用于排行榜上报
#[derive(Serialize)]
pub struct ListenDurations {
    /// 今日听歌时长（秒）
    pub daily: i64,
    /// 最近 7 天听歌时长（秒）
    pub weekly: i64,
    /// 累计听歌时长（秒）
    pub total: i64,
    /// 今日听歌首数（daily_stats 当日 play_count）
    pub today_play_count: i64,
}

/// 获取三个周期的听歌时长（日/周/总），用于排行榜分周期上报
pub fn get_listen_durations(conn: &rusqlite::Connection) -> Result<ListenDurations, String> {
    // 今日：从 daily_stats 表取今天的 play_time_ms
    let daily_ms: i64 = conn
        .query_row(
            "SELECT COALESCE(play_time_ms, 0) FROM daily_stats
             WHERE date = strftime('%Y-%m-%d', 'now', 'localtime')",
            [],
            |row| row.get(0),
        )
        .unwrap_or(0);

    // 最近 7 天：从 daily_stats 表取最近 7 天（含今天）的 play_time_ms 总和
    let weekly_ms: i64 = conn
        .query_row(
            "SELECT COALESCE(SUM(play_time_ms), 0) FROM daily_stats
             WHERE date >= strftime('%Y-%m-%d', 'now', 'localtime', '-6 days')",
            [],
            |row| row.get(0),
        )
        .unwrap_or(0);

    // 累计：从 global_stats 表取 total_play_time_ms
    let total_ms: i64 = conn
        .query_row(
            "SELECT COALESCE(total_play_time_ms, 0) FROM global_stats WHERE id = 1",
            [],
            |row| row.get(0),
        )
        .unwrap_or(0);

    // 今日首数：从 daily_stats 表取今天的 play_count
    let today_count: i64 = conn
        .query_row(
            "SELECT COALESCE(play_count, 0) FROM daily_stats
             WHERE date = strftime('%Y-%m-%d', 'now', 'localtime')",
            [],
            |row| row.get(0),
        )
        .unwrap_or(0);

    Ok(ListenDurations {
        daily: daily_ms / 1000,
        weekly: weekly_ms / 1000,
        total: total_ms / 1000,
        today_play_count: today_count,
    })
}

