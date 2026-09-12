import 'dart:async';

import 'package:flutter/foundation.dart'
    show compute;
import 'package:xianyu_music_mobile/src/widgets/predictive_dialog_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../src/favorites/favorites_provider.dart';
import '../../src/favorites/favorites_delete.dart';
import '../../src/core/app_colors.dart';
import '../../src/core/settings.dart';
import '../../src/download/download_provider.dart';
import '../../src/navigation/shell.dart';
import '../../src/player/player_provider.dart';
import '../../src/plugin/plugin_provider.dart';
import '../../src/widgets/add_to_playlist_sheet.dart';
import '../../src/widgets/app_toast.dart';
import '../../src/widgets/batch_action_bar.dart';
import '../../src/widgets/bottom_play_bar_slot.dart';
import '../../src/widgets/cover_image.dart';
import '../../src/widgets/drag_handle.dart';
import '../../src/widgets/floating_search_bar.dart';
import '../../src/widgets/flying_cover.dart';
import '../../src/widgets/glass_appbar.dart';
import '../../src/widgets/list_metrics.dart';
import '../../src/widgets/mini_player_bar.dart';
import '../../src/widgets/online_cover.dart';
import '../../src/widgets/sheet_dialog.dart';
import '../../src/widgets/song_actions_sheet.dart';
import '../../src/widgets/song_list_view.dart';
import '../../src/widgets/song_list_scroll_fabs.dart';
import '../../src/widgets/source_tag.dart';
import '../home/online_detail_page.dart';
import '../../src/i18n/i18n.dart';

/// 收藏页：单曲 / 歌单 / 专辑三 tab（对齐桌面）。
class FavoritesPage extends ConsumerStatefulWidget {
  const FavoritesPage({super.key, this.initialTab = 0});

  /// 初始 Tab：0 单曲 / 1 歌单 / 2 专辑（「我的」页收藏歌单/专辑直达）。
  final int initialTab;

  @override
  ConsumerState<FavoritesPage> createState() => _FavoritesPageState();
}

