import 'dart:async';

import 'package:flutter/foundation.dart'
    show compute;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../src/core/app_colors.dart';
import '../../src/core/settings.dart';
import '../../src/favorites/favorites_provider.dart';
import '../../src/library/library_provider.dart';
import '../../src/navigation/routes.dart' show coverPageRoute;
import '../../src/navigation/shell.dart';
import '../../src/player/player_provider.dart';
import '../../src/widgets/cover_image.dart';
import '../../src/widgets/floating_search_bar.dart';
import '../../src/widgets/glass_appbar.dart';
import '../../src/widgets/list_metrics.dart';
import '../../src/widgets/mini_player_bar.dart';
import '../../src/widgets/add_to_playlist_sheet.dart';
import '../../src/widgets/app_toast.dart';
import '../../src/widgets/batch_action_bar.dart';
import '../../src/widgets/sheet_dialog.dart';
import '../../src/widgets/song_list_view.dart';
import '../../src/widgets/letter_index_song_list.dart';
import 'song_list_page.dart';
import '../../src/i18n/i18n.dart';

/// 本地曲库：全部 / 歌手 / 专辑（从「我的」页进入的二级页面）。
///
/// 歌单与收藏入口已分流到「我的」页；本页专注本地曲库浏览。
/// 「文件夹」页已独立为 [LibraryFolderPage]（顶部搜索框右侧「+」进入）。
class LibraryPage extends ConsumerStatefulWidget {
  const LibraryPage({super.key, this.initialTab = 0});

  /// 初始 Tab：0 全部 / 1 歌手 / 2 专辑。
  final int initialTab;

  @override
  ConsumerState<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends ConsumerState<LibraryPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;

  /// 整页搜索：从标题栏输入，跨整个本地页（任意 Tab）过滤歌曲。
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';

  /// 最近一次离线程搜索结果；null 表示正在计算或暂无输入。
  List<Song>? _searchResult;
  Timer? _searchDebounce;
  int _searchReq = 0;

  /// —— 全部歌曲 Tab 的排序/去重/批量/统计状态。
  /// 提升到页面层（而非 _AllSongsTab 内部）：横屏音乐库 pane 页头「右侧操作区」
  /// 要把排序/批量/统计与 TabBar 并列，这些控件需在页面层持有状态并下发给 Tab。
  /// 竖屏二级页台词不变，状态同样由此处持有、_AllSongsTab 通过参数读取。
  _SongSort _sort = _SongSort.none;
  bool _hideDuplicates = false;

  /// 最近一次离线程排序/过滤结果；null 表示尚未计算，直接展示库原始顺序。
  List<Song>? _result;
  Timer? _debounce;
  int _req = 0;

