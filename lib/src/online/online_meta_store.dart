import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../player/player_provider.dart';

/// 在线歌曲元数据持久化池（对齐桌面端 recentSongMeta + extraSong 机制）。
///
/// 在线歌曲（lx://、plugin://）不在本地曲库/数据库中，播放历史（Rust stats
/// 表）只存路径，列表无法反查标题/歌手/封面。参考桌面端做法：播放时把完整
/// 队列项元数据写入本池，最近播放列表从池中还原并可重新播放。
///
/// 存储为 SharedPreferences 单键 JSON（path → 元数据），上限 [maxEntries]，
/// 超出按 `_updatedAt` 淘汰最旧条目。清理最近播放时同步删除对应条目。
class OnlineMetaStore {
  static const _key = 'xianyu_recent_online_meta_v1';
  static const maxEntries = 500;

  Map<String, Map<String, dynamic>> _cache = {};
  bool _loaded = false;

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw != null && raw.isNotEmpty) {
      try {
        final map = jsonDecode(raw) as Map;
        _cache = map
            .map((k, v) => MapEntry(k as String,
                (v as Map).cast<String, dynamic>()));
      } catch (_) {
        _cache = {};
      }
    }
    _loaded = true;
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(_cache));
  }

  /// 按播放路径取回在线歌曲元数据；未命中返回 null。
  Future<QueueItem?> get(String path) async {
    final map = await getAll([path]);
    return map[path];
  }

  /// 批量取回（最近播放列表一次性还原用）；未命中的路径不在结果中。
  Future<Map<String, QueueItem>> getAll(Iterable<String> paths) async {
    await _ensureLoaded();
    final out = <String, QueueItem>{};
    for (final path in paths) {
      final meta = _cache[path];
      if (meta == null) continue;
      out[path] = QueueItem(
        path: meta['path'] as String? ?? path,
        title: meta['title'] as String? ?? '',
        artist: meta['artist'] as String? ?? '',
        album: meta['album'] as String? ?? '',
        durationMs: (meta['durationMs'] as num?)?.toInt() ?? 0,
        coverUrl: meta['coverUrl'] as String?,
        coverPath: meta['coverPath'] as String?,
        source: meta['source'] as String?,
        onlineSongJson: meta['onlineSongJson'] as String?,
        onlineQuality: meta['onlineQuality'] as String?,
        onlineInfoJson: meta['onlineInfoJson'] as String?,
      );
    }
    return out;
  }

  /// 写入/更新在线歌曲元数据（重复播放同曲刷新时间戳）。
  Future<void> put(QueueItem item) async {
    await _ensureLoaded();
    _cache[item.path] = {
      'path': item.path,
      'title': item.title,
      'artist': item.artist,
      'album': item.album,
      'durationMs': item.durationMs,
      'coverUrl': item.coverUrl,
      'coverPath': item.coverPath,
      'source': item.source,
      'onlineSongJson': item.onlineSongJson,
      'onlineQuality': item.onlineQuality,
      'onlineInfoJson': item.onlineInfoJson,
      '_updatedAt': DateTime.now().millisecondsSinceEpoch,
    };
    // 容量淘汰：按 _updatedAt 最旧删除。
    while (_cache.length > maxEntries) {
      String? oldestKey;
      int oldest = DateTime.now().millisecondsSinceEpoch + 1;
      for (final e in _cache.entries) {
        final t = (e.value['_updatedAt'] as num?)?.toInt() ?? 0;
        if (t < oldest) {
          oldest = t;
          oldestKey = e.key;
        }
      }
      if (oldestKey == null) break;
      _cache.remove(oldestKey);
    }
    await _save();
  }

  /// 批量删除（最近播放单条移除时调用）。
  Future<void> remove(List<String> paths) async {
    if (paths.isEmpty) return;
    await _ensureLoaded();
    final changed = paths.any(_cache.containsKey);
    if (!changed) return;
    for (final p in paths) {
      _cache.remove(p);
    }
    await _save();
  }

  /// 清空（最近播放整体清空时调用）。
  Future<void> clear() async {
    await _ensureLoaded();
    if (_cache.isEmpty) return;
    _cache = {};
    await _save();
  }
}

final onlineMetaStoreProvider =
    Provider<OnlineMetaStore>((ref) => OnlineMetaStore());