class _FavoritesPageState extends ConsumerState<FavoritesPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;
  /// 单曲 tab 的批量选择控制器（顶栏入口 + 列表共用）。
  final SongBatchController _batch = SongBatchController();

  /// 竖屏页内搜索（非面板）：标题栏输入，过滤单曲收藏。
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';
  /// 最近一次离线程「过滤+排序」结果；null 表示无过滤/排序，直接用库顺序。
  List<FavoriteEntry>? _result;
  Timer? _debounce;
  int _req = 0;
  _FavSort _sort = _FavSort.none;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this);
    _tab.index = widget.initialTab.clamp(0, 2);
    // 批量模式关闭即复位播放条托起量（绑定退出事件，不依赖批量栏卸载时序）。
    _batch.addListener(_onBatchChanged);
  }

  void _onBatchChanged() {
    if (!_batch.batchMode) {
      ref.read(batchBarLiftProvider.notifier).state = 0;
    }
  }

  @override
  void dispose() {
    _batch.removeListener(_onBatchChanged);
    _batch.dispose();
    _tab.dispose();
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  /// 批量模式切换按钮：未进入时显示「批量」，进入后变为「完成」。
  /// [floating] 为真时用 BiliPai 玻璃圆钮（面板悬浮形态），否则普通图标钮。
  Widget _batchToggle(BuildContext context, {bool floating = false}) {
    return ListenableBuilder(
      listenable: _batch,
      builder: (context, _) {
        final active = _batch.batchMode;
        final icon = active
            ? Icons.check_rounded
            : Icons.library_add_check_outlined;
        final tip = active ? tr('完成') : tr('批量');
        void onTap() => active ? _batch.exit() : _batch.enter();
        if (floating) {
          return BiliPaiIconButton(
            icon: icon,
            tooltip: tip,
            color: active ? Theme.of(context).colorScheme.primary : null,
            onTap: onTap,
          );
        }
        return IconButton(
          icon: Icon(icon, size: 22),
          tooltip: tip,
          onPressed: onTap,
        );
      },
    );
  }

  /// 查询/排序任一变化后立即刷新界面并防抖调度离线程重算。
  void _onCriteriaChanged() {
    setState(() {});
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 160), _runFilter);
  }

  Future<void> _runFilter() async {
    final gen = ++_req;
    final entries = ref.read(favoritesProvider).entries;
    final out = await compute(
      _filterSortFavorites,
      (entries, _query, _sort.index),
    );
    if (!mounted || gen != _req) return;
    setState(() => _result = out);
  }

  void _clearSearch() {
    _searchCtrl.clear();
    setState(() => _query = '');
    _debounce?.cancel();
    // 清空搜索：排序可能选中，保留排序结果；无条件重跑一次对齐。
    _runFilter();
  }

  Widget _buildSearchField(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return SizedBox(
      height: 40,
      child: TextField(
        controller: _searchCtrl,
        onChanged: (v) {
          _query = v.trim().toLowerCase();
          _onCriteriaChanged();
        },
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

  /// 打开排序选择弹窗（统一弹窗风格），参考本地页。
  Future<void> _openSortMenu(BuildContext context) async {
    final v = await showSheetDialog<_FavSort>(
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
            for (final s in _FavSort.values)
              _SortItem(
                label: _favSortLabel(s),
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

  @override
  Widget build(BuildContext context) {
    final fav = ref.watch(favoritesProvider);
    // 面板模式下隐藏本页顶部 GlassTopBar（由外层横屏胶囊顶栏占位）。
    final inMusicPane = ref.watch(landscapeLibraryProvider) != null;
    // 横屏 pane 内：全局顶栏搜索承担本地过滤（按单曲标题/歌手过滤）。
    final filter = inMusicPane
        ? ref.watch(landscapeLibraryQueryProvider).trim().toLowerCase()
        : '';
    final notifier = ref.read(favoritesProvider.notifier);
    // 单曲 tab 有内容时提供批量入口（顶栏动作 / 面板 Tab 行内）。
    final showBatch = fav.entries.isNotEmpty && _tab.index == 0;
    final tabBar = TabBar(
      controller: _tab,
      onTap: (_) => setState(() {}),
      tabs:   [
        Tab(text: tr('单曲')),
        Tab(text: tr('歌单')),
        Tab(text: tr('专辑')),
      ],
    );
    // 横屏音乐库面板模式下统一继承壳层全局顶栏：页内不再渲染完整 GlassTopBar，
    // 仅保留 TabBar 作为「内容头」，位于全局顶栏下方（悬浮模式按顶栏高度下移）。
    final floating = ref.watch(
        settingsProvider.select((s) => s.valueOrNull?.floatingSearchBar ?? false));
    final statusBar = MediaQuery.paddingOf(context).top;
    final paneTop = (floating && inMusicPane) ? statusBar + 66 : 0.0;
    // 内容头（TabBar）高度，用于内容区顶部避让。
    const tabBarHeight = 48.0;
    // 面板模式下把批量入口并入 TabBar 行（仅单曲 tab 显示）。
    final paneTabBar = showBatch
        ? Row(
            children: [
              Expanded(child: tabBar),
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: _batchToggle(context, floating: floating),
              ),
            ],
          )
        : tabBar;

    // 竖屏悬浮顶栏（非面板）：TabBarView 铺满全屏、避让量注入各 tab 滚动体
    // padding，内容从顶栏胶囊与 Tab 气泡下方穿过（穿透观感，与反馈/壁纸中心
    // 同口径）；面板/横屏由壳层全局顶栏承接，不参与悬浮。
    final portraitFloating = !inMusicPane &&
        MediaQuery.of(context).orientation != Orientation.landscape &&
        floating;
    // 悬浮模式内容避让量：整数级对齐本地页悬浮顶栏——状态栏 + 8 顶距 + 44
    // 搜索胶囊行 + 10 间距 + Tab 气泡原高 + 14 呼吸；固定模式 0。
    final topInset = portraitFloating
        ? statusBar + 8 + 44 + 10 + tabBar.preferredSize.height + 14
        : 0.0;

    return HideShellChrome(
      child: Scaffold(
        backgroundColor: appScaffoldBackground(context, ref),
        body: Stack(
          children: [
            _tabHost(
              portraitFloating,
              // 面板模式下内容头位于全局顶栏下方，内容按其避让；非面板模式沿用
              // 完整 GlassTopBar（含 TabBar）高度避让。
              inMusicPane
                  ? paneTop + tabBarHeight + 2
                  : GlassTopBar.height(context, bottom: tabBar),
              fav.loading
                  ? const Center(child: CircularProgressIndicator())
                  : TabBarView(
                      controller: _tab,
                      children: [
                        _SongsTab(
                            fav: fav,
                            notifier: notifier,
                            batch: _batch,
                            filter: filter,
                            topInset: topInset,
                            // 面板模式沿用全局顶栏搜索，页内搜索/排序让位。
                            query: inMusicPane ? '' : _query,
                            sort: inMusicPane ? _FavSort.none : _sort,
                            result: inMusicPane ? null : _result,
                            showControls: !inMusicPane,
                            onOpenSort: () => _openSortMenu(context)),
                        _CollectionsTab(
                            fav: fav,
                            kind: 'playlist',
                            filter: filter,
                            topInset: topInset),
                        _CollectionsTab(
                            fav: fav,
                            kind: 'album',
                            filter: filter,
                            topInset: topInset),
                      ],
                    ),
            ),
            // 内容头：面板模式只保留 TabBar（悬浮气泡 / 固定细分条）；非面板模式
            // 渲染完整顶栏——竖屏悬浮态用全宽搜索胶囊 [FloatingSearchTopBar]（对齐
            // 本地页），固定态用 GlassTopBar（返回 + 标题搜索 + 清空 + TabBar）。
            Positioned(
              top: inMusicPane
                  ? paneTop
                  : (portraitFloating ? statusBar + 8 : 0),
              left: (inMusicPane || portraitFloating) ? 12 : 0,
              right: (inMusicPane || portraitFloating) ? 12 : 0,
              child: inMusicPane
                  ? (floating
                      ? FloatingTabPill(child: paneTabBar)
                      : _tabBarStrip(context, paneTabBar))
                  : (portraitFloating
                      ? FloatingSearchTopBar(
                          onBack: () => context.pop(),
                          field: FloatingGlassSearchField(
                            controller: _searchCtrl,
                            onChanged: (v) {
                              _query = v.trim().toLowerCase();
                              _onCriteriaChanged();
                            },
                            showClear: _query.isNotEmpty,
                            onClear: _clearSearch,
                            hint: tr('搜索歌曲、歌手、专辑'),
                          ),
                          action: showBatch
                              ? Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    _batchToggle(context, floating: true),
                                    if (!_batch.batchMode) ...[
                                      const SizedBox(width: 10),
                                      BiliPaiIconButton(
                                        icon:
                                            Icons.delete_sweep_outlined,
                                        tooltip: tr('清空'),
                                        onTap: () => _confirmClear(
                                            context, notifier),
                                      ),
                                    ],
                                  ],
                                )
                              : null,
                          tabPill: FloatingTabPill(child: tabBar),
                        )
                      : GlassTopBar(
                          leading: const BackButton(),
                          // 竖屏/非面板模式下标题栏内联搜索框（过滤单曲收藏，对齐本地页）。
                          title: _buildSearchField(context),
                          actions: [
                            if (showBatch) _batchToggle(context),
                            if (showBatch && !_batch.batchMode)
                              IconButton(
                                icon:
                                    const Icon(Icons.delete_sweep_outlined),
                                tooltip: tr('清空'),
                                onPressed: () =>
                                    _confirmClear(context, notifier),
                              ),
                          ],
                          bottom: tabBar,
                        )),
            ),
            // 统一播放条由外壳承载：横屏面板模式下不渲染页内嵌条。
            if (!inMusicPane) const BottomPlayBarSlot(),
          ],
        ),
      ),
    );
  }

  /// 内容容器：悬浮模式铺满全屏（[SizedBox.expand]，内容穿透顶栏与 Tab 气泡），
  /// 固定模式沿用 Padding 避让（避让量由调用方按面板/固定形态计算）。
  Widget _tabHost(bool floating, double dockedTop, Widget child) {
    // 悬浮模式必须用非定位（非 Positioned）的全尺寸子项撑起外层 body Stack：
    // 若用 Positioned.fill，外层 Stack 只剩定位子项、无「非定位子项驱动自身尺寸」，
    // 在 StackFit.loose 下 Stack 会坍缩成 0×0——页面内容全白屏（收藏/日推/最近/
    // 搜索结果页在悬浮顶栏开启时均复现）。SizedBox.expand 与 Positioned.fill 对子项
    // 视觉效果一致（都铺满填满），但不破坏 Stack 的自适应尺寸。
    if (floating) return SizedBox.expand(child: child);
    return Padding(
      padding: EdgeInsets.only(top: dockedTop),
      child: child,
    );
  }

  /// 面板模式（非悬浮）下仅含 TabBar 的内容头：细分隔线 + 48 高 TabBar。
  Widget _tabBarStrip(BuildContext context, Widget tabBar) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: scheme.onSurface.withValues(alpha: 0.06)),
        ),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(
          tabBarTheme: TabBarThemeData(
            dividerColor: Colors.transparent,
          ),
        ),
        child: SizedBox(height: 48, child: tabBar),
      ),
    );
  }

  Future<void> _confirmClear(
      BuildContext context, FavoritesManager notifier) async {
    // 已登录且收藏存在云端副本：先弹删除范围三选一（对齐桌面端），
    // 用户取消则不动作；未同步走原普通确认框。
    final paths =
        ref.read(favoritesProvider).entries.map((e) => e.path).toList();
    if (await shouldAskFavoriteDeleteScope(ref, paths)) {
      if (!context.mounted) return;
      final scope = await resolveFavoriteDeleteScope(context, ref, paths);
      if (!context.mounted) return;
      if (scope == null) return; // 用户取消
      await applyFavoriteDeleteScope(context, ref, scope, paths,
          onLocalRemove: () => notifier.clear());
      return;
    }
    if (!context.mounted) return;
    showPredictiveDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title:   Text(tr('清空收藏')),
        content:   Text(tr('确定要清空全部收藏歌曲吗？收藏的歌单与专辑不受影响。')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child:   Text(tr('取消')),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              notifier.clear();
            },
            child:   Text(tr('清空')),
          ),
        ],
      ),
    );
  }
}

