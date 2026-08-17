//! 清空所有应用数据（数据库表 + 封面/状态目录）。

use rusqlite::Connection;
use std::fs;
use std::path::Path;

/// 清空所有库表，并清理封面与状态目录（阻塞）。
pub fn clear_all_app_data(conn: &mut Connection, data_dir: &Path) -> Result<(), String> {
    let tx = conn.transaction().map_err(|e| e.to_string())?;

    tx.execute_batch(
        "
        DELETE FROM play_history;
        DELETE FROM song_artists;
        DELETE FROM artists;
        DELETE FROM songs;
        DELETE FROM library_folders;
        DELETE FROM sidebar_folders;
        ",
    )
    .map_err(|e| e.to_string())?;

    tx.commit().map_err(|e| e.to_string())?;

    conn.execute_batch("PRAGMA wal_checkpoint(TRUNCATE); VACUUM;")
        .map_err(|e| e.to_string())?;

    let cover_dir = data_dir.join("covers");
    if cover_dir.exists() {
        fs::remove_dir_all(&cover_dir).map_err(|e| e.to_string())?;
    }

    // 清理文件系统存储的歌单数据（大歌单超过 localStorage 配额时使用）
    let state_dir = data_dir.join("state");
    if state_dir.exists() {
        fs::remove_dir_all(&state_dir).map_err(|e| e.to_string())?;
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::database::schema::{configure_connection, ensure_base_schema};
    use rusqlite::Connection;

    #[test]
    fn clear_all_app_data_empties_tables() {
        let mut conn = Connection::open_in_memory().unwrap();
        configure_connection(&conn).unwrap();
        ensure_base_schema(&conn).unwrap();

        conn.execute("INSERT INTO artists (id, name) VALUES (1, 'Artist')", [])
            .unwrap();
        conn.execute("INSERT INTO songs (path, title, container, codec) VALUES ('/x.flac', 'T', 'flac', 'flac')", [])
            .unwrap();

        let data_dir = std::env::temp_dir();
        clear_all_app_data(&mut conn, &data_dir).unwrap();

        let artists: i64 = conn
            .query_row("SELECT COUNT(*) FROM artists", [], |r| r.get(0))
            .unwrap();
        let songs: i64 = conn
            .query_row("SELECT COUNT(*) FROM songs", [], |r| r.get(0))
            .unwrap();
        assert_eq!(artists, 0);
        assert_eq!(songs, 0);
    }
}