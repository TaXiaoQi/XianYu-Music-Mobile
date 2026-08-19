import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/library/library_provider.dart';
import '../../src/widgets/song_list_view.dart';
import 'song_list_page.dart';

class LibraryPage extends ConsumerStatefulWidget {
  const LibraryPage({super.key});

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
    _tab.index = ref.read(libraryTabProvider);
    ref.listenManual(libraryTabProvider, (prev, next) {
      if (next != prev && _tab.index != next) {
        _tab.animateTo(next);
      }
    });
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lib = ref.watch(libraryProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('音乐库'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.read(libraryProvider.notifier).load(),
          ),
        ],
        bottom: TabBar(
          controller: _tab,
          tabs: const [
            Tab(text: '全部'),
            Tab(text: '歌手'),
            Tab(text: '专辑'),
            Tab(text: '文件夹'),
          ],
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.only(bottom: 150),
        child: lib.loading
            ? const Center(child: CircularProgressIndicator())
            : lib.error != null
                ? _ErrorView(message: lib.error!, onRetry: () => ref.read(libraryProvider.notifier).load())
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

  @override
  Widget build(BuildContext context) {
    final lib = ref.watch(libraryProvider);
    final songs = _query.isEmpty
        ? lib.songs
        : lib.songs
            .where((s) =>
                s.title.toLowerCase().contains(_query) ||
                s.artist.toLowerCase().contains(_query) ||
                s.album.toLowerCase().contains(_query))
            .toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
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
                  onPlay: (list, i) =>
                      ref.read(libraryProvider.notifier).playList(list, i),
                ),
        ),
      ],
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
      itemCount: artists.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final a = artists[i];
        return ListTile(
          leading: CircleAvatar(
            backgroundColor: Theme.of(context).colorScheme.primaryContainer,
            child: Text(
              a.name.isEmpty ? '?' : String.fromCharCode(a.name.runes.first),
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onPrimaryContainer),
            ),
          ),
          title: Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text('${a.count} 首'),
          trailing: Icon(Icons.chevron_right, color: Theme.of(context).colorScheme.outline),
          onTap: () => Navigator.push(
            context,
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

/// 专辑目录。
class _AlbumsTab extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final albums = ref.watch(libraryProvider.select((s) => s.albums));
    if (albums.isEmpty) return const Center(child: Text('暂无专辑'));
    return ListView.separated(
      itemCount: albums.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final a = albums[i];
        return ListTile(
          leading: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.tertiaryContainer,
              borderRadius: BorderRadius.circular(6),
            ),
            alignment: Alignment.center,
            child: const Icon(Icons.album, size: 20),
          ),
          title: Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            '${a.artist} · ${a.count} 首',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Icon(Icons.chevron_right, color: Theme.of(context).colorScheme.outline),
          onTap: () => Navigator.push(
            context,
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
            Navigator.push(
              context,
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
      ));
      if (isExpanded && n.children.isNotEmpty) {
        _buildNodes(context, n.children, out);
      }
    }
  }

  bool _scanning = false;

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
    final tiles = <Widget>[];
    _buildNodes(context, root, tiles);
    // 用 RefreshIndicator 包裹，空态也可下拉；空态用可滚动布局撑满。
    return RefreshIndicator(
      onRefresh: _onRefresh,
      child: root.isEmpty
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                SizedBox(
                  height: MediaQuery.of(context).size.height * 0.5,
                  child: const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        '暂无文件夹\n请先在「设置 → 扫描文件夹」添加音乐目录，\n然后在此下拉刷新开始扫描',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ),
              ],
            )
          : ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: tiles,
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
  const _FolderTile({
    required this.node,
    required this.hasChildren,
    required this.isExpanded,
    required this.onToggle,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.folder),
      // 标题只显示文件夹名，完整路径放副标题（从右侧省略，保留末级目录）。
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
        ],
      ),
      onTap: hasChildren ? onToggle : onOpen,
    );
  }
}