/// 单曲收藏列表：长按行首把手可拖动排序（顶级列表，拖到边缘自动滚动）。
/// 右下角叠加「回到顶部 / 定位当前播放歌曲」悬浮按钮。
/// 批量模式（[SongBatchController.batchMode]）下切换为勾选列表 + 底部批量操作栏。
class _SongsTab extends ConsumerStatefulWidget {
  const _SongsTab({
    required this.fav,
    required this.notifier,
    required this.batch,
    this.filter = '',
    this.topInset = 0,
    this.query = '',
    this.sort = _FavSort.none,
    this.result,
    this.showControls = false,
    required this.onOpenSort,
  });

  final FavoritesState fav;
  final FavoritesManager notifier;
  final SongBatchController batch;

  /// 横屏音乐库 pane 的本地过滤关键词（已小写）；空=不过滤。
  final String filter;

  /// 悬浮模式避让量：注入列表滚动 padding.top，内容穿透顶栏；0=固定模式。
  /// FAB 行位推算（rowTopOf）需同步加上此值。
  final double topInset;

  /// 页内搜索关键词（已小写）；空=不搜索。
  final String query;

  /// 当前排序；[none]=库原始顺序（可拖拽）。
  final _FavSort sort;

  /// 最近一次离线程「过滤+排序」结果；null 表示无过滤/排序，直接用库顺序。
  final List<FavoriteEntry>? result;

