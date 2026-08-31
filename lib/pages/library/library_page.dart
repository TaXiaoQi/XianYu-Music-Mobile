import 'dart:async';

import 'package:flutter/foundation.dart'
    show compute;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../src/core/app_colors.dart';
import '../../src/library/library_provider.dart';
import '../../src/navigation/shell.dart';
import '../../src/player/player_provider.dart';
import '../../src/widgets/cover_image.dart';
import '../../src/widgets/glass_appbar.dart';
import '../../src/widgets/list_metrics.dart';
import '../../src/widgets/mini_player_bar.dart';
import '../../src/widgets/sheet_dialog.dart';
import '../../src/widgets/song_list_view.dart';
import '../../src/widgets/letter_index_song_list.dart';
import 'song_list_page.dart';
import '../../src/i18n/i18n.dart';

/// 本地曲库：全部 / 歌手 / 专辑（从「我的」页进入的二级页面）。
///
/// 歌单与收藏入口已分流到「我的」页；本页专注本地曲库浏览。
/// 「文件夹」页已独立为 [LibraryFolderPage]（顶部搜索框右侧「+」进入）。
class LibraryPage extends ConsumerStatefulWidget {
  const LibraryPage({super.key, this.initialTab = 0});

  /// 初始 Tab：0 全部 / 1 歌手 / 2 专辑。
  final int initialTab;

  @override
  ConsumerState<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends ConsumerState<LibraryPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;

  /// 整页搜索：从标题栏输入，跨整个本地页（任意 Tab）过滤歌曲。
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';

  /// 最近一次离线程搜索结果；null 表示正在计算或暂无输入。
  List<Song>? _searchResult;
  Timer? _searchDebounce;
  int _searchReq = 0;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this);
    _tab.index = widget.initialTab.clamp(0, 2);
  }

  @override
  void dispose() {
    _tab.dispose();
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onSearchChanged(String v) {
    setState(() => _query = v.trim().toLowerCase());
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 160), _runSearch);
  }

  /// 在后台 isolate 过滤「标题/歌手/专辑」，避免逐键在 UI 线程对全量歌曲卡顿。
  Future<void> _runSearch() async {
    final gen = ++_searchReq;
    final q = _query;
    final songs = ref.read(libraryProvider).songs;
    if (q.isEmpty) {
      if (mounted) setState(() => _searchResult = null);
      return;
    }
    final out = await compute(
      _filterSortSongs,
      (songs, q, _SongSort.none.index, false),
    );
    if (!mounted || gen != _searchReq) return;
    setState(() => _searchResult = out);
  }

  void _clearSearch() {
    _searchCtrl.clear();
    _searchDebounce?.cancel();
    setState(() {
      _query = '';
      _searchResult = null;
    });
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

  /// 整页搜索结果列表（跨 Tab 生效），带关键词高亮。
  Widget _buildSearchResults() {
    final result = _searchResult;
    if (result == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (result.isEmpty) {
      return   Center(child: Text(tr('没有找到相关歌曲')));
    }
    return SongsListView(
      songs: result,
      highlight: _query,
      padding: EdgeInsets.only(
        bottom: (ref.watch(playerProvider.select((s) => s.current != null)) ? 92.0 : 16.0) +
            MediaQuery.of(context).padding.bottom,
      ),
      onPlay: (list, i) =>
          ref.read(libraryProvider.notifier).playList(list, i),
    );
  }

  @override
  Widget build(BuildContext context) {
    final lib = ref.watch(libraryProvider);
    // 面板模式下隐藏本页顶部 GlassTopBar（由外层横屏胶囊顶栏占位）。
    final inMusicPane = ref.watch(landscapeLibraryProvider) != null;

    // 大数量压缩显示，避免均分 Tab 宽度不足时文字被截断。
    String fmt(int n) => n >= 10000
        ? '${(n / 10000).toStringAsFixed(n >= 100000 ? 0 : 1)}万'
        : '$n';

    final tabBar = TabBar(
      controller: _tab,
      isScrollable: false,
      tabs: [
        Tab(text: '全部 ${fmt(lib.songs.length)}'),
        Tab(text: '歌手 ${fmt(lib.artists.length)}'),
        Tab(text: '专辑 ${fmt(lib.albums.length)}'),
      ],
    );

    return HideShellChrome(
      child: Scaffold(
        backgroundColor: appScaffoldBackground(context, ref),
        resizeToAvoidBottomInset: false,
        body: RepaintBoundary(child: Stack(
          children: [
            Padding(
              // 面板模式下仍保留 TabBar，故内容顶部始终按顶栏高度（含 TabBar）避让。
              padding: EdgeInsets.only(
                top: GlassTopBar.height(context, bottom: tabBar),
              ),
              child: lib.loading
                  ? const Center(child: CircularProgressIndicator())
                  : lib.error != null
                      ? _ErrorView(
                          message: lib.error!,
                          onRetry: () =>
                              ref.read(libraryProvider.notifier).load(),
                        )
                      : _query.isNotEmpty
                          ? _buildSearchResults()
                          : TabBarView(
                              controller: _tab,
                              children: [
                                _AllSongsTab(),
                                _ArtistsTab(),
                                _AlbumsTab(),
                              ],
                            ),
            ),
            // 面板模式下保留 TabBar，仅去掉 leading / title（搜索框）/ actions。
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: GlassTopBar(
                leading: inMusicPane ? null : const BackButton(),
                titleSpacing: 4,
                title: inMusicPane ? null : _buildSearchField(context),
                actions: [
                  // 文件夹页入口（已从 Tab 独立为二级页）。
                  IconButton(
                    tooltip: tr('文件夹'),
                    onPressed: () => context.push('/library/folders'),
                    icon: const Icon(Icons.add, size: 24),
                  ),
                ],
                bottom: tabBar,
              ),
            ),
            // 统一播放条由外壳承载：横屏面板模式下不渲染页内嵌条。
            if (!inMusicPane && lib.songs.isNotEmpty)
              const MiniPlayerBar(),
          ],
        ),
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label:   Text(tr('重试')),
          ),
        ],
      ),
    );
  }
}

