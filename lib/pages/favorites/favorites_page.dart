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

class FavoritesPage extends ConsumerStatefulWidget {
  const FavoritesPage({super.key, this.initialTab = 0});

  final int initialTab;

  @override
  ConsumerState<FavoritesPage> createState() => _FavoritesPageState();
}

class _FavoritesPageState extends ConsumerState<FavoritesPage>
    with SingleTickerProviderStateMixin {
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
            if (!inMusicPane) const BottomPlayBarSlot(),
          ],
        ),
      ),
    );
  }

  Widget _tabHost(bool floating, double dockedTop, Widget child) {
    if (floating) return SizedBox.expand(child: child);
    return Padding(
      padding: EdgeInsets.only(top: dockedTop),
      child: child,
    );
  }

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
    final paths =
        ref.read(favoritesProvider).entries.map((e) => e.path).toList();
    if (await shouldAskFavoriteDeleteScope(ref, paths)) {
      if (!context.mounted) return;
      final scope = await resolveFavoriteDeleteScope(context, ref, paths);
      if (!context.mounted) return;
      if (scope == null) return;
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

  final String filter;

  final double topInset;

  final String query;

  final _FavSort sort;

  final List<FavoriteEntry>? result;

  final bool showControls;

  final VoidCallback onOpenSort;

  @override
  ConsumerState<_SongsTab> createState() => _SongsTabState();
}

class _SongsTabState extends ConsumerState<_SongsTab> {
  final ScrollController _controller = ScrollController();
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
    if (!await dn.requireDownloadDir(context)) return;
    final localSkipped = selected.where((e) => !e.isOnline).length;
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
    if (await shouldAskFavoriteDeleteScope(ref, paths)) {
      if (!mounted) return;
      final scope = await resolveFavoriteDeleteScope(context, ref, paths);
      if (!mounted) return;
      if (scope == null) return;
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

class _CollectionsTab extends ConsumerWidget {
  const _CollectionsTab({
    required this.fav,
    required this.kind,
    this.filter = '',
    this.topInset = 0,
  });

  final FavoritesState fav;
  final String kind;

  final String filter;

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
    BuildContext? coverCtx;
    Future<void> play() async {
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

enum _FavSort { none, title, artist, album, addedAt }

String _favSortLabel(_FavSort s) => switch (s) {
      _FavSort.none => tr('默认排序'),
      _FavSort.title => tr('按标题'),
      _FavSort.artist => tr('按歌手'),
      _FavSort.album => tr('按专辑'),
      _FavSort.addedAt => tr('按添加时间'),
    };

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