  /// 竖屏非面板模式下显示页内排序工具栏（对齐本地页竖屏二级页）。
  final bool showControls;

  final VoidCallback onOpenSort;

  @override
  ConsumerState<_SongsTab> createState() => _SongsTabState();
}

class _SongsTabState extends ConsumerState<_SongsTab> {
  /// 常规列表（可拖拽排序 + 悬浮按钮）控制器。
  final ScrollController _controller = ScrollController();
  /// 批量模式列表专用控制器：与 [_controller] 分离，避免进出批量模式时
  /// ReorderableListView↔ListView 复用同一控制器导致多滚动视图断言崩溃。
  final ScrollController _batchController = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    _batchController.dispose();
    super.dispose();
  }

  List<FavoriteEntry> _selectedEntries(
      List<FavoriteEntry> entries, SongBatchController batch) {
    return entries.where((e) => batch.selected.contains(e.path)).toList();
  }

  Future<void> _batchPlay(
      List<FavoriteEntry> entries, SongBatchController batch) async {
    final sel = _selectedEntries(entries, batch);
    if (sel.isEmpty) return;
    final items = sel.map((e) => e.toQueueItem()).toList();
    await ref.read(playerProvider.notifier).playQueue(items, startIndex: 0);
    batch.exit();
  }

  Future<void> _batchAddToPlaylist(
      List<FavoriteEntry> entries, SongBatchController batch) async {
    final sel = _selectedEntries(entries, batch);
    if (sel.isEmpty) return;
    final songs = sel.map((e) => importedSongFromQueueItem(e.toQueueItem())).toList();
    await showAddToPlaylistSheet(context, ref, songs);
    batch.exit();
  }

  Future<void> _batchDownload(
      List<FavoriteEntry> entries, SongBatchController batch) async {
    final selected = _selectedEntries(entries, batch);
    if (selected.isEmpty) return;
    final dn = ref.read(downloadProvider.notifier);
    // 未设置自定义下载目录/无「所有文件访问」权限：禁止批量下载并提示。
    if (!await dn.requireDownloadDir(context)) return;
    // 本地歌曲不计入下载（对齐桌面端「跳过本地歌曲」）。
    final localSkipped = selected.where((e) => !e.isOnline).length;
    // 在线歌曲里已下载（下载历史 + 文件仍存在）的一并跳过，避免重复下载。
    var downloadedSkipped = 0;
    final toDownload = <FavoriteEntry>[];
    for (final e in selected.where((e) => e.isOnline)) {
      if (await dn.isAlreadyDownloaded(e.path)) {
        downloadedSkipped++;
      } else {
        toDownload.add(e);
      }
    }
    if (!mounted) return;
    if (localSkipped > 0) {
      showXianYuToast(
          context, tr('已跳过 {n} 首本地歌曲', {'n': localSkipped}));
    }
    if (downloadedSkipped > 0) {
      showXianYuToast(
          context, tr('已跳过 {n} 首已下载歌曲', {'n': downloadedSkipped}));
    }
    if (toDownload.isEmpty) {
      showXianYuToast(context, tr('没有可下载的在线歌曲'));
      return;
    }
    for (final e in toDownload) {
      dn.download(e.toQueueItem());
    }
    showXianYuToast(context, tr('开始下载 {n} 首歌曲', {'n': toDownload.length}));
    batch.exit();
  }

  Future<void> _confirmBatchRemove(
      List<FavoriteEntry> entries, SongBatchController batch) async {
    final sel = _selectedEntries(entries, batch);
    if (sel.isEmpty) return;
    final paths = sel.map((e) => e.path).toList();
    // 已登录且存在云端副本：先弹删除范围三选一（对齐桌面端），
    // 用户取消则不动作（保持批量选中状态）；未同步走原普通确认框。
    if (await shouldAskFavoriteDeleteScope(ref, paths)) {
      if (!mounted) return;
      final scope = await resolveFavoriteDeleteScope(context, ref, paths);
      if (!mounted) return;
      if (scope == null) return; // 用户取消
      await applyFavoriteDeleteScope(context, ref, scope, paths,
          onLocalRemove: () async {
        for (final e in sel) {
          await widget.notifier.remove(e.path);
        }
      });
      batch.exit();
      return;
    }
    if (!mounted) return;
    final ok = await showPredictiveDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('移除收藏')),
        content: Text(tr('确定要移除选中的 {n} 首收藏歌曲吗？', {'n': sel.length})),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('移除')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    for (final e in sel) {
      await widget.notifier.remove(e.path);
    }
    batch.exit();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.batch,
      builder: (context, _) {
        final scheme = Theme.of(context).colorScheme;
        final hasSong =
            ref.watch(playerProvider.select((s) => s.current != null));
        final entries = widget.fav.entries;
        final batch = widget.batch;
        final inBatch = batch.batchMode;
        final filter = widget.filter;
        // 页内搜索/排序任一生效即视为过滤态：展示离线程结果、禁用拖拽排序。
        final filtering =
            widget.query.isNotEmpty || widget.sort != _FavSort.none;
        final songs = filtering ? (widget.result ?? entries) : entries;
        if (entries.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.favorite_border,
                    size: 48,
                    color: scheme.onSurface.withValues(alpha: 0.25)),
                const SizedBox(height: 12),
                Text(
                  tr('暂无收藏歌曲'),
                  style: TextStyle(
                      fontSize: 14, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          );
        }
        final m = ListMetrics.ofRef(ref);
        // 行高固定（封面 + 上下内边距），悬浮按钮按此推算行位置。
        final rowExtent = m.songCover + 2 * m.vPad;
        // 竖屏非面板排序工具栏高度，供列表顶部避让（对齐本地页）。
        final toolPad = (widget.showControls && !inBatch) ? 54.0 : 0.0;

        void onReorder(int oldIndex, int newIndex) {
          if (newIndex < 0 ||
              newIndex >= entries.length ||
              newIndex == oldIndex) {
            return;
          }
          final paths = entries.map((e) => e.path).toList();
          final moved = paths.removeAt(oldIndex);
          // onReorderItem 的 newIndex 已随移除项调整，直接作为目标下标。
          paths.insert(newIndex.clamp(0, paths.length), moved);
          widget.notifier.reorderEntries(paths);
        }

        final bottomPad =
            (hasSong ? 92.0 : 24.0) + MediaQuery.of(context).padding.bottom;

        // 竖屏非面板排序工具栏（对齐本地页竖屏二级页）：默认排序允许拖拽。
        Widget sortBar() {
          final sc = Theme.of(context).colorScheme;
          return ColoredBox(
            color: Theme.of(context).scaffoldBackgroundColor,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
              child: Align(
                alignment: Alignment.centerLeft,
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
                            size: 18, color: sc.onSurfaceVariant),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            _favSortLabel(widget.sort),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 13, color: sc.onSurfaceVariant),
                          ),
                        ),
                        Icon(Icons.arrow_drop_down,
                            size: 18, color: sc.onSurfaceVariant),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        }

        Widget rowFor(int i) {
          final entry = entries[i];
          // 批量模式：整行点按切换选中，行首由 wrapBatchRow 挂勾选。
          if (inBatch) {
            final row = CoverRow(
              cover: CoverImage(
                songPath: entry.path,
                networkUrl: entry.coverUrl,
                width: m.songCover,
                height: m.songCover,
                radius: m.songRadius,
                icon: Icons.music_note,
              ),
              title: Text(
                entry.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: m.titleSize, fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                entry.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: m.subtitleSize,
                    color: scheme.onSurfaceVariant),
              ),
              verticalPadding: m.vPad,
              trailing: SourceTag(
                path: entry.path,
                isOnline: entry.isOnline,
                source: entry.source,
                onlineSongJson: entry.onlineSongJson,
              ),
              onTap: () => batch.toggle(entry.path),
            );
            return wrapBatchRow(
              context,
              row: row,
              selected: batch.isSelected(entry.path),
              onToggle: () => batch.toggle(entry.path),
            );
          }
          return _FavoriteTile(
            entry: entry,
            onPlay: () => widget.notifier.play(i),
            onRemove: () => widget.notifier.remove(entry.path),
          );
        }

        // 横屏 pane 本地过滤：过滤子集非原始全量，禁用拖拽排序（下标不对应），
        // 改走扁平列表 + 悬浮按钮。
        if (filter.isNotEmpty) {
          final visible = entries
              .where((e) =>
                  e.title.toLowerCase().contains(filter) ||
                  e.artist.toLowerCase().contains(filter))
              .toList();
          if (visible.isEmpty) {
            return Center(child: Text(tr('没有找到相关歌曲')));
          }
          return Stack(
            children: [
              ListView.builder(
                controller: _controller,
                padding: EdgeInsets.only(
                    top: widget.topInset, bottom: bottomPad),
                itemExtent: rowExtent,
                addAutomaticKeepAlives: false,
                itemCount: visible.length,
                itemBuilder: (context, i) {
                  final entry = visible[i];
                  final orig = entries.indexOf(entry);
                  return _FavoriteTile(
                    entry: entry,
                    onPlay: () => widget.notifier.play(orig),
                    onRemove: () => widget.notifier.remove(entry.path),
                  );
                },
              ),
              SongListScrollFabs(
                controller: _controller,
                paths: visible.map((e) => e.path).toList(),
                // 悬浮模式 padding.top 注入后行位整体下移，推算同步偏移。
                rowTopOf: (i) => widget.topInset + i * rowExtent,
                itemExtent: rowExtent,
                bottom: bottomPad + 8,
                right: 12,
              ),
            ],
          );
        }

        // 页内搜索/排序生效：展示离线程过滤结果，扁平列表（下标对排序结果），
        // 禁用拖拽排序；批量勾选按 path 匹配仍可用。
        if (filtering) {
          final visible = songs;
          if (visible.isEmpty) {
            return Center(child: Text(tr('没有找到相关歌曲')));
          }
          return Stack(
            children: [
              if (inBatch)
                ListView.builder(
                  controller: _batchController,
                  padding: EdgeInsets.only(
                      top: widget.topInset + toolPad,
                      bottom: bottomPad + 140),
                  itemExtent: rowExtent,
                  addAutomaticKeepAlives: false,
                  itemCount: visible.length,
                  itemBuilder: (context, i) {
                    final entry = visible[i];
                    final row = CoverRow(
                      cover: CoverImage(
                        songPath: entry.path,
                        networkUrl: entry.coverUrl,
                        width: m.songCover,
                        height: m.songCover,
                        radius: m.songRadius,
                        icon: Icons.music_note,
                      ),
                      title: Text(
                        entry.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: m.titleSize,
                            fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(
                        entry.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: m.subtitleSize,
                            color: scheme.onSurfaceVariant),
                      ),
                      verticalPadding: m.vPad,
                      trailing: SourceTag(
                        path: entry.path,
                        isOnline: entry.isOnline,
                        source: entry.source,
                        onlineSongJson: entry.onlineSongJson,
                      ),
                      onTap: () => batch.toggle(entry.path),
                    );
                    return RepaintBoundary(
                      key: ValueKey('batch_${entry.path}_$i'),
                      child: wrapBatchRow(
                        context,
                        row: row,
                        selected: batch.isSelected(entry.path),
                        onToggle: () => batch.toggle(entry.path),
                      ),
                    );
                  },
                )
              else
                ListView.builder(
                  controller: _controller,
                  padding: EdgeInsets.only(
                      top: widget.topInset + toolPad, bottom: bottomPad),
                  itemExtent: rowExtent,
                  addAutomaticKeepAlives: false,
                  itemCount: visible.length,
                  itemBuilder: (context, i) {
                    final entry = visible[i];
                    final orig = entries.indexOf(entry);
                    return _FavoriteTile(
                      entry: entry,
                      onPlay: () => widget.notifier.play(orig),
                      onRemove: () => widget.notifier.remove(entry.path),
                    );
                  },
                ),
              if (!inBatch)
                SongListScrollFabs(
                  controller: _controller,
                  paths: visible.map((e) => e.path).toList(),
                  rowTopOf: (i) =>
                      widget.topInset + toolPad + i * rowExtent,
                  itemExtent: rowExtent,
                  bottom: bottomPad + 8,
                  right: 12,
                ),
              if (widget.showControls && !inBatch)
                Positioned(
                  top: widget.topInset,
                  left: 0,
                  right: 0,
                  child: sortBar(),
                ),
            ],
          );
        }

        return Stack(
          children: [
            // 批量模式禁用拖动排序（行首把手被勾选槽替代），统一走扁平列表，
            // 且专用 [_batchController] 避免与常规列表复用控制器。
            if (inBatch)
              ListView.builder(
                controller: _batchController,
                padding: EdgeInsets.only(
                    top: widget.topInset + toolPad,
                    bottom: bottomPad + 140),
                itemExtent: rowExtent,
                addAutomaticKeepAlives: false,
                itemCount: entries.length,
                itemBuilder: (context, i) => RepaintBoundary(
                  key: ValueKey('batch_${entries[i].path}_$i'),
                  child: rowFor(i),
                ),
              )
            else
              ReorderableListView.builder(
                scrollController: _controller,
                padding: EdgeInsets.only(
                    top: widget.topInset + toolPad, bottom: bottomPad),
                buildDefaultDragHandles: false,
                // 拖动 proxy 处于根 Overlay 下（无 Material 祖先），行内 InkWell 会以
                // debugCheckHasMaterial 报错；补一层透明 Material 提供水波纹上下文。
                proxyDecorator: (child, index, animation) =>
                    Material(type: MaterialType.transparency, child: child),
                itemCount: entries.length,
                onReorderItem: onReorder,
                itemBuilder: (context, i) {
                  final entry = entries[i];
                  return RepaintBoundary(
                    key: ValueKey(entry.path),
                    child: Stack(
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(left: 44),
                          child: _FavoriteTile(
                            entry: entry,
                            onPlay: () => widget.notifier.play(i),
                            onRemove: () =>
                                widget.notifier.remove(entry.path),
                          ),
                        ),
                        Positioned(
                          left: 8,
                          top: 0,
                          bottom: 0,
                          width: 36,
                          child: Center(child: DragHandle(index: i)),
                        ),
                      ],
                    ),
                  );
                },
              ),
            if (inBatch)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: BatchActionBar(
                  selectedCount: batch.selectedCount,
                  totalCount: entries.length,
                  showPlay: true,
                  showPlaylist: true,
                  showDownload: true,
                  showRemove: true,
                  onSelectAll: () => batch.toggleSelectAll(
                      {for (final e in entries) e.path}),
                  onPlay: () => _batchPlay(entries, batch),
                  onPlaylist: () => _batchAddToPlaylist(entries, batch),
                  onDownload: () => _batchDownload(entries, batch),
                  onRemove: () => _confirmBatchRemove(entries, batch),
                  onDone: batch.exit,
                ),
              ),
            if (!inBatch)
              SongListScrollFabs(
                controller: _controller,
                paths: entries.map((e) => e.path).toList(),
                // 悬浮模式 padding.top 注入后行位整体下移，推算同步偏移。
                rowTopOf: (i) =>
                    widget.topInset + toolPad + i * rowExtent,
                itemExtent: rowExtent,
                bottom: bottomPad + 8,
                right: 12,
              ),
            // 竖屏非面板排序工具栏（默认排序允许拖拽）。
            if (widget.showControls && !inBatch)
              Positioned(
                top: widget.topInset,
                left: 0,
                right: 0,
                child: sortBar(),
              ),
          ],
        );
      },
    );
  }
}

