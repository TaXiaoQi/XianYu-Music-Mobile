use super::*;

// =====================================================
// 曲库统计
// =====================================================

/// 曲库统计结果（简化版）
#[derive(Serialize)]
pub struct LibraryStats {
    pub total_songs: i64,
    pub total_duration: i64,   // 秒
    pub total_file_size: i64,  // 字节
    pub album_count: i64,      // 专辑数（排除空/未知）
    pub artist_count: i64,     // 歌手数（排除空/未知）
    pub lossless_count: i64,   // 无损数量
    pub hires_count: i64,      // Hi-Res 数量 (24bit + >=48k)
    pub this_month_added: i64, // 本月首次入库数量
}

/// 音质分布统计
#[derive(Serialize)]
pub struct QualityDistribution {
    pub hires: i64,         // Hi-Res (24bit + >=48kHz 无损)
    pub super_quality: i64, // SQ (普通无损)
    pub high_quality: i64,  // HQ (有损 >= 256kbps)
    pub other: i64,         // 其他
}

/// 文件格式分布统计
#[derive(Serialize)]
pub struct FormatDistribution {
    pub flac: i64,
    pub mp3: i64,
    pub alac: i64,
    pub wav: i64,
    pub aiff: i64,
    pub aac: i64,
    pub ogg: i64,
    pub other: i64,
}

/// 获取文件格式分布统计
pub fn get_format_distribution(conn: &rusqlite::Connection) -> Result<FormatDistribution, String> {
    let mut stmt = conn
        .prepare("SELECT format, container, codec FROM songs")
        .map_err(|e| e.to_string())?;

    let rows = stmt
        .query_map([], |row| {
            Ok((
                row.get::<_, String>(0).unwrap_or_default(),
                row.get::<_, Option<String>>(1).ok().flatten(),
                row.get::<_, Option<String>>(2).ok().flatten(),
            ))
        })
        .map_err(|e| e.to_string())?;

    let mut flac = 0i64;
    let mut mp3 = 0i64;
    let mut alac = 0i64;
    let mut wav = 0i64;
    let mut aiff = 0i64;
    let mut aac = 0i64;
    let mut ogg = 0i64;
    let mut other = 0i64;

    for row in rows.flatten() {
        match format_distribution_bucket(row.1.as_deref(), row.2.as_deref(), &row.0) {
            "flac" => flac += 1,
            "mp3" => mp3 += 1,
            "alac" => alac += 1,
            "wav" => wav += 1,
            "aiff" => aiff += 1,
            "aac" => aac += 1,
            "ogg" => ogg += 1,
            _ => other += 1,
        }
    }

    Ok(FormatDistribution {
        flac,
        mp3,
        alac,
        wav,
        aiff,
        aac,
        ogg,
        other,
    })
}

/// 获取音质分布统计
pub fn get_quality_distribution(conn: &rusqlite::Connection) -> Result<QualityDistribution, String> {
    let mut stmt = conn
        .prepare("SELECT format, codec, bit_depth, sample_rate, bitrate FROM songs")
        .map_err(|e| e.to_string())?;

    let rows = stmt
        .query_map([], |row| {
            Ok((
                row.get::<_, String>(0).unwrap_or_default(),
                row.get::<_, Option<String>>(1).ok().flatten(),
                row.get::<_, Option<i64>>(2).ok().flatten(),
                row.get::<_, i64>(3).unwrap_or(0),
                row.get::<_, i64>(4).unwrap_or(0),
            ))
        })
        .map_err(|e| e.to_string())?;

    let mut hires = 0i64;
    let mut super_quality = 0i64;
    let mut high_quality = 0i64;
    let mut other = 0i64;

    for row in rows.flatten() {
        let (format, codec, bit_depth, sample_rate, bitrate) = row;
        let is_lossless = is_lossless_audio(codec.as_deref(), &format);
        let is_hr = is_hires(bit_depth, sample_rate);

        if is_lossless && is_hr {
            hires += 1;
        } else if is_lossless {
            super_quality += 1;
        } else if bitrate >= 256 {
            high_quality += 1;
        } else {
            other += 1;
        }
    }

    Ok(QualityDistribution {
        hires,
        super_quality,
        high_quality,
        other,
    })
}

/// 获取曲库统计（全库，无 scope/time_range 参数）
pub fn get_library_stats(conn: &rusqlite::Connection) -> Result<LibraryStats, String> {
    // 基础统计
    let (total_songs, total_duration, total_file_size): (i64, i64, i64) = conn
        .query_row(
            "SELECT COUNT(*), COALESCE(SUM(duration), 0), COALESCE(SUM(file_size), 0) FROM songs",
            [],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .map_err(|e| e.to_string())?;

    // 专辑数（排除空/未知）- 在 Rust 端过滤
    let album_count: i64 = {
        let mut stmt = conn
            .prepare("SELECT DISTINCT album FROM songs WHERE album IS NOT NULL AND album != ''")
            .map_err(|e| e.to_string())?;
        let albums: Vec<String> = stmt
            .query_map([], |row| row.get(0))
            .map_err(|e| e.to_string())?
            .filter_map(|r| r.ok())
            .filter(|name: &String| !is_invalid_name(name))
            .collect();
        albums.len() as i64
    };

    // 歌手数（排除空/未知）
    let artist_count: i64 = {
        let mut stmt = conn
            .prepare("SELECT DISTINCT artist FROM songs WHERE artist IS NOT NULL AND artist != ''")
            .map_err(|e| e.to_string())?;
        let artists: Vec<String> = stmt
            .query_map([], |row| row.get(0))
            .map_err(|e| e.to_string())?
            .filter_map(|r| r.ok())
            .filter(|name: &String| !is_invalid_name(name))
            .collect();
        artists.len() as i64
    };

    // 无损数量 + Hi-Res 数量
    let (lossless_count, hires_count): (i64, i64) = {
        let mut stmt = conn
            .prepare("SELECT format, codec, bit_depth, sample_rate FROM songs")
            .map_err(|e| e.to_string())?;
        let rows = stmt
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0).unwrap_or_default(),
                    row.get::<_, Option<String>>(1).ok().flatten(),
                    row.get::<_, Option<i64>>(2).ok().flatten(),
                    row.get::<_, i64>(3).unwrap_or(0),
                ))
            })
            .map_err(|e| e.to_string())?;

        let mut lossless = 0i64;
        let mut hires = 0i64;
        for row in rows.flatten() {
            if is_lossless_audio(row.1.as_deref(), &row.0) {
                lossless += 1;
                if is_hires(row.2, row.3) {
                    hires += 1;
                }
            }
        }
        (lossless, hires)
    };

    // 本月首次入库数量
    let this_month_added: i64 = {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs() as i64;
        // 简化：30天内入库
        let month_start = now - 30 * 24 * 60 * 60;
        conn.query_row(
            "SELECT COUNT(*) FROM songs WHERE added_at >= ?1",
            [month_start],
            |row| row.get(0),
        )
        .unwrap_or(0)
    };

    Ok(LibraryStats {
        total_songs,
        total_duration,
        total_file_size,
        album_count,
        artist_count,
        lossless_count,
        hires_count,
        this_month_added,
    })
}

