import '../player/media_url.dart';
import 'plugin_engine.dart';
import 'plugin_models.dart';

/// baka 模块单例：baka 系插件的能力全部自持（识别/取链/音质/缓存），
/// 不挂在 mf 引擎（PluginEngine）上，二者仅在 plugin_dispatch.dart 交汇。
final bakaManager = BakaPluginManager();

class BakaPluginManager {
  BakaPluginManager();

  static const List<String> nonBakaAuthors = ['时迁酱'];

  final Map<String, bool> _cache = {};

  final Map<String, Future<ResolvedMediaUrl?>> _pending = {};

  final Map<String, ResolvedMediaUrl?> _mediaCache = {};
  static const int _mediaCacheMax = 128;

  /// 是否为 baka 插件（含旧装插件的运行时启发式识别）。
  bool isBakaPlugin(PluginEngine engine, String pluginId,
      {PluginSource? source}) {
    // 一等 baka 格式优先（安装时按 author 写入，不依赖运行时 author 字符串）
    if (source?.format == PluginFormat.baka) return true;
    final cached = _cache[pluginId];
    if (cached != null) return cached;
    final meta = engine.metadataOf(pluginId);
    if (meta == null) return false;
    final result = _detectBakaPlugin(meta);
    _cache[pluginId] = result;
    return result;
  }

  /// format 路由判定：baka 一等格式直判；anime 格式永不走 baka；
  /// 其余沙箱格式用启发式识别（兼容未打 format 标的旧装插件）。
  bool shouldRouteToBaka(PluginEngine engine, PluginSource source) {
    if (source.format == PluginFormat.baka) return true;
    if (source.format == PluginFormat.anime) return false;
    return isBakaPlugin(engine, source.id, source: source);
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

  List<String> getSupportedQualities(PluginEngine engine, String pluginId) {
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

  /// baka 取链入口：自持加载、歌曲条目归一化与声明音质收集。
  Future<ResolvedMediaUrl?> getMediaSource(
    PluginEngine engine,
    PluginSource source,
    Map<String, dynamic> songInfo, {
    String preferred = '320k',
    String fallback = 'lower',
  }) async {
    await engine.ensureLoaded(source);
    final musicItem = engine.prepareMusicItem(source, songInfo);
    final declaredKeys = _declaredKeysOf(engine, source.id);
    final songId = (musicItem['id'] ?? musicItem['songmid'] ?? '').toString();
    final cacheKey = '${source.id}|$songId|$preferred|$fallback';
    if (_mediaCache.containsKey(cacheKey)) return _mediaCache[cacheKey];
    final existing = _pending[cacheKey];
    if (existing != null) return existing;

    final future = _resolveMediaSource(
      engine,
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

  Set<String> _declaredKeysOf(PluginEngine engine, String pluginId) {
    final declaredKeys = <String>{};
    final declaredRaw = engine.metadataOf(pluginId)?['supportedQualities'];
    if (declaredRaw is List) {
      for (final dq in declaredRaw) {
        final norm = PluginEngine.normalizeQualityKey(dq);
        if (norm != null) declaredKeys.add(norm);
      }
    }
    return declaredKeys;
  }

  Future<ResolvedMediaUrl?> _resolveMediaSource(
    PluginEngine engine,
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
      final url = await _tryOnce(engine, source, musicItem, pluginQ, qk);
      if (url != null) return url;
      final legacy = _legacyQuality(qk);
      if (legacy != null && attempted.add(legacy)) {
        final legacyUrl = await _tryOnce(engine, source, musicItem, legacy, qk);
        if (legacyUrl != null) return legacyUrl;
      }
    }
    return null;
  }

  Future<ResolvedMediaUrl?> _tryOnce(
    PluginEngine engine,
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
      case 'dts':
      case 'atmos':
      case 'atmos_plus':
      case 'atmos_pro':
      case 'master':
        return 'super';
    }
    return null;
  }
}
