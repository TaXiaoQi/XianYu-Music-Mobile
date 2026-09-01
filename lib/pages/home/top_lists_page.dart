import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../src/core/app_colors.dart';
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
    // 壁纸抽透明态：来源 chip 未选中透出壁纸、选中轻量红底+细边，
    // 避免榜单来源选择条在壁纸上堆成实色色块；普通模式走主题原样。
    final wallpaper = ref.watch(wallpaperActiveProvider);
    return Scaffold(
      backgroundColor: appScaffoldBackground(context, ref),
      body: Stack(
        children: [
          Padding(
            padding: EdgeInsets.only(
                top: widget.embedded ? 0 : GlassTopBar.height(context)),
            child: Column(
              children: [
                if (_sources.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    // 来源插件切换条玻璃气泡：与悬浮顶栏气泡同材质。
                    child: FloatingTabPill(
                      height: 46,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        physics: const BouncingScrollPhysics(),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 7),
                        children: [
                          for (final s in _sources)
                            Padding(
                              key: _chipKeys[s.id],
                              padding: const EdgeInsets.only(right: 8),
                              child: ChoiceChip(
                                label: Text(s.name),
                                showCheckmark: false,
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 8),
                                selected: _selectedId == s.id,
                                backgroundColor:
                                    wallpaper ? Colors.transparent : null,
                                selectedColor: wallpaper
                                    ? scheme.primary.withValues(alpha: 0.14)
                                    : null,
                                side: wallpaper
                                    ? BorderSide(
                                        color: _selectedId == s.id
                                            ? scheme.primary
                                            : scheme.outline
                                                .withValues(alpha: 0.35),
                                      )
                                    : null,
                                onSelected: (_) =>
                                    _selectSource(_sources.indexOf(s)),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                Expanded(child: _buildBody(scheme)),
              ],
            ),
          ),
          if (!widget.embedded)
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
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBody(ColorScheme scheme) {
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
      itemBuilder: (context, i) => _buildSourcePage(scheme, _sources[i]),
    );
  }

  Widget _buildSourcePage(ColorScheme scheme, PluginSource source) {
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
    return GridView.builder(
      padding: EdgeInsets.fromLTRB(14, 8, 14, MediaQuery.of(context).padding.bottom + 24),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.72,
      ),
      itemCount: boards.length,
      itemBuilder: (context, i) {
        final b = boards[i];
        return InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _openBoard(b),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: OnlineCover(url: b.coverUrl, size: 200, radius: 12),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Text(
                b.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
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
