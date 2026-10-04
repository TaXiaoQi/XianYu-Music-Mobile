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
import '../../src/widgets/online_cover.dart';
import '../../src/widgets/sheet_dialog.dart';
import '../../src/widgets/song_actions_sheet.dart';
import '../../src/widgets/song_list_view.dart';
import '../../src/widgets/song_list_scroll_fabs.dart';
import '../../src/widgets/source_tag.dart';
import '../home/online_detail_page.dart';
import '../../src/i18n/i18n.dart';
part 'favorites_page.toolbar.dart';
part 'favorites_page.search_sort.dart';
part 'favorites_page.songs.dart';
part 'favorites_page.collections.dart';

class FavoritesPage extends ConsumerStatefulWidget {
  const FavoritesPage({super.key, this.initialTab = 0});

  final int initialTab;

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

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this);
    _tab.index = widget.initialTab.clamp(0, 2);
    _batch.addListener(_onBatchChanged);
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
    final inMusicPane = ref.watch(landscapeLibraryProvider) != null;
    final filter = inMusicPane
        ? ref.watch(landscapeLibraryQueryProvider).trim().toLowerCase()
        : '';
    final notifier = ref.read(favoritesProvider.notifier);
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
    final floating = ref.watch(
        settingsProvider.select((s) => s.valueOrNull?.floatingSearchBar ?? false));
    final statusBar = MediaQuery.paddingOf(context).top;
    final paneTop = (floating && inMusicPane) ? statusBar + 66 : 0.0;
    const tabBarHeight = 48.0;
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

    final portraitFloating = !inMusicPane &&
        MediaQuery.of(context).orientation != Orientation.landscape &&
        floating;
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
                  return _stagger.wrap(
                    i,
                    Stack(
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(left: 44),
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
                            padding: const EdgeInsets.only(left: 44),
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
