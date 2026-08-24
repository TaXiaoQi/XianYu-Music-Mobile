import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/library/library_provider.dart';
import '../../src/widgets/cover_image.dart';
import '../../src/widgets/sheet_dialog.dart';
import '../../src/widgets/song_list_view.dart';
import '../settings/scan_folders_page.dart';
import 'song_list_page.dart';
import '../../src/core/app_colors.dart';

/// 音乐库：全部 / 歌手 / 专辑 / 文件夹（从「我的」页进入的二级页面）。
///
/// 歌单与收藏入口已分流到「我的」页；本页专注本地曲库浏览。
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

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 4, vsync: this);
    _tab.index = widget.initialTab.clamp(0, 3);
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lib = ref.watch(libraryProvider);

    final tabBar = TabBar(
      controller: _tab,
      isScrollable: true,
      tabAlignment: TabAlignment.start,
      tabs: const [
        Tab(text: '全部'),
        Tab(text: '歌手'),
        Tab(text: '专辑'),
        Tab(text: '文件夹'),
      ],
    );

    return Scaffold(
      backgroundColor: appSurfaceBg(context),
      appBar: AppBar(
        title: const Text('音乐库'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.read(libraryProvider.notifier).load(),
          ),
        ],
        bottom: tabBar,
      ),
      body: lib.loading
          ? const Center(child: CircularProgressIndicator())
          : lib.error != null
              ? _ErrorView(
                  message: lib.error!,
                  onRetry: () => ref.read(libraryProvider.notifier).load(),
                )
              : TabBarView(
                  controller: _tab,
                  children: [
                    _AllSongsTab(),
                    _ArtistsTab(),
                    _AlbumsTab(),
                    _FoldersTab(),
                  ],
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
            label: const Text('重试'),
          ),
        ],
      ),
    );
  }
}

/// 全部歌曲（支持本地搜索）。
class _AllSongsTab extends ConsumerStatefulWidget {
  @override
  ConsumerState<_AllSongsTab> createState() => _AllSongsTabState();
}

class _AllSongsTabState extends ConsumerState<_AllSongsTab> {
  String _query = '';

  /// 排序方式；null 表示保持库默认顺序。
  _SongSort _sort = _SongSort.none;
  bool _hideDuplicates = false;

