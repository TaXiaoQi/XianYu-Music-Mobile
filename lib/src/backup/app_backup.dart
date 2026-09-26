import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';
import '../favorites/favorites_provider.dart';
import '../plugin/plugin_backup_import.dart';
import '../plugin/plugin_models.dart';
import '../plugin/plugin_provider.dart';
import '../plugin/plugin_sync_crypto.dart';
import '../plugin/plugin_user_vars.dart';
import '../playlist/playlist_provider.dart';
import '../playlist/playlist_store.dart';
import '../i18n/i18n.dart';
import '../core/db_path.dart';
import '../online/online_meta_store.dart';
import '../player/player_provider.dart';
import '../recent/recent_provider.dart';
import '../rust/api.dart';

const _kBackupSchema = 'xianyu-music.app-backup';
const _kBackupVersion = 2;

/// 三端名称（settings 分槽 / platform 标记用）。
const kBackupPlatformMobile = 'mobile';
const kBackupPlatformDesktop = 'desktop';
const kBackupPlatformWatch = 'watch';

/// 本端写入 / 读取的 settings 槽位键。
const kBackupSelfSettingKey = kBackupPlatformMobile;

/// 加密备份需要密码时抛出
class BackupPasswordRequiredException implements Exception {}

class AppBackupSummary {
  final int playlistCount;
  final int totalSongs;
  final int onlineSongs;
  final int favoriteCount;
  final int favoriteCollectionCount;
  final int pluginCount;
  final bool hasSettings;
  final String createdAt;

  const AppBackupSummary({
    this.playlistCount = 0,
    this.totalSongs = 0,
    this.onlineSongs = 0,
    this.favoriteCount = 0,
    this.favoriteCollectionCount = 0,
    this.pluginCount = 0,
    this.hasSettings = false,
    this.createdAt = '',
  });
}

class AppBackupImportResult {
  final AppBackupSummary summary;
  final int importedPlaylists;
  final int importedFavorites;
  final int importedPlugins;
  final int skippedPlugins;
  final bool settingsApplied;
  final List<String> errors;

  const AppBackupImportResult({
    required this.summary,
    this.importedPlaylists = 0,
    this.importedFavorites = 0,
    this.importedPlugins = 0,
    this.skippedPlugins = 0,
    this.settingsApplied = false,
    this.errors = const [],
  });
}

class AppBackupService {
  final Ref _ref;

  AppBackupService(this._ref);

  // ==================== 导出 ====================

  Future<String> exportJson({
    bool includePlaylists = true,
    bool includeFavorites = true,
    bool includePlugins = true,
    bool includeSettings = true,
    bool includeRecent = true,
  }) async {
    final playlists = includePlaylists
        ? (await PlaylistStore().loadAll()).map((p) => p.toJson()).toList()
        : null;

    final favorites = <Map<String, dynamic>>[];
    final collections = <Map<String, dynamic>>[];
    if (includeFavorites) {
      favorites.addAll(
          (await FavoritesStore().loadAll()).map((e) => e.toJson()));
      collections.addAll((await FavoritesCollectionStore().loadAll())
          .map((c) => c.toJson()));
    }

    final plugins = <Map<String, dynamic>>[];
    if (includePlugins) {
      final engine = await _ref.read(pluginEngineProvider.future);
      final sources = await engine.store.loadSources();
      for (final source in sources) {
        if (source.isBuiltin) continue;
        final script = await engine.store.readScript(source.id);
        if (script == null || script.isEmpty) continue;
        plugins.add({'source': source.toJson(), 'script': script});
      }
    }

    final recent = includeRecent
        ? await _collectRecentForExport()
        : null;

    final settings = includeSettings
        ? _ref.read(settingsProvider).valueOrNull
        : null;

    final backup = {
      'schema': _kBackupSchema,
      'version': _kBackupVersion,
      'createdAt': DateTime.now().toIso8601String(),
      'platform': kBackupPlatformMobile,
      'data': {
        'playlists': ?playlists,
        if (includeFavorites) ...{
          'favorites': favorites,
          'favoriteCollections': collections,
        },
        if (includePlugins) 'plugins': plugins,
        if (includeRecent) 'recentHistory': recent,
        // 设置按端分槽：本端只写自己的槽位，其余端留空位，导入互不影响。
        'settings': {
          kBackupPlatformMobile:
              includeSettings && settings != null ? _settingsToJson(settings) : null,
          kBackupPlatformDesktop: null,
          kBackupPlatformWatch: null,
        },
      },
    };
    return const JsonEncoder.withIndent('  ').convert(backup);
  }

