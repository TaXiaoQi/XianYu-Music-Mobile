import 'dart:async';

import 'package:flutter/foundation.dart'
    show compute;
import 'package:xianyu_music_mobile/src/widgets/predictive_dialog_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/navigation/shell.dart';
import '../../src/core/app_colors.dart';
import '../../src/core/settings.dart';
import '../../src/player/player_provider.dart';
import '../../src/recent/recent_provider.dart';
import '../../src/widgets/bottom_play_bar_slot.dart';
import '../../src/widgets/cover_image.dart';
import '../../src/widgets/flying_cover.dart';
import '../../src/widgets/glass_appbar.dart';
import '../../src/widgets/list_metrics.dart';
import '../../src/widgets/sheet_dialog.dart';
import '../../src/widgets/song_list_view.dart';
import '../../src/widgets/song_list_scroll_fabs.dart';
import '../../src/widgets/source_tag.dart';
import '../../src/i18n/i18n.dart';

/// 最近播放页：展示播放历史，支持点播/移除/清空、竖屏搜索与排序。
class RecentPage extends ConsumerStatefulWidget {
  const RecentPage({super.key});

  @override
  ConsumerState<RecentPage> createState() => _RecentPageState();
}

class _RecentPageState extends ConsumerState<RecentPage> {
  /// 竖屏页内搜索（非面板）：标题栏输入，过滤播放记录。
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';

  /// 最近一次离线程「过滤+排序」结果；null 表示无过滤/排序，用原始顺序。
  List<RecentEntry>? _result;
  Timer? _debounce;
  int _req = 0;
  _RecentSort _sort = _RecentSort.none;

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  /// 查询/排序任一生效即视为过滤态。
  bool get _filtering => _query.isNotEmpty || _sort != _RecentSort.none;

  void _onSearchChanged(String v) {
    setState(() => _query = v.trim().toLowerCase());
    _onCriteriaChanged();
  }