  List<Song> _applySort(List<Song> list) {
    final copy = [...list];
    switch (_sort) {
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

  List<Song> _filter(List<Song> list) {
    List<Song> result = list;
    if (_query.isNotEmpty) {
      result = result
          .where((s) =>
              s.title.toLowerCase().contains(_query) ||
              s.artist.toLowerCase().contains(_query) ||
              s.album.toLowerCase().contains(_query))
          .toList();
    }
    if (_hideDuplicates) {
      final seen = <String, String>{};
      result = result.where((s) {
        final key = '${s.title.toLowerCase()}|${s.artist.toLowerCase()}';
        if (seen.containsKey(key)) return false;
        seen[key] = s.path;
        return true;
      }).toList();
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final lib = ref.watch(libraryProvider);
    final songs = _applySort(_filter(lib.songs));
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
                  items: const [
                    DropdownMenuItem(value: _SongSort.none, child: Text('默认排序')),
                    DropdownMenuItem(value: _SongSort.title, child: Text('按标题')),
                    DropdownMenuItem(value: _SongSort.artist, child: Text('按歌手')),
                    DropdownMenuItem(value: _SongSort.album, child: Text('按专辑')),
                    DropdownMenuItem(value: _SongSort.addedAt, child: Text('按添加时间')),
                  ],
                  onChanged: (v) => setState(() => _sort = v ?? _SongSort.none),
                ),
              ),
              const SizedBox(width: 4),
              Tooltip(
                message: _hideDuplicates ? '已隐藏重复歌曲' : '隐藏重复歌曲',
                child: IconButton(
                  icon: Icon(
                    _hideDuplicates ? Icons.flip_to_front : Icons.flip_to_back,
                    color: _hideDuplicates ? scheme.primary : null,
                  ),
                  onPressed: () =>
                      setState(() => _hideDuplicates = !_hideDuplicates),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.bar_chart),
                tooltip: '曲库统计',
                onPressed: () => _showStats(context, lib),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
          child: TextField(
            onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
            decoration: InputDecoration(
              hintText: '搜索歌曲、歌手、专辑',
              prefixIcon: const Icon(Icons.search),
              isDense: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(24),
              ),
            ),
          ),
        ),
        Expanded(
          child: songs.isEmpty
              ? const Center(child: Text('没有匹配的歌曲'))
              : SongsListView(
                  songs: songs,
                  padding: EdgeInsets.only(
                    bottom: 92 + MediaQuery.of(context).padding.bottom,
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
      final f = s.format.isEmpty ? '未知' : s.format.toUpperCase();
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
            const Text('曲库统计',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 14),
            _StatRow(label: '歌曲总数', value: '$total 首'),
            _StatRow(label: '总时长', value: _fmtDuration(durationMs)),
            _StatRow(label: '歌手', value: '${lib.artists.length} 位'),
            _StatRow(label: '专辑', value: '${lib.albums.length} 张'),
            _StatRow(label: '文件夹', value: '${lib.folders.length} 个'),
            if (formats.isNotEmpty) ...[
              const Divider(height: 20),
              for (final f in formats)
                _StatRow(label: f.key, value: '${f.value} 首'),
            ],
            const SizedBox(height: 8),
            Icon(TextDirection.ltr == TextDirection.ltr ? Icons.info_outline : Icons.info_outline,
              size: 14, color: Theme.of(ctx).colorScheme.outline),
            const SizedBox(height: 4),
            Text('统计基于本地曲库', style: TextStyle(fontSize: 11, color: Theme.of(ctx).colorScheme.outline)),
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
    if (artists.isEmpty) return const Center(child: Text('暂无歌手'));
    return ListView.separated(
      padding: EdgeInsets.only(bottom: 92 + MediaQuery.of(context).padding.bottom),
      itemCount: artists.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final a = artists[i];
        final scheme = Theme.of(context).colorScheme;
        return ListTile(
          leading: CoverImage(
            songPath: a.firstSongPath,
            width: 44,
            height: 44,
            radius: 22,
            icon: Icons.person,
            placeholder: _letterAvatar(context, a.name, scheme),
          ),
          title: Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text('${a.count} 首'),
          trailing: Icon(Icons.chevron_right, color: Theme.of(context).colorScheme.outline),
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
    if (albums.isEmpty) return const Center(child: Text('暂无专辑'));
    return ListView.separated(
      padding: EdgeInsets.only(bottom: 92 + MediaQuery.of(context).padding.bottom),
      itemCount: albums.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final a = albums[i];
        return ListTile(
          leading: CoverImage(
            songPath: a.firstSongPath,
            width: 40,
            height: 40,
            radius: 6,
            icon: Icons.album,
          ),
          title: Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            '${a.artist} · ${a.count} 首',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Icon(Icons.chevron_right, color: Theme.of(context).colorScheme.outline),
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

/// 文件夹树。
class _FoldersTab extends ConsumerStatefulWidget {
  @override
  ConsumerState<_FoldersTab> createState() => _FoldersTabState();
}

class _FoldersTabState extends ConsumerState<_FoldersTab> {
  final Set<String> _expanded = {};

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

  bool _scanning = false;

  Future<void> _importAsPlaylist(FolderNodeData node) async {
    final count = await ref
        .read(libraryProvider.notifier)
        .importFolderAsPlaylist(node.path);
    if (!mounted) return;
    final name = node.name.isNotEmpty ? node.name : node.path.split('/').last;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          count > 0
              ? '已将 $count 首歌曲导入到歌单「$name」'
              : '「$name」下没有可导入的歌曲',
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _onRefresh() async {
    if (_scanning) return;
    setState(() => _scanning = true);
    try {
      final count = await ref.read(libraryProvider.notifier).scanAllFolders();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('扫描完成，共 $count 首'),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('扫描失败：$e')),
      );
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final root = ref.watch(libraryProvider.select((s) => s.folderRoot));
    final lost = ref.watch(
        libraryProvider.select((s) => s.unauthorizedFolders));
    final tiles = <Widget>[];
    _buildNodes(context, root, tiles);
    final bottomPadding = EdgeInsets.only(
      bottom: 92 + MediaQuery.of(context).padding.bottom,
    );
    return RefreshIndicator(
      onRefresh: _onRefresh,
      child: root.isEmpty
          ? ListView(
              padding: bottomPadding,
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                if (lost.isNotEmpty) _UnauthorizedBanner(lost: lost),
                SizedBox(
                  height: MediaQuery.of(context).size.height * 0.5,
                  child: const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        '暂无文件夹\n请先在「设置 → 扫描文件夹」添加一个音乐目录\n（仅首次添加需要授权），\n然后在此下拉刷新开始扫描',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ),
              ],
            )
          : ListView(
              padding: bottomPadding,
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                if (lost.isNotEmpty) _UnauthorizedBanner(lost: lost),
                ...tiles,
              ],
            ),
    );
  }
}

/// 授权失效目录的警示横幅：点击跳转扫描文件夹页重新授权。
///
/// 重新授权选回同一目录时 tree URI 不变，旧曲库数据直接复活，无需重扫。
class _UnauthorizedBanner extends StatelessWidget {
  final List<String> lost;
  const _UnauthorizedBanner({required this.lost});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Material(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => Navigator.of(context, rootNavigator: true).push(
            MaterialPageRoute(
              builder: (_) => const ScanFoldersPage(),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                Icon(Icons.folder_off, size: 20, color: scheme.onErrorContainer),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '${lost.length} 个目录授权已失效，点击重新授权',
                    style: TextStyle(
                        fontSize: 13,
                        color: scheme.onErrorContainer,
                        fontWeight: FontWeight.w500),
                  ),
                ),
                Icon(Icons.chevron_right, size: 18, color: scheme.onErrorContainer),
              ],
            ),
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
        '${node.songCount} 首',
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
            tooltip: '更多',
            onSelected: (action) {
              if (action == 'import') onImport();
            },
            itemBuilder: (ctx) => [
              PopupMenuItem(
                value: 'import',
                enabled: node.songCount > 0,
                child: const Text('导入为歌单'),
              ),
            ],
          ),
        ],
      ),
      onTap: hasChildren ? onToggle : onOpen,
    );
  }
}