  /// 最近播放：读 stats db 的 recent history，逐条补全歌曲元数据（本地/在线
  /// 各取对应来源），生成与其他端统一的 [{path, playedAt, song}] 结构。
  Future<List<Map<String, dynamic>>> _collectRecentForExport() async {
    final out = <Map<String, dynamic>>[];
    try {
      final dbPath = await _ref.read(dbPathProvider.future);
      final list = await statsGetRecentHistory(dbPath: dbPath, limit: BigInt.from(200));
      final rows = (jsonDecode(list) as List)
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
      final paths = rows
          .map((e) => e['songPath'] as String? ?? '')
          .where((p) => p.isNotEmpty)
          .toList();
      final localPaths = paths.where((p) => !_isOnlinePath(p)).toList();
      final songMap = <String, Map<String, dynamic>>{};
      if (localPaths.isNotEmpty) {
        try {
          final songsJson =
              await getLibrarySongsByPaths(dbPath: dbPath, paths: localPaths);
          for (final e in jsonDecode(songsJson) as List) {
            final m = (e as Map).cast<String, dynamic>();
            // 库查询结果已是歌曲字段（path/title/artist... 等），直接用。
            songMap[m['path'] as String? ?? ''] = m;
          }
        } catch (_) {}
      }
      final onlineMeta = await _ref.read(onlineMetaStoreProvider)
          .getAll(paths.where(_isOnlinePath).toList());
      for (final row in rows) {
        final path = row['songPath'] as String? ?? '';
        if (path.isEmpty) continue;
        final playedAt = (row['playedAt'] as num?)?.toInt() ?? 0;
        final song = _isOnlinePath(path)
            ? _queueItemToSongMap(onlineMeta[path])
            : (songMap[path] ?? {});
        out.add({
          'path': path,
          'playedAt': playedAt,
          'song': song,
        });
      }
    } catch (_) {}
    return out;
  }

  bool _isOnlinePath(String p) =>
      p.startsWith('lx://') || p.startsWith('plugin://');

  /// 在线歌曲 QueueItem → 统一歌曲 dict（供最近播放导出）。
  Map<String, dynamic> _queueItemToSongMap(QueueItem? q) {
    if (q == null) return const {};
    return {
      'path': q.path,
      'title': q.title,
      'artist': q.artist,
      'album': q.album,
      'duration': (q.durationMs / 1000).round(),
      'coverUrl': q.coverUrl,
      'pluginId': q.source,
      'musicInfo': q.onlineSongJson,
    };
  }

  Map<String, dynamic> _settingsToJson(AppSettings s) => {
        'volume': s.volume,
        'playMode': s.playMode,
        'lastTab': s.lastTab,
        'keepScreenOn': s.keepScreenOn,
        'themeMode': s.themeMode.index,
        'accentColor': s.accentColor,
        'showQualityBadges': s.showQualityBadges,
        'onlineDefaultQuality': s.onlineDefaultQuality,
        'libraryMinDurationSeconds': s.libraryMinDurationSeconds,
        'showLyricsTranslation': s.showLyricsTranslation,
        'enableWordEffect': s.enableWordEffect,
        'downloadPath': s.downloadPath,
        'downloadQuality': s.downloadQuality,
        'downloadLyrics': s.downloadLyrics,
        'organizeRule': s.organizeRule,
        'lyricFontSize': s.lyricFontSize,
        'lyricOffsetMs': s.lyricOffsetMs,
        'liquidGlass': s.liquidGlass,
        'playerLiquidGlass': s.playerLiquidGlass,
        'scanFormats': s.scanFormats,
        'floatingNavBar': s.floatingNavBar,
        'navBarPosition': s.navBarPosition.name,
        'sideBarExpandDirection': s.sideBarExpandDirection.name,
        'usbExclusiveOutput': s.usbExclusiveOutput,
        'autoResumeAfterInterruption': s.autoResumeAfterInterruption,
      };

