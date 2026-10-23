import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth/account_api.dart';
import '../auth/auth_provider.dart';
import '../cloud/cloud_credentials_store.dart';
import '../cloud/cloud_folder_selection_store.dart';
import '../core/application_logger.dart';
import '../core/db_path.dart';
import '../core/settings.dart';
import '../favorites/favorites_provider.dart';
import '../home/home_providers.dart' show pullListenServerSnapshot;
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
import 'playlist_sync_ops.dart';
import '../recent/recent_provider.dart';
import '../rust/api.dart' as rust;
import 'settings_conflict_dialog.dart';
import '../i18n/i18n.dart';
part 'sync_provider.playlist.dart';
part 'sync_provider.favorites.dart';
part 'sync_provider.plugins.dart';
part 'sync_provider.settings.dart';
part 'sync_provider.history.dart';
part 'sync_provider.cloud.dart';

class UploadConfig {
  final bool playlists;
  final bool favorites;
  final bool plugins;
  final bool settings;
  final bool history;
  final bool cloudCreds;

  const UploadConfig({
    this.playlists = true,
    this.favorites = true,
    this.plugins = true,
    this.settings = true,
    this.history = false,
    this.cloudCreds = true,
  });

  UploadConfig copyWith({
    bool? playlists,
    bool? favorites,
    bool? plugins,
    bool? settings,
    bool? history,
    bool? cloudCreds,
  }) {
    return UploadConfig(
      playlists: playlists ?? this.playlists,
      favorites: favorites ?? this.favorites,
      plugins: plugins ?? this.plugins,
      settings: settings ?? this.settings,
      history: history ?? this.history,
      cloudCreds: cloudCreds ?? this.cloudCreds,
    );
  }

  Map<String, dynamic> toJson() => {
        'playlists': playlists,
        'favorites': favorites,
        'plugins': plugins,
        'settings': settings,
        'history': history,
        'cloudCreds': cloudCreds,
      };

  factory UploadConfig.fromJson(Map<String, dynamic> j) => UploadConfig(
        playlists: j['playlists'] as bool? ?? true,
        favorites: j['favorites'] as bool? ?? true,
        plugins: j['plugins'] as bool? ?? true,
        settings: j['settings'] as bool? ?? true,
        history: false,
        cloudCreds: j['cloudCreds'] as bool? ?? true,
      );
}

class AutoSyncConfig {
  final bool enabled;
  final int syncIntervalSeconds;
  final int maxDelayMinutes;