  /// 全部歌曲批量选择控制器（页头入口 + 列表 + 底部批量操作栏共用）。
  final SongBatchController _batch = SongBatchController();

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this);
    _tab.index = widget.initialTab.clamp(0, 2);
    _tab.addListener(_onTabChanged);
    // 批量模式关闭即复位播放条托起量：绑定「批量真正退出」事件而非批量栏
    // 卸载，避免卸载时序差异导致批量栏收起后播放条仍悬空、无法拖回。
    _batch.addListener(_onBatchChanged);
  }

  void _onBatchChanged() {
    if (!_batch.batchMode) {
      ref.read(batchBarLiftProvider.notifier).state = 0;
    }
  }

  void _onTabChanged() {
    // 排序/批量/统计仅对「全部(歌曲)」Tab 有意义；切 Tab 时刷新
    // 页头右侧操作区显隐与底部批量栏收起状态。
    if (!_tab.indexIsChanging) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _tab.removeListener(_onTabChanged);
    _tab.dispose();
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
    _debounce?.cancel();
    _batch.removeListener(_onBatchChanged);
    _batch.dispose();
    super.dispose();
  }

  /// 查询/排序/去重任一变化后立即刷新界面，并防抖调度一次离线程重算。
  void _onCriteriaChanged() {
    setState(() {});
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 160), _runFilter);
  }

  Future<void> _runFilter() async {
    final gen = ++_req;
    final songs = ref.read(libraryProvider).songs;
    final out = await compute(
      _filterSortSongs,
      (songs, '', _sort.index, _hideDuplicates),
    );
    if (!mounted || gen != _req) return;
    setState(() => _result = out);
  }

  /// 打开排序选择弹窗（统一弹窗风格），选中项主色勾选强调、轻量选中态。
  Future<void> _openSortMenu(BuildContext context) async {
    final v = await showSheetDialog<_SongSort>(
      context,
      (ctx) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
              child: Text(
                tr('排序方式'),
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            for (final s in _SongSort.values)
              _SortItem(
                label: _songSortLabel(s),
                selected: s == _sort,
                onTap: () => Navigator.pop(ctx, s),
              ),
            const SizedBox(height: 4),
          ],
        ),
      ),
      // 选项列表较轻，收窄成窄面板、纵向拉长的风格。
      maxWidth: 240,
    );
    if (v != null) {
      _sort = v;
      _onCriteriaChanged();
    }
  }

  void _showStats(BuildContext context, LibraryState lib) {
    final total = lib.songs.length;
    final durationMs =
        lib.songs.fold<int>(0, (sum, s) => sum + s.duration * 1000);
    final formatMap = <String, int>{};
    for (final s in lib.songs) {
      final f = s.format.isEmpty ? tr('未知') : s.format.toUpperCase();
      formatMap[f] = (formatMap[f] ?? 0) + 1;
    }
    final formats = formatMap.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    showSheetDialog<void>(
      context,
      (ctx) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
              Text(tr('曲库统计'),
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 14),
            _StatRow(label: tr('歌曲总数'), value: '$total 首'),
            _StatRow(label: tr('总时长'), value: _fmtDuration(durationMs)),
            _StatRow(label: tr('歌手'), value: '${lib.artists.length} 位'),
            _StatRow(label: tr('专辑'), value: '${lib.albums.length} 张'),
            _StatRow(label: tr('文件夹'), value: '${lib.folders.length} 个'),
            if (formats.isNotEmpty) ...[
              const SizedBox(height: 14),
              for (final f in formats)
                _StatRow(label: f.key, value: '${f.value} 首'),
            ],
            const SizedBox(height: 8),
            Icon(Icons.info_outline,
              size: 14, color: Theme.of(ctx).colorScheme.outline),
            const SizedBox(height: 4),
            Text(tr('统计基于本地曲库'), style: TextStyle(fontSize: 11, color: Theme.of(ctx).colorScheme.outline)),
          ],
        ),
      ),
    );
  }

  String _fmtDuration(int ms) {
    final sec = (ms / 1000).round();
    final h = sec ~/ 3600;
    final m = (sec % 3600) ~/ 60;
    if (h > 0) return '$h 小时 $m 分钟';
    return '$m 分钟';
  }

  /// 全部歌曲右侧操作区（横屏音乐库 pane 页头用）：文件夹 + 排序/去重/批量/统计。
  /// 参考桌面端 LocalMusicHeader——标题/功能放左侧，操作按钮集中放右侧。
  Widget _buildSongsActions(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final inBatch = _batch.batchMode;
    // 让按钮在有 TabBar 时仍显紧凑：仅保留图标按钮。
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: tr('文件夹'),
          onPressed: () => context.push('/library/folders'),
          icon: const Icon(Icons.add, size: 22),
        ),
        const SizedBox(width: 2),
        Tooltip(
          message: _hideDuplicates ? tr('已隐藏重复歌曲') : tr('隐藏重复歌曲'),
          child: IconButton(
            icon: Icon(
              _hideDuplicates ? Icons.flip_to_front : Icons.flip_to_back,
              color: _hideDuplicates ? scheme.primary : null,
            ),
            onPressed: () {
              _hideDuplicates = !_hideDuplicates;
              _onCriteriaChanged();
            },
          ),
        ),
        IconButton(
          icon: const Icon(Icons.bar_chart),
          tooltip: tr('曲库统计'),
          onPressed: () => _showStats(context, ref.read(libraryProvider)),
        ),
        IconButton(
          icon: Icon(
            inBatch ? Icons.check_rounded : Icons.library_add_check_outlined,
            size: 22,
            color: inBatch ? scheme.primary : null,
          ),
          tooltip: inBatch ? tr('完成') : tr('批量'),
          onPressed: () => inBatch ? _batch.exit() : _batch.enter(),
        ),
        const SizedBox(width: 2),
        // 排序入口：默认排序时显示「排序」图标，选中后显示当前排序标签。
        // 放在最右与 TabBar 右侧隔开，对齐桌面端 SortModeButton 的位置。
        InkWell(
          onTap: () => _openSortMenu(context),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.sort, size: 18, color: scheme.onSurfaceVariant),
                const SizedBox(width: 2),
                if (_sort != _SongSort.none)
                  Icon(Icons.arrow_drop_down,
                      size: 18, color: scheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ],
    );
  }

  void _onSearchChanged(String v) {
    setState(() => _query = v.trim().toLowerCase());
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 160), _runSearch);
  }

  /// 在后台 isolate 过滤「标题/歌手/专辑」，避免逐键在 UI 线程对全量歌曲卡顿。
  Future<void> _runSearch() async {
    final gen = ++_searchReq;
    final q = _query;
    final songs = ref.read(libraryProvider).songs;
    if (q.isEmpty) {
      if (mounted) setState(() => _searchResult = null);
      return;
    }
    final out = await compute(
      _filterSortSongs,
      (songs, q, _SongSort.none.index, false),
    );
    if (!mounted || gen != _searchReq) return;
    setState(() => _searchResult = out);
  }

  void _clearSearch() {
    _searchCtrl.clear();
    _searchDebounce?.cancel();
    setState(() {
      _query = '';
      _searchResult = null;
    });
  }

  Widget _buildSearchField(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return SizedBox(
      height: 40,
      child: TextField(
        controller: _searchCtrl,
        onChanged: _onSearchChanged,
        textInputAction: TextInputAction.search,
        style: TextStyle(fontSize: 14.5, color: scheme.onSurface),
        decoration: InputDecoration(
          hintText: tr('搜索歌曲、歌手、专辑'),
          hintStyle:
              TextStyle(fontSize: 14.5, color: scheme.onSurfaceVariant),
          prefixIcon: Icon(Icons.search, size: 20, color: scheme.onSurfaceVariant),
          prefixIconConstraints:
              const BoxConstraints(minWidth: 40, minHeight: 40),
          suffixIcon: _query.isNotEmpty
              ? InkWell(
                  onTap: _clearSearch,
                  child: Icon(Icons.close,
                      size: 18, color: scheme.onSurfaceVariant),
                )
              : null,
          suffixIconConstraints:
              const BoxConstraints(minWidth: 40, minHeight: 40),
          isDense: true,
          filled: true,
          fillColor: isDark
              ? const Color(0x14FFFFFF)
              : const Color(0x14000000),
          contentPadding:
              const EdgeInsets.symmetric(vertical: 0, horizontal: 8),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(20),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }

  /// 整页搜索结果列表（跨 Tab 生效），带关键词高亮。
  Widget _buildSearchResults(double topInset) {
    final result = _searchResult;
    if (result == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (result.isEmpty) {
      return   Center(child: Text(tr('没有找到相关歌曲')));
    }
    return SongsListView(
      songs: result,
      highlight: _query,
      enableScrollFabs: true,
      padding: EdgeInsets.only(
        top: topInset,
        bottom: (ref.watch(playerProvider.select((s) => s.current != null)) ? 92.0 : 16.0) +
            MediaQuery.of(context).padding.bottom,
      ),
      onPlay: (list, i) =>
          ref.read(libraryProvider.notifier).playList(list, i),
    );
  }

  @override
  Widget build(BuildContext context) {
    final lib = ref.watch(libraryProvider);
    // 悬浮形态（行 + Tab 气泡）横竖屏通用：竖屏二级页与横屏音乐库 pane 都
    // 由本页自绘悬浮顶栏（横屏 pane 激活时壳层全局顶栏已让位隐藏）。
    final floating = ref.watch(settingsProvider.select(
        (s) => s.valueOrNull?.floatingSearchBar ?? false));
    final statusBar = MediaQuery.paddingOf(context).top;
    // 横屏音乐库 pane（侧边栏激活本地页）：无返回键、无页内迷你条。
    final inMusicPane = ref.watch(landscapeLibraryProvider) != null;

    // 横屏 pane 内：全局顶栏搜索承担本地过滤。把全局关键词同步进页内既有
    // _query/_searchResult（离线程 isolate 过滤管线），并回填 _searchCtrl 文本
    // 使横竖屏翻转后窗口状态一致。竖屏二级页仍用页内自带搜索框（_searchCtrl）。
    if (inMusicPane) {
      ref.listen(landscapeLibraryQueryProvider, (prev, next) {
        if (_searchCtrl.text != next) _searchCtrl.text = next;
        _onSearchChanged(next);
      });
    }

    // 大数量压缩显示，避免均分 Tab 宽度不足时文字被截断。
    String fmt(int n) => n >= 10000
        ? '${(n / 10000).toStringAsFixed(n >= 100000 ? 0 : 1)}万'
        : '$n';

    final tabBar = TabBar(
      controller: _tab,
      isScrollable: false,
      tabs: [
        Tab(text: '全部 ${fmt(lib.songs.length)}'),
        Tab(text: '歌手 ${fmt(lib.artists.length)}'),
        Tab(text: '专辑 ${fmt(lib.albums.length)}'),
      ],
    );
    // 横屏音乐库 pane 专用 TabBar：isScrollable + start 对齐让 Tab「缩小到
    // 左侧」，右侧让位给文件夹/排序/批量/统计操作区（参考桌面端布局）。
    final paneTabBar = TabBar(
      controller: _tab,
      isScrollable: true,
      tabAlignment: TabAlignment.start,
      indicatorSize: TabBarIndicatorSize.label,
      labelPadding: const EdgeInsets.symmetric(horizontal: 10),
      tabs: [
        Tab(text: '全部 ${fmt(lib.songs.length)}'),
        Tab(text: '歌手 ${fmt(lib.artists.length)}'),
        Tab(text: '专辑 ${fmt(lib.albums.length)}'),
      ],
    );

    // 横屏音乐库 pane 模式：本页不再渲染完整顶栏（返回/皮肤/设置/搜索入口由
    // 壳层 LandscapeGlobalTopBar 统一继承），页内仅保留「内容头」作为页面特有
    // 控件（TabBar 靠左 + 文件夹/排序/批量/统计靠右），位于全局顶栏下方。
    // 悬浮模式：全局顶栏独立悬浮在右侧容器顶部（高度≈statusBar+60），内容头
    // 需下移到其下方（paneTop=statusBar+66）；固定（覆盖）模式全局顶栏在壳层
    // Column 上层，内容直接从其下方开始（paneTop=0）。
    final paneTop = (inMusicPane && floating) ? statusBar + 66 : 0.0;

    // 页内内容头（悬浮胶囊 / 固定细分条）。悬浮模式用与首页同款的玻璃胶囊行；
    // 固定（覆盖）模式用带细分隔线的紧凑条，保持与全局顶栏一致的常规观感。
    final Widget header;
    final double headerTop;
    if (inMusicPane) {
      // 横屏 pane 不再渲染本地搜索框——搜索职能由全局顶栏承接。
      headerTop = paneTop;
      header = _buildPaneHeader(context, paneTabBar, floating);
    } else if (floating) {
      headerTop = statusBar + 8;
      header = FloatingSearchTopBar(
        onBack: () => context.pop(),
        field: FloatingGlassSearchField(
          controller: _searchCtrl,
          onChanged: _onSearchChanged,
          showClear: _query.isNotEmpty,
          onClear: _clearSearch,
          hint: tr('搜索歌曲、歌手、专辑'),
        ),
        action: BiliPaiIconButton(
          icon: Icons.add,
          tooltip: tr('文件夹'),
          onTap: () => context.push('/library/folders'),
        ),
        tabPill: FloatingTabPill(child: tabBar),
      );
    } else {
      headerTop = 0;
      header = GlassTopBar(
        leading: const BackButton(),
        titleSpacing: 4,
        title: _buildSearchField(context),
        actions: [
          // 文件夹页入口（已从 Tab 独立为二级页）。
          IconButton(
            tooltip: tr('文件夹'),
            onPressed: () => context.push('/library/folders'),
            icon: const Icon(Icons.add, size: 24),
          ),
        ],
        bottom: tabBar,
      );
    }

    // 顶栏下方的内容初始避让量：悬浮=整列高度；固定=GlassTopBar（含 TabBar）。
    // 内容铺满全屏，避让量注入列表 padding.top——滚动时内容从顶栏下方穿过
    //（与首页一致的悬浮穿透观感），而非被 Padding 压在顶栏下。
    // pane 模式下还需额外让出全局顶栏高度（paneTop）+ 页内内容头高度。
    final topInset = inMusicPane
        ? paneTop + (floating ? 10 : 4) + _kPaneHeaderHeight + 8
        : (floating
            ? statusBar + 8 + 44 + 10 + 48 + 14
            : GlassTopBar.height(context, bottom: tabBar));

    return HideShellChrome(
      child: Scaffold(
        backgroundColor: appScaffoldBackground(context, ref),
        resizeToAvoidBottomInset: false,
        body: RepaintBoundary(child: Stack(
          children: [
            if (lib.loading)
              const Center(child: CircularProgressIndicator())
            else if (lib.error != null)
              _ErrorView(
                message: lib.error!,
                onRetry: () => ref.read(libraryProvider.notifier).load(),
              )
            else if (_query.isNotEmpty)
              _buildSearchResults(topInset)
            else
              TabBarView(
                controller: _tab,
                children: [
                  _AllSongsTab(
                    topInset: topInset,
                    sort: _sort,
                    hideDuplicates: _hideDuplicates,
                    result: _result,
                    batch: _batch,
                    inPane: inMusicPane,
                    onToggleDedup: () {
                      _hideDuplicates = !_hideDuplicates;
                      _onCriteriaChanged();
                    },
                    onOpenSort: () => _openSortMenu(context),
                    onShowStats: _showStats,
                  ),
                  _ArtistsTab(topInset: topInset),
                  _AlbumsTab(topInset: topInset),
                ],
              ),
            // 顶栏层：悬浮/固定/pane 三种形态统一在此铺位。
            // 横屏 pane 内无路由可弹，返回钮由全局顶栏承接（页内头不含返回键）。
            Positioned(
              top: headerTop,
              left: (inMusicPane || floating) && floating ? 12 : 0,
              right: (inMusicPane || floating) && floating ? 12 : 0,
              child: header,
            ),
            // 统一播放条由外壳承载：横屏面板模式下不渲染页内嵌条。
            if (!inMusicPane && lib.songs.isNotEmpty)
              const MiniPlayerBar(),
          ],
        ),
        ),
      ),
    );
  }

  /// 横屏音乐库 pane 的内容头：TabBar 缩小靠左，右侧放文件夹 + 排序/去重/
  /// 批量/统计（参考桌面端 LocalMusicHeader 布局）。不再含本地搜索框——搜索
  /// 已由全局顶栏承接。悬浮模式用玻璃胶囊行，固定（覆盖）模式用细分隔线的
  /// 紧凑条，均位于全局顶栏下方。
  Widget _buildPaneHeader(BuildContext context, Widget tabBar, bool floating) {
    final scheme = Theme.of(context).colorScheme;
    final content = SizedBox(
      height: _kPaneHeaderHeight,
      child: Row(
        children: [
          Expanded(
            child: Theme(
              data: Theme.of(context).copyWith(
                tabBarTheme: TabBarThemeData(
                  dividerColor: Colors.transparent,
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.only(left: 4, right: 8),
                child: tabBar,
              ),
            ),
          ),
          _buildSongsActions(context),
          const SizedBox(width: 6),
        ],
      ),
    );
    if (floating) {
      return FloatingGlassSurface(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 0),
          child: content,
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: scheme.onSurface.withValues(alpha: 0.06)),
        ),
      ),
      child: content,
    );
  }
}

/// 横屏音乐库 pane 内容头高度（TabBar 与右侧操作区并排的单行高度）。
const double _kPaneHeaderHeight = 48.0;

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label:   Text(tr('重试')),
          ),
        ],
      ),
    );
  }
}

