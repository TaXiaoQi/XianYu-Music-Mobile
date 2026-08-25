import 'dart:convert';

import '../player/player_provider.dart';
import 'plugin_catalog.dart';
import 'plugin_engine.dart';
import 'plugin_models.dart';

/// 插件在线搜索服务：跨已启用插件搜索，并把结果转成可播放的 [QueueItem]。
class PluginSearchService {
  final PluginEngine engine;
  final List<PluginSource> sources;

  PluginSearchService(this.engine, this.sources);

  /// 搜索所有已启用插件（LX 按声明音源逐个搜索；MusicFree 走 search music）。
  /// 返回 (插件, 搜索结果) 列表。
  Future<List<(PluginSource, List<PluginSearchResult>)>> searchAll(
    String keyword, {
    int limit = 30,
  }) async {
    final results = <(PluginSource, List<PluginSearchResult>)>[];
    final enabled = sources.where((s) => s.enabled).toList();
    final catalog = PluginCatalogService(engine, sources);
    for (final source in enabled) {
      if (source.format == PluginFormat.musicfree) {
        try {
          final items = await catalog.searchMusic(source, keyword, limit: limit);
          if (items.isNotEmpty) results.add((source, items));
        } catch (_) {
          // 单个插件失败不影响其他
        }
        continue;
      }
      final sourceKeys = source.sources.isEmpty
          ? <String>['default']
          : source.sources;
      final merged = <PluginSearchResult>[];
      for (final key in sourceKeys) {
        try {
          final items =
              await engine.searchInPlugin(source, key, keyword, limit: limit);
          merged.addAll(items);
        } catch (_) {
          // 单个音源失败不影响其他
        }
      }
      if (merged.isNotEmpty) {
        results.add((source, merged));
      }
    }
    return results;
  }

  /// 把插件搜索结果转成可播放的 [QueueItem]。
  QueueItem toQueueItem(PluginSource source, PluginSearchResult r) {
    if (source.format == PluginFormat.musicfree) {
      return PluginCatalogService.toQueueItem(source, r);
    }
    final songJson = jsonEncode({
      'pluginId': source.id,
      'source': r.source,
      'musicInfo': r.toJson(),
    });
    return QueueItem(
      path: 'lx://${r.source}/${r.songmid}',
      title: r.name,
      artist: r.singer,
      album: r.albumName,
      durationMs: _parseDurationMs(r.interval),
      coverUrl: r.img,
      onlineSongJson: songJson,
      onlineQuality: _bestQuality(r),
    );
  }

  int _parseDurationMs(String interval) {
    // "mm:ss" → 毫秒
    final parts = interval.split(':');
    if (parts.length == 2) {
      final m = int.tryParse(parts[0]);
      final s = int.tryParse(parts[1]);
      if (m != null && s != null) return (m * 60 + s) * 1000;
    }
    return 0;
  }

  String _bestQuality(PluginSearchResult r) {
    // 优先无损，其次 320k，最后 128k
    for (final q in ['flac', '320k', '128k']) {
      if (r.types.any((t) => t['type'] == q)) return q;
    }
    return '320k';
  }
}