/// 歌单/专辑收藏列表（来自收藏集）。
class _CollectionsTab extends ConsumerWidget {
  const _CollectionsTab({
    required this.fav,
    required this.kind,
    this.filter = '',
    this.topInset = 0,
  });

  final FavoritesState fav;
  final String kind;

  /// 横屏音乐库 pane 的本地过滤关键词（已小写）；空=不过滤。
  final String filter;

  /// 悬浮模式避让量：注入列表滚动 padding.top，内容穿透顶栏；0=固定模式。
  final double topInset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final hasSong = ref.watch(playerProvider.select((s) => s.current != null));
    final filter = this.filter;
    final items = fav.collections
        .where((c) =>
            c.kind == kind &&
            (filter.isEmpty ||
                c.title.toLowerCase().contains(filter) ||
                c.subtitle.toLowerCase().contains(filter)))
        .toList();
    if (items.isEmpty) {
      final kindName = kind == 'album' ? tr('专辑') : tr('歌单');
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              kind == 'album'
                  ? Icons.album_outlined
                  : Icons.queue_music_outlined,
              size: 48,
              color: scheme.onSurface.withValues(alpha: 0.25),
            ),
            const SizedBox(height: 12),
            Text(
              // 过滤无结果时提示「没有找到相关」，区别于真实的「暂无收藏」。
              filter.isNotEmpty
                  ? tr('没有找到相关{kind}', {'kind': kindName})
                  : tr('暂无收藏{kind}', {'kind': kindName}),
              style:
                  TextStyle(fontSize: 14, color: scheme.onSurfaceVariant),
            ),
            if (!filter.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                tr('在在线详情页点击收藏按钮'),
                style:
                    TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ],
          ],
        ),
      );
    }
    final m = ListMetrics.ofRef(ref);
    return ListView.builder(
      padding: EdgeInsets.only(
        top: topInset,
        bottom: (hasSong ? 92.0 : 24.0) +
            MediaQuery.of(context).padding.bottom,
      ),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final c = items[i];
        final type = c.kind == 'album'
            ? OnlineDetailType.album
            : OnlineDetailType.playlist;
        return CoverRow(
          cover: OnlineCover(
            url: c.coverUrl,
            size: m.songCover,
            radius: m.songRadius,
          ),
          title: Text(
            c.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: m.titleSize, fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            [
              if (c.subtitle.isNotEmpty) c.subtitle,
              _pluginName(ref, c.pluginId),
            ].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: m.subtitleSize, color: scheme.onSurfaceVariant),
          ),
          verticalPadding: m.vPad,
          trailing: IconButton(
            icon: Icon(Icons.favorite,
                size: 20, color: scheme.primary),
            tooltip: tr('取消收藏'),
            onPressed: () => ref.read(favoritesProvider.notifier).toggleCollection(
                  kind: c.kind,
                  pluginId: c.pluginId,
                  title: c.title,
                  subtitle: c.subtitle,
                  coverUrl: c.coverUrl,
                  raw: c.raw,
                ),
          ),
          onTap: () => _openCollection(context, c, type),
        );
      },
    );
  }

  /// 打开收藏集：本地歌单（pluginId 以 `local:` 开头）进本地歌单详情，
  /// 其余走在线详情页。
  void _openCollection(
    BuildContext context, FavoriteCollection c, OnlineDetailType type) {
    if (c.pluginId.startsWith('local:')) {
      final id = c.pluginId.substring('local:'.length);
      context.push('/playlist/$id');
      return;
    }
    context.push(
        '/online-detail',
        extra: OnlineDetailArgs(
          type: type,
          pluginId: c.pluginId,
          title: c.title,
          subtitle: c.subtitle,
          coverUrl: c.coverUrl,
          raw: c.raw,
        ));
  }

  String _pluginName(WidgetRef ref, String id) {
    final source = ref
        .read(pluginManagerProvider)
        .sources
        .where((s) => s.id == id)
        .firstOrNull;
    return source?.name ?? '';
  }
}