/// 离线程执行的「过滤 + 去重 + 排序」（compute 回调，须为顶层函数）。
///
/// 每次按键若在 UI 线程对全库做 toLowerCase 会卡顿，故整体搬进后台 isolate。
List<Song> _filterSortSongs((List<Song>, String, int, bool) args) {
  final (songs, query, sortIdx, hideDuplicates) = args;
  List<Song> result = songs;
  if (query.isNotEmpty) {
    result = result
        .where((s) =>
            s.title.toLowerCase().contains(query) ||
            s.artist.toLowerCase().contains(query) ||
            s.album.toLowerCase().contains(query))
        .toList();
  }
  if (hideDuplicates) {
    final seen = <String, String>{};
    result = result.where((s) {
      final key = '${s.title.toLowerCase()}|${s.artist.toLowerCase()}';
      if (seen.containsKey(key)) return false;
      seen[key] = s.path;
      return true;
    }).toList();
  }
  final copy = [...result];
  switch (_SongSort.values[sortIdx]) {
    case _SongSort.title:
      copy.sort((a, b) => a.title.compareTo(b.title));
    case _SongSort.artist:
      copy.sort((a, b) {
        final c = a.artist.compareTo(b.artist);
        return c != 0 ? c : a.title.compareTo(b.title);
      });
    case _SongSort.album:
      copy.sort((a, b) {
        final c = a.album.compareTo(b.album);
        return c != 0 ? c : a.title.compareTo(b.title);
      });
    case _SongSort.addedAt:
    case _SongSort.none:
      break;
  }
  return copy;
}

