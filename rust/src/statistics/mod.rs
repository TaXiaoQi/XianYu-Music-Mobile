use crate::music::utils::{format_distribution_bucket, is_lossless_audio, normalize_path};
use rusqlite::OptionalExtension;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};
use time::{format_description::well_known::Rfc3339, OffsetDateTime};

mod behavior;
mod catalog;
mod history;
mod library;
mod portable;
mod record;

pub use behavior::*;
pub use catalog::*;
pub use history::*;
pub use library::*;
pub use portable::*;
pub use record::*;

#[cfg(test)]
mod playback_count_tests {
    use super::*;

    #[test]
    fn periodic_time_flushes_only_increment_play_count_once() {
        let conn = rusqlite::Connection::open_in_memory().expect("open in-memory database");
        crate::database::schema::ensure_base_schema(&conn).expect("create schema");
        let identity = PortableSongIdentity {
            title: "Demo".to_string(),
            artist: "Artist".to_string(),
            album: "Album".to_string(),
            duration_ms: 195_000,
            track_number: Some(1),
        };

        record_aggregate_play(&conn, &identity, 1_700_000_000, 30_000, false, false, true)
            .expect("record initial play chunk");
        for offset in 1..=12 {
            record_aggregate_play(
                &conn,
                &identity,
                1_700_000_000 + offset,
                30_000,
                false,
                false,
                false,
            )
            .expect("record time-only chunk");
        }

        let (play_count, play_time_ms): (i64, i64) = conn
            .query_row(
                "SELECT total_play_count, total_play_time_ms FROM global_stats WHERE id = 1",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .expect("read global stats");
        assert_eq!(play_count, 1);
        assert_eq!(play_time_ms, 390_000);

        let recent_count: i64 = conn
            .query_row("SELECT COUNT(*) FROM recent_plays", [], |row| row.get(0))
            .expect("read recent plays");
        assert_eq!(recent_count, 1);
    }
}