class _FavoriteTile extends ConsumerWidget {
  const _FavoriteTile({
    required this.entry,
    required this.onPlay,
    required this.onRemove,
  });

  final FavoriteEntry entry;
  final VoidCallback onPlay;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final m = ListMetrics.ofRef(ref);
    // 捕获封面自身 context：飞封面直接取封面 RenderBox 的全局矩形，与列表封面像素级一致。
    BuildContext? coverCtx;
    Future<void> play() async {
      // 等封面落地后再播放：播放条封面随落地同步更新。
      final ok = await launchFlyCover(
        context,
        coverContext: coverCtx,
        coverSize: m.songCover,
        vPad: m.vPad,
        songPath: entry.path,
        networkUrl: entry.coverUrl,
        radius: m.songRadius,
      );
      if (ok) onPlay();
    }

    final g = songRowPlay(ref, onPlay: play);
    // 长按 / 行尾「更多」：通用歌曲操作弹层（收藏/下一首/加歌单/分享/信息/下载，
    // 与本地音乐列表一致）；菜单「播放」复用完整起播手势（含飞封面）。
    void openActions() => showSongActionsSheet(
          context,
          ref: ref,
          item: entry.toQueueItem(),
          onPlay: play,
        );
    return g.wrap(
      CoverRow(
        cover: Builder(
          builder: (c) {
            coverCtx = c;
            return CoverImage(
              songPath: entry.path,
              networkUrl: entry.coverUrl,
              width: m.songCover,
              height: m.songCover,
              radius: m.songRadius,
              icon: Icons.music_note,
            );
          },
        ),
        onTap: g.onTap,
        onLongPress: openActions,
        title: Text(entry.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style:
                TextStyle(fontSize: m.titleSize, fontWeight: FontWeight.w600)),
        subtitle: Text(
          entry.artist,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style:
              TextStyle(fontSize: m.subtitleSize, color: scheme.onSurfaceVariant),
        ),
        verticalPadding: m.vPad,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SourceTag(
              path: entry.path,
              isOnline: entry.isOnline,
              source: entry.source,
              onlineSongJson: entry.onlineSongJson,
            ),
            const SizedBox(width: 4),
            IconButton(
              icon: Icon(Icons.favorite,
                  size: 20, color: scheme.primary),
              tooltip: tr('取消收藏'),
              onPressed: onRemove,
            ),
            IconButton(
              icon: const Icon(Icons.more_horiz, size: 22),
              color: scheme.onSurfaceVariant,
              tooltip: tr('更多'),
              onPressed: openActions,
            ),
          ],
        ),
      ),
    );
  }
}

