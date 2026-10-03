import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../plugin/plugin_backup_import.dart';
import '../playlist/playlist_store.dart';

// ==================== v2 歌单同步 ops 应用（纯函数，对齐桌面端 playlistOpsApply） ====================
// diff 计算在服务端（file_sync_v2_download_ops），本模块把返回的 ops 幂等应用到
// 本地歌单列表。匹配既有歌单时 cloudId 优先、云端快照 id 兜底（消除跨设备重复建单）。

/// v2 协议 song_hash：online=md5(path)，local=md5(title|artist|local)。
/// 必须与桌面端 computeSongHash、服务端 song_diff_key 的回退口径逐字节一致，
/// 否则服务端会把双方都已有的歌判成新增。
String playlistSyncSongHash(ImportedSong song) {
  final path = song.path;
  final isOnline = path.startsWith('lx://') ||
      path.startsWith('plugin://') ||
      path.startsWith('http://') ||
      path.startsWith('https://');
  if (isOnline && path.isNotEmpty) {
    return md5.convert(utf8.encode(path)).toString();
  }
  return md5.convert(utf8.encode('${song.title}|${song.artist}|local')).toString();
}

/// 应用 ops 时的可变工作集：playlists 为调用方持有的工作副本，
/// applySyncOps 原地增改，持久化由调用方负责。
class SyncOpsTarget {
  SyncOpsTarget({
    required this.playlists,
    required this.resolveSong,
    required this.isSongKept,
    required this.isSongPendingDeleted,
  });

  final List<ImportedPlaylist> playlists;

  /// 云端歌曲载荷 → 本地歌曲（含本地曲库路径解析，对齐 v1 _songFromSyncPayload）
  final ImportedSong Function(Map<String, dynamic> payload) resolveSong;

  /// 仅删本地墓碑（与 v1 下载 songKeepMap 语义一致）
  final bool Function(String cloudId, String path) isSongKept;

  /// 待上报删除墓碑
  final bool Function(String cloudId, String path) isSongPendingDeleted;
}

class SyncOpsOutcome {
  final int createdPlaylists;
  final int mergedPlaylists;
  /// 可见云歌曲总数（与 v1 downloadedSongs 口径一致，非净新增）
  final int addedSongs;
  final int removedSongs;

  const SyncOpsOutcome({
    this.createdPlaylists = 0,
    this.mergedPlaylists = 0,
    this.addedSongs = 0,
    this.removedSongs = 0,
  });
}

class _MetaPatch {
  final String? cloudId;
  final String? sourcePluginId;
  final String? sourceUrl;
  final Map<String, dynamic>? sourceRaw;

  const _MetaPatch(
      {this.cloudId, this.sourcePluginId, this.sourceUrl, this.sourceRaw});
}

Map<String, dynamic> _asMap(Object? v) =>
    v is Map ? v.cast<String, dynamic>() : const <String, dynamic>{};

String? _nonEmptyStr(Object? v) {
  final s = v?.toString() ?? '';
  return s.isEmpty ? null : s;
}

bool _hasCloudId(ImportedPlaylist p) =>
    p.cloudId != null && p.cloudId!.isNotEmpty;

ImportedPlaylist? _findExisting(
  SyncOpsTarget target,
  String cloudId,
  String? localId,
) {
  if (cloudId.isNotEmpty) {
    for (final p in target.playlists) {
      if (p.cloudId == cloudId) return p;
    }
  }
  if (localId != null && localId.isNotEmpty) {
    for (final p in target.playlists) {
      if (p.id == localId) return p;
    }
  }
  return null;
}

/// 与 v1 下载一致：展开墓碑（含云歌曲元数据可解析出的本地路径）并过滤 keep/pending。
({List<ImportedSong> songs, Set<String> expandedDeleted}) _visibleLocalSongs(
  List<Map<String, dynamic>> cloudSongs,
  String cloudId,
  Set<String> deletedPaths,
  SyncOpsTarget target,
) {
  final expandedDeleted = <String>{...deletedPaths};
  if (deletedPaths.isNotEmpty) {
    for (final raw in cloudSongs) {
      final p = raw['path'] as String?;
      if (p != null && deletedPaths.contains(p)) {
        expandedDeleted.add(target.resolveSong(raw).path);
      }
    }
  }
  final songs = <ImportedSong>[];
  for (final raw in cloudSongs) {
    final p = raw['path'] as String?;
    if (p != null) {
      if (expandedDeleted.contains(p) ||
          target.isSongPendingDeleted(cloudId, p) ||
          target.isSongKept(cloudId, p)) {
        continue;
      }
    }
    songs.add(target.resolveSong(raw));
  }
  return (songs: songs, expandedDeleted: expandedDeleted);
}

/// 把云端歌曲增量并入既有歌单（墓碑过滤/按 path 去重追加），返回净增歌曲数。
int _mergeIntoExisting(
  ImportedPlaylist existing,
  List<ImportedSong> incoming,
  Set<String> expandedDeleted,
  _MetaPatch meta,
  SyncOpsTarget target,
) {
  var songs = expandedDeleted.isEmpty
      ? [...existing.songs]
      : existing.songs.where((s) => !expandedDeleted.contains(s.path)).toList();
  final afterTombstone = songs.length;
  final knownPaths = songs.map((s) => s.path).toSet();
  for (final s in incoming) {
    if (knownPaths.add(s.path)) songs = [...songs, s];
  }
  final netAdded = songs.length - afterTombstone;
  final index = target.playlists.indexWhere((p) => p.id == existing.id);
  if (index >= 0) {
    target.playlists[index] = existing.copyWith(
      songs: songs,
      cloudId: meta.cloudId,
      isCloud: true,
      sourcePluginId: meta.sourcePluginId,
      sourceUrl: meta.sourceUrl,
      sourceRaw: meta.sourceRaw,
    );
  }
  return netAdded;
}

