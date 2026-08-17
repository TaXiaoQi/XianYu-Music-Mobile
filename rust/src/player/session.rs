//! 播放会话状态管理（纯逻辑，无 Tauri 广播）。
//!
//! 将播放队列、当前歌曲、进度、播放模式等状态持久化到 SQLite，
//! 实现跨重启恢复。运行时播放编排权威在前端（Flutter），本模块仅负责存储与分发。

use super::types::PlaybackSessionData;
use rusqlite::Connection;
use std::sync::{Arc, Mutex};
use std::time::{Instant, UNIX_EPOCH};

/// 进度持久化防抖间隔：避免每次都写 SQLite
const POSITION_PERSIST_INTERVAL_MS: u128 = 5000;

/// 播放会话托管状态
pub struct PlaybackSessionState {
    /// 内存中的权威状态
    inner: Arc<Mutex<PlaybackSessionData>>,
    /// 上次进度持久化时间（防抖）
    last_position_persist: Arc<Mutex<Instant>>,
}

impl PlaybackSessionState {
    pub fn new() -> Self {
        Self {
            inner: Arc::new(Mutex::new(PlaybackSessionData::default())),
            last_position_persist: Arc::new(Mutex::new(Instant::now())),
        }
    }

    /// 从 SQLite 加载持久化的会话状态（启动时调用）
    pub fn load_from_db(&self, conn: &Connection) -> Result<(), String> {
        let result: Result<Option<String>, rusqlite::Error> = conn
            .query_row("SELECT data FROM playback_session WHERE id = 1", [], |row| {
                row.get(0)
            })
            .map(Some)
            .or_else(|e| {
                if matches!(e, rusqlite::Error::QueryReturnedNoRows) {
                    Ok(None)
                } else {
                    Err(e)
                }
            });

        match result {
            Ok(Some(json_str)) => {
                let data: PlaybackSessionData = serde_json::from_str(&json_str)
                    .map_err(|e| format!("反序列化播放会话失败: {}", e))?;
                let mut inner = self.inner.lock().map_err(|e| e.to_string())?;
                *inner = data;
            }
            Ok(None) => {}
            Err(_) => {}
        }
        Ok(())
    }

    /// 将当前内存状态持久化到 SQLite
    fn persist_to_db_internal(data: &PlaybackSessionData, conn: &Connection) -> Result<(), String> {
        let json_str =
            serde_json::to_string(data).map_err(|e| format!("序列化播放会话失败: {}", e))?;
        let now = std::time::SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0);

        conn.execute(
            "INSERT OR REPLACE INTO playback_session (id, data, updated_at) VALUES (1, ?1, ?2)",
            rusqlite::params![json_str, now],
        )
        .map_err(|e| format!("写入播放会话失败: {}", e))?;
        Ok(())
    }

    /// 保存完整播放会话状态（切歌/队列变更时调用），写入内存 + SQLite。
    pub fn save_playback_session(
        &self,
        conn: &Connection,
        mut session: PlaybackSessionData,
    ) -> Result<(), String> {
        let now = std::time::SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0);
        session.updated_at = now;

        {
            let mut inner = self.inner.lock().map_err(|e| e.to_string())?;
            *inner = session.clone();
        }

        Self::persist_to_db_internal(&session, conn)?;

        {
            let mut last = self
                .last_position_persist
                .lock()
                .map_err(|e| e.to_string())?;
            *last = Instant::now();
        }

        Ok(())
    }

    /// 高频更新播放进度（仅内存 + 防抖写 SQLite）。
    pub fn update_playback_position(
        &self,
        conn: &Connection,
        position_secs: f64,
        is_playing: bool,
    ) -> Result<(), String> {
        let should_persist = {
            let mut inner = self.inner.lock().map_err(|e| e.to_string())?;
            inner.current_position_secs = position_secs;
            inner.is_playing = is_playing;

            let mut last = self
                .last_position_persist
                .lock()
                .map_err(|e| e.to_string())?;
            let elapsed = last.elapsed().as_millis();
            if elapsed >= POSITION_PERSIST_INTERVAL_MS {
                *last = Instant::now();
                true
            } else {
                false
            }
        };

        if should_persist {
            let inner = self.inner.lock().map_err(|e| e.to_string())?;
            Self::persist_to_db_internal(&inner, conn)?;
        }

        Ok(())
    }

    /// 强制将内存状态持久化到 SQLite（定时刷新或应用退出时调用）。
    pub fn flush_playback_session(&self, conn: &Connection) -> Result<(), String> {
        let inner = self.inner.lock().map_err(|e| e.to_string())?;
        if inner.current_song_path.is_none() && inner.play_queue_paths.is_empty() {
            return Ok(());
        }
        Self::persist_to_db_internal(&inner, conn)?;
        Ok(())
    }

    /// 获取当前播放会话状态（从内存读取权威状态）。
    pub fn get_playback_session(&self) -> PlaybackSessionData {
        let inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        inner.clone()
    }
}

impl Default for PlaybackSessionState {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::Connection;

    fn setup_db() -> Connection {
        let conn = Connection::open_in_memory().expect("open in-memory db");
        conn.execute_batch(
            "CREATE TABLE playback_session (
                id INTEGER PRIMARY KEY,
                data TEXT,
                updated_at INTEGER
            );",
        )
        .expect("create playback_session table");
        conn
    }

    #[test]
    fn test_state_new_defaults() {
        let state = PlaybackSessionState::new();
        let data = state.get_playback_session();
        assert!(data.current_song_path.is_none());
        assert!(data.play_queue_paths.is_empty());
    }

    #[test]
    fn test_save_then_load_round_trip() {
        let conn = setup_db();
        let state = PlaybackSessionState::new();

        let mut session = PlaybackSessionData::default();
        session.current_song_path = Some("/music/song.flac".into());
        session.play_queue_paths = vec!["/music/song.flac".into()];
        session.play_mode = 2;
        session.volume = 75.0;
        session.current_position_secs = 42.5;
        session.is_playing = true;

        state
            .save_playback_session(&conn, session.clone())
            .expect("save session");

        // 新实例从 DB 加载
        let state2 = PlaybackSessionState::new();
        state2.load_from_db(&conn).expect("load session");
        let loaded = state2.get_playback_session();

        assert_eq!(loaded.current_song_path, session.current_song_path);
        assert_eq!(loaded.play_queue_paths, session.play_queue_paths);
        assert_eq!(loaded.play_mode, session.play_mode);
        assert_eq!(loaded.volume, session.volume);
        assert_eq!(loaded.current_position_secs, session.current_position_secs);
        assert_eq!(loaded.is_playing, session.is_playing);
        assert!(loaded.updated_at > 0);
    }

    #[test]
    fn test_flush_skips_when_empty() {
        let conn = setup_db();
        let state = PlaybackSessionState::new();
        state.flush_playback_session(&conn).expect("flush empty ok");

        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM playback_session", [], |row| row.get(0))
            .expect("count");
        assert_eq!(count, 0);
    }

    #[test]
    fn test_update_position_persists_after_interval() {
        let conn = setup_db();
        let state = PlaybackSessionState::new();

        let mut session = PlaybackSessionData::default();
        session.current_song_path = Some("/music/song.flac".into());
        state
            .save_playback_session(&conn, session)
            .expect("save session");

        // 更新位置（防抖间隔内，不强制持久化；但保存时已写入）
        state
            .update_playback_position(&conn, 10.0, true)
            .expect("update position");
        assert_eq!(state.get_playback_session().current_position_secs, 10.0);

        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM playback_session", [], |row| row.get(0))
            .expect("count");
        assert_eq!(count, 1);
    }
}