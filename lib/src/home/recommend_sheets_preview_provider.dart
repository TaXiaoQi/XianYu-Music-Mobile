import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/application_logger.dart';
import '../plugin/plugin_catalog.dart';
import '../plugin/plugin_models.dart';
import '../plugin/plugin_provider.dart';

class RecommendSheetsPreview {
  final bool loading;
  final bool hasData;
  final String? sourceName;
  final List<MfSheetItem> sheets;

  const RecommendSheetsPreview({
    this.loading = true,
    this.hasData = false,
    this.sourceName,
    this.sheets = const [],
  });
}

class RecommendSheetsPreviewNotifier
    extends StateNotifier<RecommendSheetsPreview> {
  RecommendSheetsPreviewNotifier(this._ref) : super(const RecommendSheetsPreview()) {
    _ref.listen<PluginListState>(pluginManagerProvider, (_, next) async {
      // 插件清单变化（安装/启停/排序）时刷新预览；缓存优先后台重取
      final sig = next.sources.map((s) => s.id).join(',');
      final changed = _lastOrderSig != null && _lastOrderSig != sig;
      _lastOrderSig = sig;
      if (changed && !_running) await _refresh();
    });
    _init();
  }

  final Ref _ref;
  String? _lastOrderSig;
  bool _running = false;
  static const _cacheKey = 'recommend_sheets_preview_v1';
  static const _previewCount = 8;

  Future<void> _init() async {
    // 缓存优先：先展示上次拉到的歌单卡片，后台再刷新覆盖
    final cached = await _loadCache();
    if (cached != null && mounted) {
      state = RecommendSheetsPreview(
        loading: false,
        hasData: true,
        sourceName: cached.sourceName,
        sheets: cached.sheets,
      );
    }
    await _refresh();
  }

  Future<void> _refresh() async {
    if (_running) return;
    _running = true;
    try {
      final engine = await _ref.read(pluginEngineProvider.future);
      final catalog = PluginCatalogService(
          engine, _ref.read(pluginManagerProvider).sources);
      final candidates = <PluginSource>[];
      for (final s in sortPluginSources(catalog.musicFreeSources)) {
        if (await catalog.supportsRecommendSheets(s)) candidates.add(s);
      }
      if (candidates.isEmpty) {
        // 无任何插件支持推荐歌单：缓存一并清除，整块隐藏
        await _clearCache();
        if (mounted) state = const RecommendSheetsPreview(loading: false);
        return;
      }
      var chosen = candidates.first;
      var sheets = const <MfSheetItem>[];
      for (final c in candidates) {
        final r = await catalog.getRecommendSheets(c);
        if (r.isNotEmpty) {
          chosen = c;
          sheets = r;
          break;
        }
      }
      if (!mounted) return;
      if (sheets.isEmpty) {
        // 拉取失败/返回空：保留缓存展示，不闪没
        if (!state.hasData) {
          state = const RecommendSheetsPreview(loading: false);
        }
        return;
      }
      state = RecommendSheetsPreview(
        loading: false,
        hasData: true,
        sourceName: chosen.name,
        sheets: sheets.take(_previewCount).toList(),
      );
      await _saveCache(chosen.name, state.sheets);
    } catch (e) {
      AppLog.warn('home', '推荐歌单刷新失败: $e');
      if (mounted && !state.hasData) {
        state = const RecommendSheetsPreview(loading: false);
      }
    } finally {
      _running = false;
    }
  }

  Future<({String sourceName, List<MfSheetItem> sheets})?> _loadCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cacheKey);
      if (raw == null || raw.isEmpty) return null;
      final j = jsonDecode(raw);
      if (j is! Map) return null;
      final sheets = (j['sheets'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .map((m) => MfSheetItem(
                id: (m['id'] ?? '').toString(),
                title: (m['title'] ?? '').toString(),
                artist: (m['artist'] ?? '').toString(),
                coverUrl: (m['coverUrl'] as String?),
                playCount: (m['playCount'] as num?)?.toInt(),
                trackCount: (m['trackCount'] as num?)?.toInt(),
                platform: (m['platform'] ?? '').toString(),
                pluginId: (m['pluginId'] ?? '').toString(),
                raw: (m['raw'] as Map?)?.cast<String, dynamic>() ?? const {},
              ))
          .where((s) => s.title.isNotEmpty && s.pluginId.isNotEmpty)
          .toList();
      if (sheets.isEmpty) return null;
      return (
        sourceName: (j['sourceName'] ?? '').toString(),
        sheets: sheets,
      );
    } catch (e) {
      AppLog.warn('home', '读取推荐歌单缓存失败: $e');
      return null;
    }
  }

  Future<void> _saveCache(String sourceName, List<MfSheetItem> sheets) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _cacheKey,
        jsonEncode({
          'sourceName': sourceName,
          'sheets': [
            for (final s in sheets)
              {
                'id': s.id,
                'title': s.title,
                'artist': s.artist,
                'coverUrl': s.coverUrl,
                'playCount': s.playCount,
                'trackCount': s.trackCount,
                'platform': s.platform,
                'pluginId': s.pluginId,
                'raw': s.raw,
              },
          ],
        }),
      );
    } catch (e) {
      AppLog.warn('home', '写入推荐歌单缓存失败: $e');
    }
  }

  Future<void> _clearCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_cacheKey);
    } catch (e) {
      AppLog.warn('home', '清除推荐歌单缓存失败: $e');
    }
  }
}

final recommendSheetsPreviewProvider =
    StateNotifierProvider<RecommendSheetsPreviewNotifier, RecommendSheetsPreview>(
        (ref) => RecommendSheetsPreviewNotifier(ref));