String _songSortLabel(_SongSort s) => switch (s) {
      _SongSort.none => tr('默认排序'),
      _SongSort.title => tr('按标题'),
      _SongSort.artist => tr('按歌手'),
      _SongSort.album => tr('按专辑'),
      _SongSort.addedAt => tr('按添加时间'),
    };

/// 全部歌曲。
///
/// 排序/去重/批量/统计状态统一由 [LibraryPage]（_LibraryPageState）持有，
/// 经本 widget 参数共享——横屏音乐库 pane 页头右侧操作区与竖屏二级页都
/// 作用在同一份数据上，避免「页头按钮」与「列表批量勾选」各持一份互不联动。
class _AllSongsTab extends ConsumerStatefulWidget {
  const _AllSongsTab({
    required this.topInset,
    required this.sort,
    required this.hideDuplicates,
    required this.result,
    required this.batch,
    required this.inPane,
    required this.onToggleDedup,
    required this.onOpenSort,
    required this.onShowStats,
  });

  /// 顶栏避让量：列表 padding.top，滚动时内容穿透顶栏。
  final double topInset;

  final _SongSort sort;
  final bool hideDuplicates;

  /// 最近一次离线程排序/过滤结果；null 表示直接展示库原始顺序。
  final List<Song>? result;

  /// 批量选择控制器（页头入口 + 列表 + 底部批量操作栏共用）。
  final SongBatchController batch;