/// 离线程执行的「过滤 + 去重 + 排序」（compute 回调，须为顶层函数）。
///
/// 每次按键若在 UI 线程对全库做 toLowerCase 会卡顿，故整体搬进后台 isolate。
List<Song> _filterSortSongs((List<Song>, String, int, bool) args) {
  final (songs, query, sortIdx, hideDuplicates) = args;
  List<Song> result = songs;
  if (query.isNotEmpty) {
    result = result
        .where((s) =>
            s.title.toLowerCase().contains(query) ||
            s.artist.toLowerCase().contains(query) ||
            s.album.toLowerCase().contains(query))
        .toList();
  }
  if (hideDuplicates) {
    final seen = <String, String>{};
    result = result.where((s) {
      final key = '${s.title.toLowerCase()}|${s.artist.toLowerCase()}';
      if (seen.containsKey(key)) return false;
      seen[key] = s.path;
      return true;
    }).toList();
  }
  final copy = [...result];
  switch (_SongSort.values[sortIdx]) {
    case _SongSort.title:
      copy.sort((a, b) => a.title.compareTo(b.title));
    case _SongSort.artist:
      copy.sort((a, b) {
        final c = a.artist.compareTo(b.artist);
        return c != 0 ? c : a.title.compareTo(b.title);
      });
    case _SongSort.album:
      copy.sort((a, b) {
        final c = a.album.compareTo(b.album);
        return c != 0 ? c : a.title.compareTo(b.title);
      });
    case _SongSort.addedAt:
    case _SongSort.none:
      break;
  }
  return copy;
}

/// 全部歌曲（支持本地搜索）。
class _AllSongsTab extends ConsumerStatefulWidget {
  @override
  ConsumerState<_AllSongsTab> createState() => _AllSongsTabState();
}

class _AllSongsTabState extends ConsumerState<_AllSongsTab> {
  /// 排序方式；null 表示保持库默认顺序。
  _SongSort _sort = _SongSort.none;
  bool _hideDuplicates = false;

