//! player 模块的纯逻辑类型（无音频引擎依赖）。

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};

pub const VISUALIZER_BAND_COUNT: usize = 48;
pub const VISUALIZER_WINDOW_SIZE: usize = 2048;

/// 可视化环形缓冲（频谱数据）。
///
/// 播放线程写入 PCM 采样，渲染线程通过 `snapshot` 读取。纯 CPU 环形缓冲，
/// 不依赖任何 Tauri / 音频后端。
pub struct SharedVisualizer {
    samples: Vec<AtomicU32>,
    pub cursor: AtomicU64,
}

impl SharedVisualizer {
    pub fn new() -> Self {
        Self {
            samples: (0..VISUALIZER_WINDOW_SIZE)
                .map(|_| AtomicU32::new(0))
                .collect(),
            cursor: AtomicU64::new(0),
        }
    }

    pub fn reset(&self) {
        for sample in &self.samples {
            sample.store(0.0_f32.to_bits(), Ordering::Relaxed);
        }
        self.cursor.store(0, Ordering::Relaxed);
    }

    pub fn push_sample(&self, sample: f32) {
        let cursor = self.cursor.fetch_add(1, Ordering::Relaxed) as usize;
        self.samples[cursor % VISUALIZER_WINDOW_SIZE]
            .store(sample.clamp(-1.0, 1.0).to_bits(), Ordering::Relaxed);
    }

    pub fn snapshot(&self) -> Vec<f32> {
        let cursor = self.cursor.load(Ordering::Relaxed) as usize;
        let written = cursor.min(VISUALIZER_WINDOW_SIZE);
        let empty = VISUALIZER_WINDOW_SIZE - written;
        let mut output = Vec::with_capacity(VISUALIZER_WINDOW_SIZE);

        output.extend(std::iter::repeat(0.0).take(empty));

        for logical_position in 0..written {
            let index = if cursor < VISUALIZER_WINDOW_SIZE {
                logical_position
            } else {
                (cursor + logical_position) % VISUALIZER_WINDOW_SIZE
            };
            output.push(f32::from_bits(self.samples[index].load(Ordering::Relaxed)));
        }

        output
    }
}

impl Default for SharedVisualizer {
    fn default() -> Self {
        Self::new()
    }
}

/// 全局共享可视化器（Flutter 播放线程可写入，渲染线程读取）。
pub fn global_visualizer() -> &'static SharedVisualizer {
    static VIZ: std::sync::OnceLock<SharedVisualizer> = std::sync::OnceLock::new();
    VIZ.get_or_init(SharedVisualizer::new)
}

/// 播放会话数据（可序列化，用于 IPC 传输和 SQLite 持久化）。
#[derive(Clone, Serialize, Deserialize, Default, Debug)]
#[serde(rename_all = "camelCase")]
pub struct PlaybackSessionData {
    /// 当前播放歌曲路径
    pub current_song_path: Option<String>,
    /// 播放队列路径数组
    pub play_queue_paths: Vec<String>,
    /// 源歌单路径数组（当前播放上下文的完整歌曲列表）
    pub source_song_paths: Vec<String>,
    /// 播放模式 (0=顺序, 1=循环, 2=随机, 3=单曲循环)
    pub play_mode: u32,
    /// 音量 (0-100)
    pub volume: f32,
    /// 当前播放位置（秒）
    pub current_position_secs: f64,
    /// 是否正在播放
    pub is_playing: bool,
    /// 会话级音质覆盖
    pub session_quality_override: Option<String>,
    /// 队列中在线歌曲的元数据（path → JSON Song 对象）
    pub queue_song_meta: HashMap<String, serde_json::Value>,
    /// 最后更新时间戳（毫秒）
    pub updated_at: i64,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_visualizer_snapshot_empty_first() {
        let v = SharedVisualizer::new();
        let snap = v.snapshot();
        assert_eq!(snap.len(), VISUALIZER_WINDOW_SIZE);
        assert!(snap.iter().all(|&s| s == 0.0));
    }