  /// 横屏音乐库 pane：页头已含排序/批量/统计，隐藏 Tab 内自绘工具栏。
  final bool inPane;

  final VoidCallback onToggleDedup;
  final VoidCallback onOpenSort;
  final void Function(BuildContext, LibraryState) onShowStats;

  @override
  ConsumerState<_AllSongsTab> createState() => _AllSongsTabState();
}

class _AllSongsTabState extends ConsumerState<_AllSongsTab> {
  /// 批量播放：选中歌曲入队并起播。
  Future<void> _batchPlay(List<Song> songs) async {
    final sel =
        songs.where((s) => widget.batch.selected.contains(s.path)).toList();
    if (sel.isEmpty) return;
    final items = sel.map((s) => s.toQueueItem()).toList();
    await ref.read(playerProvider.notifier).playQueue(items, startIndex: 0);
    widget.batch.exit();
  }

  /// 批量添加到我的收藏（对齐桌面端「添加至我喜欢」）。
  Future<void> _batchAddToFavorites(List<Song> songs) async {
    final sel =
        songs.where((s) => widget.batch.selected.contains(s.path)).toList();
    if (sel.isEmpty) return;
    final fav = ref.read(favoritesProvider.notifier);
    for (final s in sel) {
      fav.add(s.toQueueItem());
    }
    showXianYuToast(context, tr('已收藏 {n} 首歌曲', {'n': sel.length}));
    widget.batch.exit();
  }