  // ==================== 解析 ====================

  Map<String, dynamic> parse(String content, {String? password}) {
    final dynamic data;
    try {
      data = jsonDecode(content);
    } catch (_) {
      throw   FormatException(tr('文件不是有效的 JSON 格式'));
    }
    if (data is! Map || data['schema'] != _kBackupSchema) {
      throw   FormatException(tr('无法识别的备份格式，请选择本应用导出的备份文件'));
    }
    if (data['encrypted'] == true) {
      // 加密备份：用密码解密内部 JSON 后重新解析
      if (password == null || password.isEmpty) {
        throw BackupPasswordRequiredException();
      }
      final decrypted = PluginUserVarCrypto.decryptString(
          password, data.cast<String, dynamic>());
      if (decrypted == null) {
        throw   FormatException(tr('解密失败：密码错误或备份已损坏'));
      }
      return parse(decrypted);
    }
    final inner = data['data'];
    if (inner is! Map) {
      throw   FormatException(tr('备份文件数据结构无效'));
    }
    return data.cast<String, dynamic>();
  }

  AppBackupSummary summarize(Map<String, dynamic> backup) {
    final data = (backup['data'] as Map).cast<String, dynamic>();
    final playlists = (data['playlists'] as List? ?? []);
    final favorites = (data['favorites'] as List? ?? []);
    final collections = (data['favoriteCollections'] as List? ?? []);
    final plugins = (data['plugins'] as List? ?? []);

    var totalSongs = 0;
    for (final pl in playlists) {
      if (pl is Map) totalSongs += (pl['songs'] as List? ?? []).length;
    }
    return AppBackupSummary(
      playlistCount: playlists.length,
      totalSongs: totalSongs,
      favoriteCount: favorites.length,
      favoriteCollectionCount: collections.length,
      pluginCount: plugins.length,
      hasSettings: data['settings'] is Map && _selfSettings(data) != null,
      createdAt: backup['createdAt'] as String? ?? '',
    );
  }

  /// 取出写给「本端」的 settings 槽位。v2 起按端分槽；旧 v1 备份的 settings
  /// 是扁平对象（无端概念），视为旧结构、不导入设置（提示可见但跳过写入）。
  Map<String, dynamic>? _selfSettings(Map<String, dynamic> data) {
    final settings = data['settings'];
    if (settings is Map) {
      final slot = settings[kBackupSelfSettingKey];
      if (slot is Map) return slot.cast<String, dynamic>();
      return null;
    }
    return null;
  }

  // ==================== 导入 ====================