    #[test]
    fn test_visualizer_roundtrip_after_writes() {
        let v = SharedVisualizer::new();
        for i in 0..100 {
            v.push_sample((i as f32 / 100.0) - 0.5);
        }
        let snap = v.snapshot();
        assert_eq!(snap.len(), VISUALIZER_WINDOW_SIZE);
        assert!(snap.iter().any(|&s| s != 0.0));
    }

    #[test]
    fn test_visualizer_wraps_ring_buffer() {
        let v = SharedVisualizer::new();
        for i in 0..(VISUALIZER_WINDOW_SIZE * 3) {
            v.push_sample(0.0);
        }
        let snap = v.snapshot();
        assert_eq!(snap.len(), VISUALIZER_WINDOW_SIZE);
        assert!(snap.iter().all(|&s| s == 0.0));
    }

    #[test]
    fn test_session_default_values() {
        let data = PlaybackSessionData::default();
        assert!(data.current_song_path.is_none());
        assert!(data.play_queue_paths.is_empty());
        assert!(data.source_song_paths.is_empty());
        assert_eq!(data.play_mode, 0);
        assert_eq!(data.volume, 0.0);
        assert_eq!(data.current_position_secs, 0.0);
        assert!(!data.is_playing);
        assert!(data.session_quality_override.is_none());
        assert!(data.queue_song_meta.is_empty());
        assert_eq!(data.updated_at, 0);
    }

    #[test]
    fn test_session_camel_case_serialization() {
        let mut data = PlaybackSessionData::default();
        data.current_song_path = Some("/music/song.flac".into());
        data.play_queue_paths = vec!["/music/song.flac".into()];
        data.source_song_paths = vec!["/music/song.flac".into()];
        data.play_mode = 2;
        data.volume = 75.0;
        data.current_position_secs = 42.5;
        data.is_playing = true;
        data.session_quality_override = Some("flac".into());
        data.updated_at = 1700000000000;

        let json = serde_json::to_string(&data).unwrap();
        let v: serde_json::Value = serde_json::from_str(&json).unwrap();

        assert_eq!(v["currentSongPath"], "/music/song.flac");
        assert_eq!(v["playQueuePaths"][0], "/music/song.flac");
        assert_eq!(v["sourceSongPaths"][0], "/music/song.flac");
        assert_eq!(v["playMode"], 2);
        assert_eq!(v["volume"], 75.0);
        assert_eq!(v["currentPositionSecs"], 42.5);
        assert_eq!(v["isPlaying"], true);
        assert_eq!(v["sessionQualityOverride"], "flac");
        assert_eq!(
            v["queueSongMeta"],
            serde_json::Value::Object(serde_json::Map::new())
        );
        assert_eq!(v["updatedAt"], 1700000000000_i64);

        assert!(v.get("current_song_path").is_none());
        assert!(v.get("play_queue_paths").is_none());
        assert!(v.get("current_position_secs").is_none());
    }

    #[test]
    fn test_session_round_trip_serialization() {
        let mut data = PlaybackSessionData::default();
        data.current_song_path = Some("remote://song1".into());
        data.play_queue_paths = vec!["remote://song1".into(), "remote://song2".into()];
        data.play_mode = 3;
        data.volume = 50.0;
        data.current_position_secs = 120.0;
        data.is_playing = true;
        data.session_quality_override = Some("320k".into());

        let song_meta = serde_json::json!({
            "title": "Test Song",
            "artist": "Test Artist",
            "duration": 180
        });
        data.queue_song_meta
            .insert("remote://song1".into(), song_meta.clone());

        let json = serde_json::to_string(&data).unwrap();
        let restored: PlaybackSessionData = serde_json::from_str(&json).unwrap();

        assert_eq!(restored.current_song_path, data.current_song_path);
        assert_eq!(restored.play_queue_paths, data.play_queue_paths);
        assert_eq!(restored.play_mode, data.play_mode);
        assert_eq!(restored.volume, data.volume);
        assert_eq!(restored.current_position_secs, data.current_position_secs);
        assert_eq!(restored.is_playing, data.is_playing);
        assert_eq!(
            restored.session_quality_override,
            data.session_quality_override
        );
        assert_eq!(restored.queue_song_meta.len(), 1);
        assert_eq!(restored.queue_song_meta["remote://song1"], song_meta);
    }
}