import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';
import '../library/library_provider.dart';
import 'batch_action_bar.dart';
import 'cover_image.dart';
import 'drag_handle.dart';
import 'flying_cover.dart';
import 'list_metrics.dart';
import 'song_actions_sheet.dart';
import 'song_list_scroll_fabs.dart';
import '../i18n/i18n.dart';

class SongRowPlay {
  const SongRowPlay._(this.onTap, this.onDoubleTap);

  final GestureTapCallback? onTap;

  final GestureTapCallback? onDoubleTap;

  Widget wrap(Widget child) => onDoubleTap == null
      ? child
      : GestureDetector(onDoubleTap: onDoubleTap, child: child);
}

SongRowPlay songRowPlay(WidgetRef ref, {VoidCallback? onPlay}) {
  if (onPlay == null) return const SongRowPlay._(null, null);
  final single =
      (ref.read(settingsProvider).valueOrNull?.songClickAction ?? 'single') ==
          'single';
  return single
      ? SongRowPlay._(onPlay, null)
      : SongRowPlay._(() {}, onPlay);
}

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

class SongsListView extends ConsumerStatefulWidget {
  final List<Song> songs;
  final Future<void> Function(List<Song> songs, int index)? onPlay;
  final EdgeInsets? padding;
  final String? highlight;
  final bool enableActions;
  final ReorderCallback? onReorder;
  final ScrollController? controller;
  final bool enableScrollFabs;
  final SongBatchController? batch;
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
    this.batch,
  });

  @override
  ConsumerState<SongsListView> createState() => _SongsListViewState();
}

class _SongsListViewState extends ConsumerState<SongsListView> {
  late final ScrollController _controller;
  bool _ownsController = false;
  final ScrollController _batchController = ScrollController();

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller = widget.controller ?? ScrollController();
  }

  @override
  void dispose() {
    if (_ownsController) _controller.dispose();
    _batchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final songs = widget.songs;
    if (songs.isEmpty) {
      return   Center(child: Text(tr('暂无歌曲')));
    }
    final batch = widget.batch;
    final single =
        (ref.watch(settingsProvider).valueOrNull?.songClickAction ?? 'single') ==
            'single';
    final m = ListMetrics.ofRef(ref);

    final onPlay = widget.onPlay;
    final enableActions = widget.enableActions;
    final highlight = widget.highlight;
    Widget buildRow(int i, bool inBatch) {
      final s = songs[i];
      final hlColor = Theme.of(context).colorScheme.primary;
      if (inBatch && batch != null) {
        final row = CoverRow(
          cover: SongCover(song: s, size: m.songCover),
          title: Text(
            s.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: m.titleSize, fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            '${s.artist} · ${s.album}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: m.subtitleSize,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          verticalPadding: m.vPad,
          onTap: () => batch.toggle(s.path),
        );
        return wrapBatchRow(
          context,
          row: row,
          selected: batch.isSelected(s.path),
          onToggle: () => batch.toggle(s.path),
        );
      }
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
    final rowExtent = m.songCover + 2 * m.vPad;
    Widget buildContent() {
      final inBatch = batch != null && batch.batchMode;
      final Widget list;
      if (onReorder == null || inBatch) {
        list = ListView.builder(
          controller: inBatch ? _batchController : _controller,
          padding: padding,
          scrollCacheExtent: ScrollCacheExtent.pixels(500),
          addAutomaticKeepAlives: false,
          itemExtent: rowExtent,
          itemCount: songs.length,
          itemBuilder: (context, i) => RepaintBoundary(
            key: ValueKey('${songs[i].path}_$i'),
            child: buildRow(i, inBatch),
          ),
        );
      } else {
        list = ReorderableListView.builder(
          scrollController: _controller,
          padding: padding,
          itemExtent: rowExtent,
          buildDefaultDragHandles: false,
          proxyDecorator: (child, index, animation) =>
              Material(type: MaterialType.transparency, child: child),
          itemCount: songs.length,
          onReorderItem: onReorder,
          itemBuilder: (context, i) {
            return RepaintBoundary(
              key: ValueKey('${songs[i].path}_$i'),
              child: Stack(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: 44),
                    child: buildRow(i, false),
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

      Widget result = list;
      if (widget.enableScrollFabs && !inBatch) {
        result = Stack(
          children: [
            list,
            SongListScrollFabs(
              controller: _controller,
              paths: songs.map((s) => s.path).toList(),
              rowTopOf: (i) => (padding?.top ?? 0.0) + i * rowExtent,
              itemExtent: rowExtent,
              bottom: (padding?.bottom ?? 0.0) + 8,
              right: 12,
            ),
          ],
        );
      }
      return result;
    }

    if (batch != null) {
      return ListenableBuilder(
        listenable: batch,
        builder: (context, _) => buildContent(),
      );
    }
    return buildContent();
  }

  String _fmt(int s) {
    final m = s ~/ 60;
    final sec = s % 60;
    return '${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }
}

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
  if (!lowerSource.contains(lowerKw)) {
    return Text(source,
        style: style, maxLines: maxLines, overflow: overflow);
  }

  final spans = <TextSpan>[];
  var start = 0;
  while (true) {
    final idx = lowerSource.indexOf(lowerKw, start);
    if (idx < 0) {
      if (start < source.length) {
        spans.add(TextSpan(text: source.substring(start)));
      }
      break;
    }
    if (idx > start) {
      spans.add(TextSpan(text: source.substring(start, idx)));
    }
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

  final double size;

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
