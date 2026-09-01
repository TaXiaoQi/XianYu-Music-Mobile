import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../plugin/plugin_catalog.dart';
import '../plugin/plugin_models.dart';
import '../plugin/plugin_provider.dart';

/// 首页「音源榜单」内嵌预览数据（对齐桌面端首页内嵌榜单区块）。
///
/// 检测首个支持榜榜单接口的 MusicFree 音源，拉取其榜单前 N 项。
/// 非 autoDispose：首次进入发现区即加载一次，切标签/返回时复用，避免重复检测。
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

  /// 已完成检测但没有任一可用的榜单音源（区别于「有音源但暂无榜单」）。
  bool get noSources => loaded && !hasSource && !loading;
}

class TopListsPreviewNotifier extends StateNotifier<TopListsPreview> {
  TopListsPreviewNotifier(this._ref) : super(const TopListsPreview()) {
    _init();
  }

  final Ref _ref;
  static const _previewCount = 8;

  Future<void> _init() async {
    final engine = await _ref.read(pluginEngineProvider.future);
    final catalog = PluginCatalogService(
      engine,
      _ref.read(pluginManagerProvider).sources,
    );
    final mfSources = catalog.musicFreeSources;
    if (mfSources.isEmpty) {
      state = const TopListsPreview(loaded: true, checking: false);
      return;
    }

    // 并行检测各音源是否支持榜单接口，避免串行阻塞。
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

    // 与完整「音源榜单页」保持一致：用同一排序（sortPluginSources），避免
    // Future.wait 并行收集的 supported 顺序不确定，导致首页预览选中的首位
    // 音源（恰好榜单为空）而完整榜单页却又能切到有内容的音源。
    final ordered = sortPluginSources(supported);
    state = TopListsPreview(
      checking: false,
      loading: true,
      loaded: true,
      hasSource: true,
      sourceName: ordered.first.name,
    );
    // 依次取榜首：优先选首个「真能拉到榜单」的音源，保证首页预览与完整榜单页
    // 展示一致；即便某音源榜单接口瞬时失败/为空，也会继续尝试后续音源。
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
  }
}

final topListsPreviewProvider = StateNotifierProvider<TopListsPreviewNotifier,
    TopListsPreview>((ref) => TopListsPreviewNotifier(ref));