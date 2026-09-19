import '../player/media_url.dart';
import 'plugin_engine.dart';
import 'plugin_models.dart';

class BakaPluginManager {
  final PluginEngine engine;

  BakaPluginManager(this.engine);

  static const List<String> nonBakaAuthors = ['时迁酱'];

  final Map<String, bool> _cache = {};

  final Map<String, Future<ResolvedMediaUrl?>> _pending = {};

  final Map<String, ResolvedMediaUrl?> _mediaCache = {};
  static const int _mediaCacheMax = 128;

  bool isBakaPlugin(String pluginId) {
    final cached = _cache[pluginId];
    if (cached != null) return cached;
    final meta = engine.metadataOf(pluginId);
    if (meta == null) return false;
    final result = _detectBakaPlugin(meta);
    _cache[pluginId] = result;
    return result;
  }

  bool _detectBakaPlugin(Map<String, dynamic> meta) {
    final author = (meta['author'] as String? ?? '').toLowerCase();
    if (author.contains('toskysun')) return true;
    for (final name in nonBakaAuthors) {
      if (author.contains(name.toLowerCase())) return false;
    }
    final methods = meta['_availableMethods'];
    if (methods is List && methods.contains('getMusicComments')) return true;
    final raw = meta['supportedQualities'];
    if (raw is List) {
      for (final dq in raw) {
        if (PluginEngine.normalizeQualityKey(dq) != null) return true;
      }
    }
    return false;
  }

  void clearCache([String? pluginId]) {
    if (pluginId == null || pluginId.isEmpty) {
      _cache.clear();
      _mediaCache.clear();
      return;
    }
    _cache.remove(pluginId);
    _mediaCache
        .removeWhere((k, _) => k == pluginId || k.startsWith('$pluginId|'));
  }

  List<String> getSupportedQualities(String pluginId) {
    final raw = engine.metadataOf(pluginId)?['supportedQualities'];
    if (raw is List) {
      final out = <String>{};
      for (final dq in raw) {
        final norm = PluginEngine.normalizeQualityKey(dq);
        if (norm != null) out.add(norm);
      }
      if (out.isNotEmpty) return out.toList();
    }
    return const ['128k', '320k', 'flac'];
  }

  Future<ResolvedMediaUrl?> getMediaSource(
    PluginSource source,
    Map<String, dynamic> musicItem, {
    String preferred = '320k',
    String fallback = 'lower',
    Set<String> declaredKeys = const {},
  }) async {
    await engine.ensureLoaded(source);
    final songId = (musicItem['id'] ?? musicItem['songmid'] ?? '').toString();
    final cacheKey = '${source.id}|$songId|$preferred|$fallback';
    if (_mediaCache.containsKey(cacheKey)) return _mediaCache[cacheKey];
    final existing = _pending[cacheKey];
    if (existing != null) return existing;

    final future = _resolveMediaSource(
      source,
      musicItem,
      preferred: preferred,
      fallback: fallback,
      declaredKeys: declaredKeys,
    );
    _pending[cacheKey] = future;
    try {
      final res = await future;
      if (_mediaCache.length >= _mediaCacheMax) {
        _mediaCache.remove(_mediaCache.keys.first);
      }
      _mediaCache[cacheKey] = res;
      return res;
    } finally {
      _pending.remove(cacheKey);
    }
  }

  Future<ResolvedMediaUrl?> _resolveMediaSource(
    PluginSource source,
    Map<String, dynamic> musicItem, {
    required String preferred,
    required String fallback,
    required Set<String> declaredKeys,
  }) async {
    final tryKeys = _qualityCandidates(preferred, fallback, declaredKeys);
    final attempted = <String>{};
    for (final qk in tryKeys) {
      final pluginQ = PluginEngine.qualityKeyToPluginString(qk);
      if (!attempted.add(pluginQ)) continue;
      final url = await _tryOnce(source, musicItem, pluginQ, qk);
      if (url != null) return url;
      final legacy = _legacyQuality(qk);
      if (legacy != null && attempted.add(legacy)) {
        final legacyUrl = await _tryOnce(source, musicItem, legacy, qk);
        if (legacyUrl != null) return legacyUrl;
      }
    }
    return null;
  }

  Future<ResolvedMediaUrl?> _tryOnce(
    PluginSource source,
    Map<String, dynamic> musicItem,
    String pluginQ,
    String requestedKey,
  ) async {
    try {
      final response = await engine.call(
        source.id,
        'getMediaSource',
        [musicItem, pluginQ],
      );
      return PluginEngine.extractMfPlayableUrl(response,
          requestedKey: requestedKey);
    } catch (e) {
      final msg = e is PluginEngineException ? e.message : e.toString();
      // 鉴权失效（卡密/401）时向上抛出，终止剩余档位
      if (PluginEngine.isAuthFailureMessage(msg)) rethrow;
      return null;
    }
  }

  static List<String> _qualityCandidates(
    String preferred,
    String fallback,
    Set<String> declaredKeys,
  ) {
    final ladder = PluginEngine.qualityLadder;
    final ladderDesc = ladder.reversed.toList();
    final native = <String>[];
    final seen = <String>{};
    void add(String qk) {
      if (seen.add(qk)) native.add(qk);
    }

    if (fallback == 'pause') {
      add(preferred);
    } else if (fallback == 'higher') {
      final start = ladder.indexOf(preferred);
      if (start >= 0) {
        for (var i = start; i < ladder.length; i++) {
          add(ladder[i]);
        }
      } else {
        add(preferred);
      }
    } else {
      final start = ladderDesc.indexOf(preferred);
      if (start >= 0) {
        for (var i = start; i < ladderDesc.length; i++) {
          add(ladderDesc[i]);
        }
      } else {
        add(preferred);
      }
    }

    if (declaredKeys.isNotEmpty) {
      final filtered = native.where(declaredKeys.contains).toList();
      if (filtered.isNotEmpty) {
        native
          ..clear()
          ..addAll(filtered);
      }
    } else {
      final idx = ladder.indexOf(preferred);
      if (idx >= 0) {
        final adj = fallback == 'higher'
            ? (idx + 1 < ladder.length ? ladder[idx + 1] : null)
            : (idx - 1 >= 0 ? ladder[idx - 1] : null);
        if (adj != null) add(adj);
      }
    }
    return native;
  }

  static String? _legacyQuality(String q) {
    switch (q) {
      case 'mgg':
      case '128k':
        return 'low';
      case '192k':
        return 'standard';
      case '320k':
        return 'high';
      case 'flac':
      case 'flac24bit':
      case 'hires':
      case 'vinyl':
      case 'dolby':
      case 'atmos':
      case 'atmos_plus':
      case 'master':
        return 'super';
    }
    return null;
  }
}
