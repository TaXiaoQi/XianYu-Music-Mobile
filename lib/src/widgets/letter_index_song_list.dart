import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pinyin/pinyin.dart';

import '../core/settings.dart';
import '../library/library_provider.dart';
import 'flying_cover.dart';
import 'list_metrics.dart';
import 'song_actions_sheet.dart';
import 'song_list_view.dart';
import '../i18n/i18n.dart';

/// 分组项：某首字母对应的歌曲区间。
class _IndexGroup {
  _IndexGroup(this.letter, this.startIndex, this.cou);
  final String letter;

  /// 该分组首歌在 [songs] 中的原始下标。
  final int startIndex;
  final int cou;

  _IndexGroup add() => _IndexGroup(letter, startIndex, cou + 1);
}

/// 求某字段的索引导航首字母（A-Z；数字/非中英文字符归入 '#'）。
String _initialOf(String text) {
  final raw = text.trim();
  if (raw.isEmpty) return '#';
  final code = raw.runes.first;
  if (code >= 0x41 && code <= 0x5A) return raw.substring(0, 1);
  if (code >= 0x61 && code <= 0x7A) return String.fromCharCode(code - 0x20);
  if (code >= 0x30 && code <= 0x39) return '#';
  final py = PinyinHelper.getFirstWordPinyin(raw.substring(0, 1));
  if (py.isEmpty) return '#';
  final c = py.toUpperCase().substring(0, 1);
  return (c.codeUnitAt(0) >= 0x41 && c.codeUnitAt(0) <= 0x5A) ? c : '#';
}

int _groupRank(String letter) => letter == '#' ? 27 : letter.codeUnitAt(0) - 0x41;

/// 首字母分组：字母升序（A-Z 在前，'#' 殿后）。
List<_IndexGroup> _buildGroups(List<Song> songs, String Function(Song) field) {
  final entries = <_IndexGroup>[];
  final idx = <String, int>{};
  for (var i = 0; i < songs.length; i++) {
    final letter = _initialOf(field(songs[i]));
    final j = idx[letter];
    if (j == null) {
      idx[letter] = entries.length;
      entries.add(_IndexGroup(letter, i, 1));
    } else {
      entries[j] = entries[j].add();
    }
  }
  entries.sort((a, b) => _groupRank(a.letter).compareTo(_groupRank(b.letter)));
  return entries;
}

/// 带字母索引导航的歌曲列表：按 [indexField] 分组，行间插入分组表头，
/// 右侧悬浮 A-Z 索引条支持拖拽/点按快速定位。
///
/// 行渲染复用 [SongsListView] 的原语（飞封面、长按操作菜单、关键词高亮），
/// 但分组表头导致下标错位，无法直接复用其扁平 [ListView.builder]，故独立实现。
class LetterIndexSongList extends ConsumerStatefulWidget {
  final List<Song> songs;

  /// 索引字段取值器（如 `(s) => s.title`）。非空时按该字段首字母分组并显示
  /// 索引条；传 null 则退化为无表头无索引条的扁平渲染。
  final String Function(Song)? indexField;
  final Future<void> Function(List<Song> songs, int index)? onPlay;
  /// 用 [EdgeInsets] 以兼容内嵌 [SongsListView] 的 padding 入参类型。
  final EdgeInsets? padding;
  final String? highlight;
  final bool enableActions;
  const LetterIndexSongList({
    super.key,
    required this.songs,
    this.indexField,
    this.onPlay,
    this.padding,
    this.highlight,
    this.enableActions = true,
  });

  @override
  ConsumerState<LetterIndexSongList> createState() =>
      _LetterIndexSongListState();
}

class _LetterIndexSongListState extends ConsumerState<LetterIndexSongList> {
  static const double _headerExtent = 26;

  final ScrollController _controller = ScrollController();
  final ValueNotifier<String> _active = ValueNotifier('');

