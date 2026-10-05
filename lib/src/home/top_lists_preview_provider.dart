import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../plugin/plugin_catalog.dart';
import '../plugin/plugin_models.dart';
import '../plugin/plugin_provider.dart';

class TopListsPreview {
  final bool checking;
  final bool loading;
  final bool loaded;
  final bool hasSource;
  final String? sourceName;
  final List<MfSheetItem> boards;

  const TopListsPreview({
    this.checking = true,
    this.loading = false,
    this.loaded = false,
    this.hasSource = false,
    this.sourceName,
    this.boards = const [],
  });

  bool get noSources => loaded && !hasSource && !loading;
}

class TopListsPreviewNotifier extends StateNotifier<TopListsPreview> {
  TopListsPreviewNotifier(this._ref) : super(const TopListsPreview()) {
    _ref.listen<PluginListState>(pluginManagerProvider, (_, _) async {
      if (state.loaded && state.hasSource && !state.loading) return;
      await _run();
    });
    _run();
  }

  final Ref _ref;
  bool _running = false;
  static const _previewCount = 8;

  Future<void> _run() async {
    if (_running) return;
    _running = true;
    try {
      final engine = await _ref.read(pluginEngineProvider.future);
      var sources = _ref.read(pluginManagerProvider).sources;
      if (sources.isEmpty) {
        for (var i = 0; i < 40; i++) {
          await Future.delayed(const Duration(milliseconds: 200));
          final s = _ref.read(pluginManagerProvider).sources;
          if (s.isNotEmpty) {
            sources = s;
            break;
          }
        }
      }
      final catalog = PluginCatalogService(engine, sources);
      // MF 源需过插件方法检测，LX 源由 lx_toplist 兜底模块保证能力
      final mfCandidates = catalog.musicFreeSources;
      final lxSources = catalog.lxToplistSources;
      if (mfCandidates.isEmpty && lxSources.isEmpty) {
        state = const TopListsPreview(loaded: true, checking: false);
        return;
      }

      final basePlugins = <PluginSource>[];
      await Future.wait(
        mfCandidates.map((s) async {
          if (await catalog.supportsTopLists(s)) basePlugins.add(s);
        }),
      );
      basePlugins.addAll(lxSources);
      if (basePlugins.isEmpty) {
        state = const TopListsPreview(loaded: true, checking: false, boards: []);
        return;
      }

      // 基础源先排序，LX 源再按内部平台拆分（与搜索结果页同款）
      const lxKeys = {'wy', 'kg', 'kw', 'tx'};
      final ordered = <({PluginSource plugin, String? lxKey, String name})>[];
      for (final p in sortPluginSources(basePlugins)) {
        if (p.format != PluginFormat.lx) {
          ordered.add((plugin: p, lxKey: null, name: p.name));
          continue;
        }
        final keys = p.sources.where(lxKeys.contains).toSet();
        if (keys.length <= 1) {
          final key = keys.isEmpty ? null : keys.first;
          ordered.add((plugin: p, lxKey: key, name: p.name));
        } else {
          for (final key in keys) {
            ordered.add((plugin: p, lxKey: key, name: lxPlatformDisplayName(key)));
          }
        }
      }

      state = TopListsPreview(
        checking: false,
        loading: true,
        loaded: true,
        hasSource: true,
        sourceName: ordered.first.name,
      );
      var chosen = ordered.first;
      var boards = const <MfSheetItem>[];
      for (final c in ordered) {
        final b = await catalog.getTopLists(c.plugin, lxKey: c.lxKey);
        if (b.isNotEmpty) {
          chosen = c;
          boards = b;
          break;
        }
      }
      state = TopListsPreview(
        checking: false,
        loading: false,
        loaded: true,
        hasSource: true,
        sourceName: chosen.name,
        boards: boards.take(_previewCount).toList(),
      );
    } finally {
      _running = false;
    }
  }
}

final topListsPreviewProvider = StateNotifierProvider<TopListsPreviewNotifier,
    TopListsPreview>((ref) => TopListsPreviewNotifier(ref));