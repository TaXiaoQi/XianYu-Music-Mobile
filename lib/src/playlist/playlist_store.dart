import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../plugin/plugin_backup_import.dart';

/// 导入的歌单（备份导入产生，持久化到 SharedPreferences）。
class ImportedPlaylist {
  final String id;
  final String name;
  final List<ImportedSong> songs;
  final int importedAt;

  ImportedPlaylist({
    required this.id,
    required this.name,
    required this.songs,
    required this.importedAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'songs': songs.map((s) => s.toJson()).toList(),
        'importedAt': importedAt,
      };

  factory ImportedPlaylist.fromJson(Map<String, dynamic> j) => ImportedPlaylist(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? '未命名歌单',
        songs: (j['songs'] as List? ?? [])
            .whereType<Map>()
            .map((e) => ImportedSong.fromJson(e.cast<String, dynamic>()))
            .toList(),
        importedAt: (j['importedAt'] as num?)?.toInt() ?? 0,
      );
}

/// 导入歌单的持久化存储。
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

  /// 追加导入的歌单（按名称去重，同名则合并歌曲）。
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
        result[existingIndex] = ImportedPlaylist(
          id: existing.id,
          name: existing.name,
          songs: merged.values.toList(),
          importedAt: existing.importedAt,
        );
      } else {
        result.add(ImportedPlaylist(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          name: pl.name,
          songs: pl.songs,
          importedAt: DateTime.now().millisecondsSinceEpoch,
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

  /// 新建空歌单。
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

  /// 重命名歌单。
  Future<List<ImportedPlaylist>> renamePlaylist(
      String id, String name) async {
    final all = await loadAll();
    final result = all
        .map((p) => p.id == id
            ? ImportedPlaylist(
                id: p.id,
                name: name,
                songs: p.songs,
                importedAt: p.importedAt,
              )
            : p)
        .toList();
    await saveAll(result);
    return result;
  }

  /// 向歌单添加歌曲（按 path 去重）。
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
      return ImportedPlaylist(
        id: p.id,
        name: p.name,
        songs: merged.values.toList(),
        importedAt: p.importedAt,
      );
    }).toList();
    await saveAll(result);
    return result;
  }

  /// 从歌单移除单曲（按 path 匹配）。
  Future<List<ImportedPlaylist>> removeSong(
      String id, String path) async {
    final all = await loadAll();
    final result = all.map((p) {
      if (p.id != id) return p;
      return ImportedPlaylist(
        id: p.id,
        name: p.name,
        songs: p.songs.where((s) => s.path != path).toList(),
        importedAt: p.importedAt,
      );
    }).toList();
    await saveAll(result);
    return result;
  }

  Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}