/// 单曲收藏的排序选项：none=库原始顺序（默认排序，允许拖拽）。
enum _FavSort { none, title, artist, album, addedAt }

String _favSortLabel(_FavSort s) => switch (s) {
      _FavSort.none => tr('默认排序'),
      _FavSort.title => tr('按标题'),
      _FavSort.artist => tr('按歌手'),
      _FavSort.album => tr('按专辑'),
      _FavSort.addedAt => tr('按添加时间'),
    };

/// 离线程执行的「过滤 + 排序」（compute 回调，须为顶层函数）。
///
/// 每次按键若在 UI 线程对全量收藏做 toLowerCase 会卡顿，故整体搬进后台 isolate。
List<FavoriteEntry> _filterSortFavorites(
    (List<FavoriteEntry>, String, int) args) {
  final (entries, query, sortIdx) = args;
  List<FavoriteEntry> result = entries;
  if (query.isNotEmpty) {
    result = result
        .where((e) =>
            e.title.toLowerCase().contains(query) ||
            e.artist.toLowerCase().contains(query) ||
            e.album.toLowerCase().contains(query))
        .toList();
  }
  final copy = [...result];
  switch (_FavSort.values[sortIdx]) {
    case _FavSort.title:
      copy.sort((a, b) => a.title.compareTo(b.title));
    case _FavSort.artist:
      copy.sort((a, b) {
        final c = a.artist.compareTo(b.artist);
        return c != 0 ? c : a.title.compareTo(b.title);
      });
    case _FavSort.album:
      copy.sort((a, b) {
        final c = a.album.compareTo(b.album);
        return c != 0 ? c : a.title.compareTo(b.title);
      });
    case _FavSort.addedAt:
      copy.sort((a, b) => b.addedAt.compareTo(a.addedAt));
    case _FavSort.none:
      break;
  }
  return copy;
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
