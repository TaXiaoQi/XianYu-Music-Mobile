import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../plugin/plugin_backup_import.dart';
import '../player/player_provider.dart';
import 'playlist_store.dart';

/// 导入歌单状态。
class ImportedPlaylistState {
  final List<ImportedPlaylist> playlists;
  final bool loading;

  const ImportedPlaylistState({this.playlists = const [], this.loading = true});

  ImportedPlaylistState copyWith({
    List<ImportedPlaylist>? playlists,
    bool? loading,
  }) {
    return ImportedPlaylistState(
      playlists: playlists ?? this.playlists,
      loading: loading ?? this.loading,
    );
  }
}

/// 导入歌单管理器。
class PlaylistManager extends StateNotifier<ImportedPlaylistState> {
  PlaylistManager(this._ref) : super(const ImportedPlaylistState()) {
    refresh();
  }

  final Ref _ref;
  final PlaylistStore _store = PlaylistStore();

  Future<void> refresh() async {
    final playlists = await _store.loadAll();
    state = ImportedPlaylistState(playlists: playlists, loading: false);
  }

  /// 保存导入结果中的歌单，返回更新后的列表。
  Future<List<ImportedPlaylist>> addFromBackup(
    PreparedPluginBackupImport prepared,
  ) async {
    final playlists = await _store.addPlaylists(prepared.playlists);
    state = ImportedPlaylistState(playlists: playlists, loading: false);
    return playlists;
  }

  Future<void> remove(String id) async {
    final playlists = await _store.removePlaylist(id);
    state = ImportedPlaylistState(playlists: playlists, loading: false);
  }

  /// 仅保留本地：解绑云端标记（清除 cloudId），保留本地歌单。
  Future<void> detachCloud(String id) async {
    final playlists = await _store.setCloudId(id, null);
    state = ImportedPlaylistState(playlists: playlists, loading: false);
  }

  /// 按指定 id 顺序重排歌单（未列出的歌单保持在队尾）。
  Future<void> reorder(List<String> orderedIds) async {
    final current = state.playlists;
    final idSet = orderedIds.toSet();
    final byId = {for (final p in current) p.id: p};
    final result = <ImportedPlaylist>[
      for (final id in orderedIds)
        if (byId.containsKey(id)) byId[id]!,
      for (final p in current)
        if (!idSet.contains(p.id)) p,
    ];
    await _store.saveAll(result);
    state = ImportedPlaylistState(playlists: result, loading: false);
  }

  Future<void> create(String name) async {
    final playlists = await _store.createPlaylist(name);
    state = ImportedPlaylistState(playlists: playlists, loading: false);
  }

  Future<void> rename(String id, String name) async {
    final playlists = await _store.renamePlaylist(id, name);
    state = ImportedPlaylistState(playlists: playlists, loading: false);
  }

  Future<void> addSongs(String id, List<ImportedSong> songs) async {
    final playlists = await _store.addSongsTo(id, songs);
    state = ImportedPlaylistState(playlists: playlists, loading: false);
  }

  Future<void> removeSong(String id, String path) async {
    final playlists = await _store.removeSong(id, path);
    state = ImportedPlaylistState(playlists: playlists, loading: false);
  }

  /// 悬空 pluginId 运行时修复（播放解析回写）：持久化并刷新内存态，
  /// 使后续播放直接命中新插件而无需重复重匹配。
  Future<void> healSongPlugin(String path, String pluginId) async {
    final playlists = await _store.healSongPluginId(path, pluginId);
    state = ImportedPlaylistState(playlists: playlists, loading: false);
  }

  /// 跨格式换源完整修复：更新 pluginId/source/format/musicInfo，
  /// 使跨格式（LX↔MusicFree/Baka）重搜后的歌曲下次播放直接命中新插件。
  Future<void> healSongPluginFull(
    String path, {
    required String pluginId,
    String? source,
    String? format,
    Map<String, dynamic>? musicInfo,
  }) async {
    final playlists = await _store.healSongPluginFull(
      path,
      pluginId: pluginId,
      source: source,
      format: format,
      musicInfo: musicInfo,
    );
    state = ImportedPlaylistState(playlists: playlists, loading: false);
  }

  /// 重排歌单内歌曲顺序（按 path）。
  Future<void> reorderSongs(String id, List<String> orderedPaths) async {
    final playlists = await _store.reorderSongs(id, orderedPaths);
    state = ImportedPlaylistState(playlists: playlists, loading: false);
  }

  /// 播放歌单（从指定索引开始）。
  Future<void> play(ImportedPlaylist playlist, int index) async {
    final items = playlist.songs.map((s) => _toQueueItem(s)).toList();
    await _ref.read(playerProvider.notifier).playQueue(items, startIndex: index);
  }

  QueueItem _toQueueItem(ImportedSong song) {
    if (song.isLocal) {
      return QueueItem(
        path: song.path,
        title: song.title,
        artist: song.artist,
        album: song.album,
        durationMs: song.duration * 1000,
      );
    }
    final songJson = <String, dynamic>{
      'pluginId': song.pluginId,
      'source': song.source,
      'format': song.format,
      'musicInfo': song.musicInfo,
    };
    return QueueItem(
      path: song.path,
      title: song.title,
      artist: song.artist,
      album: song.album,
      durationMs: song.duration * 1000,
      coverUrl: song.coverUrl,
      onlineSongJson: jsonEncodeSafe(songJson),
      onlineQuality: '320k',
      source: song.source,
      // 补全 onlineInfoJson：插件 getLyric 失败时，歌词仓库能走 Rust 内置
      // fetchLyricFromSource 兜底（与在线搜索结果的 QueueItem 对齐）。
      onlineInfoJson: jsonEncodeSafe(song.musicInfo ?? <String, dynamic>{}),
    );
  }
}

String jsonEncodeSafe(Map<String, dynamic> map) {
  try {
    return jsonEncode(map);
  } catch (_) {
    return '{}';
  }
}

final playlistManagerProvider =
    StateNotifierProvider<PlaylistManager, ImportedPlaylistState>((ref) {
  return PlaylistManager(ref);
});
