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
part 'sync_provider.playlist.dart';
part 'sync_provider.favorites.dart';
part 'sync_provider.plugins.dart';
part 'sync_provider.settings.dart';
part 'sync_provider.history.dart';

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

/// 域同步状态透镜：把 SyncNotifier 各域（歌单/收藏/插件/设置/历史）的
/// 状态读写收敛为注入点，域同步服务类不直接触碰
/// StateNotifier.state（@protected），由 Notifier 类体内装配。
class SyncDomainLens {
  SyncDomainLens({
    required SyncItemState Function() read,
    required void Function(SyncItemState) write,
  })  : _read = read,
        _write = write;

  final SyncItemState Function() _read;
  final void Function(SyncItemState) _write;

  SyncItemState get item => _read();
  set item(SyncItemState next) => _write(next);
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

  // ---- 域同步服务装配 ----
  /// 状态写权限收口：透镜在类体内创建，域同步服务类经注入读写各域状态。
  SyncDomainLens _lens(
    SyncItemState Function(SyncState) pick,
    SyncState Function(SyncState, SyncItemState) place,
  ) =>
      SyncDomainLens(
        read: () => pick(state),
        write: (v) => state = place(state, v),
      );

  PlaylistSyncService get _playlistSyncSvc => PlaylistSyncService(
      _ref,
      _lens((s) => s.playlistSync, (s, v) => s.copyWith(playlistSync: v)));

  FavoritesSyncService get _favoritesSyncSvc => FavoritesSyncService(_ref,
      _lens((s) => s.favoritesSync, (s, v) => s.copyWith(favoritesSync: v)));

  PluginsSyncService get _pluginsSyncSvc => PluginsSyncService(_ref,
      _lens((s) => s.pluginSync, (s, v) => s.copyWith(pluginSync: v)));

  SettingsSyncService get _settingsSyncSvc => SettingsSyncService(
        _ref,
        _lens((s) => s.settingsSync, (s, v) => s.copyWith(settingsSync: v)),
        uploadConfig: () => state.uploadConfig,
        playlists: _playlistSyncSvc,
        plugins: _pluginsSyncSvc,
      );

  HistorySyncService get _historySyncSvc => HistorySyncService(
      _ref, _lens((s) => s.historySync, (s, v) => s.copyWith(historySync: v)));

  // ---- 对外同步入口（薄委托，公共 API 不变）----

  Future<void> syncPlaylistsUpload() => _playlistSyncSvc.upload();

  Future<void> syncPlaylistsDownload() => _playlistSyncSvc.download();

  Future<void> syncFavoritesUpload() => _favoritesSyncSvc.upload();

  Future<void> syncFavoritesDownload() => _favoritesSyncSvc.download();

  Future<void> syncPluginsUpload() => _pluginsSyncSvc.upload();

  Future<void> syncPluginsDownload() => _pluginsSyncSvc.download();

  Future<void> syncSettingsUpload() => _settingsSyncSvc.upload();

  Future<void> syncSettingsDownload() => _settingsSyncSvc.download();

  Future<void> syncSettings(BuildContext context) =>
      _settingsSyncSvc.sync(context);

  Future<void> syncHistoryUpload() => _historySyncSvc.upload();

  Future<void> syncHistoryDownload() => _historySyncSvc.download();

  Future<void> syncListenStats() async {
    AppLogger.instance
        .log('sync', '[听歌统计] 快照同步已废弃，听歌时长由增量上报统一维护');
  }

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

  static ({Map<String, Song> byPath, Map<String, List<Song>> byMeta})
      _buildLibraryIndex(Ref ref) {
    final library = ref.read(libraryProvider);
    final byPath = <String, Song>{};
    final byMeta = <String, List<Song>>{};
    for (final s in library.songs) {
      byPath[s.path] = s;
      final key = '${_normMeta(s.title)}|${_normMeta(s.artist)}';
      (byMeta[key] ??= []).add(s);
    }
    return (byPath: byPath, byMeta: byMeta);
  }

  static Song? _matchLocalLibrarySong(
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
  // ==================== 插件同步 ====================

  static String _encodeRevBase64(String s) =>
      String.fromCharCodes(base64Encode(utf8.encode(s)).codeUnits.reversed);

  static String _decodeRevBase64(String s) =>
      utf8.decode(base64Decode(String.fromCharCodes(s.codeUnits.reversed)));

}

final syncProvider = StateNotifierProvider<SyncNotifier, SyncState>(
  (ref) => SyncNotifier(ref),
);
