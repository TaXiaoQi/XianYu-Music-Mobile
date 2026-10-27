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
import '../../src/core/page_sort_prefs.dart';
import '../../src/core/pinyin_key.dart';
import '../../src/core/settings.dart';
import '../../src/responsive/landscape.dart';
import '../../src/theme/theme_tint.dart';
import '../../src/download/download_provider.dart';
import '../../src/navigation/shell.dart';
import '../../src/player/player_provider.dart';
import '../../src/plugin/plugin_provider.dart';
import '../../src/widgets/add_to_playlist_sheet.dart';
import '../../src/widgets/app_toast.dart';
import '../../src/widgets/batch_action_bar.dart';
import '../../src/widgets/cover_image.dart';
import '../../src/widgets/drag_handle.dart';
import '../../src/widgets/floating_search_bar.dart';
import '../../src/widgets/flying_cover.dart';
import '../../src/widgets/glass_appbar.dart';
import '../../src/widgets/list_metrics.dart';
import '../../src/widgets/stagger_in.dart';
import '../../src/widgets/mini_player_bar.dart';
import '../../src/widgets/floating_letter_index.dart';
import '../../src/widgets/online_cover.dart';
import '../../src/widgets/sort_dropdown.dart';
import '../../src/widgets/song_actions_sheet.dart';
import '../../src/widgets/song_list_view.dart';
import '../../src/widgets/song_list_scroll_fabs.dart';
import '../../src/widgets/source_tag.dart';
import '../../src/widgets/scrolling_text.dart';
import '../home/online_detail_page.dart';
import '../../src/i18n/i18n.dart';
part 'favorites_page.toolbar.dart';
part 'favorites_page.search_sort.dart';
part 'favorites_page.songs.dart';
part 'favorites_page.collections.dart';

class FavoritesPage extends ConsumerStatefulWidget {
  const FavoritesPage({
    super.key,
    this.initialTab = 0,
    this.paneEmbedded = false,
  });

  final int initialTab;

  /// 横屏音乐库面板专用：锁定面板态布局，与 landscapeLibraryProvider
  /// 解耦（切导航分支时该状态先于退场动画清空，会导致淡出中重建成
  /// 路由态头部闪烁），见 LibraryPage.paneEmbedded
  final bool paneEmbedded;

  @override
  ConsumerState<FavoritesPage> createState() => _FavoritesPageState();
}