  const AutoSyncConfig({
    this.enabled = true,
    // 变更驱动的即时同步是主路径，轮询仅兜底（如设置类变更、上传失败重试）
    this.syncIntervalSeconds = 900,
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
  final SyncItemState cloudCredsSync;

  const SyncState({
    this.uploadConfig = const UploadConfig(),
    this.autoSyncConfig = const AutoSyncConfig(),
    this.playlistSync = const SyncItemState(),
    this.favoritesSync = const SyncItemState(),
    this.pluginSync = const SyncItemState(),
    this.settingsSync = const SyncItemState(),
    this.historySync = const SyncItemState(),
    this.cloudCredsSync = const SyncItemState(),
  });

  SyncState copyWith({
    UploadConfig? uploadConfig,
    AutoSyncConfig? autoSyncConfig,
    SyncItemState? playlistSync,
    SyncItemState? favoritesSync,
    SyncItemState? pluginSync,
    SyncItemState? settingsSync,
    SyncItemState? historySync,
    SyncItemState? cloudCredsSync,
  }) {
    return SyncState(
      uploadConfig: uploadConfig ?? this.uploadConfig,
      autoSyncConfig: autoSyncConfig ?? this.autoSyncConfig,
      playlistSync: playlistSync ?? this.playlistSync,
      favoritesSync: favoritesSync ?? this.favoritesSync,
      pluginSync: pluginSync ?? this.pluginSync,
      settingsSync: settingsSync ?? this.settingsSync,
      historySync: historySync ?? this.historySync,
      cloudCredsSync: cloudCredsSync ?? this.cloudCredsSync,
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

/// 当前后台同步来源标签（'登录同步'/'自动同步'），null=空闲；账号页据此区分进度文案
final bgSyncSourceProvider = StateProvider<String?>((_) => null);

class SyncNotifier extends StateNotifier<SyncState> {
  SyncNotifier(this._ref) : super(const SyncState()) {
    _init();
    _ref.listen<bool>(
      authProvider.select((s) => s.user != null),
      (prev, next) {
        if (prev == true && next == false) _resetLoginSyncFlag();
      },
    );
    // 网盘凭据变更（绑定/解绑/轮换）→ 防抖后自动上传
    CloudCredentialsStore.onPersisted = _scheduleCloudCredsUpload;
    // 网盘目录选择变更（勾选/取消勾选/同步合并）→ 随凭据密封串一并上传
    CloudFolderSelectionStore.onPersisted = _scheduleCloudCredsUpload;
  }

  final Ref _ref;
  static const _uploadKey = 'sync_upload_config';
  static const _autoSyncKey = 'sync_auto_config';
  static const _loginSyncKey = 'sync_login_synced';

  bool _loginSyncCompleted = false;
  bool _loginSyncInProgress = false;
  Timer? _cloudCredsUploadTimer;

  /// 凭据落盘触发：防抖 3s 合并短时间内的多次变更（如连续绑定多盘）。
  void _scheduleCloudCredsUpload() {
    if (_loginSyncInProgress) return; // 登录同步流程内会统一上传，避免重复
    _cloudCredsUploadTimer?.cancel();
    _cloudCredsUploadTimer = Timer(const Duration(seconds: 3), () {
      final loggedIn = _ref.read(authProvider.select((s) => s.user != null));
      if (!loggedIn) return;
      if (!state.uploadConfig.cloudCreds) return;
      _cloudCredsSyncSvc.upload();
    });
  }

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

  CloudCredsSyncService get _cloudCredsSyncSvc => CloudCredsSyncService(
      _ref,
      _lens((s) => s.cloudCredsSync, (s, v) => s.copyWith(cloudCredsSync: v)));

  // ---- 对外同步入口（薄委托，公共 API 不变）----
  // overwrite=true 为手动覆盖语义：上传覆盖服务端、下载覆盖本地；
  // 自动同步/登录同步不带该参数，仍走原有对比合并逻辑

  Future<void> syncPlaylistsUpload({bool overwrite = false}) =>
      _playlistSyncSvc.upload(overwrite: overwrite);

  Future<void> syncPlaylistsDownload({bool overwrite = false}) =>
      _playlistSyncSvc.download(overwrite: overwrite);

  Future<void> syncFavoritesUpload({bool overwrite = false}) =>
      _favoritesSyncSvc.upload(overwrite: overwrite);

  Future<void> syncFavoritesDownload({bool overwrite = false}) =>
      _favoritesSyncSvc.download(overwrite: overwrite);

  Future<void> syncPluginsUpload({bool overwrite = false}) =>
      _pluginsSyncSvc.upload(overwrite: overwrite);

  Future<void> syncPluginsDownload({bool overwrite = false}) =>
      _pluginsSyncSvc.download(overwrite: overwrite);

  Future<void> syncSettingsUpload() => _settingsSyncSvc.upload();

  Future<void> syncSettingsDownload() => _settingsSyncSvc.download();

  Future<void> syncSettings(BuildContext context) =>
      _settingsSyncSvc.sync(context);

  Future<void> syncHistoryUpload() => _historySyncSvc.upload();

  Future<void> syncHistoryDownload() => _historySyncSvc.download();

  Future<void> syncCloudCredsUpload() => _cloudCredsSyncSvc.upload();

  Future<void> syncCloudCredsDownload() => _cloudCredsSyncSvc.download();

  Future<void> syncListenStats() async {
    // 快照双向同步已废弃，听歌时长由 delta 增量上报统一维护；此处只做纯
    // 快照拉取（零 delta 不入账），登录同步与自动同步心跳复用同一路径
    await pullListenServerSnapshot(_ref);
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    final uploadJsonStr = prefs.getString(_uploadKey);
    if (uploadJsonStr != null && uploadJsonStr.isNotEmpty) {
      try {
        final j = jsonDecode(uploadJsonStr) as Map<String, dynamic>;
        state = state.copyWith(uploadConfig: UploadConfig.fromJson(j));
      } catch (_) { /* 解析失败按默认值处理 */ }
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
    } catch (e) {
      AppLog.warn('sync', '重置登录同步标记失败: $e');
    }
  }

  Future<void> updateUploadConfig(UploadConfig next) async {
    state = state.copyWith(uploadConfig: next);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_uploadKey, jsonEncode(next.toJson()));
  }

  Future<void> syncOnLoginSuccess(BuildContext context) async {
    if (_loginSyncCompleted || _loginSyncInProgress) return;
    _loginSyncInProgress = true;
    _ref.read(bgSyncSourceProvider.notifier).state = '登录同步';
    final upload = state.uploadConfig;
    try {
      // 各数据域并发执行（域内先后顺序保持原语义：上传/下载依赖不变）。
      // 串行时网盘绑定排在歌单/插件之后才落库，登录后进网盘页看到的是
      // 空绑定，体感像「没同步」。域 service 自带错误兜底（写入各自状
      // 态），外层 catch 仅防未预期异常炸整组——单域失败不影响其余域。
      Future<void> guard(Future<void> Function() run) async {
        try {
          await run();
        } catch (e) {
          AppLog.warn('sync', '登录同步域执行失败: $e');
        }
      }
      await Future.wait([
        if (upload.playlists)
          guard(() async {
            await syncPlaylistsUpload();
            await syncPlaylistsDownload();
          }),
        if (upload.plugins)
          guard(() async {
            await syncPluginsUpload();
            await syncPluginsDownload();
          }),
        if (upload.favorites)
          guard(() async {
            await syncFavoritesDownload();
            await syncFavoritesUpload();
          }),
        if (upload.cloudCreds)
          guard(() async {
            // 先拉后推：把云端绑定合并进本地，再把合并结果推回云端
            await syncCloudCredsDownload();
            await syncCloudCredsUpload();
          }),
        guard(syncListenStats),
      ]);
      // UI 段并发结束后串行：通知弹窗与设置冲突对话框需要独占交互，
      // 且设置同步内部可能联动歌单/插件域，须等对应域空闲后执行。
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
      } catch (e) {
        AppLog.warn('sync', '记录登录同步标记失败: $e');
      }
      _loginSyncInProgress = false;
      _ref.read(bgSyncSourceProvider.notifier).state = null;
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
      AppLog.warn('sync', '导入本地备份失败: $e');
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
