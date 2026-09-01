import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';
import '../library/library_provider.dart';
import 'cover_image.dart';
import 'drag_handle.dart';
import 'flying_cover.dart';
import 'list_metrics.dart';
import 'song_actions_sheet.dart';
import 'song_list_scroll_fabs.dart';
import '../i18n/i18n.dart';

/// 歌曲行起播手势装配结果，配合 [songRowPlay] 使用：
///
/// ```dart
/// final g = songRowPlay(ref, onPlay: () => play(i));
/// return g.wrap(ListTile(onTap: g.onTap, ...));
/// ```
class SongRowPlay {
  const SongRowPlay._(this.onTap, this.onDoubleTap);

  /// 挂到行自身（ListTile.onTap）：
  /// - 单击模式：起播回调，点击即水波纹 + 播放；
  /// - 双击模式：空回调，单击仍有水波纹反馈（延迟约 300ms 等待双击窗口结束）。
  final GestureTapCallback? onTap;

  /// 双击模式的起播回调；非 null 时 [wrap] 会把行包进双击识别器。
  final GestureTapCallback? onDoubleTap;

  /// 双击模式下包裹行本体；单击模式原样返回。
  Widget wrap(Widget child) => onDoubleTap == null
      ? child
      : GestureDetector(onDoubleTap: onDoubleTap, child: child);
}

/// 按设置装配歌曲行起播手势（单击/双击播放）。
///
/// 起播必须挂到行自身 onTap：带 onLongPress 的 ListTile 的 InkWell 会注册
/// 自己的 Tap 识别器，且在手势竞技场清扫中作为内层成员必胜——外层
/// GestureDetector 的 onTap 永远被拒绝（曾表现为「点行有水波纹高亮但
/// 不起播」）。双击模式用外层 onDoubleTap 包裹则不受影响：DoubleTap
/// 识别器自行 hold/解析竞技场，内层竞争无法否决它。
SongRowPlay songRowPlay(WidgetRef ref, {VoidCallback? onPlay}) {
  if (onPlay == null) return const SongRowPlay._(null, null);
  final single =
      (ref.read(settingsProvider).valueOrNull?.songClickAction ?? 'single') ==
          'single';
  return single
      ? SongRowPlay._(onPlay, null)
      : SongRowPlay._(() {}, onPlay);
}

/// 大封面列表行：封面、标题、副标题、尾部控件的横向排布。
///
/// 不用 ListTile：其 leading/trailing 高度被钳制在 56px
/// （ListTile.maxIconHeightConstraint），80px 以上的封面会被压扁且行高
/// 不跟随封面增长；本组件行高由封面完整撑开，内边距可调。
class CoverRow extends StatelessWidget {
  const CoverRow({
    super.key,
    required this.cover,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.onLongPress,
    this.horizontalPadding = 16,
    this.verticalPadding = 8,
    this.gap = 12,
  });

  final Widget cover;
  final Widget title;
  final Widget? subtitle;
  final Widget? trailing;
  final GestureTapCallback? onTap;
  final GestureLongPressCallback? onLongPress;
  final double horizontalPadding;
  final double verticalPadding;
  final double gap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: horizontalPadding,
          vertical: verticalPadding,
        ),
        child: Row(
          children: [
            cover,
            SizedBox(width: gap),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  title,
                  if (subtitle != null) ...[
                    const SizedBox(height: 4),
                    subtitle!,
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 8),
              trailing!,
            ],
          ],
        ),
      ),
    );
  }
}

/// 通用歌曲列表：展示歌曲并支持点击播放、长按弹出操作菜单。
///
/// 传入 [onReorder] 时切换为可拖动排序（顶级列表，拖到边缘自动滚动），
/// 行首出现长按把手，排序结果由调用方持久化。
/// 传入 [enableScrollFabs] 时在右下角叠加「回到顶部 / 定位当前播放歌曲」
/// 悬浮按钮（对齐桌面端 SongTable）。
class SongsListView extends ConsumerStatefulWidget {
  final List<Song> songs;
  final Future<void> Function(List<Song> songs, int index)? onPlay;
  /// 列表内边距。全屏页可留出底部安全区，嵌在 shell 内的页面可避让底栏。
  /// 用 [EdgeInsets]（而非 [EdgeInsetsGeometry]）以兼容
  /// ReorderableListView.builder 的 padding 入参类型。
  final EdgeInsets? padding;
  /// 需要高亮的关键词。非空时在标题/歌手/专辑中以主题色标出命中片段。
  final String? highlight;
  /// 长按歌曲是否弹出操作菜单（收藏/添加到歌单/歌曲信息）。
  final bool enableActions;
  /// 非空时启用可拖动排序；onReorderItem 的 newIndex 已随移除项调整。
  final ReorderCallback? onReorder;
  /// 外部提供的滚动控制器（可选）；缺省时内部自建并随组件释放。
  final ScrollController? controller;
  /// 是否叠加「回到顶部 / 定位当前播放歌曲」悬浮按钮。
  final bool enableScrollFabs;
  const SongsListView({
    super.key,
    required this.songs,
    this.onPlay,
    this.padding,
    this.highlight,
    this.enableActions = true,
    this.onReorder,
    this.controller,
    this.enableScrollFabs = false,
  });