class _FavoritesPageState extends ConsumerState<FavoritesPage>
    with SingleTickerProviderStateMixin, HidesShellChrome {
  late final TabController _tab;
  final SongBatchController _batch = SongBatchController();

  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';
  List<FavoriteEntry>? _result;
  Timer? _debounce;
  int _req = 0;
  _FavSort _sort = _FavSort.none;
  bool _sortAsc = true;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this);
    _tab.index = widget.initialTab.clamp(0, 2);
    _batch.addListener(_onBatchChanged);
    // 恢复上次排序档/方向（退出页面不再回落默认）
    unawaited(_loadSortPrefs());
  }

  Future<void> _loadSortPrefs() async {
    final (idx, asc) = await PageSortPrefs.load('favorites');
    if (!mounted) return;
    final sort = _FavSort.values[idx.clamp(0, _FavSort.values.length - 1)];
    setState(() {
      _sort = sort;
      _sortAsc = asc;
    });
    // 收藏可能尚未加载完：非默认展示先算一次，数据到达后由既有
    // favoritesProvider listen 重算兜底
    if ((sort != _FavSort.none || !asc) &&
        ref.read(favoritesProvider).entries.isNotEmpty) {
      _runFilter();
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

  @override
  Widget build(BuildContext context) {
    final fav = ref.watch(favoritesProvider);
    final inMusicPane =
        widget.paneEmbedded || ref.watch(landscapeLibraryProvider) != null;
    final filter = inMusicPane
        ? ref.watch(landscapeLibraryQueryProvider).trim().toLowerCase()
        : '';
    final notifier = ref.read(favoritesProvider.notifier);
    final showBatch = fav.entries.isNotEmpty && _tab.index == 0;
    // 面板态搜索词来自壳层全局顶栏：变化即重跑 filter+sort 管线
    ref.listen(landscapeLibraryQueryProvider, (_, _) {
      if (widget.paneEmbedded || ref.read(landscapeLibraryProvider) != null) {
        _onCriteriaChanged();
      }
    });
    // 过滤/排序生效期间收藏列表变化：重算结果集防止陈旧（移除后行仍显示）
    ref.listen(favoritesProvider, (_, _) {
      if (_sort != _FavSort.none || !_sortAsc || _query.isNotEmpty) {
        _runFilter();
      }
    });
    final tabBar = TabBar(
      controller: _tab,
      onTap: (_) => setState(() {}),
      tabs:   [
        Tab(text: tr('单曲')),
        Tab(text: tr('歌单')),
        Tab(text: tr('专辑')),
      ],
    );
    final floating = ref.watch(
        settingsProvider.select((s) => s.valueOrNull?.floatingSearchBar ?? false));
    final statusBar = MediaQuery.paddingOf(context).top;
    final paneTop = (floating && inMusicPane) ? statusBar + 66 : 0.0;
    const tabBarHeight = 48.0;
    final paneTabBar = showBatch
        ? Row(
            children: [
              Expanded(child: tabBar),
              // 面板态与网盘/本地页统一：tab 右侧带批量 + 排序入口
              // 面板 tab 行已内嵌玻璃面，批量钮用普通图标（不加气泡）
              _batchToggle(context),
              _paneSortToggle(context),
              const SizedBox(width: 4),
            ],
          )
        : tabBar;

    final portraitFloating = !inMusicPane &&
        MediaQuery.of(context).orientation != Orientation.landscape &&
        floating;
    // 横屏固定态：shell 固定带盖住顶部（带内全局 chrome），页面沿用悬浮
    // 玻璃 header 整体下移到带下，不另画贴顶顶栏
    final landscapeFixed = !inMusicPane &&
        MediaQuery.of(context).orientation == Orientation.landscape &&
        !floating;
    final floatHeader = portraitFloating || landscapeFixed;
    final topInset = portraitFloating
        ? statusBar + 8 + 44 + 10 + tabBar.preferredSize.height + 14
        : landscapeFixed
            ? GlassTopBar.height(context, topInset: 8) +
                8 +
                44 +
                10 +
                tabBar.preferredSize.height +
                14
            : 0.0;

    return HideShellChrome(
      child: Scaffold(
        backgroundColor: appScaffoldBackground(context, ref),
        body: Stack(
          children: [
            _tabHost(
              portraitFloating,
              inMusicPane
                  ? paneTop + tabBarHeight + 2
                  : (floatHeader
                      ? topInset
                      : GlassTopBar.height(context, bottom: tabBar)),
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
                    query: inMusicPane ? '' : _query,
                    // 面板态排序同样生效（头部下拉入口）：结果集由 _runFilter
                    // 以壳层搜索词 + 排序档统一计算
                    sort: _sort,
                    sortAsc: _sortAsc,
                    result: _result,
                    showControls: !inMusicPane,
                    onSortChanged: _applySort),
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
            Positioned(
              top: inMusicPane
                  ? paneTop
                  : (portraitFloating
                      ? statusBar + 8
                      : landscapeFixed
                          ? GlassTopBar.height(context, topInset: 8) + 8
                          : 0),
              left: (inMusicPane || floatHeader) ? 12 : 0,
              right: (inMusicPane || floatHeader) ? 12 : 0,
              child: inMusicPane
                  ? (floating
                      ? FloatingTabPill(child: paneTabBar)
                      : _tabBarStrip(context, paneTabBar))
                  : (floatHeader
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
          ],
        ),
      ),
    );
  }
}

class _SongsTabState extends ConsumerState<_SongsTab> {
  final ScrollController _controller = ScrollController();
  final ScrollController _batchController = ScrollController();
  late final StaggerWindow _stagger = StaggerWindow(onClosed: () {
    if (mounted) setState(() {});
  });

  @override
  void initState() {
    super.initState();
    _stagger.start();
  }

  @override
  void dispose() {
    _stagger.dispose();
    _controller.dispose();
    _batchController.dispose();
    super.dispose();
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
        final filtering = widget.query.isNotEmpty ||
            widget.sort != _FavSort.none ||
            // 默认排序降序（倒序展示）同样走 _runFilter 结果集
            !widget.sortAsc;
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
        final rowExtent = m.songCover + 2 * m.vPad;
        final toolPad = (widget.showControls && !inBatch) ? 54.0 : 0.0;

        void onReorder(int oldIndex, int newIndex) {
          if (newIndex < 0 ||
              newIndex >= entries.length ||
              newIndex == oldIndex) {
            return;
          }
          final paths = entries.map((e) => e.path).toList();
          final moved = paths.removeAt(oldIndex);
          paths.insert(newIndex.clamp(0, paths.length), moved);
          widget.notifier.reorderEntries(paths);
        }

        final bottomPad =
            (hasSong ? 92.0 : 24.0) + MediaQuery.of(context).padding.bottom;

        Widget sortBar() {
          final sc = Theme.of(context).colorScheme;
          return ColoredBox(
            color: Theme.of(context).scaffoldBackgroundColor,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
              child: Align(
                alignment: Alignment.centerLeft,
                // 桌面端同款锚定排序下拉（非居中弹窗）
                child: SortMenuButton<_FavSort>(
                  options: _favSortOptions(),
                  current: widget.sort,
                  ascending: widget.sortAsc,
                  isDirectional: _favSortDirectional,
                  defaultAscending: _favSortDefaultAsc,
                  onChanged: widget.onSortChanged,
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
          if (inBatch) {
            final row = CoverRow(
              background: useLandscape(ref)
                  ? themeTintOrNull(ref, 'ls-lib.row')
                  : null,
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

        // 面板态简易过滤（编号行 + 悬浮跳转）仅在未选排序且默认升序时走；
        // 已选排序或默认降序则交由下方 filtering 分支（_runFilter 结果集：
        // 搜索词 + 排序合并计算）
        if (filter.isNotEmpty &&
            widget.sort == _FavSort.none &&
            widget.sortAsc) {
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
                  return _stagger.wrap(
                    i,
                    Stack(
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(left: 34),
                          child: _FavoriteTile(
                            entry: entry,
                            onPlay: () => widget.notifier.play(orig),
                            onRemove: () => widget.notifier.remove(entry.path),
                          ),
                        ),
                        Positioned(
                          left: 8,
                          top: 0,
                          bottom: 0,
                          width: 36,
                          child: Center(
                            child: SongRowLeading(
                              index: i,
                              songPath: entry.path,
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
              SongListScrollFabs(
                controller: _controller,
                paths: visible.map((e) => e.path).toList(),
                rowTopOf: (i) => widget.topInset + i * rowExtent,
                itemExtent: rowExtent,
                bottom: bottomPad + 8,
                right: 12,
              ),
            ],
          );
        }

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
                      background: useLandscape(ref)
                          ? themeTintOrNull(ref, 'ls-lib.row')
                          : null,
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
              else if (_FavSort.values[widget.sort.index] == _FavSort.title ||
                  widget.sort == _FavSort.artist ||
                  widget.sort == _FavSort.album)
                // A-Z 排序视图：右侧悬浮字母索引（滑动滑入，停 2s 滑出）
                FloatingLetterIndex(
                  controller: _controller,
                  itemExtent: rowExtent,
                  topInset: widget.topInset + toolPad,
                  letters: [
                    for (final e in visible)
                      letterOfPinyinKey(
                        widget.sort == _FavSort.artist
                            ? e.artist
                            : widget.sort == _FavSort.album
                                ? e.album
                                : e.title,
                      ),
                  ],
                  child: ListView.builder(
                    controller: _controller,
                    padding: EdgeInsets.only(
                        top: widget.topInset + toolPad, bottom: bottomPad),
                    itemExtent: rowExtent,
                    addAutomaticKeepAlives: false,
                    itemCount: visible.length,
                    itemBuilder: (context, i) {
                      final entry = visible[i];
                      final orig = entries.indexOf(entry);
                      return _stagger.wrap(
                        i,
                        Stack(
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(left: 34),
                              child: _FavoriteTile(
                                entry: entry,
                                onPlay: () => widget.notifier.play(orig),
                                onRemove: () =>
                                    widget.notifier.remove(entry.path),
                              ),
                            ),
                            Positioned(
                              left: 8,
                              top: 0,
                              bottom: 0,
                              width: 36,
                              child: Center(
                                child: SongRowLeading(
                                  index: i,
                                  songPath: entry.path,
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
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
                    return _stagger.wrap(
                      i,
                      Stack(
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(left: 34),
                            child: _FavoriteTile(
                              entry: entry,
                              onPlay: () => widget.notifier.play(orig),
                              onRemove: () => widget.notifier.remove(entry.path),
                            ),
                          ),
                          Positioned(
                            left: 8,
                            top: 0,
                            bottom: 0,
                            width: 36,
                            child: Center(
                              child: SongRowLeading(
                                index: i,
                                songPath: entry.path,
                              ),
                            ),
                          ),
                        ],
                      ),
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
                proxyDecorator: (child, index, animation) =>
                    Material(type: MaterialType.transparency, child: child),
                itemCount: entries.length,
                onReorderItem: onReorder,
                itemBuilder: (context, i) {
                  final entry = entries[i];
                  return RepaintBoundary(
                    key: ValueKey(entry.path),
                    child: _stagger.wrap(
                      i,
                      Stack(
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(left: 34),
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
                            child: Center(
                              child: SongRowLeading(
                                index: i,
                                songPath: entry.path,
                                draggable: true,
                              ),
                            ),
                          ),
                        ],
                      ),
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
      },
    );
  }
}
