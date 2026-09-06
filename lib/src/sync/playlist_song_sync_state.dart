import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 歌单内单曲删除的同步墓碑状态（SharedPreferences 持久化），
/// 与桌面端 playlistSongSyncState.ts 语义一致。
///
/// 三张墓碑表（均按歌单 cloudId 分组，歌曲以 path 为键）：
/// - cloudKeep「仅删本地」墓碑：歌曲已从本机歌单移除但云端保留，
///   值为上传载荷 JSON 字符串（本地移除后无法再构造完整元数据），
///   上传时回填进载荷让云端保留；重新添加回本机歌单时清除。
/// - localOnly「仅保留本地」墓碑：歌曲保留本机但已从云端删除，
///   上传时从载荷剔除并随 deletedSongPaths 上报删除，防止其他端回灌复活；
///   歌曲从本机歌单移除后自然失效（上传时清理）。
/// - pendingDeleted「待上报删除」墓碑（删除全部）：歌曲已从本机移除，
///   待上传时随 deletedSongPaths 上报；下载响应确认服务端已记录（或重新添加）后清除。
///
/// 整个歌单从云端删除时调用 clearTombstones 清空三张表。
abstract final class PlaylistSongSyncState {
  static const _cloudKeepKey = 'playlist_song_cloud_keep';
  static const _localOnlyKey = 'playlist_song_local_only';
  static const _pendingDeletedKey = 'playlist_song_pending_deleted';

  static Future<Map<String, dynamic>> _readMap(String key) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(key);
    if (raw == null || raw.isEmpty) return const {};
    try {
      final v = jsonDecode(raw);
      return v is Map ? v.cast<String, dynamic>() : const {};
    } catch (_) {
      return const {};
    }
  }

  static Future<void> _writeMap(String key, Map<String, dynamic> map) async {
    final prefs = await SharedPreferences.getInstance();
    if (map.isEmpty) {
      await prefs.remove(key);
    } else {
      await prefs.setString(key, jsonEncode(map));
    }
  }

  // ==================== 仅删本地墓碑（cloudKeep） ====================

  /// 已从本机移除但云端保留的歌曲：path → 上传载荷 JSON 字符串
  static Future<Map<String, String>> cloudKeepSongs(String cloudId) async {
    if (cloudId.isEmpty) return const {};
    final bucket = (await _readMap(_cloudKeepKey))[cloudId];
    if (bucket is! Map) return const {};
    return bucket.cast<String, dynamic>().map(
          (k, v) => MapEntry(k, v is String ? v : jsonEncode(v)),
        );
  }

  static Future<void> addCloudKeepSongs(
      String cloudId, Map<String, String> payloadByPath) async {
    if (cloudId.isEmpty || payloadByPath.isEmpty) return;
    final map = await _readMap(_cloudKeepKey);
    final bucket =
        ((map[cloudId] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{})
          ..addAll(payloadByPath);
    map[cloudId] = bucket;
    await _writeMap(_cloudKeepKey, map);
  }

  /// 重新添加回本机的 path 清除墓碑（恢复正常同步行为）
  static Future<void> pruneCloudKeepSongs(
      String cloudId, Set<String> localPaths) async {
    if (cloudId.isEmpty) return;
    final map = await _readMap(_cloudKeepKey);
    final bucket = (map[cloudId] as Map?)?.cast<String, dynamic>();
    if (bucket == null || bucket.isEmpty) return;
    bucket.removeWhere((p, _) => localPaths.contains(p));
    if (bucket.isEmpty) {
      map.remove(cloudId);
    } else {
      map[cloudId] = bucket;
    }
    await _writeMap(_cloudKeepKey, map);
  }

  // ==================== 仅保留本地墓碑（localOnly） ====================

  static Future<Set<String>> localOnlySongs(String cloudId) async {
    if (cloudId.isEmpty) return const {};
    final list = (await _readMap(_localOnlyKey))[cloudId];
    if (list is! List) return const {};
    return list.whereType<String>().toSet();
  }

  static Future<void> addLocalOnlySongs(
      String cloudId, Iterable<String> paths) async {
    if (cloudId.isEmpty) return;
    final set = await localOnlySongs(cloudId);
    final before = set.length;
    set.addAll(paths.where((p) => p.isNotEmpty));
    if (set.length == before) return;
    final map = await _readMap(_localOnlyKey);
    map[cloudId] = set.toList();
    await _writeMap(_localOnlyKey, map);
  }

  /// 歌曲不再保留在本机歌单时清除墓碑（取消「仅保留本地」自然失效）
  static Future<void> pruneLocalOnlySongs(
      String cloudId, Set<String> localPaths) async {
    if (cloudId.isEmpty) return;
    final list = (await _readMap(_localOnlyKey))[cloudId];
    if (list is! List) return;
    final next = list.whereType<String>().where(localPaths.contains).toList();
    final map = await _readMap(_localOnlyKey);
    if (next.isEmpty) {
      map.remove(cloudId);
    } else {
      map[cloudId] = next;
    }
    await _writeMap(_localOnlyKey, map);
  }

  // ==================== 待上报删除墓碑（pendingDeleted） ====================

  static Future<Set<String>> pendingDeletedSongs(String cloudId) async {
    if (cloudId.isEmpty) return const {};
    final list = (await _readMap(_pendingDeletedKey))[cloudId];
    if (list is! List) return const {};
    return list.whereType<String>().toSet();
  }

  static Future<void> addPendingDeletedSongs(
      String cloudId, Iterable<String> paths) async {
    if (cloudId.isEmpty) return;
    final set = await pendingDeletedSongs(cloudId);
    final before = set.length;
    set.addAll(paths.where((p) => p.isNotEmpty));
    if (set.length == before) return;
    final map = await _readMap(_pendingDeletedKey);
    map[cloudId] = set.toList();
    await _writeMap(_pendingDeletedKey, map);
  }

  /// 精确移除指定 path：下载响应确认服务端已记录、或歌曲重新添加回本机时调用
  static Future<void> prunePendingDeletedSongs(
      String cloudId, Iterable<String> paths) async {
    if (cloudId.isEmpty) return;
    final list = (await _readMap(_pendingDeletedKey))[cloudId];
    if (list is! List) return;
    final remove = paths.toSet();
    final next =
        list.whereType<String>().where((p) => !remove.contains(p)).toList();
    final map = await _readMap(_pendingDeletedKey);
    if (next.isEmpty) {
      map.remove(cloudId);
    } else {
      map[cloudId] = next;
    }
    await _writeMap(_pendingDeletedKey, map);
  }

  // ==================== 整单清理 ====================

  /// 歌单从云端删除（删除全部/仅保留本地的整单删除）后清空该歌单全部歌曲墓碑
  static Future<void> clearTombstones(String cloudId) async {
    if (cloudId.isEmpty) return;
    for (final key in [_cloudKeepKey, _localOnlyKey, _pendingDeletedKey]) {
      final map = await _readMap(key);
      if (map.remove(cloudId) != null) {
        await _writeMap(key, map);
      }
    }
  }
}