  Future<AppBackupImportResult> import(
    Map<String, dynamic> backup, {
    bool includePlaylists = true,
    bool includeFavorites = true,
    bool includePlugins = true,
    bool includeSettings = true,
    bool includeRecent = true,
  }) async {
    final summary = summarize(backup);
    final data = (backup['data'] as Map).cast<String, dynamic>();
    final errors = <String>[];
    var importedPlaylists = 0;
    var importedFavorites = 0;
    var importedPlugins = 0;
    var skippedPlugins = 0;
    var settingsApplied = false;

    if (includePlugins) {
      final manager = _ref.read(pluginManagerProvider.notifier);
      final existing = manager.sources.map((s) => s.id).toSet();
      for (final raw in (data['plugins'] as List? ?? [])) {
        if (raw is! Map) continue;
        final entry = raw.cast<String, dynamic>();
        final script = entry['script'] as String? ?? '';
        final sourceRaw = entry['source'];
        if (script.trim().isEmpty || sourceRaw is! Map) continue;
        final source = PluginSource.fromJson(sourceRaw.cast<String, dynamic>());
        if (existing.contains(source.id)) {
          skippedPlugins++;
          continue;
        }
        try {
          await manager.installFromScript(
            script,
            nameOverride: source.name.isNotEmpty ? source.name : null,
            versionOverride: source.version.isNotEmpty ? source.version : null,
          );
          // 恢复备份中的用户变量值（跨端迁移卡密等配置）
          final userVarsRaw = entry['userVariables'];
          if (userVarsRaw is Map && userVarsRaw.isNotEmpty) {
            final values = userVarsRaw
                .map((k, v) => MapEntry(k.toString(), v?.toString() ?? ''));
            await _ref
                .read(pluginUserVarValuesProvider.notifier)
                .save(source.id, values);
            await manager.syncBilibiliCookiesFromVars(source.id, values);
          }
          importedPlugins++;
        } catch (e) {
          errors.add(tr('插件「{name}」导入失败：{e}',
              {'name': source.name, 'e': e}));
          skippedPlugins++;
        }
      }
    }

    if (includePlaylists) {
      final store = PlaylistStore();
      final entries = <PluginBackupPlaylist>[];
      for (final raw in (data['playlists'] as List? ?? [])) {
        if (raw is! Map) continue;
        final pl = raw.cast<String, dynamic>();
        final name = pl['name'] as String? ?? '';
        final songs = _parseSongs(pl['songs']);
        if (name.isEmpty || songs.isEmpty) continue;
        entries.add(PluginBackupPlaylist(
          name: name,
          songs: songs,
          originalSongCount: songs.length,
          sourcePluginId: pl['sourcePluginId'] as String?,
          sourceUrl: pl['sourceUrl'] as String?,
          sourceRaw: pl['sourceRaw'] is Map
              ? (pl['sourceRaw'] as Map).cast<String, dynamic>()
              : null,
        ));
      }
      if (entries.isNotEmpty) {
        await store.addPlaylists(entries);
        await _ref.read(playlistManagerProvider.notifier).refresh();
        importedPlaylists = entries.length;
      }
    }

    if (includeFavorites) {
      final store = FavoritesStore();
      final existing = await store.loadAll();
      final known = existing.map((e) => e.path).toSet();
      final incoming = <FavoriteEntry>[];
      for (final raw in (data['favorites'] as List? ?? [])) {
        if (raw is! Map) continue;
        final entry = _parseFavorite(raw.cast<String, dynamic>());
        if (entry == null || known.contains(entry.path)) continue;
        incoming.add(entry);
        known.add(entry.path);
      }
      if (incoming.isNotEmpty) {
        await store.saveAll([...incoming, ...existing]);
        importedFavorites = incoming.length;
      }

      final collectionStore = FavoritesCollectionStore();
      final existingCollections = await collectionStore.loadAll();
      final knownKeys = existingCollections.map((c) => c.key).toSet();
      final incomingCollections = <FavoriteCollection>[];
      for (final raw in (data['favoriteCollections'] as List? ?? [])) {
        if (raw is! Map) continue;
        final item = FavoriteCollection.fromJson(raw.cast<String, dynamic>());
        if (item.key.isEmpty || knownKeys.contains(item.key)) continue;
        incomingCollections.add(item);
        knownKeys.add(item.key);
      }
      if (incomingCollections.isNotEmpty) {
        await collectionStore.saveAll(
            [...incomingCollections, ...existingCollections]);
      }
      await _ref.read(favoritesProvider.notifier).refresh();
    }

    if (includeSettings) {
      final selfSettings = _selfSettings(data);
      if (selfSettings != null) {
        try {
          final current = _ref.read(settingsProvider).valueOrNull;
          if (current != null) {
            final restored =
                _settingsFromJson(current, selfSettings);
            await _ref.read(settingsProvider.notifier).saveAll(restored);
            settingsApplied = true;
          }
        } catch (e) {
          errors.add(tr('设置导入失败：{e}', {'e': e}));
        }
      }
    }

    if (includeRecent) {
      await _importRecent(data['recentHistory']);
    }

    return AppBackupImportResult(
      summary: summary,
      importedPlaylists: importedPlaylists,
      importedFavorites: importedFavorites,
      importedPlugins: importedPlugins,
      skippedPlugins: skippedPlugins,
      settingsApplied: settingsApplied,
      errors: errors,
    );
  }