  /// 最近一次离线程计算结果；null 表示尚未计算，直接展示库原始顺序。
  List<Song>? _result;
  Timer? _debounce;
  int _req = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  /// 查询/排序/去重任一变化后立即刷新界面，并防抖调度一次离线程重算，
  /// 避免逐键在 UI 线程对全量歌曲做 toLowerCase 造成卡顿。
  void _onCriteriaChanged() {
    setState(() {});
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 160), _runFilter);
  }

  Future<void> _runFilter() async {
    final gen = ++_req;
    final songs = ref.read(libraryProvider).songs;
    final out = await compute(
      _filterSortSongs,
      (songs, '', _sort.index, _hideDuplicates),
    );
    if (!mounted || gen != _req) return;
    setState(() => _result = out);
  }

  @override
  Widget build(BuildContext context) {
    final lib = ref.watch(libraryProvider);
    final songs = _result ?? lib.songs;
    final scheme = Theme.of(context).colorScheme;

    return Column(
      children: [
        // 工具栏：排序 / 去重 / 统计
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Row(
            children: [
              Expanded(
                child: DropdownButton<_SongSort>(
                  value: _sort,
                  isExpanded: true,
                  underline: const SizedBox.shrink(),
                  items:   [
                    DropdownMenuItem(value: _SongSort.none, child: Text(tr('默认排序'))),
                    DropdownMenuItem(value: _SongSort.title, child: Text(tr('按标题'))),
                    DropdownMenuItem(value: _SongSort.artist, child: Text(tr('按歌手'))),
                    DropdownMenuItem(value: _SongSort.album, child: Text(tr('按专辑'))),
                    DropdownMenuItem(value: _SongSort.addedAt, child: Text(tr('按添加时间'))),
                  ],
                  onChanged: (v) {
                    _sort = v ?? _SongSort.none;
                    _onCriteriaChanged();
                  },
                ),
              ),
              const SizedBox(width: 4),
              Tooltip(
                message: _hideDuplicates ? tr('已隐藏重复歌曲') : tr('隐藏重复歌曲'),
                child: IconButton(
                  icon: Icon(
                    _hideDuplicates ? Icons.flip_to_front : Icons.flip_to_back,
                    color: _hideDuplicates ? scheme.primary : null,
                  ),
                  onPressed: () {
                    _hideDuplicates = !_hideDuplicates;
                    _onCriteriaChanged();
                  },
                ),
              ),
              IconButton(
                icon: const Icon(Icons.bar_chart),
                tooltip: tr('曲库统计'),
                onPressed: () => _showStats(context, lib),
              ),
            ],
          ),
        ),
        Expanded(
          child: songs.isEmpty
              ?   Center(child: Text(tr('没有匹配的歌曲')))
              : _sort == _SongSort.none
                  // 默认排序：支持长按把手拖动排序（顶级列表，拖到边缘自动滚动）。
                  ? SongsListView(
                      songs: songs,
                      padding: EdgeInsets.only(
                        bottom: (ref.watch(playerProvider.select((s) => s.current != null))
                                ? 92.0
                                : 16.0) +
                            MediaQuery.of(context).padding.bottom,
                      ),
                      onPlay: (list, i) =>
                          ref.read(libraryProvider.notifier).playList(list, i),
                      onReorder: (oldIndex, newIndex) {
                        if (newIndex < 0 ||
                            newIndex >= songs.length ||
                            newIndex == oldIndex) {
                          return;
                        }
                        final paths = [for (final s in songs) s.path];
                        final moved = paths.removeAt(oldIndex);
                        // onReorderItem 的 newIndex 已随移除项调整。
                        paths.insert(newIndex.clamp(0, paths.length), moved);
                        ref
                            .read(libraryProvider.notifier)
                            .reorderLocalSongs(paths);
                      },
                    )
                  : LetterIndexSongList(
                      songs: songs,
                      // 仅按字母序字段排序时才启用 A-Z 索引条；默认/添加时间无意义。
                      indexField: switch (_sort) {
                        _SongSort.title => (Song s) => s.title,
                        _SongSort.artist => (Song s) => s.artist,
                        _SongSort.album => (Song s) => s.album,
                        _SongSort.none || _SongSort.addedAt => null,
                      },
                      padding: EdgeInsets.only(
                        bottom: (ref.watch(playerProvider.select((s) => s.current != null))
                                ? 92.0
                                : 16.0) +
                            MediaQuery.of(context).padding.bottom,
                      ),
                      onPlay: (list, i) =>
                          ref.read(libraryProvider.notifier).playList(list, i),
                    ),
        ),
      ],
    );
  }

  void _showStats(BuildContext context, LibraryState lib) {
    final total = lib.songs.length;
    final durationMs =
        lib.songs.fold<int>(0, (sum, s) => sum + s.duration * 1000);
    final formatMap = <String, int>{};
    for (final s in lib.songs) {
      final f = s.format.isEmpty ? tr('未知') : s.format.toUpperCase();
      formatMap[f] = (formatMap[f] ?? 0) + 1;
    }
    final formats = formatMap.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    showSheetDialog<void>(
      context,
      (ctx) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
              Text(tr('曲库统计'),
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 14),
            _StatRow(label: tr('歌曲总数'), value: '$total 首'),
            _StatRow(label: tr('总时长'), value: _fmtDuration(durationMs)),
            _StatRow(label: tr('歌手'), value: '${lib.artists.length} 位'),
            _StatRow(label: tr('专辑'), value: '${lib.albums.length} 张'),
            _StatRow(label: tr('文件夹'), value: '${lib.folders.length} 个'),
            if (formats.isNotEmpty) ...[
              const SizedBox(height: 14),
              for (final f in formats)
                _StatRow(label: f.key, value: '${f.value} 首'),
            ],
            const SizedBox(height: 8),
            Icon(TextDirection.ltr == TextDirection.ltr ? Icons.info_outline : Icons.info_outline,
              size: 14, color: Theme.of(ctx).colorScheme.outline),
            const SizedBox(height: 4),
            Text(tr('统计基于本地曲库'), style: TextStyle(fontSize: 11, color: Theme.of(ctx).colorScheme.outline)),
          ],
        ),
      ),
    );
  }

  String _fmtDuration(int ms) {
    final sec = (ms / 1000).round();
    final h = sec ~/ 3600;
    final m = (sec % 3600) ~/ 60;
    if (h > 0) return '$h 小时 $m 分钟';
    return '$m 分钟';
  }
}

