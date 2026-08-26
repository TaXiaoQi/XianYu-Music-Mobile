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
import '../playlist/playlist_provider.dart';
import '../playlist/playlist_store.dart';
import '../player/player_provider.dart' show QueueItem;
import '../plugin/plugin_backup_import.dart';
import '../plugin/plugin_provider.dart';
import '../plugin/plugin_subscriptions.dart';
import '../recent/recent_provider.dart';
import '../rust/api.dart' as rust;
import 'settings_conflict_dialog.dart';

/// 上传选项配置
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
    // 移动端已去除播放历史同步入口（对齐需求），默认不上传历史。
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

/// 自动同步配置（与 auto_sync.dart 的 AutoSyncService 共用同一份，账号页/同步页开关均写入这里）
class AutoSyncConfig {
  final bool enabled;
  final int syncIntervalSeconds;
  final int maxDelayMinutes;

  const AutoSyncConfig({
    // 默认开启，对齐桌面端（否则用户不手动开就永远不自动上传收藏/歌单）
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
  }

  final Ref _ref;
  static const _uploadKey = 'sync_upload_config';
  static const _autoSyncKey = 'sync_auto_config';

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
    state = state.copyWith(
      autoSyncConfig: AutoSyncConfig(
        enabled: autoEnabled,
        syncIntervalSeconds: autoInterval,
        maxDelayMinutes: autoMaxDelay,
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
    await prefs.setInt('${_autoSyncKey}_interval_seconds', next.syncIntervalSeconds);
    await prefs.setInt('${_autoSyncKey}_max_delay', next.maxDelayMinutes);
  }

  Future<String> _dataDir() => _ref.read(appDataDirProvider.future);

  /// 导入本地备份文件（支持 BakaMusic / MusicFree / 洛雪及软件应用备份）
  Future<String> importLocalBackupFile() async {
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json', 'txt'],
      );
      if (files.isEmpty) return '未选择文件';
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
      if (jsonContent.trim().isEmpty) return '读取文件失败或文件为空';

      final Map<String, dynamic> data = jsonDecode(jsonContent);
      final schema = data['schema'] as String?;

      // 1. 如果是原生全量备份格式
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
        return '成功导入备份：包含 $importedFavs 首收藏曲目';
      }

      // 2. 兼容导入 BakaMusic / MusicFree / 洛雪备份文件
      final pluginSources = _ref.read(pluginManagerProvider).sources;
      final prepared = preparePluginBackupImport(jsonContent, pluginSources);
      final importedPlaylists = await _ref
          .read(playlistManagerProvider.notifier)
          .addFromBackup(prepared);

      final versionNote = describeBackupVersion(prepared);
      return '导入成功（$versionNote）：共新增 ${importedPlaylists.length} 个歌单，包含 ${prepared.importedSongCount} 首歌曲';
    } on FormatException catch (e) {
      return '文件格式不匹配或无法解析: ${e.message}';
    } catch (e) {
      AppLogger.instance.log('sync', '导入本地备份失败: $e');
      return '导入失败: $e';
    }
  }

  // ==================== 歌单同步 ====================

  /// 桌面端同步载荷（Song 字段 + duration 毫秒），附移动端扩展字段。
  Map<String, dynamic> _songToSyncPayload(ImportedSong s) => {
        ...s.toJson(),
        'name': s.title,
        'duration': s.duration * 1000,
        // 与桌面端 classifySyncSong 对齐：标记本地/在线，供下载端恢复来源类型。
        'syncType': _classifySyncSong(s),
      };

  /// 与桌面端 classifySyncSong 对齐：按路径前缀判定本地/在线。
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

  /// 取歌单内第一首在线歌曲的远程封面（http/https），无则返回空串。
  String _firstRemoteSongCover(List<ImportedSong> songs) {
    for (final s in songs) {
      final cover = s.coverUrl ?? '';
      if (cover.startsWith('http://') || cover.startsWith('https://')) {
        return cover;
      }
    }
    return '';
  }

  /// 云端同步载荷 → 本地导入歌曲（duration 毫秒 → 秒）。
  ///
  /// 与桌面端 syncPayloadToSong 对齐：
  /// - 在线歌曲（lx:// / plugin:// / http(s):// 路径，或 syncType=online /
  ///   source_type=remote|plugin 标记）localPath 置空，避免被误判为本地歌曲
  ///   导致在线歌曲缺少 onlineSongJson 而无法解析播放。
  /// - 本地歌曲：桌面端载荷只有 `path`（Windows 路径）+ `syncType/source_type=local`，
  ///   没有 `localPath` 字段，需据此识别为本地歌曲；再按元数据匹配本地曲库，
  ///   把跨设备失效路径替换为本地真实路径。
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
    // 只要路径是本地文件路径就尝试匹配本地曲库（兼容旧版云端数据
    // 未带 syncType/source_type/localPath 标记的情况）。
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

  static bool _isLocalFilePath(String path) =>
      path.isNotEmpty &&
      !path.startsWith('lx://') &&
      !path.startsWith('plugin://') &&
      !path.startsWith('http://') &&
      !path.startsWith('https://');

  /// 构建本地曲库匹配索引：按路径精确匹配 + 按「标题|歌手」元数据匹配。
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

  /// 将同步的本地歌曲路径解析到本地曲库：路径已存在则原样返回，
  /// 否则按「标题|歌手」（+时长容差）匹配本地曲库并返回本地歌曲。
  /// 命中后由调用方把本地歌曲的专辑/封面等元数据一并带回，保证
  /// 云端同步下来的本地歌单与本地音乐展示一致。未命中（或非本地
  /// 路径）返回 null，调用方保留云端路径。
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
            lastSummary: '本地暂无可上传的歌单',
            lastTime: DateTime.now(),
          ),
        );
        return;
      }
      final payload = local
          .map((p) => {
                'id': p.id,
                'name': p.name,
                // 移动端歌单无自定义封面，取歌单内第一首在线歌曲封面作为云端封面，
                // 避免覆盖桌面端已上传的 cloudCoverUrl。
                'cloudCoverUrl': _firstRemoteSongCover(p.songs),
                'songs': p.songs.map(_songToSyncPayload).toList(),
              })
          .toList();
      final res = await _api.fileSyncUpload(payload);
      state = state.copyWith(
        playlistSync: state.playlistSync.copyWith(
          syncing: false,
          lastSummary: '已上传 ${res.playlistCount} 个歌单 / ${res.songTotal} 首',
          lastTime: DateTime.now(),
          errors: [],
        ),
      );
    } catch (e) {
      AppLogger.instance.log('sync', '歌单上传失败: $e');
      _setPlaylistError(e is AuthException ? e.message : '上传失败: $e');
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
            lastSummary: '云端暂无歌单数据',
            lastTime: DateTime.now(),
          ),
        );
        return;
      }
      final toImport = <PluginBackupPlaylist>[];
      var songCount = 0;
      // 确保本地曲库已加载，用于把跨设备失效的本地路径匹配回本地曲库。
      final library = _ref.read(libraryProvider);
      if (library.loading) {
        await _ref.read(libraryProvider.notifier).load();
      }
      final index = _buildLibraryIndex();
      for (final pl in cloudPlaylists) {
        final songs = ((pl['songs'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) =>
                _songFromSyncPayload(e.cast<String, dynamic>(), index.byPath, index.byMeta))
            .toList();
        songCount += songs.length;
        toImport.add(PluginBackupPlaylist(
          name: (pl['name'] as String?) ?? '未命名歌单',
          songs: songs,
          originalSongCount: songs.length,
        ));
      }
      await PlaylistStore().addPlaylists(toImport);
      await _ref.read(playlistManagerProvider.notifier).refresh();
      state = state.copyWith(
        playlistSync: state.playlistSync.copyWith(
          syncing: false,
          lastSummary: '已导入 ${toImport.length} 个歌单 / $songCount 首',
          lastTime: DateTime.now(),
          errors: [],
        ),
      );
    } catch (e) {
      AppLogger.instance.log('sync', '歌单下载失败: $e');
      _setPlaylistError(e is AuthException ? e.message : '下载失败: $e');
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
        // 空列表保护：本地收藏为空时跳过上传，避免覆盖云端收藏
        // （换包名/重装后本地为空，若直接上传会把云端收藏清空）。
        state = state.copyWith(
          favoritesSync: state.favoritesSync.copyWith(
            syncing: false,
            lastSummary: '本地收藏为空，跳过上传',
            lastTime: DateTime.now(),
            errors: [],
          ),
        );
        return;
      }
      final payload = favEntries.map((e) {
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
      final count = await _api.uploadFavorites(payload);
      state = state.copyWith(
        favoritesSync: state.favoritesSync.copyWith(
          syncing: false,
          lastSummary: '已上传 $count 首收藏歌曲',
          lastTime: DateTime.now(),
          errors: [],
        ),
      );
    } catch (e) {
      AppLogger.instance.log('sync', '收藏上传失败: $e');
      _setFavoritesError(e is AuthException ? e.message : '上传失败: $e');
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
            lastSummary: '云端暂无收藏数据',
            lastTime: DateTime.now(),
          ),
        );
        return;
      }
      final notifier = _ref.read(favoritesProvider.notifier);
      // 确保本地曲库已加载，用于把跨设备失效的本地路径匹配回本地曲库。
      final library = _ref.read(libraryProvider);
      if (library.loading) {
        await _ref.read(libraryProvider.notifier).load();
      }
      final index = _buildLibraryIndex();
      for (final item in favs) {
        final path = item['path'] as String?;
        if (path == null || path.isEmpty) continue;
        final title = (item['title'] ?? item['name'] ?? path
            .split(RegExp(r'[\\/]'))
            .last) as String;
        final artist = (item['artist'] as String?) ?? '';
        final durationMs = (item['duration'] as num?)?.toInt() ?? 0;
        final matched = _matchLocalLibrarySong(
            index.byPath, index.byMeta, path, title, artist, (durationMs / 1000).round());
        await notifier.add(
          QueueItem(
            path: matched?.path ?? path,
            title: matched?.title ?? title,
            artist: matched?.artist ?? artist,
            album: matched?.album ?? (item['album'] as String?) ?? '',
            durationMs: durationMs,
            coverUrl: item['coverUrl'] as String?,
            coverPath: matched?.coverThumbPath,
            source: item['source'] as String?,
            onlineSongJson: item['onlineSongJson'] as String?,
            onlineQuality: item['onlineQuality'] as String?,
            onlineInfoJson: item['onlineInfoJson'] as String?,
          ),
        );
      }
      state = state.copyWith(
        favoritesSync: state.favoritesSync.copyWith(
          syncing: false,
          lastSummary: '已拉取 ${favs.length} 首收藏',
          lastTime: DateTime.now(),
          errors: [],
        ),
      );
    } catch (e) {
      AppLogger.instance.log('sync', '收藏下载失败: $e');
      _setFavoritesError(e is AuthException ? e.message : '下载失败: $e');
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

  /// 与桌面端 pluginSync.ts 一致的反转 Base64（utf8 → base64 → 字符反转），
  /// 避免 WAF 解码检测到原始 JS 代码。
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
      // 订阅链接列表随插件一起上传（服务端整包替换）
      final subs = _ref
          .read(pluginSubscriptionsProvider)
          .map((s) => s.toJson())
          .toList();
      if (sources.isEmpty) {
        if (subs.isNotEmpty) {
          // 本地无插件但有订阅：用空 plugin 做载体单独上传订阅
          try {
            await _api.uploadPlugin({},
                isFirst: true, subscriptions: subs);
            state = state.copyWith(
              pluginSync: state.pluginSync.copyWith(
                syncing: false,
                lastSummary: '已上传 ${subs.length} 个订阅链接',
                lastTime: DateTime.now(),
              ),
            );
          } catch (e) {
            _setPluginError(e is AuthException ? e.message : '订阅上传失败: $e');
          }
        } else {
          state = state.copyWith(
            pluginSync: state.pluginSync.copyWith(
              syncing: false,
              lastSummary: '本地暂无可上传的插件',
              lastTime: DateTime.now(),
            ),
          );
        }
        return;
      }
      final dir = await _dataDir();
      final errors = <String>[];
      var uploaded = 0;
      for (var i = 0; i < sources.length; i++) {
        final p = sources[i];
        final scriptPath = '$dir/plugins/${p.id}.js';
        try {
          final script = await rust.readPluginFile(path: scriptPath);
          if (script.trim().isEmpty) {
            errors.add('插件 "${p.name}" 脚本读取失败，已跳过');
            continue;
          }
          await _api.uploadPlugin({
            'id': p.id,
            'name': p.name,
            'version': p.version,
            'author': p.author,
            'description': p.description,
            'enabled': p.enabled,
            'sources': p.sources,
            'filePath': scriptPath,
            'script': _encodeRevBase64(script),
            'scriptEncoded': true,
          }, isFirst: i == 0, subscriptions: subs);
          uploaded++;
        } catch (e) {
          AppLogger.instance.log('sync', '插件 ${p.name} 上传失败: $e');
          errors.add('插件 "${p.name}" 上传失败');
        }
      }
      state = state.copyWith(
        pluginSync: state.pluginSync.copyWith(
          syncing: false,
          lastSummary: uploaded > 0
              ? '已上传 $uploaded 个插件${subs.isNotEmpty ? '、${subs.length} 个订阅' : ''}'
              : '没有插件被上传',
          lastTime: DateTime.now(),
          errors: errors,
        ),
      );
    } catch (e) {
      AppLogger.instance.log('sync', '插件上传失败: $e');
      _setPluginError(e is AuthException ? e.message : '上传失败: $e');
    }
  }

  Future<void> syncPluginsDownload() async {
    state = state.copyWith(
      pluginSync: state.pluginSync.copyWith(syncing: true, errors: []),
    );
    try {
      final snapshot = await _api.downloadPluginSnapshot();

      // 云端订阅链接合并进本地（即使云端无插件也要合并）
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
                ? '已同步 $mergedSubs 个订阅链接'
                : '云端暂无插件数据',
            lastTime: DateTime.now(),
          ),
        );
        return;
      }
      final errors = <String>[];
      var installed = 0;
      final pluginManager = _ref.read(pluginManagerProvider.notifier);
      for (final item in items) {
        final cloudName = (item['name'] as String?)?.trim() ?? '';
        final name = cloudName.isNotEmpty ? cloudName : '未知插件';
        var script = (item['script'] as String?) ?? '';
        if (item['scriptEncoded'] == true && script.isNotEmpty) {
          try {
            script = _decodeRevBase64(script);
          } catch (_) {
            errors.add('插件 "$name" 脚本解码失败');
            continue;
          }
        }
        if (script.trim().isEmpty) {
          errors.add('插件 "$name" 脚本为空，已跳过');
          continue;
        }
        try {
          // 恢复走 Dart PluginManager（与上传/插件页/在线播放同一套存储），
          // 自动识别 Lx/MusicFree 格式，避免写进 Rust 侧孤立索引而不可见。
          final version = (item['version'] as String?)?.trim() ?? '';
          final source = await pluginManager.installFromScript(
            script,
            nameOverride: cloudName.isEmpty ? null : cloudName,
            versionOverride: version.isEmpty ? null : version,
          );
          // 云端标记停用的插件同步后保持停用
          if (item['enabled'] == false && source.enabled) {
            await pluginManager.toggleEnabled(source.id);
          }
          installed++;
        } catch (e) {
          AppLogger.instance.log('sync', '插件 $name 恢复失败: $e');
          errors.add('插件 "$name" 恢复失败：$e');
        }
      }
      state = state.copyWith(
        pluginSync: state.pluginSync.copyWith(
          syncing: false,
          lastSummary: installed > 0
              ? '已恢复 $installed 个插件${mergedSubs > 0 ? '、$mergedSubs 个订阅' : ''}'
              : (mergedSubs > 0 ? '已同步 $mergedSubs 个订阅链接' : '没有插件被恢复'),
          lastTime: DateTime.now(),
          errors: errors,
        ),
      );
    } catch (e) {
      AppLogger.instance.log('sync', '插件下载失败: $e');
      _setPluginError(e is AuthException ? e.message : '下载失败: $e');
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
        _setSettingsError('本地设置尚未加载完成');
        return;
      }
      await _api.uploadSettings(settings);
      state = state.copyWith(
        settingsSync: state.settingsSync.copyWith(
          syncing: false,
          lastSummary: '已上传偏好设置',
          lastTime: DateTime.now(),
          errors: [],
        ),
      );
    } catch (e) {
      AppLogger.instance.log('sync', '设置上传失败: $e');
      _setSettingsError(e is AuthException ? e.message : '上传失败: $e');
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
            lastSummary: '云端暂无设置',
            lastTime: DateTime.now(),
          ),
        );
        return;
      }
      final local = _ref.read(settingsProvider).valueOrNull;
      if (local == null) {
        _setSettingsError('本地设置尚未加载完成');
        return;
      }
      final merged = applySyncedSettings(local, cloud);
      await _ref.read(settingsProvider.notifier).saveAll(merged);
      state = state.copyWith(
        settingsSync: state.settingsSync.copyWith(
          syncing: false,
          lastSummary: '已应用云端设置',
          lastTime: DateTime.now(),
          errors: [],
        ),
      );
    } catch (e) {
      AppLogger.instance.log('sync', '设置下载失败: $e');
      _setSettingsError(e is AuthException ? e.message : '下载失败: $e');
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

  /// 双向同步设置：先下载云端设置比较，不一致时弹冲突弹窗按类别选择。
  ///
  /// 与桌面端 syncSettings 对齐：云端无数据则上传本地（首次同步）；一致则跳过；
  /// 不一致则弹出「设置同步冲突」弹窗，让用户按类别（设置/歌单/插件）选择
  /// 保留本地或云端。自动同步走 auto_sync 的静默合并，不弹窗。
  Future<void> syncSettings(BuildContext context) async {
    state = state.copyWith(
      settingsSync: state.settingsSync.copyWith(syncing: true, errors: []),
    );
    try {
      final local = _ref.read(settingsProvider).valueOrNull;
      if (local == null) {
        _setSettingsError('本地设置尚未加载完成');
        return;
      }
      final meta = await _api.downloadSettingsWithMeta();
      final cloud = meta.settings;
      final cloudTime = meta.uploadedAt;
      final upload = _ref.read(syncProvider).uploadConfig;

      // 云端无数据：直接上传本地设置（首次同步）
      if (cloud == null || cloud.isEmpty) {
        if (upload.settings) {
          await _api.uploadSettings(local);
          state = state.copyWith(
            settingsSync: state.settingsSync.copyWith(
              syncing: false,
              lastSummary: '已上传偏好设置',
              lastTime: DateTime.now(),
              errors: [],
            ),
          );
        } else {
          state = state.copyWith(
            settingsSync: state.settingsSync.copyWith(
              syncing: false,
              lastSummary: '云端暂无设置',
              lastTime: DateTime.now(),
              errors: [],
            ),
          );
        }
        return;
      }

      // 本地与云端一致：跳过
      if (areSettingsEqual(local, cloud)) {
        state = state.copyWith(
          settingsSync: state.settingsSync.copyWith(
            syncing: false,
            lastSummary: '本地与云端设置一致，无需同步',
            lastTime: DateTime.now(),
            errors: [],
          ),
        );
        return;
      }

      // 不一致：弹冲突弹窗，用户按类别选择保留本地或云端
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
            lastSummary: '已取消设置同步',
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
            errors.add('设置上传失败: $e');
          }
        }
      } else {
        try {
          final merged = applySyncedSettings(local, cloud);
          await _ref.read(settingsProvider.notifier).saveAll(merged);
        } catch (e) {
          errors.add('设置下载失败: $e');
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
          lastSummary: errors.isEmpty ? '同步完成' : '同步完成（${errors.length} 个错误）',
          lastTime: DateTime.now(),
          errors: errors,
        ),
      );
    } catch (e) {
      AppLogger.instance.log('sync', '设置同步失败: $e');
      _setSettingsError(e is AuthException ? e.message : '同步失败: $e');
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
            lastSummary: '本地暂无播放历史',
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
          lastSummary: '已上传 $count 条播放记录',
          lastTime: DateTime.now(),
          errors: [],
        ),
      );
    } catch (e) {
      AppLogger.instance.log('sync', '播放历史上传失败: $e');
      _setHistoryError(e is AuthException ? e.message : '上传失败: $e');
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
            lastSummary: '云端暂无播放历史',
            lastTime: DateTime.now(),
          ),
        );
        return;
      }
      // 云端按时间倒序，写回本地最近播放历史。
      final dbPath = await _ref.read(dbPathProvider.future);
      var added = 0;
      for (final item in history) {
        final path = (item['songPath'] as String?)?.trim() ?? '';
        if (path.isEmpty) continue;
        await rust.statsAddToHistory(dbPath: dbPath, songPath: path);
        added++;
      }
      // 刷新最近播放列表，使新写入的历史立即可见。
      await _ref.read(recentProvider.notifier).refresh();
      state = state.copyWith(
        historySync: state.historySync.copyWith(
          syncing: false,
          lastSummary: '已恢复 $added 条播放历史',
          lastTime: DateTime.now(),
          errors: [],
        ),
      );
    } catch (e) {
      AppLogger.instance.log('sync', '播放历史下载失败: $e');
      _setHistoryError(e is AuthException ? e.message : '下载失败: $e');
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
}

final syncProvider = StateNotifierProvider<SyncNotifier, SyncState>(
  (ref) => SyncNotifier(ref),
);