  /// 最近播放：读 [{path, playedAt}]，与现有历史按 path 合并（保留较新时间戳），
  /// 再整体重写。stats 端 add_to_history 以「当前时刻」落时间戳，故按 playedAt
  /// 降序重插可保持相对先后（最近优先）。
  Future<void> _importRecent(dynamic raw) async {
    final list = raw is List ? raw.whereType<Map>().toList() : const <Map>[];
    if (list.isEmpty) return;
    try {
      final dbPath = await _ref.read(dbPathProvider.future);
      final existingJson =
          await statsGetRecentHistory(dbPath: dbPath, limit: BigInt.from(5000));
      final merged = <String, int>{};
      for (final e in (jsonDecode(existingJson) as List).cast<Map>()) {
        final p = e['songPath'] as String? ?? '';
        if (p.isNotEmpty) merged[p] = (e['playedAt'] as num?)?.toInt() ?? 0;
      }
      for (final e in list) {
        final p = (e['path'] as String? ?? e['songPath'] as String? ?? '');
        final t = (e['playedAt'] as num?)?.toInt() ?? 0;
        if (p.isEmpty) continue;
        final prev = merged[p] ?? 0;
        merged[p] = t > prev ? t : prev;
      }
      final ordered = merged.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      await statsRemoveFromRecentHistory(
          dbPath: dbPath, songPaths: ordered.map((e) => e.key).toList());
      for (final entry in ordered) {
        await statsAddToHistory(dbPath: dbPath, songPath: entry.key);
      }
      await _ref.read(recentProvider.notifier).refresh();
    } catch (_) {}
  }

  AppSettings _settingsFromJson(AppSettings fallback, Map<String, dynamic> j) {
    int? asInt(String k) => j[k] is num ? (j[k] as num).toInt() : null;
    bool? asBool(String k) => j[k] is bool ? j[k] as bool : null;
    String? asStr(String k) => j[k] is String ? j[k] as String : null;
    return fallback.copyWith(
      volume: j['volume'] is num ? (j['volume'] as num).toDouble() : null,
      playMode: asInt('playMode'),
      keepScreenOn: asBool('keepScreenOn'),
      themeMode: asInt('themeMode') == null
          ? null
          : ThemeModePreference.values[asInt('themeMode')!.clamp(0, 2)],
      accentColor: asInt('accentColor'),
      showQualityBadges: asBool('showQualityBadges'),
      onlineDefaultQuality: asStr('onlineDefaultQuality'),
      libraryMinDurationSeconds: asInt('libraryMinDurationSeconds'),
      showLyricsTranslation: asBool('showLyricsTranslation'),
      enableWordEffect: asBool('enableWordEffect'),
      downloadPath: asStr('downloadPath'),
      downloadQuality: asStr('downloadQuality'),
      downloadLyrics: asBool('downloadLyrics'),
      organizeRule: asStr('organizeRule'),
      lyricFontSize: asInt('lyricFontSize'),
      lyricOffsetMs: asInt('lyricOffsetMs'),
      liquidGlass: asBool('liquidGlass'),
      playerLiquidGlass: asBool('playerLiquidGlass'),
      scanFormats: j['scanFormats'] is List
          ? (j['scanFormats'] as List).cast<String>()
          : null,
      floatingNavBar: asBool('floatingNavBar'),
      navBarPosition: asStr('navBarPosition') == 'side'
          ? NavBarPosition.side
          : asStr('navBarPosition') == 'bottom'
              ? NavBarPosition.bottom
              : null,
      sideBarExpandDirection: asStr('sideBarExpandDirection') == 'up'
          ? SideBarExpandDirection.up
          : asStr('sideBarExpandDirection') == 'down'
              ? SideBarExpandDirection.down
              : null,
      usbExclusiveOutput: asBool('usbExclusiveOutput'),
      autoResumeAfterInterruption: asBool('autoResumeAfterInterruption'),
    );
  }

