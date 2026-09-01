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
    // 首页首帧可能早于 pluginManagerProvider 的异步 refresh() 填充 sources：
    // 若在构造时同步读 .sources 往往拿到空列表，会被误判成「无榜单音源」，
    // 且本 provider 非 autoDispose 永不重跑，导致首页始终不显示榜单（完整榜单页
    // 因导航后才建、sources 已就绪而能正常显示）。改为监听插件列表变化并在
    // sources 就绪后再检测：启动填充 / 增删改 / 顺序变化都会触发重跑。
    _ref.listen<PluginListState>(pluginManagerProvider, (_, _) async {
      // 已有可展示的榜单即不再因插件列表微变动而重复拉网络。
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
      // 等待插件列表被异步加载出来（最多 ~8s），避免把「加载中」误判为无插件。
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
    } finally {
      _running = false;
    }
  }
}

final topListsPreviewProvider = StateNotifierProvider<TopListsPreviewNotifier,
    TopListsPreview>((ref) => TopListsPreviewNotifier(ref));