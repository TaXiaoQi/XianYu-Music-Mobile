import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth/account_api.dart';
import '../auth/auth_provider.dart';
import '../core/app_logger.dart';
import '../core/db_path.dart';
import '../core/settings.dart';
import '../favorites/favorites_provider.dart';
import '../playlist/playlist_provider.dart';
import '../playlist/playlist_store.dart';
import '../player/player_provider.dart' show QueueItem;
import '../plugin/plugin_backup_import.dart';
import '../plugins/plugin_provider.dart';
import '../rust/api.dart' as rust;

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
      return '不支持的备份文件格式';
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
      };

  /// 云端同步载荷 → 本地导入歌曲（duration 毫秒 → 秒）。
  ImportedSong _songFromSyncPayload(Map<String, dynamic> j) =>
      ImportedSong.fromJson({
        'title': j['title'] ?? j['name'] ?? '',
        'artist': j['artist'],
        'album': j['album'],
        'duration': (((j['duration'] as num?) ?? 0) / 1000).round(),
        'coverUrl': j['coverUrl'],
        'localPath': j['localPath'],
        'pluginId': j['pluginId'],
        'source': j['source'],
        'format': j['format'],
        'musicInfo': j['musicInfo'],
        'path': j['path'] ?? '',
      });

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
      for (final pl in cloudPlaylists) {
        final songs = ((pl['songs'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => _songFromSyncPayload(e.cast<String, dynamic>()))
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
      for (final item in favs) {
        final path = item['path'] as String?;
        if (path == null || path.isEmpty) continue;
        await notifier.add(
          QueueItem(
            path: path,
            title: (item['title'] ?? item['name'] ?? path
                .split(RegExp(r'[\\/]'))
                .last) as String,
            artist: (item['artist'] as String?) ?? '',
            album: (item['album'] as String?) ?? '',
            durationMs: (item['duration'] as num?)?.toInt() ?? 0,
            coverUrl: item['coverUrl'] as String?,
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
      var plugins = _ref.read(pluginProvider).plugins;
      if (plugins.isEmpty) {
        await _ref.read(pluginProvider.notifier).load();
        plugins = _ref.read(pluginProvider).plugins;
      }
      if (plugins.isEmpty) {
        state = state.copyWith(
          pluginSync: state.pluginSync.copyWith(
            syncing: false,
            lastSummary: '本地暂无可上传的插件',
            lastTime: DateTime.now(),
          ),
        );
        return;
      }
      final dir = await _dataDir();
      final errors = <String>[];
      var uploaded = 0;
      for (var i = 0; i < plugins.length; i++) {
        final p = plugins[i];
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
            'qualitys': p.qualitys,
            'filePath': scriptPath,
            'script': _encodeRevBase64(script),
            'scriptEncoded': true,
          }, isFirst: i == 0);
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
              ? '已上传 $uploaded 个插件'
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
      final items = await _api.downloadPlugins();
      if (items.isEmpty) {
        state = state.copyWith(
          pluginSync: state.pluginSync.copyWith(
            syncing: false,
            lastSummary: '云端暂无插件数据',
            lastTime: DateTime.now(),
          ),
        );
        return;
      }
      final dir = await _dataDir();
      final errors = <String>[];
      var installed = 0;
      for (final item in items) {
        final name = (item['name'] as String?) ?? '未知插件';
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
          await rust.pluginInstallScript(
            dataDir: dir,
            script: script,
            origin: 'cloud_sync',
          );
          final id = item['id'] as String?;
          if (item['enabled'] == false && id != null && id.isNotEmpty) {
            await rust.pluginSetEnabled(dataDir: dir, id: id, enabled: false);
          }
          installed++;
        } catch (e) {
          AppLogger.instance.log('sync', '插件 $name 恢复失败: $e');
          errors.add('插件 "$name" 恢复失败');
        }
      }
      await _ref.read(pluginProvider.notifier).load();
      state = state.copyWith(
        pluginSync: state.pluginSync.copyWith(
          syncing: false,
          lastSummary: installed > 0 ? '已恢复 $installed 个插件' : '没有插件被恢复',
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
}

final syncProvider = StateNotifierProvider<SyncNotifier, SyncState>(
  (ref) => SyncNotifier(ref),
);
