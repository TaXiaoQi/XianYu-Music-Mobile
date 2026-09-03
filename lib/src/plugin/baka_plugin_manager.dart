import '../player/media_url.dart';
import 'plugin_engine.dart';
import 'plugin_models.dart';

/// Baka/Toskysun 系列插件独立管理器（对齐桌面端 bakaPluginManager 架构拆分）。
///
/// Baka 插件 API 向下兼容 MusicFree（module.exports 结构，走 MF 引擎加载），
/// 但音质协议不同：`getMediaSource` 直接收 12 档原生键（96k/128k/.../master），
/// 并声明 12 档风格 `supportedQualities`。桌面端以独立管理器与 MF 通用路径隔离
/// （pluginEngineMedia 在 getMediaSource 入口分发），移动端同样拆分：
/// - 本类负责：识别锚点、声明档读取、原生键媒体解析（含 legacy 回退）、
///   在途请求去重与结果缓存；
/// - MF 通用路径（四级键主路径 + 原生键兜底）保留在 [PluginEngine.getMusicFreeUrl]。
class BakaPluginManager {
  final PluginEngine engine;

  BakaPluginManager(this.engine);

  /// 已知非 Baka 的 MusicFree 插件作者：强制排除，不走能力检测
  ///（对齐桌面 NON_BAKA_PLUGIN_AUTHORS）。这些作者的插件虽然可能声明
  /// Baka 风格的 supportedQualities，但本质是标准 MF 插件（四级键协议）。
  static const List<String> nonBakaAuthors = ['时迁酱'];

  /// 判定结果缓存：true 稳定缓存；false 可能是插件尚未加载完成时的临时误判，
  /// 元数据就绪前不落缓存，允许就绪后重检（对齐桌面 bakaPluginManagerCore 缓存语义）。
  final Map<String, bool> _cache = {};

  /// 媒体源在途请求去重（对齐桌面 _mediaSourcePending）：
  /// 同歌同档的探测/起播/切档共享同一次真实解析，消除重复网络请求。
  final Map<String, Future<ResolvedMediaUrl?>> _pending = {};

  /// 媒体源结果缓存（对齐桌面 MediaSourceCacheEntry）：已解析直链短期复用。
  final Map<String, ResolvedMediaUrl?> _mediaCache = {};
  static const int _mediaCacheMax = 128;

  /// 是否 Baka 系列插件（对齐桌面 BakaPluginManager.isBakaPlugin，顺序敏感）：
  /// 作者判定优先于能力检测 —— 部分新式 MF 插件（如时迁酱系列）也声明了
  /// Baka 风格的 supportedQualities，仅凭能力检测会误判。
  bool isBakaPlugin(String pluginId) {
    final cached = _cache[pluginId];
    if (cached != null) return cached;
    final meta = engine.metadataOf(pluginId);
    // 元数据未就绪：按 false 处理且不缓存，插件加载完成后可重检。
    if (meta == null) return false;
    final result = _detectBakaPlugin(meta);
    _cache[pluginId] = result;
    return result;
  }

  bool _detectBakaPlugin(Map<String, dynamic> meta) {
    // 1. 作者归属判定（ Toskysun 是 BakaMusic 开发者，强制判定为 Baka）。
    final author = (meta['author'] as String? ?? '').toLowerCase();
    if (author.contains('toskysun')) return true;
    for (final name in nonBakaAuthors) {
      if (author.contains(name.toLowerCase())) return false;
    }
    // 2. 能力检测：getMusicComments（评论区 API）是最可靠的 Baka 特征，
    //    原版 MusicFree 及时迁酱系列插件都不实现该方法。
    final methods = meta['_availableMethods'];
    if (methods is List && methods.contains('getMusicComments')) return true;
    // 3. 声明了 12 档风格 supportedQualities（可为完整或部分新音质键）。
    final raw = meta['supportedQualities'];
    if (raw is List) {
      for (final dq in raw) {
        if (PluginEngine.normalizeQualityKey(dq) != null) return true;
      }
    }
    return false;
  }

  /// 插件更新/卸载/启停切换时清除缓存（对齐桌面 clearCache）。
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

  /// Baka 插件声明的支持音质（归一化 12 档键）；无声明时回退三档
  /// （对齐桌面 BakaPluginManager.getSupportedQualities）。
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

  /// Baka 插件媒体源解析（对齐桌面 bakaPluginManagerMedia.getMediaSource）：
  /// 12 档原生键主路径（mgg→96k），按 首选→更高→更低 排序，声明键过滤；
  /// 每档原生键失败后按 legacy 映射补试旧四级键。未声明 supportedQualities
  /// 时只试首选 + 相邻一档，避免每档一次网络请求拖慢起播。
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
      // 新键无结果：按 BAKA_TO_LEGACY_QUALITY_MAP 补试旧四级键。
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
    } catch (_) {
      // 单档失败继续下一档
      return null;
    }
  }

  /// 12 档原生键候选链：首选 → 更高 → 更低；声明键过滤后逐档尝试。
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
      // 未声明 supportedQualities（Baka 自回落插件）：只补一个相邻档。
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

  /// Baka 插件旧四级键回退（对齐桌面 BAKA_TO_LEGACY_QUALITY_MAP）。
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