  /// 查询/排序任一变化后立即刷新界面并防抖调度离线程重算。
  void _onCriteriaChanged() {
    setState(() {});
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 160), _runFilter);
  }

  Future<void> _runFilter() async {
    final gen = ++_req;
    final entries = ref.read(recentProvider).entries;
    final rows = [
      for (final e in entries)
        (
          title: _recentTitle(e),
          artist: _recentArtist(e),
          playedAt: e.playedAt,
        )
    ];
    final out = await compute(
      _filterSortRecent,
      (rows, _query, _sort.index),
    );
    if (!mounted || gen != _req) return;
    setState(() {
      _result = [for (final i in out) entries[i]];
    });
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

  /// 打开排序选择弹窗（统一弹窗风格）。
  Future<void> _openSortMenu(BuildContext context) async {
    final v = await showSheetDialog<_RecentSort>(
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
            for (final s in _RecentSort.values)
              _SortItem(
                label: _recentSortLabel(s),
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
    final recent = ref.watch(recentProvider);
    // 面板模式下隐藏本页顶部 GlassTopBar（由外层横屏胶囊顶栏占位）。
    final inMusicPane = ref.watch(landscapeLibraryProvider) != null;
    // 横屏 pane 内：全局顶栏搜索承担本地过滤（按曲名/歌手过滤）。
    final filter = inMusicPane
        ? ref.watch(landscapeLibraryQueryProvider).trim().toLowerCase()
        : '';
    final notifier = ref.read(recentProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    // 横屏音乐库面板模式下统一继承壳层全局顶栏：页内只保留一个『清空』内容头，
    // 位于全局顶栏下方（悬浮模式按顶栏高度下移）。
    final floating = ref.watch(
        settingsProvider.select((s) => s.valueOrNull?.floatingSearchBar ?? false));
    final statusBar = MediaQuery.paddingOf(context).top;
    final paneTop = (floating && inMusicPane) ? statusBar + 66 : 0.0;
    // 有记录时渲染「清空」内容头，否则直接以全局顶栏为头。
    final hasHeader = inMusicPane && recent.entries.isNotEmpty;
    // 竖屏悬浮顶栏（非面板）：顶栏自动换装玻璃胶囊组，播放记录列表铺满
    // 全屏、滚动时从顶栏下方穿过（穿透观感，与歌单页同口径）。
    final portraitFloating = !inMusicPane &&
        MediaQuery.of(context).orientation != Orientation.landscape &&
        floating;

    // 页内搜索/排序结果列表；null 表示无过滤/排序，用原始顺序（含面板全局过滤）。
    // 面板模式沿用全局顶栏搜索，页内搜索/排序让位。
    final items = (!inMusicPane && _filtering) ? _result : null;
    // 竖屏非面板模式显示排序工具栏（对齐本地页）。
    final showControls = !inMusicPane;

    return HideShellChrome(
      child: Scaffold(
        backgroundColor: appScaffoldBackground(context, ref),
        body: Stack(
          children: [
            // 竖屏悬浮：列表视口铺满全屏，避让量注入列表内部 padding，
            // 滚动时内容从顶栏胶囊下方穿过；固定/面板沿用原 Padding 避让。
            if (portraitFloating && !recent.loading && recent.entries.isNotEmpty)
              // 必须用非定位（非 Positioned）全尺寸子项撑起 body Stack，否则
              // Stack 只剩定位子项坍缩成 0×0（悬浮顶栏开启白屏）。
              SizedBox.expand(
                child: _RecentList(
                  recent: recent,
                  notifier: notifier,
                  filter: filter,
                  contentTop: GlassTopBar.height(context) + 6,
                  items: items,
                  showSortBar: showControls,
                  sort: _sort,
                  onOpenSort: () => _openSortMenu(context),
                ),
              )
            else
              Padding(
                padding: EdgeInsets.only(
                  // 面板模式下内容头在全局顶栏下方，内容按内容头避让；非面板模式
                  // 沿用完整 GlassTopBar 高度避让。
                  top: inMusicPane
                      ? paneTop + (hasHeader ? 48 : 8)
                      : GlassTopBar.height(context),
                ),
                child: recent.loading
                    ? const Center(child: CircularProgressIndicator())
                    : recent.entries.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.history,
                                    size: 48,
                                    color: scheme.onSurface
                                        .withValues(alpha: 0.25)),
                                const SizedBox(height: 12),
                                Text(
                                  tr('暂无播放记录'),
                                  style: TextStyle(
                                      fontSize: 14,
                                      color: scheme.onSurfaceVariant),
                                ),
                              ],
                            ),
                          )
                        : _RecentList(
                            recent: recent,
                            notifier: notifier,
                            filter: filter,
                            items: items,
                            showSortBar: showControls,
                            sort: _sort,
                            onOpenSort: () => _openSortMenu(context),
                          ),
              ),
            // 内容头：面板模式仅保留右侧「清空」；非面板模式完整 GlassTopBar。
            if (inMusicPane)
              Positioned(
                top: paneTop,
                left: (inMusicPane && floating) ? 12 : 0,
                right: (inMusicPane && floating) ? 12 : 0,
                child: hasHeader
                    ? Align(
                        alignment: Alignment.centerRight,
                        child: IconButton(
                          icon: const Icon(Icons.delete_sweep_outlined),
                          tooltip: tr('清空'),
                          onPressed: () => _confirmClear(context, notifier),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            if (!inMusicPane)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: GlassTopBar(
                  leading: const BackButton(),
                  // 竖屏/非面板模式下标题栏内联搜索框（过滤播放记录，对齐本地页）。
                  title: _buildSearchField(context),
                  actions: [
                    if (recent.entries.isNotEmpty)
                      IconButton(
                        icon: const Icon(Icons.delete_sweep_outlined),
                        tooltip: tr('清空'),
                        onPressed: () => _confirmClear(context, notifier),
                      ),
                  ],
                ),
              ),
            // 统一播放条由外壳承载：横屏面板模式下不渲染页内嵌条。
            if (!inMusicPane) const BottomPlayBarSlot(),
          ],
        ),
      ),
    );
  }

  void _confirmClear(BuildContext context, RecentManager notifier) {
    showPredictiveDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title:   Text(tr('清空最近播放')),
        content:   Text(tr('确定要清空全部播放记录吗？')),
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

/// 最近播放列表：独立订阅播放状态以调整底部留白，播放状态翻转不波及页头。
/// 右下角叠加「回到顶部 / 定位当前播放歌曲」悬浮按钮。
class _RecentList extends ConsumerStatefulWidget {
  const _RecentList({
    required this.recent,
    required this.notifier,
    this.filter = '',
    this.contentTop,
    this.items,
    this.showSortBar = false,
    this.sort = _RecentSort.none,
    required this.onOpenSort,
  });

  final RecentState recent;
  final RecentManager notifier;

  /// 竖屏悬浮顶栏模式的顶部避让量：注入列表滚动 padding.top，内容穿透
  /// 顶栏胶囊；null=固定/面板模式，无额外顶距。
  final double? contentTop;

  /// 横屏音乐库 pane 的本地过滤关键词（已小写）；空=不过滤。
  final String filter;

  /// 竖屏页内「过滤+排序」结果列表；null 表示无过滤/排序，用原始顺序。
  final List<RecentEntry>? items;

  /// 竖屏非面板模式显示排序工具栏（对齐本地页）。
  final bool showSortBar;

  /// 当前排序，用于工具栏标签。
  final _RecentSort sort;

  final VoidCallback onOpenSort;

  @override
  ConsumerState<_RecentList> createState() => _RecentListState();
}

class _RecentListState extends ConsumerState<_RecentList> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool _match(RecentEntry e, String f) {
    if (f.isEmpty) return true;
    final item = e.toQueueItem();
    final title = item?.title ?? _titleFromPath(e.songPath);
    final artist = item?.artist ?? '';
    return title.toLowerCase().contains(f) ||
        artist.toLowerCase().contains(f) ||
        e.songPath.toLowerCase().contains(f);
  }

  String _titleFromPath(String p) {
    final name = p.split(RegExp(r'[\\/]')).last;
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  @override
  Widget build(BuildContext context) {
    final hasSong = ref.watch(playerProvider.select((s) => s.current != null));
    final m = ListMetrics.ofRef(ref);
    // 行高固定（封面 + 上下内边距），itemExtent 让 Sliver 按偏移量直接定位，
    // 跳过逐行布局测量，大列表快速滑动更省 CPU（对齐统一 SongsListView）。
    final rowExtent = m.songCover + 2 * m.vPad;
    final bottomPad =
        (hasSong ? 92.0 : 24.0) + MediaQuery.of(context).padding.bottom;

    final topExtent = widget.contentTop ?? 0;
    // 竖屏非面板排序工具栏（对齐本地页），高度供列表顶部避让。
    final sortPad = widget.showSortBar ? 54.0 : 0.0;

    final all = widget.recent.entries;
    final filter = widget.filter;
    // 页内搜索/排序生效时用离线程结果；否则走原始顺序 + 面板全局过滤。
    final items = widget.items;
    final visible =
        items ?? (filter.isEmpty ? all : all.where((e) => _match(e, filter)).toList());

    if (visible.isEmpty) {
      final scheme = Theme.of(context).colorScheme;
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_off,
                size: 40, color: scheme.onSurface.withValues(alpha: 0.25)),
            const SizedBox(height: 12),
            Text(
              items != null || filter.isNotEmpty
                  ? tr('没有找到相关歌曲')
                  : tr('暂无播放记录'),
              style:
                  TextStyle(fontSize: 14, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }

    return Stack(
      children: [
        ListView.builder(
          controller: _controller,
          padding: EdgeInsets.only(
              top: topExtent + sortPad, bottom: bottomPad),
          itemExtent: rowExtent,
          // 提前半屏预缓存，避免新行进场时突然解码封面掉帧（对齐 SongsListView）。
          scrollCacheExtent: ScrollCacheExtent.pixels(500),
          // 行不保留状态（封面/标题均无状态构建），离屏即弃，省内存与重建。
          addAutomaticKeepAlives: false,
          itemCount: visible.length,
          itemBuilder: (context, i) {
            final entry = visible[i];
            final orig = all.indexOf(entry);
            return _RecentTile(
              entry: entry,
              onPlay: () => widget.notifier.play(orig),
              onRemove: () => widget.notifier.remove(entry.songPath),
            );
          },
        ),
        SongListScrollFabs(
          controller: _controller,
          paths: visible.map((e) => e.songPath).toList(),
          rowTopOf: (i) => topExtent + sortPad + i * rowExtent,
          itemExtent: rowExtent,
          bottom: bottomPad + 8,
          right: 12,
        ),
        // 竖屏非面板排序工具栏：默认(时间)排序即原始顺序。
        if (widget.showSortBar)
          Positioned(
            top: topExtent,
            left: 0,
            right: 0,
            child: _buildSortBar(context),
          ),
      ],
    );
  }

  /// 排序工具栏（对齐本地页竖屏二级页，仅含排序选择）。
  Widget _buildSortBar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
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
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.sort, size: 18, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      _recentSortLabel(widget.sort),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 13, color: scheme.onSurfaceVariant),
                    ),
                  ),
                  Icon(Icons.arrow_drop_down,
                      size: 18, color: scheme.onSurfaceVariant),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RecentTile extends ConsumerWidget {
  const _RecentTile({
    required this.entry,
    required this.onPlay,
    required this.onRemove,
  });

  final RecentEntry entry;
  final VoidCallback onPlay;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final m = ListMetrics.ofRef(ref);
    final item = entry.toQueueItem();
    final title = item?.title ?? _titleFromPath(entry.songPath);
    final artist = item?.artist ?? '';

    // 捕获封面自身 context：飞封面直接取封面 RenderBox 的全局矩形，与列表封面像素级一致。
    BuildContext? coverCtx;
    final g = songRowPlay(ref, onPlay: () async {
      // 等封面落地后再播放：播放条封面随落地同步更新。
      final ok = await launchFlyCover(
        context,
        coverContext: coverCtx,
        coverSize: m.songCover,
        vPad: m.vPad,
        songPath: entry.songPath,
        networkUrl: item?.coverUrl,
        radius: m.songRadius,
      );
      if (ok) onPlay();
    });
    return g.wrap(
      CoverRow(
        horizontalPadding: 16,
        verticalPadding: m.vPad,
        onTap: g.onTap,
        onLongPress: () => onRemove(),
        cover: Builder(
          builder: (c) {
            coverCtx = c;
            return CoverImage(
              songPath: entry.songPath,
              networkUrl: item?.coverUrl,
              width: m.songCover,
              height: m.songCover,
              radius: m.songRadius,
              icon: Icons.music_note,
            );
          },
        ),
        title: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: m.titleSize,
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: Text(
          artist.isEmpty
              ? _timeText(entry.playedAt)
              : '$artist · ${_timeText(entry.playedAt)}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: m.subtitleSize,
            color: scheme.onSurfaceVariant,
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SourceTag(
              path: entry.songPath,
              isOnline:
                  item?.isOnline ?? _isOnlinePath(entry.songPath),
              source: item?.source,
              onlineSongJson: item?.onlineSongJson,
            ),
            const SizedBox(width: 4),
            IconButton(
              icon: Icon(Icons.close, size: 18, color: scheme.outline),
              tooltip: tr('移除'),
              onPressed: onRemove,
            ),
          ],
        ),
      ),
    );
  }

  /// 由路径判定是否为在线歌曲（无元数据时可仅凭路径识别来源标签）。
  bool _isOnlinePath(String p) =>
      p.startsWith('lx://') || p.startsWith('plugin://');

  String _titleFromPath(String p) {
    final name = p.split(RegExp(r'[\\/]')).last;
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  String _timeText(int ms) {
    if (ms <= 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(dt.year, dt.month, dt.day);
    final diff = today.difference(day).inDays;
    final hm = '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    if (diff == 0) return tr('今天 {hm}', {'hm': hm});
    if (diff == 1) return tr('昨天 {hm}', {'hm': hm});
    if (diff < 7) return tr('{m}月{d}日 {hm}', {'m': dt.month, 'd': dt.day, 'hm': hm});
    return tr('{y}年{m}月{d}日', {'y': dt.year, 'm': dt.month, 'd': dt.day});
  }
}

/// 播放记录的排序选项：none=播放时间（原始顺序）。
enum _RecentSort { none, title, artist, time }

String _recentSortLabel(_RecentSort s) => switch (s) {
      _RecentSort.none => tr('默认排序'),
      _RecentSort.time => tr('按播放时间'),
      _RecentSort.title => tr('按标题'),
      _RecentSort.artist => tr('按歌手'),
    };

/// 离线程取标题/歌手（compute 回调无法跨 isolate 携带 Song/QueueItem，
/// 故由调用方在 UI 线程先把纯文本记录摊平后传入）。
String _recentTitle(RecentEntry e) {
  final item = e.toQueueItem();
  final t = item?.title;
  if (t != null && t.isNotEmpty) return t;
  final name = e.songPath.split(RegExp(r'[\\/]')).last;
  final dot = name.lastIndexOf('.');
  return dot > 0 ? name.substring(0, dot) : name;
}

String _recentArtist(RecentEntry e) => e.toQueueItem()?.artist ?? '';

/// 离线程执行的「过滤 + 排序」（compute 回调，须为顶层函数）。
/// 返回原始下标（进入原始 entries 的索引）。
List<int> _filterSortRecent(
    (List<({String title, String artist, int playedAt})>, String, int) args) {
  final (rows, query, sortIdx) = args;
  final indices = List<int>.generate(rows.length, (i) => i);
  List<int> result = indices;
  if (query.isNotEmpty) {
    result = indices.where((i) {
      final r = rows[i];
      return r.title.toLowerCase().contains(query) ||
          r.artist.toLowerCase().contains(query);
    }).toList();
  }
  result.sort((a, b) {
    final A = rows[a];
    final B = rows[b];
    switch (_RecentSort.values[sortIdx]) {
      case _RecentSort.title:
        return A.title.compareTo(B.title);
      case _RecentSort.artist:
        final c = A.artist.compareTo(B.artist);
        return c != 0 ? c : A.title.compareTo(B.title);
      case _RecentSort.time:
      case _RecentSort.none:
        final c = B.playedAt.compareTo(A.playedAt);
        return c != 0 ? c : A.title.compareTo(B.title);
    }
  });
  return result;
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