enum _SongSort { none, title, artist, album, addedAt }

class _StatRow extends StatelessWidget {
  const _StatRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 13.5)),
          Text(
            value,
            style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: scheme.primary),
          ),
        ],
      ),
    );
  }
}

/// 歌手目录。
class _ArtistsTab extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final artists = ref.watch(libraryProvider.select((s) => s.artists));
    if (artists.isEmpty) return   Center(child: Text(tr('暂无歌手')));
    final m = ListMetrics.ofRef(ref);
    return ListView.builder(
      padding: EdgeInsets.only(
        bottom: (ref.watch(playerProvider.select((s) => s.current != null)) ? 92.0 : 16.0) +
            MediaQuery.of(context).padding.bottom,
      ),
      // 行高固定（封面 + 上下内边距），itemExtent 跳过逐行测量，长列表滚动更省。
      itemExtent: m.artistCover + 2 * m.vPad,
      addAutomaticKeepAlives: false,
      itemCount: artists.length,
      itemBuilder: (context, i) {
        final a = artists[i];
        final scheme = Theme.of(context).colorScheme;
        return RepaintBoundary(
          // key 用歌手名，滚动时该行图层可缓存复用，避免整页重绘。
          key: ValueKey('artist_${a.name}'),
          child: CoverRow(
          cover: CoverImage(
            songPath: a.firstSongPath,
            width: m.artistCover,
            height: m.artistCover,
            radius: m.artistCover / 2,
            icon: Icons.person,
            placeholder: _letterAvatar(context, a.name, scheme),
          ),
          title: Text(
            a.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: m.titleSize, fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            '${a.count} 首',
            style:
                TextStyle(fontSize: m.subtitleSize, color: scheme.onSurfaceVariant),
          ),
          verticalPadding: m.vPad,
          trailing: Icon(Icons.chevron_right, color: scheme.outline),
          onTap: () => Navigator.of(context, rootNavigator: true).push(
            MaterialPageRoute(
              builder: (_) => SongListPage(
                title: a.name,
                loader: () =>
                    ref.read(libraryProvider.notifier).songsByArtist(a.name),
              ),
            ),
          ),
          ),
        );
      },
    );
  }
}

/// 歌手无封面时的字母头像占位。
Widget _letterAvatar(BuildContext context, String name, ColorScheme scheme) {
  return DecoratedBox(
    decoration: BoxDecoration(
      color: scheme.primaryContainer,
      shape: BoxShape.circle,
    ),
    child: Center(
      child: Text(
        name.isEmpty ? '?' : String.fromCharCode(name.runes.first),
        style: TextStyle(color: scheme.onPrimaryContainer),
      ),
    ),
  );
}

/// 专辑目录。
class _AlbumsTab extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final albums = ref.watch(libraryProvider.select((s) => s.albums));
    if (albums.isEmpty) return   Center(child: Text(tr('暂无专辑')));
    final m = ListMetrics.ofRef(ref);
    return ListView.builder(
      padding: EdgeInsets.only(
        bottom: (ref.watch(playerProvider.select((s) => s.current != null)) ? 92.0 : 16.0) +
            MediaQuery.of(context).padding.bottom,
      ),
      // 行高固定（封面 + 上下内边距），itemExtent 跳过逐行测量，长列表滚动更省。
      itemExtent: m.songCover + 2 * m.vPad,
      addAutomaticKeepAlives: false,
      itemCount: albums.length,
      itemBuilder: (context, i) {
        final a = albums[i];
        final scheme = Theme.of(context).colorScheme;
        return RepaintBoundary(
          key: ValueKey('album_${a.key}'),
          child: CoverRow(
          cover: CoverImage(
            songPath: a.firstSongPath,
            width: m.songCover,
            height: m.songCover,
            radius: m.songRadius,
            icon: Icons.album,
          ),
          title: Text(
            a.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: m.titleSize, fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            '${a.artist} · ${a.count} 首',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style:
                TextStyle(fontSize: m.subtitleSize, color: scheme.onSurfaceVariant),
          ),
          verticalPadding: m.vPad,
          trailing: Icon(Icons.chevron_right, color: scheme.outline),
          onTap: () => Navigator.of(context, rootNavigator: true).push(
            MaterialPageRoute(
              builder: (_) => SongListPage(
                title: a.name,
                loader: () =>
                    ref.read(libraryProvider.notifier).songsByAlbum(a.key),
              ),
            ),
          ),
          ),
        );
      },
    );
  }
}
