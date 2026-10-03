pub mod schema;
pub mod migrations;
pub mod state;
pub mod reset;

pub use state::DbState;
/// 打开 SQLite 连接并确保 schema/迁移就绪（统计库与扫描曲库共用同一初始化流程）。
pub fn open_conn(db_path: &str) -> Result<rusqlite::Connection, String> {
    let conn = rusqlite::Connection::open(db_path).map_err(|e| e.to_string())?;
    schema::configure_connection(&conn)?;
    schema::ensure_base_schema(&conn)?;
    migrations::run_migrations(&conn)?;
    Ok(conn)
}
