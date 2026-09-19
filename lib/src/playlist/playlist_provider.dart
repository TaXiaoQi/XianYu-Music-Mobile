import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../plugin/plugin_backup_import.dart';
import '../player/player_provider.dart';
import 'playlist_store.dart';

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

  Future<void> detachCloud(String id) async {
    final playlists = await _store.setCloudId(id, null);
    state = ImportedPlaylistState(playlists: playlists, loading: false);
  }

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

  Future<void> setSource(
    String id, {
    required String sourcePluginId,
    String? sourceUrl,
    Map<String, dynamic>? sourceRaw,
  }) async {
    final playlists = await _store.setSource(
      id,
      sourcePluginId: sourcePluginId,
      sourceUrl: sourceUrl,
      sourceRaw: sourceRaw,
    );
    state = ImportedPlaylistState(playlists: playlists, loading: false);
  }

  Future<void> applySourceSync(
    String id, {
    required List<ImportedSong> sourceSongs,
    required bool fullSync,
  }) async {
    final playlists = await _store.applySourceSync(
      id,
      sourceSongs: sourceSongs,
      fullSync: fullSync,
    );
    state = ImportedPlaylistState(playlists: playlists, loading: false);
  }

  Future<void> removeSong(String id, String path) async {
    final playlists = await _store.removeSong(id, path);
    state = ImportedPlaylistState(playlists: playlists, loading: false);
  }

  Future<void> healSongPlugin(String path, String pluginId) async {
    final playlists = await _store.healSongPluginId(path, pluginId);
    state = ImportedPlaylistState(playlists: playlists, loading: false);
  }

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

  Future<void> reorderSongs(String id, List<String> orderedPaths) async {
    final playlists = await _store.reorderSongs(id, orderedPaths);
    state = ImportedPlaylistState(playlists: playlists, loading: false);
  }

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
