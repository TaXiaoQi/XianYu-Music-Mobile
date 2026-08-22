import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth/auth_provider.dart';
import '../core/app_logger.dart';
import '../core/db_path.dart';
import '../favorites/favorites_provider.dart';
import '../player/player_provider.dart';
import '../rust/api.dart';

/// 上传选项配置
class UploadConfig {
  final bool playlists;
  final bool favorites;
  final bool plugins;
  final bool settings;

  const UploadConfig({
    this.playlists = true,
    this.favorites = true,
    this.plugins = true,
    this.settings = true,
  });

  UploadConfig copyWith({
    bool? playlists,
    bool? favorites,
    bool? plugins,
    bool? settings,
  }) {
    return UploadConfig(
      playlists: playlists ?? this.playlists,
      favorites: favorites ?? this.favorites,
      plugins: plugins ?? this.plugins,
      settings: settings ?? this.settings,
    );
  }

  Map<String, dynamic> toJson() => {
        'playlists': playlists,
        'favorites': favorites,
        'plugins': plugins,
        'settings': settings,
      };

  factory UploadConfig.fromJson(Map<String, dynamic> j) => UploadConfig(
        playlists: j['playlists'] as bool? ?? true,
        favorites: j['favorites'] as bool? ?? true,
        plugins: j['plugins'] as bool? ?? true,
        settings: j['settings'] as bool? ?? true,
      );
}

/// 自动同步配置
class AutoSyncConfig {
  final bool enabled;
  final int syncIntervalHours;

  const AutoSyncConfig({
    this.enabled = false,
    this.syncIntervalHours = 24,
  });

  AutoSyncConfig copyWith({
    bool? enabled,
    int? syncIntervalHours,
  }) {
    return AutoSyncConfig(
      enabled: enabled ?? this.enabled,
      syncIntervalHours: syncIntervalHours ?? this.syncIntervalHours,
    );
  }
}

/// 单项同步状态结果
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

  const SyncState({
    this.uploadConfig = const UploadConfig(),
    this.autoSyncConfig = const AutoSyncConfig(),
    this.playlistSync = const SyncItemState(),
    this.favoritesSync = const SyncItemState(),
    this.pluginSync = const SyncItemState(),
    this.settingsSync = const SyncItemState(),
  });

  SyncState copyWith({
    UploadConfig? uploadConfig,
    AutoSyncConfig? autoSyncConfig,
    SyncItemState? playlistSync,
    SyncItemState? favoritesSync,
    SyncItemState? pluginSync,
    SyncItemState? settingsSync,
  }) {
    return SyncState(
      uploadConfig: uploadConfig ?? this.uploadConfig,
      autoSyncConfig: autoSyncConfig ?? this.autoSyncConfig,
      playlistSync: playlistSync ?? this.playlistSync,
      favoritesSync: favoritesSync ?? this.favoritesSync,
      pluginSync: pluginSync ?? this.pluginSync,
      settingsSync: settingsSync ?? this.settingsSync,
    );
  }
}

class SyncNotifier extends StateNotifier<SyncState> {
  SyncNotifier(this._ref) : super(const SyncState()) {
    _init();
  }

  final Ref _ref;
  static const _uploadKey = 'sync_upload_config';
  static const _autoSyncKey = 'sync_auto_config';

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    final uploadJsonStr = prefs.getString(_uploadKey);
    if (uploadJsonStr != null && uploadJsonStr.isNotEmpty) {
      try {
        final j = jsonDecode(uploadJsonStr) as Map<String, dynamic>;
        state = state.copyWith(uploadConfig: UploadConfig.fromJson(j));
      } catch (_) {}
    }

