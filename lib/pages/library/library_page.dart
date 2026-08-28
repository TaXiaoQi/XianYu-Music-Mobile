import 'package:xianyu_music_mobile/src/widgets/predictive_dialog_route.dart';
import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart'
    show compute;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../src/core/app_colors.dart';
import '../../src/core/settings.dart';
import '../../src/library/library_provider.dart';
import '../../src/library/saf_channel.dart';
import '../../src/library/scan_settings_provider.dart';
import '../../src/navigation/shell.dart';
import '../../src/widgets/app_toast.dart';
import '../../src/player/player_provider.dart';
import '../../src/widgets/cover_image.dart';
import '../../src/widgets/glass_appbar.dart';
import '../../src/widgets/list_metrics.dart';
import '../../src/widgets/mini_player_bar.dart';
import '../../src/widgets/sheet_dialog.dart';
import '../../src/widgets/song_list_view.dart';
import '../settings/folder_picker_page.dart';
import '../../src/widgets/letter_index_song_list.dart';
import 'song_list_page.dart';
import '../../src/i18n/i18n.dart';

/// 本地曲库：全部 / 歌手 / 专辑 / 文件夹（从「我的」页进入的二级页面）。
///
/// 歌单与收藏入口已分流到「我的」页；本页专注本地曲库浏览。
/// 「文件夹」页为扫描歌曲一体化界面（参考魅族：扫描引导 + 过滤 + 目录管理 + 文件夹树）。
class LibraryPage extends ConsumerStatefulWidget {
  const LibraryPage({super.key, this.initialTab = 0});

