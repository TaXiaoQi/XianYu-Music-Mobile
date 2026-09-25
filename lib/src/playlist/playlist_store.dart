import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../plugin/plugin_backup_import.dart';
import '../i18n/i18n.dart';

class ImportedPlaylist {
  final String id;
  final String name;
  final List<ImportedSong> songs;
  final int importedAt;
  final String? cloudId;
  final bool isCloud;
  // 来源信息：用于从源端（插件歌单）更新
  final String? sourcePluginId;
  final String? sourceUrl;
  final Map<String, dynamic>? sourceRaw;

  ImportedPlaylist({
    required this.id,
    required this.name,
    required this.songs,
    required this.importedAt,
    this.cloudId,
    this.isCloud = false,
    this.sourcePluginId,
    this.sourceUrl,
    this.sourceRaw,
  });

  bool get hasSource =>
      (sourcePluginId ?? '').isNotEmpty ||
      (sourceUrl ?? '').isNotEmpty ||
      (sourceRaw ?? const {}).isNotEmpty;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'songs': songs.map((s) => s.toJson()).toList(),
        'importedAt': importedAt,
        if (cloudId != null) 'cloudId': cloudId,
        if (isCloud) 'isCloud': true,
        if (sourcePluginId != null) 'sourcePluginId': sourcePluginId,
        if (sourceUrl != null) 'sourceUrl': sourceUrl,
        if (sourceRaw != null) 'sourceRaw': sourceRaw,
      };

  factory ImportedPlaylist.fromJson(Map<String, dynamic> j) => ImportedPlaylist(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? tr('未命名歌单'),
        songs: (j['songs'] as List? ?? [])
            .whereType<Map>()
            .map((e) => ImportedSong.fromJson(e.cast<String, dynamic>()))
            .toList(),
        importedAt: (j['importedAt'] as num?)?.toInt() ?? 0,
        cloudId: j['cloudId'] as String?,
        isCloud: j['isCloud'] == true,
        sourcePluginId: j['sourcePluginId'] as String?,
        sourceUrl: j['sourceUrl'] as String?,
        sourceRaw:
            j['sourceRaw'] is Map ? (j['sourceRaw'] as Map).cast<String, dynamic>() : null,
      );

  ImportedPlaylist copyWith({
    String? name,
    List<ImportedSong>? songs,
    String? cloudId,
    bool? isCloud,
    String? sourcePluginId,
    String? sourceUrl,
    Map<String, dynamic>? sourceRaw,
  }) =>
      ImportedPlaylist(
        id: id,
        name: name ?? this.name,
        songs: songs ?? this.songs,
        importedAt: importedAt,
        cloudId: cloudId ?? this.cloudId,
        isCloud: isCloud ?? this.isCloud,
        sourcePluginId: sourcePluginId ?? this.sourcePluginId,
        sourceUrl: sourceUrl ?? this.sourceUrl,
        sourceRaw: sourceRaw ?? this.sourceRaw,
      );
}

class PlaylistStore {
  static const _key = 'xianyu_imported_playlists_v1';

