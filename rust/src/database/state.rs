use crate::database::migrations::run_migrations;
use crate::database::schema::{configure_connection, ensure_base_schema};
use rusqlite::Connection;
use std::fs;
use std::path::Path;
use std::sync::{Arc, Mutex};

/// 共享数据库连接状态（无 Tauri 依赖）。
pub struct DbState {
    pub conn: Arc<Mutex<Connection>>,
}

impl DbState {
    /// 从数据库文件路径打开连接（替代桌面端的 `DbState::new(app_handle)`）。
    pub fn new_from_path(db_path: &Path) -> Result<Self, String> {
        if let Some(parent) = db_path.parent() {
            if !parent.exists() {
                fs::create_dir_all(parent).map_err(|e| e.to_string())?;
            }
        }

        let conn = Connection::open(db_path).map_err(|e| e.to_string())?;

        configure_connection(&conn)?;
        ensure_base_schema(&conn)?;
        run_migrations(&conn)?;

        Ok(DbState {
            conn: Arc::new(Mutex::new(conn)),
        })
    }
}