  /// 批量添加到歌单（对齐桌面端批量「添加到歌单」）。
  Future<void> _batchAddToPlaylist(List<Song> songs) async {
    final sel =
        songs.where((s) => widget.batch.selected.contains(s.path)).toList();
    if (sel.isEmpty) return;
    final imported = sel.map(importedSongFromLocal).toList();
    await showAddToPlaylistSheet(context, ref, imported);
    widget.batch.exit();
  }

  @override
  Widget build(BuildContext context) {
    final lib = ref.watch(libraryProvider);
    final songs = widget.result ?? lib.songs;
    final scheme = Theme.of(context).colorScheme;

    return ListenableBuilder(
      listenable: widget.batch,
      builder: (context, _) {
        final inBatch = widget.batch.batchMode;
        final bottomPad = (ref.watch(playerProvider.select((s) => s.current != null))
                ? 92.0
                : 16.0) +
            MediaQuery.of(context).padding.bottom +
            (inBatch ? 140 : 0);

        // 列表顶距：pane 模式页头已含操作（无 Tab 内工具栏），列表紧跟页头；
        // 竖屏二级页在列表上方仍有一行自绘工具栏，需额外避让其高度。
        final topPad = widget.topInset + (widget.inPane ? 8 : 54);

        final list = songs.isEmpty
            ? Center(child: Text(tr('没有匹配的歌曲')))
            : widget.sort == _SongSort.none
                // 默认排序：支持长按把手拖动排序（顶级列表，拖到边缘自动滚动）。
                ? SongsListView(
                    songs: songs,
                    enableScrollFabs: true,
                    batch: widget.batch,
                    padding: EdgeInsets.only(top: topPad, bottom: bottomPad),
                    onPlay: (list, i) =>
                        ref.read(libraryProvider.notifier).playList(list, i),
                    onReorder: (oldIndex, newIndex) {
                      if (newIndex < 0 ||
                          newIndex >= songs.length ||
                          newIndex == oldIndex) {
                        return;
                      }
                      final paths = [for (final s in songs) s.path];
                      final moved = paths.removeAt(oldIndex);
                      // onReorderItem 的 newIndex 已随移除项调整。
                      paths.insert(newIndex.clamp(0, paths.length), moved);
                      ref
                          .read(libraryProvider.notifier)
                          .reorderLocalSongs(paths);
                    },
                  )
                : LetterIndexSongList(
                    songs: songs,
                    // 仅按字母序字段排序时才启用 A-Z 索引条；默认/添加时间无意义。
                    indexField: switch (widget.sort) {
                      _SongSort.title => (Song s) => s.title,
                      _SongSort.artist => (Song s) => s.artist,
                      _SongSort.album => (Song s) => s.album,
                      _SongSort.none || _SongSort.addedAt => null,
                    },
                    enableScrollFabs: true,
                    batch: widget.batch,
                    padding: EdgeInsets.only(top: topPad, bottom: bottomPad),
                    onPlay: (list, i) =>
                        ref.read(libraryProvider.notifier).playList(list, i),
                  );

        return Stack(
          children: [
            Positioned.fill(child: list),
            // 竖屏二级页的工具栏：排序 / 去重 / 统计 / 批量（悬浮吸顶层）。
            // 横屏 pane 页头已提供同样操作，此处不再重复绘制。
            if (!widget.inPane)
              Positioned(
                top: widget.topInset,
                left: 0,
                right: 0,
                child: ColoredBox(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 3, 12, 3),
                    child: Row(
                      children: [
                        Expanded(
                          child: InkWell(
                            onTap: widget.onOpenSort,
                            borderRadius: BorderRadius.circular(8),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 11),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.sort,
                                      size: 18, color: scheme.onSurfaceVariant),
                                  const SizedBox(width: 6),
                                  Flexible(
                                    child: Text(
                                      _songSortLabel(widget.sort),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 13,
                                        color: scheme.onSurfaceVariant,
                                      ),
                                    ),
                                  ),
                                  Icon(Icons.arrow_drop_down,
                                      size: 18, color: scheme.onSurfaceVariant),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        Tooltip(
                          message: widget.hideDuplicates
                              ? tr('已隐藏重复歌曲')
                              : tr('隐藏重复歌曲'),
                          child: IconButton(
                            icon: Icon(
                              widget.hideDuplicates
                                  ? Icons.flip_to_front
                                  : Icons.flip_to_back,
                              color: widget.hideDuplicates
                                  ? scheme.primary
                                  : null,
                            ),
                            onPressed: widget.onToggleDedup,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.bar_chart),
                          tooltip: tr('曲库统计'),
                          onPressed: () => widget.onShowStats(context, lib),
                        ),
                        IconButton(
                          icon: Icon(
                            inBatch
                                ? Icons.check_rounded
                                : Icons.library_add_check_outlined,
                            size: 22,
                            color: inBatch ? scheme.primary : null,
                          ),
                          tooltip: inBatch ? tr('完成') : tr('批量'),
                          onPressed: () => inBatch
                              ? widget.batch.exit()
                              : widget.batch.enter(),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            // 批量操作栏：悬浮在内容底部（避开播放条/安全区）。
            if (inBatch)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: BatchActionBar(
                  selectedCount: widget.batch.selectedCount,
                  totalCount: songs.length,
                  showPlay: true,
                  showFavorite: true,
                  showPlaylist: true,
                  showDownload: false,
                  showRemove: false,
                  onSelectAll: () => widget.batch
                      .toggleSelectAll({for (final s in songs) s.path}),
                  onPlay: () => _batchPlay(songs),
                  onFavorite: () => _batchAddToFavorites(songs),
                  onPlaylist: () => _batchAddToPlaylist(songs),
                  onRemove: () {},
                  onDone: widget.batch.exit,
                ),
              ),
          ],
        );
      },
    );
  }
}

/// 排序弹窗里的单选项：选中项左侧主色勾选标记（轻量选中态）。
class _SortItem extends StatelessWidget {
  const _SortItem({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  color: selected ? scheme.primary : scheme.onSurface,
                ),
              ),
            ),
            if (selected)
              Icon(Icons.check, size: 18, color: scheme.primary),
          ],
        ),
      ),
    );
  }
}