  @override
  ConsumerState<SongsListView> createState() => _SongsListViewState();
}

class _SongsListViewState extends ConsumerState<SongsListView> {
  late final ScrollController _controller;
  bool _ownsController = false;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller = widget.controller ?? ScrollController();
  }

  @override
  void dispose() {
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final songs = widget.songs;
    if (songs.isEmpty) {
      return   Center(child: Text(tr('暂无歌曲')));
    }
    // watch：设置页切换单击/双击后列表自动换模式。
    final single =
        (ref.watch(settingsProvider).valueOrNull?.songClickAction ?? 'single') ==
            'single';
    final m = ListMetrics.ofRef(ref);

    final onPlay = widget.onPlay;
    final enableActions = widget.enableActions;
    final highlight = widget.highlight;
    // 组装歌曲行（Builder 提供行自身 context，供飞封面取封面 RenderBox）。
    Widget buildRow(int i) {
      final s = songs[i];
      final hlColor = Theme.of(context).colorScheme.primary;
      return Builder(
        builder: (rowContext) {
          BuildContext? coverCtx;
          final play = onPlay != null
              ? () async {
                  final ok = await launchFlyCover(
                    rowContext,
                    coverContext: coverCtx,
                    coverSize: m.songCover,
                    vPad: m.vPad,
                    songPath: s.path,
                    thumbPath: s.coverThumbPath,
                    radius: m.songRadius,
                  );
                  if (ok) onPlay(songs, i);
                }
              : null;
          final openActions = enableActions
              ? () => showSongActionsSheet(
                    rowContext,
                    ref: ref,
                    item: s.toQueueItem(),
                    onPlay: play,
                  )
              : null;
          final row = CoverRow(
            cover: Builder(
              builder: (c) {
                coverCtx = c;
                return SongCover(song: s, size: m.songCover);
              },
            ),
            title: highlightedText(
              s.title,
              highlight,
              hlColor,
              style: TextStyle(
                  fontSize: m.titleSize, fontWeight: FontWeight.w600),
              maxLines: 1,
            ),
            subtitle: highlightedText(
              '${s.artist} · ${s.album}',
              highlight,
              hlColor,
              style: TextStyle(
                fontSize: m.subtitleSize,
                color: Theme.of(rowContext).colorScheme.onSurfaceVariant,
              ),
              maxLines: 1,
            ),
            verticalPadding: m.vPad,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _fmt(s.duration),
                  style: TextStyle(
                      fontSize: m.subtitleSize,
                      color:
                          Theme.of(rowContext).colorScheme.onSurfaceVariant),
                ),
                if (openActions != null)
                  IconButton(
                    icon: const Icon(Icons.more_horiz, size: 22),
                    color: Theme.of(rowContext).colorScheme.onSurfaceVariant,
                    tooltip: tr('更多'),
                    onPressed: openActions,
                  ),
              ],
            ),
            onTap: play == null ? null : (single ? play : () {}),
            onLongPress: openActions,
          );
          return !single && play != null
              ? GestureDetector(onDoubleTap: play, child: row)
              : row;
        },
      );
    }

    final onReorder = widget.onReorder;
    final padding = widget.padding;
    // 行高固定（封面 + 上下内边距），itemExtent 让 Sliver 按偏移量直接定位，
    // 跳过逐行布局测量，长列表快速滑动更省 CPU（对齐 PiliNara 列表优化）。
    final rowExtent = m.songCover + 2 * m.vPad;
    final Widget list;
    if (onReorder == null) {
      list = ListView.builder(
        controller: _controller,
        padding: padding,
        // 长列表快速滑动时按默认 250px cacheExtent 现建现画，行携带封面会卡在
        // 进场帧而掉帧；提前约半屏（含封面预解码）让滚动只搬运已就绪图层。
        scrollCacheExtent: ScrollCacheExtent.pixels(500),
        // 行不保留状态（封面/标题均为无状态构建），离屏即弃，省内存与重建。
        addAutomaticKeepAlives: false,
        itemExtent: rowExtent,
        itemCount: songs.length,
        // 每行包 RepaintBoundary 隔离成独立合成层：滚动时行内的封面/文本只重绘
        // 自身图层，可被引擎缓存复用，避免整页重绘造成掉帧（与拖拽排序路径对齐）。
        // key 用「路径 + 下标」复合，防止同一首歌多次出现时的重复 Key 断言。
        itemBuilder: (context, i) => RepaintBoundary(
          key: ValueKey('${songs[i].path}_$i'),
          child: buildRow(i),
        ),
      );
    } else {
      list = ReorderableListView.builder(
        scrollController: _controller,
        padding: padding,
        itemExtent: rowExtent,
        // 顶级列表：拖到边缘时自动滚动。
        buildDefaultDragHandles: false,
        // 拖动时被拖项作为 proxy 插入根 Overlay 展示，该层没有 Material 祖先；
        // 行内 CoverRow 的 InkWell 会在拖起瞬间以 debugCheckHasMaterial 报错
        // （表现「拖动就报错」）。补一层透明 Material 提供水波纹上下文。
        proxyDecorator: (child, index, animation) =>
            Material(type: MaterialType.transparency, child: child),
        itemCount: songs.length,
        onReorderItem: onReorder,
        itemBuilder: (context, i) {
          // ReorderableListView 要求最外层带 key 才能拖拽，同时隔离合成层防抽帧。
          // 用「路径 + 下标」复合 Key：同一首歌可多次出现（如歌单多次添加），
          // 若仅用 path 作 key 会在相邻重复项间拖拽时触发重复 Key 断言报错。
          return RepaintBoundary(
            key: ValueKey('${songs[i].path}_$i'),
            child: Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 44),
                  child: buildRow(i),
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
      );
    }

    if (widget.enableScrollFabs) {
      // 悬浮按钮层：右下角「回到顶部 / 定位当前播放歌曲」。
      // bottom 放在列表底部 padding 之上，避开迷你播放条/安全区。
      return Stack(
        children: [
          list,
          SongListScrollFabs(
            controller: _controller,
            songs: songs,
            rowTopOf: (i) => (padding?.top ?? 0.0) + i * rowExtent,
            itemExtent: rowExtent,
            bottom: (padding?.bottom ?? 0.0) + 8,
            right: 12,
          ),
        ],
      );
    }
    return list;
  }

  String _fmt(int s) {
    final m = s ~/ 60;
    final sec = s % 60;
    return '${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }
}

