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
      final mfSources = catalog.musicFreeSources;
      if (mfSources.isEmpty) {
        state = const TopListsPreview(loaded: true, checking: false);
        return;
      }

      final supported = <PluginSource>[];
      await Future.wait(
        mfSources.map((s) async {
          if (await catalog.supportsTopLists(s)) supported.add(s);
        }),
      );
      if (supported.isEmpty) {
        state = const TopListsPreview(loaded: true, checking: false, boards: []);
        return;
      }

      final ordered = sortPluginSources(supported);
      state = TopListsPreview(
        checking: false,
        loading: true,
        loaded: true,
        hasSource: true,
        sourceName: ordered.first.name,
      );
      var chosen = ordered.first;
      var boards = const <MfSheetItem>[];
      for (final s in ordered) {
        final b = await catalog.getTopLists(s);
        if (b.isNotEmpty) {
          chosen = s;
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