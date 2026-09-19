import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth/account_api.dart';
import '../auth/auth_provider.dart';
import '../core/app_logger.dart';
import '../core/db_path.dart';
import '../core/settings.dart';
import '../favorites/favorites_provider.dart';
import '../library/library_provider.dart';
import '../notifications/notification_service.dart';
import '../playlist/playlist_provider.dart';
import '../playlist/playlist_store.dart';
import '../player/player_provider.dart' show QueueItem;
import '../plugin/plugin_backup_import.dart';
import '../plugin/plugin_provider.dart';
import '../plugin/plugin_subscriptions.dart';
import '../plugin/plugin_sync_crypto.dart';
import '../plugin/plugin_user_vars.dart';
import 'plugin_sync_state.dart';
import 'favorites_sync_state.dart';
import 'playlist_song_sync_state.dart';
import '../recent/recent_provider.dart';
import '../rust/api.dart' as rust;
import 'settings_conflict_dialog.dart';
import '../i18n/i18n.dart';

class UploadConfig {
  final bool playlists;
  final bool favorites;
  final bool plugins;
  final bool settings;
  final bool history;

  const UploadConfig({
    this.playlists = true,
    this.favorites = true,
    this.plugins = true,
    this.settings = true,
    this.history = false,
  });

  UploadConfig copyWith({
    bool? playlists,
    bool? favorites,
    bool? plugins,
    bool? settings,
    bool? history,
  }) {
    return UploadConfig(
      playlists: playlists ?? this.playlists,
      favorites: favorites ?? this.favorites,
      plugins: plugins ?? this.plugins,
      settings: settings ?? this.settings,
      history: history ?? this.history,
    );
  }

  Map<String, dynamic> toJson() => {
        'playlists': playlists,
        'favorites': favorites,
        'plugins': plugins,
        'settings': settings,
        'history': history,
      };

  factory UploadConfig.fromJson(Map<String, dynamic> j) => UploadConfig(
        playlists: j['playlists'] as bool? ?? true,
        favorites: j['favorites'] as bool? ?? true,
        plugins: j['plugins'] as bool? ?? true,
        settings: j['settings'] as bool? ?? true,
        history: false,
      );
}

class AutoSyncConfig {
  final bool enabled;
  final int syncIntervalSeconds;
  final int maxDelayMinutes;

  const AutoSyncConfig({
    this.enabled = true,
    this.syncIntervalSeconds = 3600,
    this.maxDelayMinutes = 30,
  });

  AutoSyncConfig copyWith({
    bool? enabled,
    int? syncIntervalSeconds,
    int? maxDelayMinutes,
  }) {
    return AutoSyncConfig(
      enabled: enabled ?? this.enabled,
      syncIntervalSeconds: syncIntervalSeconds ?? this.syncIntervalSeconds,
      maxDelayMinutes: maxDelayMinutes ?? this.maxDelayMinutes,
    );
  }
}

class SyncItemState {
  final bool syncing;
  final String? progress;
  final String? lastSummary;
  final DateTime? lastTime;
  final List<String> errors;

  const SyncItemState({
    this.syncing = false,
    this.progress,
    this.lastSummary,
    this.lastTime,
    this.errors = const [],
  });

  SyncItemState copyWith({
    bool? syncing,
    String? progress,
    String? lastSummary,
    DateTime? lastTime,
    List<String>? errors,
  }) {
    return SyncItemState(
      syncing: syncing ?? this.syncing,
      progress: progress,
      lastSummary: lastSummary ?? this.lastSummary,
      lastTime: lastTime ?? this.lastTime,
      errors: errors ?? this.errors,
    );
  }
}

class SyncState {
  final UploadConfig uploadConfig;
  final AutoSyncConfig autoSyncConfig;
  final SyncItemState playlistSync;
  final SyncItemState favoritesSync;
  final SyncItemState pluginSync;
  final SyncItemState settingsSync;
  final SyncItemState historySync;

  const SyncState({
    this.uploadConfig = const UploadConfig(),
    this.autoSyncConfig = const AutoSyncConfig(),
    this.playlistSync = const SyncItemState(),
    this.favoritesSync = const SyncItemState(),
    this.pluginSync = const SyncItemState(),
    this.settingsSync = const SyncItemState(),
    this.historySync = const SyncItemState(),
  });

  SyncState copyWith({
    UploadConfig? uploadConfig,
    AutoSyncConfig? autoSyncConfig,
    SyncItemState? playlistSync,
    SyncItemState? favoritesSync,
    SyncItemState? pluginSync,
    SyncItemState? settingsSync,
    SyncItemState? historySync,
  }) {
    return SyncState(
      uploadConfig: uploadConfig ?? this.uploadConfig,
      autoSyncConfig: autoSyncConfig ?? this.autoSyncConfig,
      playlistSync: playlistSync ?? this.playlistSync,
      favoritesSync: favoritesSync ?? this.favoritesSync,
      pluginSync: pluginSync ?? this.pluginSync,
      settingsSync: settingsSync ?? this.settingsSync,
      historySync: historySync ?? this.historySync,
    );
  }
}

class SyncNotifier extends StateNotifier<SyncState> {
  SyncNotifier(this._ref) : super(const SyncState()) {
    _init();
    _ref.listen<bool>(
      authProvider.select((s) => s.user != null),
      (prev, next) {
        if (prev == true && next == false) _resetLoginSyncFlag();
      },
    );
  }

  final Ref _ref;
  static const _uploadKey = 'sync_upload_config';
  static const _autoSyncKey = 'sync_auto_config';
  static const _loginSyncKey = 'sync_login_synced';

  bool _loginSyncCompleted = false;
  bool _loginSyncInProgress = false;

  AccountApi get _api => _ref.read(accountApiProvider);

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    final uploadJsonStr = prefs.getString(_uploadKey);
    if (uploadJsonStr != null && uploadJsonStr.isNotEmpty) {
      try {
        final j = jsonDecode(uploadJsonStr) as Map<String, dynamic>;
        state = state.copyWith(uploadConfig: UploadConfig.fromJson(j));
      } catch (_) {}
    }