/// 构建关键词高亮文本：命中片段仅改变字体颜色，不加背景色。
///
/// 匹配大小写不敏感，但渲染时保留原文的大小写。keyword 为空或无命中时
/// 返回普通 Text，避免不必要的富文本开销。
Widget highlightedText(
  String source,
  String? keyword,
  Color highlightColor, {
  int? maxLines,
  TextOverflow overflow = TextOverflow.ellipsis,
  TextStyle? style,
}) {
  final kw = keyword?.trim() ?? '';
  if (kw.isEmpty || source.isEmpty) {
    return Text(source,
        style: style, maxLines: maxLines, overflow: overflow);
  }

  final lowerSource = source.toLowerCase();
  final lowerKw = kw.toLowerCase();
  // 无命中时走普通文本。
  if (!lowerSource.contains(lowerKw)) {
    return Text(source,
        style: style, maxLines: maxLines, overflow: overflow);
  }

  final spans = <TextSpan>[];
  var start = 0;
  while (true) {
    final idx = lowerSource.indexOf(lowerKw, start);
    if (idx < 0) {
      // 命中位于末尾时无剩余文本，避免追加空 span。
      if (start < source.length) {
        spans.add(TextSpan(text: source.substring(start)));
      }
      break;
    }
    if (idx > start) {
      spans.add(TextSpan(text: source.substring(start, idx)));
    }
    // 用原文切片保留大小写，仅着色。
    spans.add(TextSpan(
      text: source.substring(idx, idx + kw.length),
      style: TextStyle(color: highlightColor, fontWeight: FontWeight.w700),
    ));
    start = idx + kw.length;
  }

  return Text.rich(
    TextSpan(children: spans, style: style),
    maxLines: maxLines,
    overflow: overflow,
  );
}

class SongCover extends StatelessWidget {
  const SongCover({super.key, required this.song, this.size = 80, this.radius});

  final Song song;

  /// 封面边长；紧凑场景（如搜索结果行）传较小值。
  final double size;

  /// 圆角；null 时按尺寸缩放（80→12，40→6）。
  final double? radius;

  @override
  Widget build(BuildContext context) {
    final r = radius ?? (size >= 60 ? 12.0 : 6.0);
    return CoverImage(
      songPath: song.path,
      thumbPath: song.coverThumbPath,
      width: size,
      height: size,
      radius: r,
    );
  }
}