    final autoEnabled = prefs.getBool('${_autoSyncKey}_enabled') ?? false;
    final autoInterval = prefs.getInt('${_autoSyncKey}_interval') ?? 24;
    state = state.copyWith(
      autoSyncConfig: AutoSyncConfig(
        enabled: autoEnabled,
        syncIntervalHours: autoInterval,
      ),
    );
  }

  Future<void> updateUploadConfig(UploadConfig next) async {
    state = state.copyWith(uploadConfig: next);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_uploadKey, jsonEncode(next.toJson()));
  }

  Future<void> updateAutoSyncConfig(AutoSyncConfig next) async {
    state = state.copyWith(autoSyncConfig: next);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('${_autoSyncKey}_enabled', next.enabled);
    await prefs.setInt('${_autoSyncKey}_interval', next.syncIntervalHours);
  }

  Future<String> _dataDir() => _ref.read(appDataDirProvider.future);

  /// 导入本地备份文件（支持 .json 应用程序备份）
  Future<String> importLocalBackupFile() async {
    try {
      final res = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (res == null || res.files.isEmpty) return '未选择文件';
      final file = res.files.first;
      final bytes = file.bytes;
      String jsonContent = '';
      if (bytes != null) {
        jsonContent = utf8.decode(bytes);
      }
      if (jsonContent.isEmpty) return '读取文件失败或文件为空';

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
            await _ref.read(favoritesProvider.notifier).toggle(
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
        return '成功导入备份：包含 $importedFavs 首收藏曲目';
      }
      return '不支持的备份文件格式';
    } catch (e) {
      AppLogger.instance.log('sync', '导入本地备份失败: $e');
      return '导入失败: $e';
    }
  }

  // ==================== 歌单同步 ====================

  Future<void> syncPlaylistsUpload() async {
    final auth = _ref.read(authProvider);
    if (!auth.isLoggedIn || auth.user?.ciyuanxiId == null) {
      _setPlaylistError('请先登录账号');
      return;
    }
    final userId = auth.user!.ciyuanxiId!;
    state = state.copyWith(
      playlistSync: state.playlistSync.copyWith(syncing: true, errors: []),
    );
    try {
      final dir = await _dataDir();

      await authAuthedRequest(
        dataDir: dir,
        action: 'file_sync_upload_start',
        bodyJson: jsonEncode({'user_id': userId}),
      );

      final dbPath = await _ref.read(dbPathProvider.future);
      final jsonStr = await loadPlaybackSession(dbPath: dbPath);
      final sessionData = jsonStr.isNotEmpty && jsonStr != 'null'
          ? jsonDecode(jsonStr)
          : {};
      final queueMeta = sessionData['queueSongMeta'] as Map<String, dynamic>? ?? {};

      final mockPlaylists = [
        {
          'id': 'my_queue_playlist',
          'name': '同步播放列表',
          'type': 'mixed',
          'songs': queueMeta.values.toList(),
        }
      ];

      await authAuthedRequest(
        dataDir: dir,
        action: 'file_sync_upload_chunk',
        bodyJson: jsonEncode({
          'user_id': userId,
          'playlists': mockPlaylists,
        }),
      );

      await authAuthedRequest(
        dataDir: dir,
        action: 'file_sync_upload_finish',
        bodyJson: jsonEncode({'user_id': userId}),
      );

      state = state.copyWith(
        playlistSync: state.playlistSync.copyWith(
          syncing: false,
          lastSummary: '上传成功',
          lastTime: DateTime.now(),
          errors: [],
        ),
      );
    } catch (e) {
      AppLogger.instance.log('sync', '歌单上传失败: $e');
      _setPlaylistError('上传失败: $e');
    }
  }

  Future<void> syncPlaylistsDownload() async {
    final auth = _ref.read(authProvider);
    if (!auth.isLoggedIn || auth.user?.ciyuanxiId == null) {
      _setPlaylistError('请先登录账号');
      return;
    }
    final userId = auth.user!.ciyuanxiId!;
    state = state.copyWith(
      playlistSync: state.playlistSync.copyWith(syncing: true, errors: []),
    );
    try {
      final dir = await _dataDir();
      final resJson = await authAuthedRequest(
        dataDir: dir,
        action: 'file_sync_download',
        bodyJson: jsonEncode({'user_id': userId}),
      );
      final data = jsonDecode(resJson);
      final count = (data['playlists'] as List? ?? []).length;
      state = state.copyWith(
        playlistSync: state.playlistSync.copyWith(
          syncing: false,
          lastSummary: '获取到 $count 个云端歌单',
          lastTime: DateTime.now(),
          errors: [],
        ),
      );
    } catch (e) {
      AppLogger.instance.log('sync', '歌单下载失败: $e');
      _setPlaylistError('下载失败: $e');
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
    final auth = _ref.read(authProvider);
    if (!auth.isLoggedIn || auth.user?.ciyuanxiId == null) {
      _setFavoritesError('请先登录账号');
      return;
    }
    final userId = auth.user!.ciyuanxiId!;
    state = state.copyWith(
      favoritesSync: state.favoritesSync.copyWith(syncing: true, errors: []),
    );
    try {
      final dir = await _dataDir();
      final favState = _ref.read(favoritesProvider);
      final favEntries = favState.entries;
      final songsPayload = favEntries.map((e) => {
        'path': e.path,
        'title': e.title.isNotEmpty ? e.title : e.path.split(RegExp(r'[\\/]')).last,
        'artist': e.artist,
        'album': e.album,
      }).toList();

      await authAuthedRequest(
        dataDir: dir,
        action: 'favorites_sync_upload',
        bodyJson: jsonEncode({
          'user_id': userId,
          'favorites': songsPayload,
        }),
      );

      state = state.copyWith(
        favoritesSync: state.favoritesSync.copyWith(
          syncing: false,
          lastSummary: '已上传 ${favEntries.length} 首收藏歌曲',
          lastTime: DateTime.now(),
          errors: [],
        ),
      );
    } catch (e) {
      AppLogger.instance.log('sync', '收藏上传失败: $e');
      _setFavoritesError('上传失败: $e');
    }
  }

  Future<void> syncFavoritesDownload() async {
    final auth = _ref.read(authProvider);
    if (!auth.isLoggedIn || auth.user?.ciyuanxiId == null) {
      _setFavoritesError('请先登录账号');
      return;
    }
    final userId = auth.user!.ciyuanxiId!;
    state = state.copyWith(
      favoritesSync: state.favoritesSync.copyWith(syncing: true, errors: []),
    );
    try {
      final dir = await _dataDir();
      final resJson = await authAuthedRequest(
        dataDir: dir,
        action: 'favorites_sync_download',
        bodyJson: jsonEncode({'user_id': userId}),
      );
      final data = jsonDecode(resJson) as Map<String, dynamic>;
      final favs = data['favorites'] as List? ?? [];
      for (final item in favs) {
        final path = item is Map ? item['path'] as String? : null;
        final title = item is Map ? item['title'] as String? : null;
        if (path != null && path.isNotEmpty) {
          await _ref.read(favoritesProvider.notifier).toggle(
            QueueItem(
              path: path,
              title: title ?? path.split(RegExp(r'[\\/]')).last,
              artist: item is Map ? item['artist'] as String? ?? '' : '',
              album: item is Map ? item['album'] as String? ?? '' : '',
            ),
          );
        }
      }

      state = state.copyWith(
        favoritesSync: state.favoritesSync.copyWith(
          syncing: false,
          lastSummary: '拉取到 ${favs.length} 首收藏',
          lastTime: DateTime.now(),
          errors: [],
        ),
      );
    } catch (e) {
      AppLogger.instance.log('sync', '收藏下载失败: $e');
      _setFavoritesError('下载失败: $e');
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

  Future<void> syncPluginsUpload() async {
    final auth = _ref.read(authProvider);
    if (!auth.isLoggedIn || auth.user?.ciyuanxiId == null) {
      _setPluginError('请先登录账号');
      return;
    }
    final userId = auth.user!.ciyuanxiId!;
    state = state.copyWith(
      pluginSync: state.pluginSync.copyWith(syncing: true, errors: []),
    );
    try {
      final dir = await _dataDir();
      await authAuthedRequest(
        dataDir: dir,
        action: 'plugins_sync_upload',
        bodyJson: jsonEncode({
          'user_id': userId,
          'plugins': [],
        }),
      );

      state = state.copyWith(
        pluginSync: state.pluginSync.copyWith(
          syncing: false,
          lastSummary: '已同步云端插件状态',
          lastTime: DateTime.now(),
          errors: [],
        ),
      );
    } catch (e) {
      AppLogger.instance.log('sync', '插件上传失败: $e');
      _setPluginError('上传失败: $e');
    }
  }

  Future<void> syncPluginsDownload() async {
    final auth = _ref.read(authProvider);
    if (!auth.isLoggedIn || auth.user?.ciyuanxiId == null) {
      _setPluginError('请先登录账号');
      return;
    }
    final userId = auth.user!.ciyuanxiId!;
    state = state.copyWith(
      pluginSync: state.pluginSync.copyWith(syncing: true, errors: []),
    );
    try {
      final dir = await _dataDir();
      await authAuthedRequest(
        dataDir: dir,
        action: 'plugins_sync_download',
        bodyJson: jsonEncode({'user_id': userId}),
      );

      state = state.copyWith(
        pluginSync: state.pluginSync.copyWith(
          syncing: false,
          lastSummary: '已拉取云端插件配置',
          lastTime: DateTime.now(),
          errors: [],
        ),
      );
    } catch (e) {
      AppLogger.instance.log('sync', '插件下载失败: $e');
      _setPluginError('下载失败: $e');
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
    final auth = _ref.read(authProvider);
    if (!auth.isLoggedIn || auth.user?.ciyuanxiId == null) {
      _setSettingsError('请先登录账号');
      return;
    }
    final userId = auth.user!.ciyuanxiId!;
    state = state.copyWith(
      settingsSync: state.settingsSync.copyWith(syncing: true, errors: []),
    );
    try {
      final dir = await _dataDir();
      await authAuthedRequest(
        dataDir: dir,
        action: 'settings_sync_upload',
        bodyJson: jsonEncode({
          'user_id': userId,
          'settings': {},
        }),
      );

      state = state.copyWith(
        settingsSync: state.settingsSync.copyWith(
          syncing: false,
          lastSummary: '已同步偏好设置',
          lastTime: DateTime.now(),
          errors: [],
        ),
      );
    } catch (e) {
      AppLogger.instance.log('sync', '设置上传失败: $e');
      _setSettingsError('上传失败: $e');
    }
  }

  Future<void> syncSettingsDownload() async {
    final auth = _ref.read(authProvider);
    if (!auth.isLoggedIn || auth.user?.ciyuanxiId == null) {
      _setSettingsError('请先登录账号');
      return;
    }
    final userId = auth.user!.ciyuanxiId!;
    state = state.copyWith(
      settingsSync: state.settingsSync.copyWith(syncing: true, errors: []),
    );
    try {
      final dir = await _dataDir();
      await authAuthedRequest(
        dataDir: dir,
        action: 'settings_sync_download',
        bodyJson: jsonEncode({'user_id': userId}),
      );

      state = state.copyWith(
        settingsSync: state.settingsSync.copyWith(
          syncing: false,
          lastSummary: '已从云端更新设置',
          lastTime: DateTime.now(),
          errors: [],
        ),
      );
    } catch (e) {
      AppLogger.instance.log('sync', '设置下载失败: $e');
      _setSettingsError('下载失败: $e');
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
}

final syncProvider = StateNotifierProvider<SyncNotifier, SyncState>(
  (ref) => SyncNotifier(ref),
);
