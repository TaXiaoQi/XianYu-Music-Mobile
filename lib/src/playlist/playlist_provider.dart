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
      onlineSongJson: jsonEncodeSafe(songJson),
      onlineQuality: '320k',
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
