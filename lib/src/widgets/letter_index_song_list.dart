import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pinyin/pinyin.dart';

import '../core/settings.dart';
import '../library/library_provider.dart';
import 'batch_action_bar.dart';
import 'flying_cover.dart';
import 'list_metrics.dart';
import 'song_actions_sheet.dart';
import 'song_list_scroll_fabs.dart';
import 'song_list_view.dart';
import '../i18n/i18n.dart';

class _IndexGroup {
  _IndexGroup(this.letter, this.startIndex, this.cou);
  final String letter;

  final int startIndex;
  final int cou;

  _IndexGroup add() => _IndexGroup(letter, startIndex, cou + 1);
}

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

class LetterIndexSongList extends ConsumerStatefulWidget {
  final List<Song> songs;

  final String Function(Song)? indexField;
  final Future<void> Function(List<Song> songs, int index)? onPlay;
  final EdgeInsets? padding;
  final String? highlight;
  final bool enableActions;
  final bool enableScrollFabs;
  final SongBatchController? batch;
  const LetterIndexSongList({
    super.key,
    required this.songs,
    this.indexField,
    this.onPlay,
    this.padding,
    this.highlight,
    this.enableActions = true,
    this.enableScrollFabs = false,
    this.batch,
  });

  @override
  ConsumerState<LetterIndexSongList> createState() =>
      _LetterIndexSongListState();
}

class _LetterIndexSongListState extends ConsumerState<LetterIndexSongList> {
  static const double _headerExtent = 26;

  final ScrollController _controller = ScrollController();
  final ValueNotifier<String> _active = ValueNotifier('');

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

  double _headerPixel(List<_IndexGroup> groups, int gi) {
    var songsBefore = 0;
    for (var i = 0; i < gi; i++) {
      songsBefore += groups[i].cou;
    }
    return gi * _headerExtent + songsBefore * _rowExtent;
  }

  double _rowTopOf(int songIndex) {
    final groups = _groups;
    if (groups == null) return _padTop;
    var before = _padTop;
    for (final g in groups) {
      if (songIndex >= g.startIndex && songIndex < g.startIndex + g.cou) {
        before += (songIndex - g.startIndex) * _rowExtent;
        return before;
      }
      before += _headerExtent + g.cou * _rowExtent;
    }
    return _padTop;
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
    final batch = widget.batch;
    if (field == null) {
      return SongsListView(
        songs: songs,
        onPlay: widget.onPlay,
        padding: widget.padding,
        highlight: widget.highlight,
        enableActions: widget.enableActions,
        enableScrollFabs: widget.enableScrollFabs,
        batch: batch,
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

    Widget buildContent() {
      final inBatch = batch != null && batch.batchMode;
      return Stack(
        children: [
          ListView.builder(
            controller: _controller,
            padding: widget.padding,
            scrollCacheExtent: ScrollCacheExtent.pixels(500),
            addAutomaticKeepAlives: false,
            itemCount: total,
            itemBuilder: (context, i) {
              final gIdx = flatGroup[i];
              if (gIdx >= 0) {
                return RepaintBoundary(
                  child: _HeaderTile(
                      letter: groups[gIdx].letter, cou: groups[gIdx].cou),
                );
              }
              final si = songAt[i];
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
                  inBatch: inBatch,
                  batch: batch,
                ),
              );
            },
          ),
          if (!inBatch)
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
          if (widget.enableScrollFabs && !inBatch)
            SongListScrollFabs(
              controller: _controller,
              paths: songs.map((s) => s.path).toList(),
              rowTopOf: _rowTopOf,
              itemExtent: _rowExtent,
              bottom: (widget.padding?.bottom ?? 0.0) + 8,
              right: 40,
            ),
        ],
      );
    }

    if (batch != null) {
      return ListenableBuilder(
        listenable: batch,
        builder: (context, _) => buildContent(),
      );
    }
    return buildContent();
  }
}

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

class _SongRowItem extends ConsumerWidget {
  final Song song;
  final int originalIndex;
  final List<Song> songs;
  final bool single;
  final Future<void> Function(List<Song> songs, int index)? onPlay;
  final String? highlight;
  final bool enableActions;
  final bool inBatch;
  final SongBatchController? batch;
  const _SongRowItem({
    required this.song,
    required this.originalIndex,
    required this.songs,
    required this.single,
    required this.onPlay,
    required this.highlight,
    required this.enableActions,
    required this.inBatch,
    this.batch,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = ListMetrics.ofRef(ref);
    final s = song;
    final hlColor = Theme.of(context).colorScheme.primary;
    if (inBatch) {
      final batch = this.batch!;
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