  /// 最近一次 build 的分组缓存，供滚动监听复用，避免每帧重算。
  List<_IndexGroup>? _groups;
  double _rowExtent = 0;
  double _padTop = 0;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScrolled);
  }

  @override
  void dispose() {
    _controller.dispose();
    _active.dispose();
    super.dispose();
  }

  void _onScrolled() {
    final groups = _groups;
    if (groups == null || !_controller.hasClients) return;
    final off = _controller.offset;
    String? cur;
    for (var i = 0; i < groups.length; i++) {
      if (_headerPixel(groups, i) <= off + 4) cur = groups[i].letter;
    }
    if (cur != null && cur != _active.value) _active.value = cur;
  }

  /// 该分组表头顶部的滚动位置（与 [ListView.builder] 扁平布局一致）。
  double _headerPixel(List<_IndexGroup> groups, int gi) {
    var songsBefore = 0;
    for (var i = 0; i < gi; i++) {
      songsBefore += groups[i].cou;
    }
    return gi * _headerExtent + songsBefore * _rowExtent;
  }

  void _jumpToLetter(String letter, List<_IndexGroup> groups) {
    if (!_controller.hasClients) return;
    for (var i = 0; i < groups.length; i++) {
      if (groups[i].letter == letter) {
        final g = groups[i];
        final target = i * _headerExtent + g.startIndex * _rowExtent + _padTop;
        _controller.jumpTo(
            target.clamp(0.0, _controller.position.maxScrollExtent));
        _active.value = letter;
        return;
      }
    }
  }

  bool get _singleClick =>
      (ref.read(settingsProvider).valueOrNull?.songClickAction ?? 'single') ==
      'single';

  @override
  Widget build(BuildContext context) {
    final songs = widget.songs;
    if (songs.isEmpty) return   Center(child: Text(tr('暂无歌曲')));
    final field = widget.indexField;
    if (field == null) {
      return SongsListView(
        songs: songs,
        onPlay: widget.onPlay,
        padding: widget.padding,
        highlight: widget.highlight,
        enableActions: widget.enableActions,
      );
    }

    final m = ListMetrics.ofRef(ref);
    _rowExtent = m.songCover + 2 * m.vPad;
    _padTop = widget.padding?.resolve(Directionality.of(context)).top ?? 0.0;
    final groups = _buildGroups(songs, field);
    _groups = groups;
    final keys = groups.map((g) => g.letter).toList(growable: false);

    final total = songs.length + groups.length;
    final songAt = List<int>.filled(total, -1);
    final flatGroup = List<int>.filled(total, -1);
    var cursor = 0;
    for (var gi = 0; gi < groups.length; gi++) {
      final g = groups[gi];
      flatGroup[cursor] = gi;
      cursor++;
      for (var k = 0; k < g.cou; k++) {
        songAt[cursor] = g.startIndex + k;
        cursor++;
      }
    }

    final single = _singleClick;

    return Stack(
      children: [
        ListView.builder(
          controller: _controller,
          padding: widget.padding,
          // 提前约半屏预渲染，避免快速滑动时行连同封面在进场帧现建现画而抽帧。
          scrollCacheExtent: ScrollCacheExtent.pixels(500),
          // 行不保留状态，离屏即弃，省内存与重建（分组表头/歌曲行均无持久状态）。
          addAutomaticKeepAlives: false,
          itemCount: total,
          itemBuilder: (context, i) {
            final gIdx = flatGroup[i];
            if (gIdx >= 0) {
              // 分组表头也包一层：滚动时整列表逐行复用缓存，避免整页重绘。
              return RepaintBoundary(
                child: _HeaderTile(
                    letter: groups[gIdx].letter, cou: groups[gIdx].cou),
              );
            }
            final si = songAt[i];
            // 歌曲行包 RepaintBoundary 隔离合成层：与默认列表路径对齐，
            // 滚动时只重绘进/出可见区的行，可缓存图层避免掉帧。
            // key 用分组下标+歌曲原始下标复合，避免重复 Key。
            return RepaintBoundary(
              key: ValueKey('${si}_$gIdx'),
              child: _SongRowItem(
                song: songs[si],
                originalIndex: si,
                songs: songs,
                single: single,
                onPlay: widget.onPlay,
                highlight: widget.highlight,
                enableActions: widget.enableActions,
              ),
            );
          },
        ),
        Positioned(
          top: _padTop,
          bottom: 0,
          right: 2,
          child: IgnorePointer(
            ignoring: keys.length <= 2,
            child: _AlphabetIndexBar(
              keys: keys,
              active: _active,
              onSelect: (c) => _jumpToLetter(c, groups),
            ),
          ),
        ),
      ],
    );
  }
}

/// 分组表头：首字母 + 本组数量。
class _HeaderTile extends StatelessWidget {
  final String letter;
  final int cou;
  const _HeaderTile({required this.letter, required this.cou});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      alignment: Alignment.centerLeft,
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
      child: Text(
        tr('{letter} · {n} 首', {'letter': letter, 'n': cou}),
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
          color: scheme.primary,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

/// 歌曲行：与 [SongsListView] 行渲染一致（飞封面/操作菜单/高亮）。
class _SongRowItem extends ConsumerWidget {
  final Song song;
  final int originalIndex;
  final List<Song> songs;
  final bool single;
  final Future<void> Function(List<Song> songs, int index)? onPlay;
  final String? highlight;
  final bool enableActions;
  const _SongRowItem({
    required this.song,
    required this.originalIndex,
    required this.songs,
    required this.single,
    required this.onPlay,
    required this.highlight,
    required this.enableActions,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = ListMetrics.ofRef(ref);
    final s = song;
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
                if (ok) onPlay!(songs, originalIndex);
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
                    color: Theme.of(rowContext).colorScheme.onSurfaceVariant),
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

  String _fmt(int s) {
    final m = s ~/ 60;
    final sec = s % 60;
    return '${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }
}

/// 右侧 A-Z 字母索引条：可拖拽/点按，当前分组字母高亮放大。
class _AlphabetIndexBar extends StatelessWidget {
  final List<String> keys;
  final ValueNotifier<String> active;
  final ValueChanged<String> onSelect;
  const _AlphabetIndexBar({
    required this.keys,
    required this.active,
    required this.onSelect,
  });

  static const double _item = 17;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<String>(
      valueListenable: active,
      builder: (context, cur, _) {
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragDown: (d) => onSelect(_pick(d.localPosition.dy)),
          onVerticalDragUpdate: (d) => onSelect(_pick(d.localPosition.dy)),
          onTapDown: (d) => onSelect(_pick(d.localPosition.dy)),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final k in keys)
                  SizedBox(
                    width: 22,
                    height: _item,
                    child: Center(
                      child: Text(
                        k,
                        style: TextStyle(
                          fontSize: k == cur ? 12 : 10,
                          fontWeight:
                              k == cur ? FontWeight.w800 : FontWeight.w500,
                          color: k == cur
                              ? scheme.primary
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _pick(double dy) {
    final idx = (dy / _item).floor().clamp(0, keys.length - 1);
    return keys[idx];
  }
}