enum _SongSort { none, title, artist, album, addedAt }

class _StatRow extends StatelessWidget {
  const _StatRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 13.5)),
          Text(
            value,
            style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: scheme.primary),
          ),
        ],
      ),
    );
  }
}

/// 歌手目录。
class _ArtistsTab extends ConsumerWidget {
  const _ArtistsTab({required this.topInset});

  /// 顶栏避让量：列表 padding.top，滚动时内容穿透顶栏。
  final double topInset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final artists = ref.watch(libraryProvider.select((s) => s.artists));
    if (artists.isEmpty) return   Center(child: Text(tr('暂无歌手')));
    final m = ListMetrics.ofRef(ref);
    return ListView.builder(
      padding: EdgeInsets.only(
        top: topInset,
        bottom: (ref.watch(playerProvider.select((s) => s.current != null)) ? 92.0 : 16.0) +
            MediaQuery.of(context).padding.bottom,
      ),
      // 行高固定（封面 + 上下内边距），itemExtent 跳过逐行测量，长列表滚动更省。
      itemExtent: m.artistCover + 2 * m.vPad,
      addAutomaticKeepAlives: false,
      itemCount: artists.length,
      itemBuilder: (context, i) {
        final a = artists[i];
        final scheme = Theme.of(context).colorScheme;
        return RepaintBoundary(
          // key 用歌手名，滚动时该行图层可缓存复用，避免整页重绘。
          key: ValueKey('artist_${a.name}'),
          child: CoverRow(
          cover: CoverImage(
            songPath: a.firstSongPath,
            width: m.artistCover,
            height: m.artistCover,
            radius: m.artistCover / 2,
            icon: Icons.person,
            placeholder: _letterAvatar(context, a.name, scheme),
          ),
          title: Text(
            a.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: m.titleSize, fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            '${a.count} 首',
            style:
                TextStyle(fontSize: m.subtitleSize, color: scheme.onSurfaceVariant),
          ),
          verticalPadding: m.vPad,
          trailing: Icon(Icons.chevron_right, color: scheme.outline),
          onTap: () => Navigator.of(context, rootNavigator: true).push(
            coverPageRoute(
              context,
              (_) => SongListPage(
                title: a.name,
                loader: () =>
                    ref.read(libraryProvider.notifier).songsByArtist(a.name),
              ),
            ),
          ),
          ),
        );
      },
    );
  }
}