  // ==================== 兼容解析 ====================

  List<ImportedSong> _parseSongs(dynamic raw) {
    if (raw is! List) return const [];
    return raw
        .map((e) => e is Map ? ImportedSong.fromJson(_normalizeSong(e.cast<String, dynamic>())) : null)
        .whereType<ImportedSong>()
        .where((s) => s.path.isNotEmpty)
        .toList();
  }

  Map<String, dynamic> _normalizeSong(Map<String, dynamic> j) {
    if (j.containsKey('localPath') || j.containsKey('musicInfo')) return j;
    final path = j['path'] as String? ?? '';
    final isOnline = path.startsWith('plugin://') || path.startsWith('lx://') || path.startsWith('http');
    return {
      'title': (j['title'] ?? j['name']) as String? ?? '',
      'artist': j['artist'] as String? ?? '',
      'album': j['album'] as String? ?? '',
      'duration': ((j['duration'] as num?)?.toDouble() ?? 0).round(),
      'coverUrl': (j['coverUrl'] ?? j['cover_thumb_path']) as String?,
      'localPath': isOnline ? null : path,
      'pluginId': (j['pluginId'] ?? j['plugin_id'] ?? j['remote_source_id']) as String?,
      'source': (j['source'] ?? j['source_type']) as String?,
      'format': j['format'] as String?,
      'musicInfo': j['musicInfo'] is Map
          ? j['musicInfo']
          : (j['rawData'] is Map ? j['rawData'] : null),
      'path': path,
    };
  }

  FavoriteEntry? _parseFavorite(Map<String, dynamic> j) {
    if (j.containsKey('onlineSongJson') || j.containsKey('addedAt')) {
      final entry = FavoriteEntry.fromJson(j);
      return entry.path.isEmpty ? null : entry;
    }
    final normalized = _normalizeSong(j);
    final path = normalized['path'] as String? ?? '';
    if (path.isEmpty) return null;
    final online = normalized['musicInfo'] is Map && normalized['localPath'] == null;
    return FavoriteEntry(
      path: path,
      title: normalized['title'] as String? ?? '',
      artist: normalized['artist'] as String? ?? '',
      album: normalized['album'] as String? ?? '',
      durationMs: ((normalized['duration'] as num?)?.toInt() ?? 0) * 1000,
      onlineSongJson: online ? jsonEncode(normalized['musicInfo']) : null,
      addedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }
}

String backupFileName() {
  final now = DateTime.now();
  final m = now.month.toString().padLeft(2, '0');
  final d = now.day.toString().padLeft(2, '0');
  return 'xianyu-backup-${now.year}-$m-$d.json';
}

Future<String> writeBackupFile(String dirPath, String json) async {
  final dir = Directory(dirPath);
  if (!dir.existsSync()) dir.createSync(recursive: true);
  final stamp = DateTime.now();
  final name = 'xianyu-backup-'
      '${stamp.year}${stamp.month.toString().padLeft(2, '0')}${stamp.day.toString().padLeft(2, '0')}-'
      '${stamp.hour}${stamp.minute.toString().padLeft(2, '0')}.json';
  final file = File('${dir.path}${Platform.pathSeparator}$name');
  await file.writeAsString(json, flush: true);
  return file.path;
}

final appBackupProvider = Provider<AppBackupService>((ref) => AppBackupService(ref));
