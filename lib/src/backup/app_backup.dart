import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';
import '../favorites/favorites_provider.dart';
import '../plugin/plugin_backup_import.dart';
import '../plugin/plugin_models.dart';
import '../plugin/plugin_provider.dart';
import '../playlist/playlist_provider.dart';
import '../playlist/playlist_store.dart';

const _kBackupSchema = 'xianyu-music.app-backup';
const _kBackupVersion = 1;

/// 备份摘要（导出预览与导入确认共用）。
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

/// 导入结果。
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

/// 应用备份导出/导入（对齐桌面端 appBackup.ts；歌单/收藏/插件/设置 → JSON）。
class AppBackupService {
  final Ref _ref;

  AppBackupService(this._ref);

  // ==================== 导出 ====================

  /// 生成完整备份 JSON 字符串。
  Future<String> exportJson() async {
    final playlistStore = PlaylistStore();
    final playlists = await playlistStore.loadAll();

    final favoritesStore = FavoritesStore();
    final favorites = await favoritesStore.loadAll();
    final collectionStore = FavoritesCollectionStore();
    final collections = await collectionStore.loadAll();

    final engine = await _ref.read(pluginEngineProvider.future);
    final sources = await engine.store.loadSources();
    final plugins = <Map<String, dynamic>>[];
    for (final source in sources) {
      if (source.isBuiltin) continue;
      final script = await engine.store.readScript(source.id);
      if (script == null || script.isEmpty) continue;
      plugins.add({'source': source.toJson(), 'script': script});
    }

    final settings = _ref.read(settingsProvider).valueOrNull;

    final backup = {
      'schema': _kBackupSchema,
      'version': _kBackupVersion,
      'createdAt': DateTime.now().toIso8601String(),
      'platform': 'mobile',
      'data': {
        'playlists': playlists.map((p) => p.toJson()).toList(),
        'favorites': favorites.map((e) => e.toJson()).toList(),
        'favoriteCollections': collections.map((c) => c.toJson()).toList(),
        'plugins': plugins,
        'settings': settings == null ? null : _settingsToJson(settings),
      },
    };
    return const JsonEncoder.withIndent('  ').convert(backup);
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
      };

  // ==================== 解析 ====================

  /// 解析并校验备份 JSON；格式不符抛出异常。
  Map<String, dynamic> parse(String content) {
    final dynamic data;
    try {
      data = jsonDecode(content);
    } catch (_) {
      throw const FormatException('文件不是有效的 JSON 格式');
    }
    if (data is! Map || data['schema'] != _kBackupSchema) {
      throw const FormatException('无法识别的备份格式，请选择本应用导出的备份文件');
    }
    final inner = data['data'];
    if (inner is! Map) {
      throw const FormatException('备份文件数据结构无效');
    }
    return data.cast<String, dynamic>();
  }

  /// 计算备份摘要（导入前预览）。
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
      hasSettings: data['settings'] is Map,
      createdAt: backup['createdAt'] as String? ?? '',
    );
  }

  // ==================== 导入 ====================

  /// 导入备份；插件先于歌单导入以确保在线歌曲可匹配插件。
  Future<AppBackupImportResult> import(
    Map<String, dynamic> backup, {
    bool includePlaylists = true,
    bool includeFavorites = true,
    bool includePlugins = true,
    bool includeSettings = true,
  }) async {
    final summary = summarize(backup);
    final data = (backup['data'] as Map).cast<String, dynamic>();
    final errors = <String>[];
    var importedPlaylists = 0;
    var importedFavorites = 0;
    var importedPlugins = 0;
    var skippedPlugins = 0;
    var settingsApplied = false;

    // 1. 插件（按脚本重装，ID 相同自动去重）
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
          importedPlugins++;
        } catch (e) {
          errors.add('插件「${source.name}」导入失败：$e');
          skippedPlugins++;
        }
      }
    }

    // 2. 歌单（同名合并）
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
        ));
      }
      if (entries.isNotEmpty) {
        await store.addPlaylists(entries);
        await _ref.read(playlistManagerProvider.notifier).refresh();
        importedPlaylists = entries.length;
      }
    }

    // 3. 收藏（按 path 合并保留现有）
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

      // 收藏集（歌单/专辑/榜单收藏）
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

    // 4. 设置
    if (includeSettings && data['settings'] is Map) {
      try {
        final current = _ref.read(settingsProvider).valueOrNull;
        if (current != null) {
          final restored = _settingsFromJson(
              current, (data['settings'] as Map).cast<String, dynamic>());
          await _ref.read(settingsProvider.notifier).saveAll(restored);
          settingsApplied = true;
        }
      } catch (e) {
        errors.add('设置导入失败：$e');
      }
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
    );
  }

  // ==================== 兼容解析 ====================

  /// 解析歌曲列表：优先移动端格式，兼容桌面端 Song 结构。
  List<ImportedSong> _parseSongs(dynamic raw) {
    if (raw is! List) return const [];
    return raw
        .map((e) => e is Map ? ImportedSong.fromJson(_normalizeSong(e.cast<String, dynamic>())) : null)
        .whereType<ImportedSong>()
        .where((s) => s.path.isNotEmpty)
        .toList();
  }

  /// 桌面端 Song（name/artist/path/plugin_id/rawData…）→ 移动端 ImportedSong 字段名。
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

  /// 解析收藏条目（兼容桌面端 Song）。
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

/// 将备份 JSON 写入文件（应用文档目录），返回文件路径。
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