/// 歌手无封面时的字母头像占位。
Widget _letterAvatar(BuildContext context, String name, ColorScheme scheme) {
  return DecoratedBox(
    decoration: BoxDecoration(
      color: scheme.primaryContainer,
      shape: BoxShape.circle,
    ),
    child: Center(
      child: Text(
        name.isEmpty ? '?' : String.fromCharCode(name.runes.first),
        style: TextStyle(color: scheme.onPrimaryContainer),
      ),
    ),
  );
}

/// 专辑目录。
class _AlbumsTab extends ConsumerWidget {
  const _AlbumsTab({required this.topInset});

  /// 顶栏避让量：列表 padding.top，滚动时内容穿透顶栏。
  final double topInset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final albums = ref.watch(libraryProvider.select((s) => s.albums));
    if (albums.isEmpty) return   Center(child: Text(tr('暂无专辑')));
    final m = ListMetrics.ofRef(ref);
    return ListView.builder(
      padding: EdgeInsets.only(
        top: topInset,
        bottom: (ref.watch(playerProvider.select((s) => s.current != null)) ? 92.0 : 16.0) +
            MediaQuery.of(context).padding.bottom,
      ),
      // 行高固定（封面 + 上下内边距），itemExtent 跳过逐行测量，长列表滚动更省。
      itemExtent: m.songCover + 2 * m.vPad,
      addAutomaticKeepAlives: false,
      itemCount: albums.length,
      itemBuilder: (context, i) {
        final a = albums[i];
        final scheme = Theme.of(context).colorScheme;
        return RepaintBoundary(
          key: ValueKey('album_${a.key}'),
          child: CoverRow(
          cover: CoverImage(
            songPath: a.firstSongPath,
            width: m.songCover,
            height: m.songCover,
            radius: m.songRadius,
            icon: Icons.album,
          ),
          title: Text(
            a.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: m.titleSize, fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            '${a.artist} · ${a.count} 首',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style:
                TextStyle(fontSize: m.subtitleSize, color: scheme.onSurfaceVariant),
          ),
          verticalPadding: m.vPad,
          trailing: Icon(Icons.chevron_right, color: scheme.outline),
          onTap: () => Navigator.of(context, rootNavigator: true).push(
            coverPageRoute(
              context,
              (_) => SongListPage(
                title: a.name,
                loader: () =>
                    ref.read(libraryProvider.notifier).songsByAlbum(a.key),
              ),
            ),
          ),
          ),
        );
      },
    );
  }
}