  Future<List<ImportedPlaylist>> loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .whereType<Map>()
          .map((e) => ImportedPlaylist.fromJson(e.cast<String, dynamic>()))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> saveAll(List<ImportedPlaylist> playlists) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _key, jsonEncode(playlists.map((p) => p.toJson()).toList()));
  }

  Future<List<ImportedPlaylist>> addPlaylists(
    List<PluginBackupPlaylist> playlists,
  ) async {
    final all = await loadAll();
    final result = [...all];
    for (final pl in playlists) {
      if (pl.songs.isEmpty) continue;
      final existingIndex = result.indexWhere((p) => p.name == pl.name);
      if (existingIndex >= 0) {
        final existing = result[existingIndex];
      final merged = <String, ImportedSong>{};
      for (final s in existing.songs) {
        merged[s.path] = s;
      }
      for (final s in pl.songs) {
        merged[s.path] = s;
      }
      result[existingIndex] = existing.copyWith(
        songs: merged.values.toList(),
        cloudId: existing.cloudId ?? pl.cloudId,
        isCloud: existing.isCloud || pl.isCloud,
        sourcePluginId: existing.sourcePluginId ?? pl.sourcePluginId,
        sourceUrl: existing.sourceUrl ?? pl.sourceUrl,
        sourceRaw: existing.sourceRaw ?? pl.sourceRaw,
      );
      } else {
        result.add(ImportedPlaylist(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          name: pl.name,
          songs: pl.songs,
          importedAt: DateTime.now().millisecondsSinceEpoch,
          cloudId: pl.cloudId,
          isCloud: pl.isCloud,
          sourcePluginId: pl.sourcePluginId,
          sourceUrl: pl.sourceUrl,
          sourceRaw: pl.sourceRaw,
        ));
      }
    }
    await saveAll(result);
    return result;
  }

  Future<List<ImportedPlaylist>> removePlaylist(String id) async {
    final all = await loadAll();
    final result = all.where((p) => p.id != id).toList();
    await saveAll(result);
    return result;
  }

  Future<List<ImportedPlaylist>> setCloudId(String id, String? cloudId) async {
    final all = await loadAll();
    final next = cloudId == null || cloudId.isEmpty ? null : cloudId;
    final result = all
        .map((p) => p.id == id && p.cloudId != next
            ? ImportedPlaylist(
                id: p.id,
                name: p.name,
                songs: p.songs,
                importedAt: p.importedAt,
                cloudId: next,
                isCloud: p.isCloud,
                sourcePluginId: p.sourcePluginId,
                sourceUrl: p.sourceUrl,
                sourceRaw: p.sourceRaw,
              )
            : p)
        .toList();
    await saveAll(result);
    return result;
  }

  Future<List<ImportedPlaylist>> createPlaylist(String name) async {
    final all = await loadAll();
    final result = [
      ...all,
      ImportedPlaylist(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        name: name,
        songs: const [],
        importedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    ];
    await saveAll(result);
    return result;
  }

  Future<List<ImportedPlaylist>> renamePlaylist(
      String id, String name) async {
    final all = await loadAll();
    final result = all
        .map((p) => p.id == id ? p.copyWith(name: name) : p)
        .toList();
    await saveAll(result);
    return result;
  }

  Future<List<ImportedPlaylist>> addSongsTo(
      String id, List<ImportedSong> songs) async {
    if (songs.isEmpty) return loadAll();
    final all = await loadAll();
    final result = all.map((p) {
      if (p.id != id) return p;
      final merged = <String, ImportedSong>{};
      for (final s in p.songs) {
        merged[s.path] = s;
      }
      for (final s in songs) {
        merged[s.path] = s;
      }
      return p.copyWith(songs: merged.values.toList());
    }).toList();
    await saveAll(result);
    return result;
  }

  Future<List<ImportedPlaylist>> removeSong(
      String id, String path) async {
    final all = await loadAll();
    final result = all.map((p) {
      if (p.id != id) return p;
      return p.copyWith(songs: p.songs.where((s) => s.path != path).toList());
    }).toList();
    await saveAll(result);
    return result;
  }

  Future<List<ImportedPlaylist>> reorderSongs(
      String id, List<String> orderedPaths) async {
    final all = await loadAll();
    final pathSet = orderedPaths.toSet();
    final result = all.map((p) {
      if (p.id != id) return p;
      final byPath = {for (final s in p.songs) s.path: s};
      final next = <ImportedSong>[
        for (final path in orderedPaths)
          if (byPath.containsKey(path)) byPath[path]!,
        for (final s in p.songs)
          if (!pathSet.contains(s.path)) s,
      ];
      return p.copyWith(songs: next);
    }).toList();
    await saveAll(result);
    return result;
  }

  /// 记录歌单来源（插件 id + 用户输入的链接/ID + 源端条目原始数据）
  Future<List<ImportedPlaylist>> setSource(
    String id, {
    required String sourcePluginId,
    String? sourceUrl,
    Map<String, dynamic>? sourceRaw,
  }) async {
    final all = await loadAll();
    final result = all.map((p) {
      if (p.id != id) return p;
      return ImportedPlaylist(
        id: p.id,
        name: p.name,
        songs: p.songs,
        importedAt: p.importedAt,
        cloudId: p.cloudId,
        isCloud: p.isCloud,
        sourcePluginId: sourcePluginId,
        sourceUrl: sourceUrl,
        sourceRaw: sourceRaw,
      );
    }).toList();
    await saveAll(result);
    return result;
  }

  /// 应用源端同步：
  /// - 仅增加：追加本地缺失的源端歌曲；
  /// - 完全同步：在仅增加的基础上，删除本地「非本软件添加」且源端已不存在的歌曲。
  Future<List<ImportedPlaylist>> applySourceSync(
    String id, {
    required List<ImportedSong> sourceSongs,
    required bool fullSync,
  }) async {
    final all = await loadAll();
    final index = all.indexWhere((p) => p.id == id);
    if (index < 0) return all;
    final p = all[index];
    final localKeys = p.songs.map((s) => s.path).toSet();
    final additions =
        sourceSongs.where((s) => !localKeys.contains(s.path)).toList();
    var nextSongs = [...p.songs, ...additions];
    if (fullSync) {
      final sourceKeys = sourceSongs.map((s) => s.path).toSet();
      nextSongs = p.songs
          .where((s) => s.addedInApp || sourceKeys.contains(s.path))
          .toList();
      final keptKeys = nextSongs.map((s) => s.path).toSet();
      nextSongs = [
        ...nextSongs,
        ...sourceSongs.where((s) => !keptKeys.contains(s.path)),
      ];
    }
    if (nextSongs.length == p.songs.length &&
        nextSongs.every((s) => localKeys.contains(s.path))) {
      return all;
    }
    final result = [...all];
    result[index] = p.copyWith(songs: nextSongs);
    await saveAll(result);
    return result;
  }

  Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}