ImportedPlaylist _buildNewPlaylist(
  Map<String, dynamic> cloudPl,
  List<ImportedSong> songs,
  SyncOpsTarget target,
) {
  final usedIds = target.playlists.map((p) => p.id).toSet();
  // 采用云端快照 id（不冲突时），便于下一轮 v2 按服务端 by_local 兜底匹配
  final cloudLocalId = _nonEmptyStr(cloudPl['id']);
  final id = cloudLocalId != null && !usedIds.contains(cloudLocalId)
      ? cloudLocalId
      : PlaylistStore.newId(usedIds);
  return ImportedPlaylist(
    id: id,
    name: (cloudPl['name'] as String?) ?? '',
    songs: songs,
    importedAt: DateTime.now().millisecondsSinceEpoch,
    cloudId: _nonEmptyStr(cloudPl['cloudId']),
    isCloud: true,
    sourcePluginId: _nonEmptyStr(cloudPl['sourcePluginId']),
    sourceUrl: _nonEmptyStr(cloudPl['sourceUrl']),
    sourceRaw: cloudPl['sourceRaw'] is Map
        ? (cloudPl['sourceRaw'] as Map).cast<String, dynamic>()
        : null,
  );
}

SyncOpsOutcome applySyncOps(
    List<Map<String, dynamic>> ops, SyncOpsTarget target) {
  var created = 0;
  var merged = 0;
  var added = 0;
  var removed = 0;

  for (final op in ops) {
    switch (op['type'] as String?) {
      case 'create_playlist':
        final cloudPl = _asMap(op['playlist']);
        if (cloudPl.isEmpty) break;
        final cloudId = _nonEmptyStr(cloudPl['cloudId']) ?? '';
        final existing =
            _findExisting(target, cloudId, _nonEmptyStr(cloudPl['id']));
        final cloudSongs = ((cloudPl['songs'] as List?) ?? const [])
            .whereType<Map>()
            .map(_asMap)
            .toList();
        final deletedPaths = ((cloudPl['deletedSongPaths'] as List?) ?? const [])
            .whereType<String>()
            .toSet();
        final visible =
            _visibleLocalSongs(cloudSongs, cloudId, deletedPaths, target);
        if (existing != null) {
          // 跨设备重复建单防护：已匹配到本地歌单 → 走合并语义
          _mergeIntoExisting(
            existing,
            visible.songs,
            visible.expandedDeleted,
            _MetaPatch(
              cloudId: _hasCloudId(existing) ? null : cloudId,
              sourcePluginId: _nonEmptyStr(cloudPl['sourcePluginId']),
              sourceUrl: _nonEmptyStr(cloudPl['sourceUrl']),
              sourceRaw: cloudPl['sourceRaw'] is Map
                  ? (cloudPl['sourceRaw'] as Map).cast<String, dynamic>()
                  : null,
            ),
            target,
          );
          merged++;
          added += visible.songs.length;
        } else {
          target.playlists.add(_buildNewPlaylist(cloudPl, visible.songs, target));
          created++;
          added += visible.songs.length;
        }
        break;

      case 'add_songs':
        final cloudId = _nonEmptyStr(op['cloudId']) ?? '';
        final existing = _findExisting(target, cloudId, _nonEmptyStr(op['id']));
        if (existing == null) break;
        merged++;
        // id 兜底命中的歌单回写 cloudId（对齐 v1 按 id 合并时的行为）
        final meta =
            _hasCloudId(existing) ? const _MetaPatch() : _MetaPatch(cloudId: cloudId);
        final effCloudId = _hasCloudId(existing) ? existing.cloudId! : cloudId;
        final visible = <ImportedSong>[];
        for (final raw in ((op['songs'] as List?) ?? const []).whereType<Map>()) {
          final payload = _asMap(raw);
          final p = payload['path'] as String?;
          if (p != null &&
              (target.isSongPendingDeleted(effCloudId, p) ||
                  target.isSongKept(effCloudId, p))) {
            continue;
          }
          visible.add(target.resolveSong(payload));
        }
        added += _mergeIntoExisting(existing, visible, const {}, meta, target);
        break;

      case 'remove_songs':
        final cloudId = _nonEmptyStr(op['cloudId']) ?? '';
        final existing = _findExisting(target, cloudId, _nonEmptyStr(op['id']));
        if (existing == null) break;
        final tombstones =
            ((op['paths'] as List?) ?? const []).whereType<String>().toSet();
        if (tombstones.isEmpty) break;
        final afterFilter =
            existing.songs.where((s) => !tombstones.contains(s.path)).length;
        removed += existing.songs.length - afterFilter;
        _mergeIntoExisting(
          existing,
          const [],
          tombstones,
          _hasCloudId(existing)
              ? const _MetaPatch()
              : _MetaPatch(cloudId: cloudId),
          target,
        );
        break;

      case 'update_playlist_meta':
        final cloudId = _nonEmptyStr(op['cloudId']) ?? '';
        final existing = _findExisting(target, cloudId, _nonEmptyStr(op['id']));
        if (existing == null) break;
        _mergeIntoExisting(
          existing,
          const [],
          const {},
          _MetaPatch(
            cloudId: _hasCloudId(existing) ? null : cloudId,
            sourcePluginId: _nonEmptyStr(op['sourcePluginId']),
            sourceUrl: _nonEmptyStr(op['sourceUrl']),
          ),
          target,
        );
        break;
    }
  }

  return SyncOpsOutcome(
    createdPlaylists: created,
    mergedPlaylists: merged,
    addedSongs: added,
    removedSongs: removed,
  );
}
