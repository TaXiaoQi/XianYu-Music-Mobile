import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../src/core/app_colors.dart';
import '../../src/core/settings.dart';
import '../../src/navigation/shell.dart';
import '../../src/plugin/plugin_catalog.dart';
import '../../src/plugin/plugin_models.dart';
import '../../src/plugin/plugin_provider.dart';
import '../../src/widgets/glass_appbar.dart';
import '../../src/widgets/floating_search_bar.dart';
import '../../src/widgets/online_cover.dart';
import 'online_detail_page.dart';
import '../../src/i18n/i18n.dart';

/// 音源榜单页：插件来源切换 + 榜单网格（对齐桌面 TopLists）。
/// [embedded]=true 时作为横屏右侧「内容」容器内嵌（无自绘顶栏，顶部让位
/// 为 0——容器外层 FlatTopBar 已承接返回与标题）。
class TopListsPage extends ConsumerStatefulWidget {
  const TopListsPage({super.key, this.embedded = false});

  final bool embedded;

  @override
  ConsumerState<TopListsPage> createState() => _TopListsPageState();
}

class _TopListsPageState extends ConsumerState<TopListsPage>
    with HidesShellChrome {
  List<PluginSource> _sources = const [];
  String? _selectedId;
  /// 内容区 PageView：每音源一页，支持横滑切换（与顶栏内容 tab 同源观感）。
  PageController? _pageCtrl;
  /// 各音源已加载的榜单缓存（横滑往返不重复请求）。
  final Map<String, List<MfSheetItem>> _boardsCache = {};
  final Set<String> _loadingIds = {};
  bool _checking = true;
  final Map<String, GlobalKey> _chipKeys = {};

  @override
  void initState() {
    super.initState();
    _detectSources();
  }

  @override
  void dispose() {
    _pageCtrl?.dispose();
    super.dispose();
  }

  Future<void> _detectSources() async {
    setState(() => _checking = true);
    final engine = await ref.read(pluginEngineProvider.future);
    final sources =
        sortPluginSources(ref.read(pluginManagerProvider).sources.where((s) => s.enabled).toList());
    final catalog = PluginCatalogService(engine, sources);
    final supported = <PluginSource>[];
    for (final s in catalog.musicFreeSources) {
      if (await catalog.supportsTopLists(s)) supported.add(s);
    }
    if (!mounted) return;
    setState(() {
      _sources = supported;
      _checking = false;
      if (supported.isNotEmpty) {
        _pageCtrl = PageController();
        _selectedId = supported.first.id;
        for (final s in supported) {
          _chipKeys[s.id] ??= GlobalKey();
        }
      }
    });
    if (supported.isNotEmpty) {
      _loadBoards(supported.first);
    }
  }

  Future<void> _loadBoards(PluginSource source) async {
    if (_boardsCache.containsKey(source.id) ||
        _loadingIds.contains(source.id)) {
      return;
    }
    setState(() => _loadingIds.add(source.id));
    final engine = await ref.read(pluginEngineProvider.future);
    final catalog = PluginCatalogService(engine,
        ref.read(pluginManagerProvider).sources);
    final boards = await catalog.getTopLists(source);
    if (!mounted) return;
    setState(() {
      _boardsCache[source.id] = boards;
      _loadingIds.remove(source.id);
    });
  }

  /// 点 chip 切换音源：300ms + fastLinearToSlowEaseIn 动画翻页，
  /// 与顶栏内容 tab 的点击切换一致。
  void _selectSource(int index) {
    final ctrl = _pageCtrl;
    if (ctrl == null || !ctrl.hasClients) return;
    ctrl.animateToPage(
      index,
      duration: const Duration(milliseconds: 300),
      curve: Curves.fastLinearToSlowEaseIn,
    );
  }

  /// 横滑翻页 / 翻页动画落位：同步选中态、按需加载、chip 滚入可视区。
  void _onPageChanged(int index) {
    final s = _sources[index];
    if (s.id == _selectedId) return;
    setState(() => _selectedId = s.id);
    _loadBoards(s);
    final ctx = _chipKeys[s.id]?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 300),
        curve: Curves.fastLinearToSlowEaseIn,
        alignment: 0.5,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final statusBar = MediaQuery.paddingOf(context).top;
    final embedded = widget.embedded;
    // 竖屏悬浮顶栏模式（横屏面板内嵌不参与）：顶栏自动换装玻璃胶囊组，
    // 来源条独立悬浮于顶栏下方，榜单网格铺满全屏、滚动时从顶栏与来源条
    // 下方穿过（穿透观感，与搜索结果页同口径）。
    final floating = !embedded &&
        (ref.watch(settingsProvider
                .select((s) => s.valueOrNull?.floatingSearchBar ?? false)) ==
            true);
    // 固定模式：来源条并入顶栏本体（bottom 底段，同材质同分割线），不再
    // 悬在页面底色上形成「灰带」；壁纸模式下来源条与工具行拉开 8px。
    final wallpaperGap = ref.watch(wallpaperActiveProvider) ? 8.0 : 0.0;
    final chromeBottom = _sources.isEmpty
        ? null
        : PreferredSizeProxy(
            height: 40 + wallpaperGap,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(height: wallpaperGap),
                _buildSourceBar(),
              ],
            ),
          );
    // 悬浮模式网格顶部避让：顶栏胶囊列（状态栏+8+48）+ 间距10 + 来源条40
    // + 呼吸6；固定/内嵌走原 Padding 避让结构，网格自带 8px 顶距。
    final contentTop =
        floating ? statusBar + 8 + 48 + 10 + 40 + 6 : null;

    return Scaffold(
      backgroundColor: appScaffoldBackground(context, ref),
      body: Stack(
        children: [
          if (floating)
            Positioned.fill(child: _buildBody(scheme, contentTop: contentTop))
          else
            Padding(
              padding:
                  EdgeInsets.only(top: embedded ? 0 : GlassTopBar.height(context)),
              child: Column(
                children: [
                  if (embedded && _sources.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: _buildSourceBar(),
                    ),
                  Expanded(child: _buildBody(scheme)),
                ],
              ),
            ),
          if (floating)
            Positioned(
              top: statusBar + 8 + 48 + 10,
              left: 12,
              right: 12,
              child: _buildSourceBar(floating: true),
            ),
          if (!embedded)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: GlassTopBar(
                leading: IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => context.pop(),
                ),
                title: Text(tr('音源榜单')),
                bottom: floating ? null : chromeBottom,
              ),
            ),
        ],
      ),
    );
  }

  /// 来源插件切换条：与搜索结果页一致，独立玻璃气泡（[FloatingSourcePill]）。
  /// [floating]=悬浮顶栏模式（居于顶栏下方悬浮行，内边距 2）；固定模式并入
  /// 顶栏底段（内边距 14，与工具行对齐）。
  Widget _buildSourceBar({bool floating = false}) {
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding: EdgeInsets.symmetric(horizontal: floating ? 2 : 14),
        children: [
          for (final s in _sources)
            Padding(
              key: _chipKeys[s.id],
              padding: const EdgeInsets.only(right: 8),
              child: FloatingSourcePill(
                name: s.name,
                selected: _selectedId == s.id,
                onTap: () => _selectSource(_sources.indexOf(s)),
              ),
            ),
        ],
      ),
    );
  }

  /// [contentTop]=悬浮模式下注入网格滚动 padding.top 的顶部避让量
  /// （内容从顶栏与来源条下方穿过）；固定/内嵌为 null，网格自带 8px 顶距。
  Widget _buildBody(ColorScheme scheme, {double? contentTop}) {
    if (_checking) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(strokeWidth: 2),
            const SizedBox(height: 12),
            Text(
              tr('正在检测可用音源…'),
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }
    if (_sources.isEmpty) {
      return _empty(
        scheme,
        Icons.extension_outlined,
        tr('暂无支持榜单的插件\n请先在「插件管理」安装支持排行榜的音源插件'),
      );
    }
    final ctrl = _pageCtrl;
    if (ctrl == null || !ctrl.hasClients && _selectedId == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    // 每音源一页：横滑直接切换，点 chip 动画翻页（见 _selectSource）。
    return PageView.builder(
      controller: ctrl,
      itemCount: _sources.length,
      onPageChanged: _onPageChanged,
      itemBuilder: (context, i) =>
          _buildSourcePage(scheme, _sources[i], contentTop: contentTop),
    );
  }

  Widget _buildSourcePage(
    ColorScheme scheme,
    PluginSource source, {
    double? contentTop,
  }) {
    final boards = _boardsCache[source.id];
    if (boards == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(strokeWidth: 2),
            const SizedBox(height: 12),
            Text(
              tr('正在加载榜单…'),
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }
    if (boards.isEmpty) {
      return _empty(scheme, Icons.library_music_outlined, tr('该音源暂无榜单\n试试切换其他音源'));
    }
    // 横屏容器内嵌：卡片对齐发现页音源榜单小尺寸（~92 宽、圆角 10、标题 12），
    // 用 maxCrossAxisExtent 让列宽贴近发现页小卡，而非固定 3 列大卡。
    final isEmbedded = widget.embedded;
    return GridView.builder(
      padding: EdgeInsets.fromLTRB(
        14,
        contentTop ?? 8,
        14,
        MediaQuery.of(context).padding.bottom + 24,
      ),
      gridDelegate: isEmbedded
          ? const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 92,
              mainAxisSpacing: 12,
              crossAxisSpacing: 10,
              childAspectRatio: 0.7,
            )
          : const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 0.72,
            ),
      itemCount: boards.length,
      itemBuilder: (context, i) {
        final b = boards[i];
        return InkWell(
          borderRadius: BorderRadius.circular(isEmbedded ? 10 : 12),
          onTap: () => _openBoard(b),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(isEmbedded ? 10 : 12),
                  child: OnlineCover(
                    url: b.coverUrl,
                    size: isEmbedded ? 92 : 200,
                    radius: isEmbedded ? 10 : 12,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                b.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: isEmbedded ? 12 : 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (b.subtitle.isNotEmpty)
                Text(
                  b.subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 11, color: scheme.onSurfaceVariant),
                ),
            ],
          ),
        );
      },
    );
  }

  void _openBoard(MfSheetItem b) {
    context.push('/online-detail',
        extra: OnlineDetailArgs(
          type: OnlineDetailType.toplist,
          pluginId: b.pluginId,
          title: b.title,
          subtitle: b.subtitle,
          coverUrl: b.coverUrl,
          raw: b.raw,
        ));
  }

  Widget _empty(ColorScheme scheme, IconData icon, String message) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 52, color: scheme.onSurfaceVariant.withValues(alpha: 0.4)),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 13, height: 1.6, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