  /// 初始 Tab：0 全部 / 1 歌手 / 2 专辑 / 3 文件夹。
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
    _tab = TabController(length: 4, vsync: this);
    _tab.index = widget.initialTab.clamp(0, 3);
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
        Tab(text: '文件夹 ${fmt(lib.folderRoot.length)}'),
      ],
    );

    return HideShellChrome(
      child: Scaffold(
        backgroundColor: appScaffoldBackground(context, ref),
        resizeToAvoidBottomInset: false,
        body: RepaintBoundary(child: Stack(
          children: [
            Padding(
              padding: EdgeInsets.only(top: GlassTopBar.height(context, bottom: tabBar)),
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
                                _FoldersTab(),
                              ],
                            ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: GlassTopBar(
                leading: const BackButton(),
                titleSpacing: 4,
                title: _buildSearchField(context),
                bottom: tabBar,
              ),
            ),
            if (lib.songs.isNotEmpty)
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
        return CoverRow(
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
        return CoverRow(
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
        );
      },
    );
  }
}

/// 文件夹页：扫描歌曲一体化界面（参考魅族音乐「扫描歌曲」）。
///
/// 由原「扫描文件夹」设置页与「排除短音频」设置项合并而来：
/// 顶部扫描引导（图标 + 开始扫描）→ 过滤设置（按时长过滤）→ 扫描目录管理
/// （添加 / 移除 / 重新授权）→ 已扫描文件夹树（浏览 / 播放 / 导入歌单）。
class _FoldersTab extends ConsumerStatefulWidget {
  @override
  ConsumerState<_FoldersTab> createState() => _FoldersTabState();
}

class _FoldersTabState extends ConsumerState<_FoldersTab> {
  final Set<String> _expanded = {};
  bool _scanning = false;
  bool _adding = false;

  /// 关闭「按时长过滤」时记住上次的阈值，重新开启时恢复。
  int _lastDuration = 60;

  @override
  void initState() {
    super.initState();
    // 进入本页即刷新各 SAF 目录的授权状态（失效目录显示红标与重新授权按钮）。
    Future.microtask(() {
      if (mounted) {
        ref.read(libraryProvider.notifier).checkSafFolderAuthorization();
      }
    });
  }

  void _toast(String msg) {
    if (!mounted) return;
    showXianYuToast(context, msg, duration: const Duration(seconds: 2));
  }

  /// 申请存储权限（按 Android 版本细分，仅申请音乐读取）。
  Future<bool> _ensureStoragePermission() async {
    if (!Platform.isAndroid) return true;
    if (await Permission.audio.isGranted) return true;
    if (await Permission.storage.isGranted) return true;
    final audio = await Permission.audio.request();
    if (audio.isGranted) return true;
    final storage = await Permission.storage.request();
    if (storage.isGranted) return true;
    if (audio.isPermanentlyDenied && storage.isPermanentlyDenied) {
      await openAppSettings();
    }
    return false;
  }

  /// 添加扫描目录：应用内文件夹选择页（MediaStore），无权限时回退系统 SAF。
  Future<void> _addFolder() async {
    setState(() => _adding = true);
    try {
      if (Platform.isAndroid) {
        final granted = await _ensureStoragePermission();
        if (!mounted) return;
        if (granted) {
          final count = await Navigator.of(context, rootNavigator: true)
              .push<int>(
                  MaterialPageRoute(builder: (_) => const FolderPickerPage()));
          if (count != null && mounted) {
            _toast(count > 0 ? '已添加扫描目录，扫描到 $count 首' : tr('已添加扫描目录'));
          }
          return;
        }
        await _addFolderViaSaf();
        return;
      }
      final granted = await _ensureStoragePermission();
      if (!granted) {
        _toast(tr('未授予存储权限，无法扫描本地文件夹'));
        return;
      }
      final dir = await FilePicker.getDirectoryPath();
      if (dir == null) return;
      if (dir.startsWith('content://')) {
        _toast(tr('该位置无法直接访问，请选择本地存储（如音乐、Download）下的文件夹'));
        return;
      }
      await ref.read(scanFoldersProvider.notifier).addFolder(dir);
      _toast(tr('已添加扫描目录'));
    } catch (e) {
      _toast('添加失败：$e');
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  /// 经系统 SAF 选择器添加目录（DSD / USB 等特殊目录的兜底入口）。
  Future<void> _addFolderViaSaf() async {
    setState(() => _adding = true);
    try {
      final treeUri = await SafChannel.chooseFolderTree();
      if (treeUri == null) return;
      await SafChannel.persistPermission(treeUri);
      await ref.read(scanFoldersProvider.notifier).addFolder(treeUri);
      String msg;
      try {
        final count = await ref.read(libraryProvider.notifier).scanAllFolders();
        msg = '已添加扫描目录，扫描到 $count 首';
      } catch (e) {
        msg = '已添加扫描目录，但扫描失败：$e';
      }
      if (mounted) _toast(msg);
    } catch (e) {
      if (mounted) _toast(tr('添加失败：{e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  /// 重新授权失效目录：选回同一目录时 tree URI 不变，旧曲库数据直接复活。
  Future<void> _reauthorize(String treeUri) async {
    setState(() => _adding = true);
    try {
      final newUri = await SafChannel.chooseFolderTree();
      if (newUri == null) return;
      await SafChannel.persistPermission(newUri);
      if (newUri != treeUri) {
        await SafChannel.releasePermission(treeUri);
        await ref.read(scanFoldersProvider.notifier).removeFolder(treeUri);
        await ref.read(scanFoldersProvider.notifier).addFolder(newUri);
      }
      String msg;
      try {
        final count = await ref.read(libraryProvider.notifier).scanAllFolders();
        msg = tr('重新授权成功，扫描到 {n} 首', {'n': count});
      } catch (e) {
        msg = tr('重新授权完成，但扫描失败：{e}', {'e': e});
      }
      if (mounted) _toast(msg);
    } catch (e) {
      if (mounted) _toast(tr('重新授权失败：{e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _removeFolder(String path) async {
    final name = await _friendlyFolderName(path);
    if (!mounted) return;
    final ok = await showPredictiveDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title:   Text(tr('移除扫描目录')),
        content: Text(tr('确定移除该目录吗？\n{name}', {'name': name})),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child:   Text(tr('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child:   Text(tr('移除')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(scanFoldersProvider.notifier).removeFolder(path);
      if (SafChannel.isSafTree(path)) {
        await SafChannel.releasePermission(path);
      }
      _toast(tr('已移除'));
    } catch (e) {
      _toast(tr('移除失败：{e}', {'e': e}));
    }
  }

  void _buildNodes(
      BuildContext context, List<FolderNodeData> nodes, List<Widget> out) {
    for (final n in nodes) {
      final hasChildren = n.children.isNotEmpty || n.childCount > 0;
      final isExpanded = _expanded.contains(n.path);
      out.add(_FolderTile(
        node: n,
        hasChildren: hasChildren,
        isExpanded: isExpanded,
        onToggle: () {
          setState(() {
            if (isExpanded) {
              _expanded.remove(n.path);
            } else {
              _expanded.add(n.path);
            }
          });
        },
        onOpen: () {
          if (n.songCount > 0) {
            Navigator.of(context, rootNavigator: true).push(
              MaterialPageRoute(
                builder: (_) => SongListPage(
                  title: n.name,
                  loader: () =>
                      ref.read(libraryProvider.notifier).songsByFolder(n.path),
                ),
              ),
            );
          }
        },
        onImport: () => _importAsPlaylist(n),
      ));
      if (isExpanded && n.children.isNotEmpty) {
        _buildNodes(context, n.children, out);
      }
    }
  }

  Future<void> _importAsPlaylist(FolderNodeData node) async {
    final count = await ref
        .read(libraryProvider.notifier)
        .importFolderAsPlaylist(node.path);
    if (!mounted) return;
    final name = node.name.isNotEmpty ? node.name : node.path.split('/').last;
    showXianYuToast(
      context,
      count > 0
          ? tr('已将 {n} 首歌曲导入到歌单「{name}」', {'n': count, 'name': name})
          : tr('「{name}」下没有可导入的歌曲', {'name': name}),
      duration: const Duration(seconds: 2),
    );
  }

  /// 一键扫描全部目录（也作为下拉刷新动作）。
  Future<void> _onRefresh() => _startScan();

  Future<void> _startScan() async {
    if (_scanning) return;
    setState(() => _scanning = true);
    try {
      final count = await ref.read(libraryProvider.notifier).scanAllFolders();
      if (!mounted) return;
      showXianYuToast(context, tr('扫描完成，共 {n} 首', {'n': count}),
          duration: const Duration(seconds: 2));
    } catch (e) {
      if (!mounted) return;
      showXianYuToast(context, tr('扫描失败：{e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  /// 按时长过滤阈值选择（不排除 / 10 / 30 / 60 秒）。
  Future<void> _pickMinDuration(int cur) async {
    final choice = await showSheetDialog<int>(
      context,
      (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
                Text(tr('按时长过滤'),
                  style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(
                tr('过滤掉时长小于阈值的音频文件，重新扫描后生效'),
                style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(ctx).colorScheme.outline),
              ),
              const SizedBox(height: 12),
              for (final v in const [0, 10, 30, 60])
                ListTile(
                  title: Text(switch (v) {
                    0 => tr('不排除'),
                    _ => tr('{v} 秒', {'v': v}),
                  }),
                  trailing: cur == v
                      ? Icon(Icons.check,
                          color: Theme.of(ctx).colorScheme.primary)
                      : null,
                  contentPadding: EdgeInsets.zero,
                  onTap: () => Navigator.pop(ctx, v),
                ),
            ],
          ),
        ),
      ),
    );
    if (choice == null) return;
    if (choice > 0) _lastDuration = choice;
    await ref
        .read(settingsProvider.notifier)
        .setLibraryMinDurationSeconds(choice);
  }

  @override
  Widget build(BuildContext context) {
    final root = ref.watch(libraryProvider.select((s) => s.folderRoot));
    final lost =
        ref.watch(libraryProvider.select((s) => s.unauthorizedFolders));
    final foldersAsync = ref.watch(scanFoldersProvider);
    final minDuration = ref
            .watch(settingsProvider)
            .valueOrNull
            ?.libraryMinDurationSeconds ??
        0;
    final scheme = Theme.of(context).colorScheme;
    final glass = ref.watch(wallpaperActiveProvider);

    final tiles = <Widget>[];
    _buildNodes(context, root, tiles);

    return RefreshIndicator(
      onRefresh: _onRefresh,
      child: ListView(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 8,
          bottom: (ref.watch(playerProvider.select((s) => s.current != null)) ? 92.0 : 16.0) +
              MediaQuery.of(context).padding.bottom,
        ),
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          // —— 扫描引导（魅族风格：渐变圆标 + 一键扫描）——
          _ScanHero(
            scanning: _scanning,
            onScan: _startScan,
            onSafFallback:
                Platform.isAndroid && !_adding ? _addFolderViaSaf : null,
          ),
          if (lost.isNotEmpty) _UnauthorizedBanner(lost: lost),
          const SizedBox(height: 16),
          // —— 过滤设置 ——
          _FilterCard(
            minDuration: minDuration,
            onToggle: (v) {
              final next = v ? _lastDuration : 0;
              ref
                  .read(settingsProvider.notifier)
                  .setLibraryMinDurationSeconds(next);
            },
            onPick: () => _pickMinDuration(minDuration),
          ),
          const SizedBox(height: 16),
          // —— 扫描目录管理 ——
          foldersAsync.when(
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (e, _) => Text(tr('扫描目录加载失败：{e}', {'e': e}),
                style: TextStyle(fontSize: 13, color: scheme.error)),
            data: (folders) => _ScanFoldersCard(
              folders: folders,
              lost: lost,
              adding: _adding,
              onAdd: _adding ? null : _addFolder,
              onRemove: _removeFolder,
              onReauthorize: _reauthorize,
            ),
          ),
          const SizedBox(height: 16),
          // —— 远程音乐库（WebDAV）入口 ——
          const _RemoteLibraryCard(),
          // —— 已扫描文件夹树 ——
          if (root.isNotEmpty) ...[
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
              child: Text(
                tr('已扫描文件夹'),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: scheme.primary,
                ),
              ),
            ),
            Material(
              color: glass ? glassControlFill : appCardColor(context),
              clipBehavior: Clip.antiAlias,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: glass
                    ? BorderSide(color: glassControlBorder)
                    : BorderSide.none,
              ),
              child: Column(children: tiles),
            ),
          ],
        ],
      ),
    );
  }
}

/// 扫描引导头图：径向渐变圆标 + 主标题 + 「开始扫描」胶囊按钮 + SAF 兜底入口。
class _ScanHero extends StatelessWidget {
  const _ScanHero({
    required this.scanning,
    required this.onScan,
    this.onSafFallback,
  });

  final bool scanning;
  final VoidCallback onScan;
  final VoidCallback? onSafFallback;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final light = Color.lerp(scheme.primary, Colors.white, 0.35)!;
    return Column(
      children: [
        const SizedBox(height: 20),
        Container(
          width: 84,
          height: 84,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              center: const Alignment(-0.3, -0.4),
              colors: [light, scheme.primary],
            ),
            boxShadow: [
              BoxShadow(
                color: scheme.primary.withValues(alpha: 0.35),
                blurRadius: 22,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: const Icon(Icons.library_music_rounded,
              color: Colors.white, size: 40),
        ),
        const SizedBox(height: 14),
          Text(
          tr('一键扫描手机内的歌曲文件'),
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 14),
        SizedBox(
          width: 220,
          height: 46,
          child: FilledButton(
            onPressed: scanning ? null : onScan,
            style: FilledButton.styleFrom(
              backgroundColor: scheme.primary,
              foregroundColor: scheme.onPrimary,
              shape: const StadiumBorder(),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (scanning)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  const Icon(Icons.play_arrow_rounded, size: 22),
                const SizedBox(width: 6),
                Text(
                  scanning ? tr('正在扫描…') : tr('开始扫描'),
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ),
        if (onSafFallback != null) ...[
          const SizedBox(height: 4),
          TextButton(
            onPressed: onSafFallback,
            style: TextButton.styleFrom(
              foregroundColor: scheme.primary,
              textStyle: const TextStyle(fontSize: 12),
            ),
            child:   Text(tr('看不到部分歌曲？试试系统选择器添加目录')),
          ),
        ],
      ],
    );
  }
}

/// 过滤设置卡：按时长过滤开关 + 阈值选择。
class _FilterCard extends ConsumerWidget {
  const _FilterCard({
    required this.minDuration,
    required this.onToggle,
    required this.onPick,
  });

  final int minDuration;
  final ValueChanged<bool> onToggle;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final glass = ref.watch(wallpaperActiveProvider);
    return Material(
      color: glass ? glassControlFill : appCardColor(context),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: glass ? BorderSide(color: glassControlBorder) : BorderSide.none,
      ),
      child: ListTile(
        leading: Icon(Icons.timer_outlined, color: scheme.primary),
        title:   Text(tr('按时长过滤')),
        subtitle: Text(
          minDuration > 0
              ? tr('已过滤时长小于 {n} 秒的音频文件', {'n': minDuration})
              : tr('可过滤掉时长过短的音频文件（点按调整阈值）'),
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
        trailing: Switch(
          value: minDuration > 0,
          onChanged: onToggle,
        ),
        onTap: onPick,
      ),
    );
  }
}

/// 扫描目录管理卡：目录列表 + 添加 / 重新授权 / 移除。
class _ScanFoldersCard extends ConsumerWidget {
  const _ScanFoldersCard({
    required this.folders,
    required this.lost,
    required this.adding,
    required this.onAdd,
    required this.onRemove,
    required this.onReauthorize,
  });

  final List<ScanFolder> folders;
  final List<String> lost;
  final bool adding;
  final VoidCallback? onAdd;
  final void Function(String path) onRemove;
  final void Function(String path) onReauthorize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final glass = ref.watch(wallpaperActiveProvider);
    return Material(
      color: glass ? glassControlFill : appCardColor(context),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: glass ? BorderSide(color: glassControlBorder) : BorderSide.none,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
            child: Row(
              children: [
                Icon(Icons.folder_copy_outlined,
                    size: 20, color: scheme.primary),
                const SizedBox(width: 8),
                Text(
                  folders.isEmpty ? tr('扫描目录') : '扫描目录 · ${folders.length}',
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                IconButton(
                  tooltip: tr('添加目录'),
                  onPressed: onAdd,
                  icon: adding
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.add),
                ),
              ],
            ),
          ),
          if (folders.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
              child: Text(
                tr('还没有扫描目录，点击右上角「+」选择包含音乐的文件夹\n（仅首次需要授予音乐读取权限）'),
                style: TextStyle(
                    fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            )
          else
            for (var i = 0; i < folders.length; i++)
              Builder(builder: (context) {
                final f = folders[i];
                final isLost = lost.contains(f.path);
                return ListTile(
                  dense: true,
                  leading: Icon(
                    isLost ? Icons.folder_off : Icons.folder,
                    color: isLost ? scheme.error : scheme.primary,
                  ),
                  title: FutureBuilder<String>(
                    future: _friendlyFolderName(f.path),
                    builder: (context, snap) => Text(
                      snap.data ?? f.path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  subtitle: Text(
                    isLost ? tr('授权已失效，点击钥匙重新授权') : '${f.songCount} 首',
                    style: TextStyle(
                      fontSize: 12,
                      color: isLost ? scheme.error : scheme.onSurfaceVariant,
                    ),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (isLost)
                        IconButton(
                          tooltip: tr('重新授权'),
                          icon: Icon(Icons.key,
                              color: scheme.error, size: 20),
                          onPressed: () => onReauthorize(f.path),
                        ),
                      IconButton(
                        tooltip: tr('移除'),
                        icon: Icon(Icons.delete_outline,
                            color: scheme.error, size: 20),
                        onPressed: () => onRemove(f.path),
                      ),
                    ],
                  ),
                );
              }),
        ],
      ),
    );
  }
}

/// tree URI → 用户可读目录名（静态缓存，避免列表滚动时反复跨 channel 查询）。
Future<String> _friendlyFolderName(String path) async {
  final hit = _folderNameCache[path];
  if (hit != null) return hit;
  if (!SafChannel.isSafTree(path)) return path;
  final name = await SafChannel.friendlyTreeName(path);
  _folderNameCache[path] = name;
  return name;
}

final Map<String, String> _folderNameCache = {};

/// 授权失效目录的警示横幅（重新授权入口在下方「扫描目录」卡片内）。
///
/// 重新授权选回同一目录时 tree URI 不变，旧曲库数据直接复活，无需重扫。
class _UnauthorizedBanner extends StatelessWidget {
  final List<String> lost;
  const _UnauthorizedBanner({required this.lost});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Material(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              Icon(Icons.folder_off, size: 20, color: scheme.onErrorContainer),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  tr('{n} 个目录授权已失效，可在下方重新授权', {'n': lost.length}),
                  style: TextStyle(
                      fontSize: 13,
                      color: scheme.onErrorContainer,
                      fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FolderTile extends StatelessWidget {
  final FolderNodeData node;
  final bool hasChildren;
  final bool isExpanded;
  final VoidCallback onToggle;
  final VoidCallback onOpen;
  final VoidCallback onImport;
  const _FolderTile({
    required this.node,
    required this.hasChildren,
    required this.isExpanded,
    required this.onToggle,
    required this.onOpen,
    required this.onImport,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.folder),
      title: Text(
        node.name.isNotEmpty ? node.name : node.path.split('/').last,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w500),
      ),
      subtitle: Text(
        tr('{n} 首', {'n': node.songCount}),
        style: const TextStyle(fontSize: 12),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hasChildren)
            IconButton(
              icon: AnimatedRotation(
                turns: isExpanded ? 0.5 : 0,
                duration: const Duration(milliseconds: 200),
                child: const Icon(Icons.expand_more),
              ),
              onPressed: onToggle,
            ),
          if (node.songCount > 0)
            IconButton(icon: const Icon(Icons.play_arrow), onPressed: onOpen),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, size: 20),
            tooltip: tr('更多'),
            onSelected: (action) {
              if (action == 'import') onImport();
            },
            itemBuilder: (ctx) => [
              PopupMenuItem(
                value: 'import',
                enabled: node.songCount > 0,
                child:   Text(tr('导入为歌单')),
              ),
            ],
          ),
        ],
      ),
      onTap: hasChildren ? onToggle : onOpen,
    );
  }
}

/// 远程音乐库 WebDAV 管理入口（从设置页「本地」迁至本文件夹页）。
class _RemoteLibraryCard extends ConsumerWidget {
  const _RemoteLibraryCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final glass = ref.watch(wallpaperActiveProvider);
    return Material(
      color: glass ? glassControlFill : appCardColor(context),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: glass ? BorderSide(color: glassControlBorder) : BorderSide.none,
      ),
      child: ListTile(
        leading: Icon(Icons.cloud_outlined, color: scheme.primary),
        title:   Text(tr('远程音乐库 (WebDAV)')),
        subtitle: Text(
          tr('访问 WebDAV 服务器上的音乐资源'),
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
        trailing: Icon(Icons.chevron_right, color: scheme.outline),
        onTap: () => context.push('/remote-library'),
      ),
    );
  }
}
