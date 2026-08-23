import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';
import '../library/library_provider.dart';
import 'song_actions_sheet.dart';

/// 歌曲行的播放点击手势：按「单击/双击播放」设置决定触发方式。
///
/// - 单击模式：`onTap` 触发 [onPlay]（此时调用方应把行的 onTap 置空，由本组件承担播放）。
/// - 双击模式：`onDoubleTap` 触发 [onPlay]，单击不做任何事（避免误触播放）。
class SongRowPlayGesture extends ConsumerWidget {
  final Widget child;
  final VoidCallback? onPlay;
  final bool enabled;
  const SongRowPlayGesture({
    super.key,
    required this.child,
    this.onPlay,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!enabled || onPlay == null) return child;
    final single =
        (ref.watch(settingsProvider).valueOrNull?.songClickAction ?? 'single') ==
            'single';
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: single ? onPlay : null,
      onDoubleTap: single ? null : onPlay,
      child: child,
    );
  }
}

/// 歌曲行的播放点击手势（见 [SongRowPlayGesture] 的说明）：
/// 供 favorite/recent 等非共享列表复用，避免重复读取设置。
Widget songRowPlayGesture(
  BuildContext context,
  WidgetRef ref,
  Widget child, {
  VoidCallback? onPlay,
  bool enabled = true,
}) {
  if (!enabled || onPlay == null) return child;
  final single =
      (ref.read(settingsProvider).valueOrNull?.songClickAction ?? 'single') ==
          'single';
  return GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: single ? onPlay : null,
    onDoubleTap: single ? null : onPlay,
    child: child,
  );
}

/// 通用歌曲列表：展示歌曲并支持点击播放、长按弹出操作菜单。
class SongsListView extends ConsumerWidget {
  final List<Song> songs;
  final Future<void> Function(List<Song> songs, int index)? onPlay;
  /// 列表内边距。全屏页可留出底部安全区，嵌在 shell 内的页面可避让底栏。
  final EdgeInsetsGeometry? padding;
  /// 需要高亮的关键词。非空时在标题/歌手/专辑中以主题色标出命中片段。
  final String? highlight;
  /// 长按歌曲是否弹出操作菜单（收藏/添加到歌单/歌曲信息）。
  final bool enableActions;
  const SongsListView({
    super.key,
    required this.songs,
    this.onPlay,
    this.padding,
    this.highlight,
    this.enableActions = true,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (songs.isEmpty) {
      return const Center(child: Text('暂无歌曲'));
    }
    return ListView.separated(
      padding: padding,
      itemCount: songs.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final s = songs[i];
        final hlColor = Theme.of(context).colorScheme.primary;
        return SongRowPlayGesture(
          onPlay: onPlay != null ? () => onPlay!(songs, i) : null,
          child: ListTile(
            leading: SongCover(song: s),
            title: highlightedText(
              s.title,
              highlight,
              hlColor,
              maxLines: 1,
            ),
            subtitle: highlightedText(
              '${s.artist} · ${s.album}',
              highlight,
              hlColor,
              maxLines: 1,
            ),
            trailing: Text(
              _fmt(s.duration),
              style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
            onLongPress: enableActions
                ? () => showSongActionsSheet(
                      context,
                      ref: ref,
                      item: s.toQueueItem(),
                      onPlay:
                          onPlay != null ? () => onPlay!(songs, i) : null,
                    )
                : null,
          ),
        );
      },
    );
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
}) {
  final kw = keyword?.trim() ?? '';
  if (kw.isEmpty || source.isEmpty) {
    return Text(source, maxLines: maxLines, overflow: overflow);
  }

  final lowerSource = source.toLowerCase();
  final lowerKw = kw.toLowerCase();
  // 无命中时走普通文本。
  if (!lowerSource.contains(lowerKw)) {
    return Text(source, maxLines: maxLines, overflow: overflow);
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
    TextSpan(children: spans),
    maxLines: maxLines,
    overflow: overflow,
  );
}

class SongCover extends StatelessWidget {
  const SongCover({super.key, required this.song});
  final Song song;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      alignment: Alignment.center,
      child: Icon(Icons.music_note,
          size: 20, color: Theme.of(context).colorScheme.onPrimaryContainer),
    );
  }
}