    final autoEnabled = prefs.getBool('${_autoSyncKey}_enabled') ?? true;
    final autoInterval = prefs.getInt('${_autoSyncKey}_interval_seconds') ?? 3600;
    final autoMaxDelay = prefs.getInt('${_autoSyncKey}_max_delay') ?? 30;
    _loginSyncCompleted = prefs.getBool(_loginSyncKey) ?? false;
    state = state.copyWith(
      autoSyncConfig: AutoSyncConfig(
        enabled: autoEnabled,
        syncIntervalSeconds: autoInterval,
        maxDelayMinutes: autoMaxDelay,
      ),
    );
  }

  Future<void> _resetLoginSyncFlag() async {
    _loginSyncCompleted = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_loginSyncKey, false);
    } catch (_) {}
  }

  Future<void> updateUploadConfig(UploadConfig next) async {
    state = state.copyWith(uploadConfig: next);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_uploadKey, jsonEncode(next.toJson()));
  }

  Future<void> syncOnLoginSuccess(BuildContext context) async {
    if (_loginSyncCompleted || _loginSyncInProgress) return;
    _loginSyncInProgress = true;
    final upload = state.uploadConfig;
    try {
      if (upload.playlists) {
        await syncPlaylistsUpload();
        await syncPlaylistsDownload();
      }
      if (upload.plugins) {
        await syncPluginsUpload();
        await syncPluginsDownload();
      }
      if (upload.favorites) {
        await syncFavoritesDownload();
        await syncFavoritesUpload();
      }
      await syncListenStats();
      if (context.mounted) {
        await _ref.read(notificationServiceProvider).showPendingListenResetNotice(context);
      }
      if (upload.settings) {
        if (context.mounted) {
          await syncSettings(context);
        }
      }
    } finally {
      _loginSyncCompleted = true;
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_loginSyncKey, true);
      } catch (_) {}
      _loginSyncInProgress = false;
    }
  }

  Future<void> updateAutoSyncConfig(AutoSyncConfig next) async {
    state = state.copyWith(autoSyncConfig: next);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('${_autoSyncKey}_enabled', next.enabled);
    await prefs.setInt('${_autoSyncKey}_interval_seconds', next.syncIntervalSeconds);
    await prefs.setInt('${_autoSyncKey}_max_delay', next.maxDelayMinutes);
  }

  Future<String> _dataDir() => _ref.read(appDataDirProvider.future);

  Future<String> importLocalBackupFile() async {
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json', 'txt'],
      );
      if (files.isEmpty) return tr('未选择文件');
      final file = files.first;
      String jsonContent = '';
      final bytes = await file.readAsBytes();
      if (bytes.isNotEmpty) {
        jsonContent = utf8.decode(bytes);
      } else if (file.path != null && file.path!.isNotEmpty) {
        final ioFile = File(file.path!);
        if (await ioFile.exists()) {
          jsonContent = await ioFile.readAsString();
        }
      }
      if (jsonContent.trim().isEmpty) return tr('读取文件失败或文件为空');

      final Map<String, dynamic> data = jsonDecode(jsonContent);
      final schema = data['schema'] as String?;

      if (schema == 'xianyu-music.app-backup') {
        final backupData = data['data'] as Map<String, dynamic>? ?? {};
        final favorites = backupData['favorites'] as List? ?? [];
        int importedFavs = 0;
        for (final item in favorites) {
          final p = item is Map ? item['path'] as String? : null;
          final title = item is Map ? item['title'] as String? : null;
          if (p != null && p.isNotEmpty) {
            await _ref.read(favoritesProvider.notifier).add(
              QueueItem(
                path: p,
                title: title ?? p.split(RegExp(r'[\\/]')).last,
                artist: item is Map ? item['artist'] as String? ?? '' : '',
                album: item is Map ? item['album'] as String? ?? '' : '',
              ),
            );
            importedFavs++;
          }
        }
        return tr('成功导入备份：包含 {n} 首收藏曲目', {'n': importedFavs});
      }

      final pluginSources = _ref.read(pluginManagerProvider).sources;
      final prepared = preparePluginBackupImport(jsonContent, pluginSources);
      final importedPlaylists = await _ref
          .read(playlistManagerProvider.notifier)
          .addFromBackup(prepared);

      final versionNote = describeBackupVersion(prepared);
      return tr('导入成功（{note}）：共新增 {pcount} 个歌单，包含 {scount} 首歌曲', {'note': versionNote, 'pcount': importedPlaylists.length, 'scount': prepared.importedSongCount});
    } on FormatException catch (e) {
      return tr('文件格式不匹配或无法解析: {msg}', {'msg': e.message});
    } catch (e) {
      AppLogger.instance.log('sync', '导入本地备份失败: $e');
      return tr('导入失败: {e}', {'e': e});
    }
  }

  // ==================== 歌单同步 ====================

  Map<String, dynamic> _songToSyncPayload(ImportedSong s) => {
        ...s.toJson(),
        'name': s.title,
        'duration': s.duration * 1000,
        'syncType': _classifySyncSong(s),
      };

  static String _classifySyncSong(ImportedSong s) {
    final path = s.path;
    if (path.startsWith('lx://') ||
        path.startsWith('plugin://') ||
        path.startsWith('http://') ||
        path.startsWith('https://')) {
      return 'online';
    }
    return 'local';
  }

  static bool _isOnlineSyncPath(String path) =>
      path.startsWith('lx://') ||
      path.startsWith('plugin://') ||
      path.startsWith('http://') ||
      path.startsWith('https://');

  String _firstRemoteSongCover(List<ImportedSong> songs) {
    for (final s in songs) {
      final cover = s.coverUrl ?? '';
      if (cover.startsWith('http://') || cover.startsWith('https://')) {
        return cover;
      }
    }
    return '';
  }

  ImportedSong _songFromSyncPayload(
    Map<String, dynamic> j,
    Map<String, Song> byPath,
    Map<String, List<Song>> byMeta,
  ) {
    final rawPath = j['path'] as String? ?? '';
    final title = (j['title'] ?? j['name'] ?? '').toString();
    final artist = (j['artist'] ?? '').toString();
    final durationSec = (((j['duration'] as num?) ?? 0) / 1000).round();

    final isOnline = _isOnlineSyncPath(rawPath) ||
        j['syncType'] == 'online' ||
        j['source_type'] == 'remote' ||
        j['source_type'] == 'plugin';
    if (isOnline) {
      return ImportedSong.fromJson({
        'title': title,
        'artist': j['artist'],
        'album': j['album'],
        'duration': durationSec,
        'coverUrl': j['coverUrl'],
        'pluginId': j['pluginId'],
        'source': j['source'],
        'format': j['format'],
        'musicInfo': j['musicInfo'],
        'path': rawPath,
      });
    }

    final isCloudLocal = j['syncType'] == 'local' || j['source_type'] == 'local';
    final cloudLocalPath = (j['localPath'] as String?) ??
        (isCloudLocal ? rawPath : null);
    final matchPath = (cloudLocalPath != null && cloudLocalPath.isNotEmpty)
        ? cloudLocalPath
        : rawPath;
    final matched = _isLocalFilePath(matchPath)
        ? _matchLocalLibrarySong(
            byPath, byMeta, matchPath, title, artist, durationSec)
        : null;
    final resolvedPath = matched?.path ?? matchPath;
    return ImportedSong.fromJson({
      'title': matched?.title ?? title,
      'artist': matched?.artist ?? (j['artist'] ?? ''),
      'album': matched?.album ?? (j['album'] ?? ''),
      'duration': durationSec,
      'coverUrl': j['coverUrl'],
      'coverThumbPath': matched?.coverThumbPath,
      'localPath': resolvedPath,
      'pluginId': j['pluginId'],
      'source': j['source'],
      'format': j['format'],
      'musicInfo': j['musicInfo'],
      'path': resolvedPath,
    });
  }

  static String _normMeta(String s) => s.trim().toLowerCase();

  static Map<String, dynamic> _asMap(Object? v) =>
      v is Map ? v.cast<String, dynamic>() : const {};

  static String? _httpCover(Object? v) {
    final s = v?.toString() ?? '';
    return s.startsWith('http://') || s.startsWith('https://') ? s : null;
  }

  static String? _lxSourceOf(String path) {
    if (!path.startsWith('lx://')) return null;
    final rest = path.substring('lx://'.length);
    final slash = rest.indexOf('/');
    if (slash <= 0) return null;
    return rest.substring(0, slash);
  }

  static String? _lxSongmidOf(String path) {
    if (!path.startsWith('lx://')) return null;
    final rest = path.substring('lx://'.length);
    final slash = rest.indexOf('/');
    if (slash <= 0) return null;
    final id = rest.substring(slash + 1);
    return id.isEmpty ? null : id;
  }

  static bool _isLocalFilePath(String path) =>
      path.isNotEmpty &&
      !path.startsWith('lx://') &&
      !path.startsWith('plugin://') &&
      !path.startsWith('http://') &&
      !path.startsWith('https://');

  ({Map<String, Song> byPath, Map<String, List<Song>> byMeta})
      _buildLibraryIndex() {
    final library = _ref.read(libraryProvider);
    final byPath = <String, Song>{};
    final byMeta = <String, List<Song>>{};
    for (final s in library.songs) {
      byPath[s.path] = s;
      final key = '${_normMeta(s.title)}|${_normMeta(s.artist)}';
      (byMeta[key] ??= []).add(s);
    }
    return (byPath: byPath, byMeta: byMeta);
  }

  Song? _matchLocalLibrarySong(
    Map<String, Song> byPath,
    Map<String, List<Song>> byMeta,
    String cloudPath,
    String title,
    String artist,
    int durationSec,
  ) {
    if (!_isLocalFilePath(cloudPath)) return null;
    final direct = byPath[cloudPath];
    if (direct != null) return direct;
    final candidates =
        byMeta['${_normMeta(title)}|${_normMeta(artist)}'] ?? const [];
    if (candidates.isEmpty) return null;
    if (candidates.length == 1) return candidates.first;
    if (durationSec <= 0) return candidates.first;
    Song? best;
    var bestDiff = 5;
    for (final c in candidates) {
      final diff = (c.duration - durationSec).abs();
      if (diff <= bestDiff) {
        bestDiff = diff;
        best = c;
      }
    }
    return best;
  }

  Future<void> syncPlaylistsUpload() async {
    state = state.copyWith(
      playlistSync: state.playlistSync.copyWith(syncing: true, errors: []),
    );
    try {
      final local = await PlaylistStore().loadAll();
      if (local.isEmpty) {
        state = state.copyWith(
          playlistSync: state.playlistSync.copyWith(
            syncing: false,
            lastSummary: tr('本地暂无可上传的歌单'),
            lastTime: DateTime.now(),
          ),
        );
        return;
      }
      final payload = <Map<String, dynamic>>[];
      for (final p in local) {
        var payloadSongs = p.songs.map(_songToSyncPayload).toList();
        List<String>? deletedSongPaths;
        final cloudId = p.cloudId ?? '';
        if (cloudId.isNotEmpty) {
          final localPaths = p.songs.map((s) => s.path).toSet();
          final keepMap = await PlaylistSongSyncState.cloudKeepSongs(cloudId);
          for (final entry in keepMap.entries) {
            if (!payloadSongs.any((s) => s['path'] == entry.key)) {
              try {
                final decoded = jsonDecode(entry.value);
                if (decoded is Map<String, dynamic>) payloadSongs.add(decoded);
              } catch (_) {
              }
            }
          }
          await PlaylistSongSyncState.pruneCloudKeepSongs(cloudId, localPaths);
          final localOnly = await PlaylistSongSyncState.localOnlySongs(cloudId);
          if (localOnly.isNotEmpty) {
            payloadSongs = payloadSongs
                .where((s) => !localOnly.contains(s['path']))
                .toList();
            await PlaylistSongSyncState.pruneLocalOnlySongs(
                cloudId, localPaths);
          }
          final pending = await PlaylistSongSyncState.pendingDeletedSongs(cloudId);
          if (pending.isNotEmpty) {
            await PlaylistSongSyncState.prunePendingDeletedSongs(
                cloudId, pending.where(localPaths.contains));
          }
          final report = {
            ...await PlaylistSongSyncState.localOnlySongs(cloudId),
            ...await PlaylistSongSyncState.pendingDeletedSongs(cloudId),
          };
          if (report.isNotEmpty) deletedSongPaths = report.toList();
        }
        payload.add({
          'id': p.id,
          'name': p.name,
          'cloudCoverUrl': _firstRemoteSongCover(p.songs),
          'cloudId': p.cloudId,
          'songs': payloadSongs,
          'deletedSongPaths': ?deletedSongPaths,
        });
      }
      final res = await _api.fileSyncUpload(payload);
      final store = PlaylistStore();
      if (res.idMap.isNotEmpty) {
        for (final entry in res.idMap) {
          final localId = (entry['id'] as String?);
          final cloudId = (entry['cloudId'] as String?);
          if (localId != null && localId.isNotEmpty) {
            await store.setCloudId(localId, cloudId);
          }
        }
      }
      state = state.copyWith(
        playlistSync: state.playlistSync.copyWith(
          syncing: false,
          lastSummary: tr('已上传 {pcount} 个歌单 / {scount} 首', {'pcount': res.playlistCount, 'scount': res.songTotal}),
          lastTime: DateTime.now(),
          errors: [],
        ),
      );
    } catch (e) {
      AppLogger.instance.log('sync', '歌单上传失败: $e');
      _setPlaylistError(e is AuthException ? e.message : tr('上传失败: {e}', {'e': e}));
    }
  }

  Future<void> syncPlaylistsDownload() async {
    state = state.copyWith(
      playlistSync: state.playlistSync.copyWith(syncing: true, errors: []),
    );
    try {
      final data = await _api.fileSyncDownload();
      final cloudPlaylists = ((data?['playlists'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
      if (cloudPlaylists.isEmpty) {
        state = state.copyWith(
          playlistSync: state.playlistSync.copyWith(
            syncing: false,
            lastSummary: tr('云端暂无歌单数据'),
            lastTime: DateTime.now(),
          ),
        );
        return;
      }
      final toImport = <PluginBackupPlaylist>[];
      var songCount = 0;
      final library = _ref.read(libraryProvider);
      if (library.loading) {
        await _ref.read(libraryProvider.notifier).load();
      }
      final index = _buildLibraryIndex();
      for (final pl in cloudPlaylists) {
        final cloudId = (pl['cloudId'] as String?) ?? '';
        final plName = (pl['name'] as String?) ?? tr('未命名歌单');
        final deletedPaths = ((pl['deletedSongPaths'] as List?) ?? const [])
            .whereType<String>()
            .toSet();
        final keepMap = cloudId.isNotEmpty
            ? await PlaylistSongSyncState.cloudKeepSongs(cloudId)
            : const <String, String>{};
        final pendingSet = cloudId.isNotEmpty
            ? await PlaylistSongSyncState.pendingDeletedSongs(cloudId)
            : const <String>{};
        final rawSongs =
            ((pl['songs'] as List?) ?? const []).whereType<Map>().toList();
        final visibleRaw = rawSongs.where((e) {
          final p = e['path'] as String?;
          if (p == null) return true;
          if (deletedPaths.contains(p) || pendingSet.contains(p)) return false;
          return !keepMap.containsKey(p);
        }).toList();
        final songs = visibleRaw
            .map((e) =>
                _songFromSyncPayload(e.cast<String, dynamic>(), index.byPath, index.byMeta))
            .toList();
        songCount += songs.length;
        toImport.add(PluginBackupPlaylist(
          name: plName,
          songs: songs,
          originalSongCount: songs.length,
          cloudId: pl['cloudId'] as String?,
          isCloud: true,
        ));
        if (deletedPaths.isNotEmpty) {
          final removePaths = <String>{};
          for (final raw in rawSongs) {
            final p = raw['path'] as String?;
            if (p == null || !deletedPaths.contains(p)) continue;
            removePaths.add(p);
            removePaths.add(_songFromSyncPayload(
                    raw.cast<String, dynamic>(), index.byPath, index.byMeta)
                .path);
          }
          removePaths.remove('');
          await _propagateDeletedSongsToLocal(cloudId, plName, removePaths);
          await PlaylistSongSyncState.prunePendingDeletedSongs(
              cloudId, deletedPaths);
        }
      }
      await PlaylistStore().addPlaylists(toImport);
      await _ref.read(playlistManagerProvider.notifier).refresh();
      state = state.copyWith(
        playlistSync: state.playlistSync.copyWith(
          syncing: false,
          lastSummary: tr('已导入 {n} 个歌单 / {scount} 首', {'n': toImport.length, 'scount': songCount}),
          lastTime: DateTime.now(),
          errors: [],
        ),
      );
    } catch (e) {
      AppLogger.instance.log('sync', '歌单下载失败: $e');
      _setPlaylistError(e is AuthException ? e.message : tr('下载失败: {e}', {'e': e}));
    }
  }

  Future<void> _propagateDeletedSongsToLocal(
      String cloudId, String name, Set<String> removePaths) async {
    if (removePaths.isEmpty) return;
    final store = PlaylistStore();
    final all = await store.loadAll();
    var changed = false;
    final next = all.map((p) {
      final matched =
          (cloudId.isNotEmpty && p.cloudId == cloudId) || p.name == name;
      if (!matched) return p;
      final filtered =
          p.songs.where((s) => !removePaths.contains(s.path)).toList();
      if (filtered.length == p.songs.length) return p;
      changed = true;
      return ImportedPlaylist(
        id: p.id,
        name: p.name,
        songs: filtered,
        importedAt: p.importedAt,
        cloudId: p.cloudId,
        isCloud: p.isCloud,
      );
    }).toList();
    if (changed) {
      await store.saveAll(next);
      await _ref.read(playlistManagerProvider.notifier).refresh();
    }
  }

  void _setPlaylistError(String err) {
    state = state.copyWith(
      playlistSync: state.playlistSync.copyWith(
        syncing: false,
        errors: [err],
      ),
    );
  }

  // ==================== 收藏同步 ====================

  Future<void> syncFavoritesUpload() async {
    state = state.copyWith(
      favoritesSync: state.favoritesSync.copyWith(syncing: true, errors: []),
    );
    try {
      final favEntries = _ref.read(favoritesProvider).entries;
      if (favEntries.isEmpty) {
        state = state.copyWith(
          favoritesSync: state.favoritesSync.copyWith(
            syncing: false,
            lastSummary: tr('本地收藏为空，跳过上传'),
            lastTime: DateTime.now(),
            errors: [],
          ),
        );
        return;
      }
      final localOnly = await FavoritesSyncState.localOnlyPaths();
      final cloudKeep = await FavoritesSyncState.cloudKeepPaths();
      final payload = favEntries.where((e) => !localOnly.contains(e.path)).map((e) {
        return {
          'title': e.title,
          'name': e.title,
          'path': e.path,
          'artist': e.artist,
          'album': e.album,
          'duration': e.durationMs,
          'coverUrl': e.coverUrl,
          'source': e.source,
          'onlineSongJson': e.onlineSongJson,
          'onlineQuality': e.onlineQuality,
          'onlineInfoJson': e.onlineInfoJson,
        };
      }).toList();
      final prefs = await SharedPreferences.getInstance();
      final currentPaths = favEntries.map((e) => e.path).toSet();
      await FavoritesSyncState
          .removeLocalOnlyPaths(localOnly.where((p) => !currentPaths.contains(p)));
      await FavoritesSyncState.removeCloudKeepPaths(currentPaths);
      final deletePaths = (prefs.getStringList('synced_favorites_paths') ?? [])
          .where((p) => !currentPaths.contains(p) && !cloudKeep.contains(p))
          .toList();
      final count = await _api.uploadFavorites(payload, deletePaths: deletePaths);
      await prefs.setStringList('synced_favorites_paths', currentPaths.toList());
      state = state.copyWith(
        favoritesSync: state.favoritesSync.copyWith(
          syncing: false,
          lastSummary: tr('已上传 {n} 首收藏歌曲', {'n': count}),
          lastTime: DateTime.now(),
          errors: [],
        ),
      );
    } catch (e) {
      AppLogger.instance.log('sync', '收藏上传失败: $e');
      _setFavoritesError(e is AuthException ? e.message : tr('上传失败: {e}', {'e': e}));
    }
  }

  Future<void> syncFavoritesDownload() async {
    state = state.copyWith(
      favoritesSync: state.favoritesSync.copyWith(syncing: true, errors: []),
    );
    try {
      final favs = await _api.downloadFavorites();
      if (favs.isEmpty) {
        state = state.copyWith(
          favoritesSync: state.favoritesSync.copyWith(
            syncing: false,
            lastSummary: tr('云端暂无收藏数据'),
            lastTime: DateTime.now(),
          ),
        );
        return;
      }
      final notifier = _ref.read(favoritesProvider.notifier);
      final library = _ref.read(libraryProvider);
      if (library.loading) {
        await _ref.read(libraryProvider.notifier).load();
      }
      final index = _buildLibraryIndex();
      final cloudKeep = await FavoritesSyncState.cloudKeepPaths();
      for (final item in favs) {
        final path = item['path'] as String?;
        if (path == null || path.isEmpty) continue;
        final title = (item['title'] ?? item['name'] ?? path
            .split(RegExp(r'[\\/]'))
            .last) as String;
        final artist = (item['artist'] as String?) ?? '';
        final durationMs = (item['duration'] as num?)?.toInt() ?? 0;

        final musicInfo = _asMap(item['musicInfo']);
        var source = item['source'] as String?;
        var onlineInfoJson = item['onlineInfoJson'] as String?;
        final hasMobileJson =
            (item['onlineSongJson'] as String?)?.isNotEmpty == true ||
            onlineInfoJson?.isNotEmpty == true;
        if (!hasMobileJson && musicInfo.isNotEmpty) {
          source ??= musicInfo['source'] as String? ?? _lxSourceOf(path);
          final mi = <String, dynamic>{'source': source, ...musicInfo};
          if (mi['songmid'] == null) mi['songmid'] = _lxSongmidOf(path);
          onlineInfoJson = jsonEncode(mi);
        }
        final coverUrl = (item['coverUrl'] as String?)?.isNotEmpty == true
            ? item['coverUrl'] as String?
            : _httpCover(musicInfo['img']) ?? _httpCover(item['cover_thumb_path']);

        final matched = _matchLocalLibrarySong(
            index.byPath, index.byMeta, path, title, artist, (durationMs / 1000).round());
        if (cloudKeep.contains(path) ||
            (matched != null && cloudKeep.contains(matched.path))) {
          continue;
        }
        await notifier.add(
          QueueItem(
            path: matched?.path ?? path,
            title: matched?.title ?? title,
            artist: matched?.artist ?? artist,
            album: matched?.album ?? (item['album'] as String?) ?? '',
            durationMs: durationMs,
            coverUrl: coverUrl,
            coverPath: matched?.coverThumbPath,
            source: source,
            onlineSongJson: item['onlineSongJson'] as String?,
            onlineQuality: item['onlineQuality'] as String?,
            onlineInfoJson: onlineInfoJson,
          ),
        );
      }
      state = state.copyWith(
        favoritesSync: state.favoritesSync.copyWith(
          syncing: false,
          lastSummary: tr('已拉取 {n} 首收藏', {'n': favs.length}),
          lastTime: DateTime.now(),
          errors: [],
        ),
      );
    } catch (e) {
      AppLogger.instance.log('sync', '收藏下载失败: $e');
      _setFavoritesError(e is AuthException ? e.message : tr('下载失败: {e}', {'e': e}));
    }
  }

  void _setFavoritesError(String err) {
    state = state.copyWith(
      favoritesSync: state.favoritesSync.copyWith(
        syncing: false,
        errors: [err],
      ),
    );
  }

  // ==================== 插件同步 ====================

  static String _encodeRevBase64(String s) =>
      String.fromCharCodes(base64Encode(utf8.encode(s)).codeUnits.reversed);

  static String _decodeRevBase64(String s) =>
      utf8.decode(base64Decode(String.fromCharCodes(s.codeUnits.reversed)));

  Future<void> syncPluginsUpload() async {
    state = state.copyWith(
      pluginSync: state.pluginSync.copyWith(syncing: true, errors: []),
    );
    try {
      var sources = _ref.read(pluginManagerProvider).sources;
      if (sources.isEmpty) {
        await _ref.read(pluginManagerProvider.notifier).refresh();
        sources = _ref.read(pluginManagerProvider).sources;
      }
      final uploadSkip = await PluginSyncState.uploadSkipIds();
      final targets =
          sources.where((p) => !uploadSkip.contains(p.id)).toList();
      final subs = _ref
          .read(pluginSubscriptionsProvider)
          .map((s) => s.toJson())
          .toList();
      if (targets.isEmpty) {
        if (subs.isNotEmpty) {
          try {
            await _api.uploadPlugin({},
                isFirst: true, subscriptions: subs);
            state = state.copyWith(
              pluginSync: state.pluginSync.copyWith(
                syncing: false,
                lastSummary: tr('已上传 {n} 个订阅链接', {'n': subs.length}),
                lastTime: DateTime.now(),
              ),
            );
          } catch (e) {
            _setPluginError(e is AuthException ? e.message : tr('订阅上传失败: {e}', {'e': e}));
          }
        } else {
          state = state.copyWith(
            pluginSync: state.pluginSync.copyWith(
              syncing: false,
              lastSummary: tr('本地暂无可上传的插件'),
              lastTime: DateTime.now(),
            ),
          );
        }
        await PluginSyncState.setSyncedIds(const <String>[]);
        return;
      }
      final dir = await _dataDir();
      final errors = <String>[];
      var uploaded = 0;
      final uploadedIds = <String>[];
      for (var i = 0; i < targets.length; i++) {
        final p = targets[i];
        final scriptPath = '$dir/plugins/${p.id}.js';
        try {
          final script = await rust.readPluginFile(path: scriptPath);
          if (script.trim().isEmpty) {
            errors.add(tr('插件 "{name}" 脚本读取失败，已跳过', {'name': p.name}));
            continue;
          }
          final plugin = <String, dynamic>{
            'id': p.id,
            'name': p.name,
            'version': p.version,
            'author': p.author,
            'description': p.description,
            'enabled': p.enabled,
            'sources': p.sources,
            'filePath': scriptPath,
            'sourceUrl': p.sourceUrl,
            'script': _encodeRevBase64(script),
            'scriptEncoded': true,
          };
          final ciyuanxiId = _api.ciyuanxiId;
          if (ciyuanxiId != null && ciyuanxiId.isNotEmpty) {
            final userVars =
                await _ref.read(pluginUserVarValuesProvider.notifier).valuesOf(p.id);
            if (userVars.isNotEmpty) {
              final block = PluginUserVarCrypto.encrypt(ciyuanxiId, userVars);
              if (block != null) plugin['userVariablesEncrypted'] = block;
            }
          }
          await _api.uploadPlugin(plugin, isFirst: i == 0, subscriptions: subs);
          uploaded++;
          uploadedIds.add(p.id);
        } catch (e) {
          AppLogger.instance.log('sync', '插件 ${p.name} 上传失败: $e');
          errors.add(tr('插件 "{name}" 上传失败', {'name': p.name}));
        }
      }
      await PluginSyncState.setSyncedIds(uploadedIds);
      state = state.copyWith(
        pluginSync: state.pluginSync.copyWith(
          syncing: false,
          lastSummary: uploaded > 0
              ? tr('已上传 {n} 个插件{subs}', {'n': uploaded, 'subs': subs.isNotEmpty ? tr('、{n} 个订阅', {'n': subs.length}) : ''})
              : tr('没有插件被上传'),
          lastTime: DateTime.now(),
          errors: errors,
        ),
      );
    } catch (e) {
      AppLogger.instance.log('sync', '插件上传失败: $e');
      _setPluginError(e is AuthException ? e.message : tr('上传失败: {e}', {'e': e}));
    }
  }

  Future<void> syncPluginsDownload() async {
    state = state.copyWith(
      pluginSync: state.pluginSync.copyWith(syncing: true, errors: []),
    );
    try {
      final snapshot = await _api.downloadPluginSnapshot();

      final cloudSubs = ((snapshot['subscriptions'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
      var mergedSubs = 0;
      if (cloudSubs.isNotEmpty) {
        mergedSubs = await _ref
            .read(pluginSubscriptionsProvider.notifier)
            .mergeFromCloud(cloudSubs);
      }

      final items = ((snapshot['plugins'] as List?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList();
      if (items.isEmpty) {
        state = state.copyWith(
          pluginSync: state.pluginSync.copyWith(
            syncing: false,
            lastSummary: mergedSubs > 0
                ? tr('已同步 {n} 个订阅链接', {'n': mergedSubs})
                : tr('云端暂无插件数据'),
            lastTime: DateTime.now(),
          ),
        );
        return;
      }
      final errors = <String>[];
      var installed = 0;
      final restoredIds = <String>[];
      final downloadSkip = await PluginSyncState.downloadSkipIds();
      final pluginManager = _ref.read(pluginManagerProvider.notifier);
      for (final item in items) {
        final cloudId = (item['id'] as String?)?.trim() ?? '';
        if (cloudId.isNotEmpty && downloadSkip.contains(cloudId)) {
          continue;
        }
        final cloudName = (item['name'] as String?)?.trim() ?? '';
        final name = cloudName.isNotEmpty ? cloudName : tr('未知插件');
        var script = (item['script'] as String?) ?? '';
        if (item['scriptEncoded'] == true && script.isNotEmpty) {
          try {
            script = _decodeRevBase64(script);
          } catch (_) {
            errors.add(tr('插件 "{name}" 脚本解码失败', {'name': name}));
            continue;
          }
        }
        if (script.trim().isEmpty) {
          errors.add(tr('插件 "{name}" 脚本为空，已跳过', {'name': name}));
          continue;
        }
        try {
          final version = (item['version'] as String?)?.trim() ?? '';
          final source = await pluginManager.installFromScript(
            script,
            nameOverride: cloudName.isEmpty ? null : cloudName,
            versionOverride: version.isEmpty ? null : version,
            sourceUrl: (item['sourceUrl'] as String?)?.trim() ?? '',
          );
          if (item['enabled'] == false && source.enabled) {
            await pluginManager.toggleEnabled(source.id);
          }
          final encBlock = item['userVariablesEncrypted'];
          if (encBlock is Map) {
            final ciyuanxiId = _api.ciyuanxiId;
            if (ciyuanxiId != null && ciyuanxiId.isNotEmpty) {
              final values = PluginUserVarCrypto.decrypt(
                  ciyuanxiId, encBlock.cast<String, dynamic>());
              if (values != null && values.isNotEmpty) {
                await _ref
                    .read(pluginUserVarValuesProvider.notifier)
                    .save(source.id, values);
                await pluginManager.syncBilibiliCookiesFromVars(
                    source.id, values);
              } else {
                errors.add(tr('插件 "{name}" 用户变量解密失败', {'name': name}));
              }
            }
          }
          installed++;
          restoredIds.add(source.id);
        } catch (e) {
          AppLogger.instance.log('sync', '插件 $name 恢复失败: $e');
          errors.add(tr('插件 "{name}" 恢复失败：{e}', {'name': name, 'e': e}));
        }
      }
      await PluginSyncState.addSyncedIds(restoredIds);
      state = state.copyWith(
        pluginSync: state.pluginSync.copyWith(
          syncing: false,
          lastSummary: installed > 0
              ? tr('已恢复 {n} 个插件{subs}', {'n': installed, 'subs': mergedSubs > 0 ? tr('、{n} 个订阅', {'n': mergedSubs}) : ''})
              : (mergedSubs > 0 ? tr('已同步 {n} 个订阅链接', {'n': mergedSubs}) : tr('没有插件被恢复')),
          lastTime: DateTime.now(),
          errors: errors,
        ),
      );
    } catch (e) {
      AppLogger.instance.log('sync', '插件下载失败: $e');
      _setPluginError(e is AuthException ? e.message : tr('下载失败: {e}', {'e': e}));
    }
  }

  void _setPluginError(String err) {
    state = state.copyWith(
      pluginSync: state.pluginSync.copyWith(
        syncing: false,
        errors: [err],
      ),
    );
  }

  // ==================== 设置同步 ====================

  Future<void> syncSettingsUpload() async {
    state = state.copyWith(
      settingsSync: state.settingsSync.copyWith(syncing: true, errors: []),
    );
    try {
      final settings = _ref.read(settingsProvider).valueOrNull;
      if (settings == null) {
        _setSettingsError(tr('本地设置尚未加载完成'));
        return;
      }
      await _api.uploadSettings(settings);
      state = state.copyWith(
        settingsSync: state.settingsSync.copyWith(
          syncing: false,
          lastSummary: tr('已上传偏好设置'),
          lastTime: DateTime.now(),
          errors: [],
        ),
      );
    } catch (e) {
      AppLogger.instance.log('sync', '设置上传失败: $e');
      _setSettingsError(e is AuthException ? e.message : tr('上传失败: {e}', {'e': e}));
    }
  }

  Future<void> syncSettingsDownload() async {
    state = state.copyWith(
      settingsSync: state.settingsSync.copyWith(syncing: true, errors: []),
    );
    try {
      final cloud = await _api.downloadSettings();
      if (cloud == null || cloud.isEmpty) {
        state = state.copyWith(
          settingsSync: state.settingsSync.copyWith(
            syncing: false,
            lastSummary: tr('云端暂无设置'),
            lastTime: DateTime.now(),
          ),
        );
        return;
      }
      final local = _ref.read(settingsProvider).valueOrNull;
      if (local == null) {
        _setSettingsError(tr('本地设置尚未加载完成'));
        return;
      }
      final merged = applySyncedSettings(local, cloud);
      await _ref.read(settingsProvider.notifier).saveAll(merged);
      state = state.copyWith(
        settingsSync: state.settingsSync.copyWith(
          syncing: false,
          lastSummary: tr('已应用云端设置'),
          lastTime: DateTime.now(),
          errors: [],
        ),
      );
    } catch (e) {
      AppLogger.instance.log('sync', '设置下载失败: $e');
      _setSettingsError(e is AuthException ? e.message : tr('下载失败: {e}', {'e': e}));
    }
  }

  void _setSettingsError(String err) {
    state = state.copyWith(
      settingsSync: state.settingsSync.copyWith(
        syncing: false,
        errors: [err],
      ),
    );
  }

  Future<void> syncSettings(BuildContext context) async {
    state = state.copyWith(
      settingsSync: state.settingsSync.copyWith(syncing: true, errors: []),
    );
    try {
      final local = _ref.read(settingsProvider).valueOrNull;
      if (local == null) {
        _setSettingsError(tr('本地设置尚未加载完成'));
        return;
      }
      final meta = await _api.downloadSettingsCrossPlatform();
      final cloud = meta.settings;
      final cloudTime = meta.uploadedAt;
      final upload = _ref.read(syncProvider).uploadConfig;

      if (cloud == null || cloud.isEmpty) {
        if (upload.settings) {
          await _api.uploadSettings(local);
          state = state.copyWith(
            settingsSync: state.settingsSync.copyWith(
              syncing: false,
              lastSummary: tr('已上传偏好设置'),
              lastTime: DateTime.now(),
              errors: [],
            ),
          );
        } else {
          state = state.copyWith(
            settingsSync: state.settingsSync.copyWith(
              syncing: false,
              lastSummary: tr('云端暂无设置'),
              lastTime: DateTime.now(),
              errors: [],
            ),
          );
        }
        return;
      }

      if (areSettingsEqual(local, cloud)) {
        state = state.copyWith(
          settingsSync: state.settingsSync.copyWith(
            syncing: false,
            lastSummary: tr('本地与云端设置一致，无需同步'),
            lastTime: DateTime.now(),
            errors: [],
          ),
        );
        return;
      }

      if (!context.mounted) return;
      final choices = await showSettingsConflictDialog(
        context: context,
        localTime: DateTime.now(),
        cloudTime: cloudTime ?? DateTime.now(),
      );
      if (choices == null) {
        state = state.copyWith(
          settingsSync: state.settingsSync.copyWith(
            syncing: false,
            lastSummary: tr('已取消设置同步'),
            lastTime: DateTime.now(),
            errors: [],
          ),
        );
        return;
      }

      final errors = <String>[];

      // --- 设置 ---
      if (choices.settings == SyncDirection.local) {
        if (upload.settings) {
          try {
            await _api.uploadSettings(local);
          } catch (e) {
            errors.add(tr('设置上传失败: {e}', {'e': e}));
          }
        }
      } else {
        try {
          final merged = applySyncedSettings(local, cloud);
          await _ref.read(settingsProvider.notifier).saveAll(merged);
        } catch (e) {
          errors.add(tr('设置下载失败: {e}', {'e': e}));
        }
      }

      // --- 歌单 ---
      if (choices.playlists == SyncDirection.local) {
        if (upload.playlists) {
          await syncPlaylistsUpload();
        }
      } else {
        await syncPlaylistsDownload();
      }

      // --- 插件 ---
      if (choices.plugins == SyncDirection.local) {
        if (upload.plugins) {
          await syncPluginsUpload();
        }
      } else {
        await syncPluginsDownload();
      }

      state = state.copyWith(
        settingsSync: state.settingsSync.copyWith(
          syncing: false,
          lastSummary: errors.isEmpty ? tr('同步完成') : '同步完成（${errors.length} 个错误）',
          lastTime: DateTime.now(),
          errors: errors,
        ),
      );
    } catch (e) {
      AppLogger.instance.log('sync', '设置同步失败: $e');
      _setSettingsError(e is AuthException ? e.message : tr('同步失败: {e}', {'e': e}));
    }
  }

  // ==================== 播放历史同步 ====================

  Future<void> syncHistoryUpload() async {
    state = state.copyWith(
      historySync: state.historySync.copyWith(syncing: true, errors: []),
    );
    try {
      final dbPath = await _ref.read(dbPathProvider.future);
      final json = await rust.statsGetRecentHistory(dbPath: dbPath, limit: BigInt.from(200));
      final list = (jsonDecode(json) as List)
          .map((e) => e as Map<String, dynamic>)
          .toList();
      if (list.isEmpty) {
        state = state.copyWith(
          historySync: state.historySync.copyWith(
            syncing: false,
            lastSummary: tr('本地暂无播放历史'),
            lastTime: DateTime.now(),
          ),
        );
        return;
      }
      final payload = list
          .map((e) => {
                'songPath': e['songPath'] ?? '',
                'playedAt': (e['playedAt'] as num?)?.toInt() ?? 0,
              })
          .where((e) => (e['songPath'] as String).isNotEmpty)
          .toList();
      final count = await _api.uploadHistory(payload);
      state = state.copyWith(
        historySync: state.historySync.copyWith(
          syncing: false,
          lastSummary: tr('已上传 {n} 条播放记录', {'n': count}),
          lastTime: DateTime.now(),
          errors: [],
        ),
      );
    } catch (e) {
      AppLogger.instance.log('sync', '播放历史上传失败: $e');
      _setHistoryError(e is AuthException ? e.message : tr('上传失败: {e}', {'e': e}));
    }
  }

  Future<void> syncHistoryDownload() async {
    state = state.copyWith(
      historySync: state.historySync.copyWith(syncing: true, errors: []),
    );
    try {
      final history = await _api.downloadHistory();
      if (history.isEmpty) {
        state = state.copyWith(
          historySync: state.historySync.copyWith(
            syncing: false,
            lastSummary: tr('云端暂无播放历史'),
            lastTime: DateTime.now(),
          ),
        );
        return;
      }
      final dbPath = await _ref.read(dbPathProvider.future);
      var added = 0;
      for (final item in history) {
        final path = (item['songPath'] as String?)?.trim() ?? '';
        if (path.isEmpty) continue;
        await rust.statsAddToHistory(dbPath: dbPath, songPath: path);
        added++;
      }
      await _ref.read(recentProvider.notifier).refresh();
      state = state.copyWith(
        historySync: state.historySync.copyWith(
          syncing: false,
          lastSummary: tr('已恢复 {n} 条播放历史', {'n': added}),
          lastTime: DateTime.now(),
          errors: [],
        ),
      );
    } catch (e) {
      AppLogger.instance.log('sync', '播放历史下载失败: $e');
      _setHistoryError(e is AuthException ? e.message : tr('下载失败: {e}', {'e': e}));
    }
  }

  void _setHistoryError(String err) {
    state = state.copyWith(
      historySync: state.historySync.copyWith(
        syncing: false,
        errors: [err],
      ),
    );
  }

  // ==================== 听歌累计统计同步 ====================

  Future<void> syncListenStats() async {
    AppLogger.instance
        .log('sync', '[听歌统计] 快照同步已废弃，听歌时长由增量上报统一维护');
  }
}

final syncProvider = StateNotifierProvider<SyncNotifier, SyncState>(
  (ref) => SyncNotifier(ref),
);
