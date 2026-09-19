import 'dart:convert';

import '../player/player_provider.dart';
import 'plugin_catalog.dart';
import 'plugin_engine.dart';
import 'plugin_models.dart';

class PluginSearchService {
  final PluginEngine engine;
  final List<PluginSource> sources;

  PluginSearchService(this.engine, this.sources);

  Future<List<(PluginSource, List<PluginSearchResult>)>> searchAll(
    String keyword, {
    int limit = 30,
  }) async {
    final results = <(PluginSource, List<PluginSearchResult>)>[];
    final enabled = sources.where((s) => s.enabled).toList();
    final catalog = PluginCatalogService(engine, sources);
    for (final source in enabled) {
      if (source.format.isMfCompatible) {
        try {
          final items = await catalog.searchMusic(source, keyword, limit: limit);
          if (items.isNotEmpty) results.add((source, items));
        } catch (_) {
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
        }
      }
      if (merged.isNotEmpty) {
        results.add((source, merged));
      }
    }
    return results;
  }

  QueueItem toQueueItem(PluginSource source, PluginSearchResult r) {
    if (source.format.isMfCompatible) {
      return PluginCatalogService.toQueueItem(source, r);
    }
    final songJson = jsonEncode({
      'pluginId': source.id,
      'format': 'lx',
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
      source: r.source,
      onlineInfoJson: jsonEncode(r.toJson()),
    );
  }

  int _parseDurationMs(String interval) {
    final parts = interval.split(':');
    if (parts.length == 2) {
      final m = int.tryParse(parts[0]);
      final s = int.tryParse(parts[1]);
      if (m != null && s != null) return (m * 60 + s) * 1000;
    }
    return 0;
  }

  String _bestQuality(PluginSearchResult r) {
    for (final q in ['flac', '320k', '128k']) {
      if (r.types.any((t) => t['type'] == q)) return q;
    }
    return '320k';
  }
}
