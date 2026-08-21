import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/favorites/favorites_provider.dart';
import '../../src/library/library_provider.dart';
import '../../src/navigation/shell.dart';
import '../../src/widgets/cover_image.dart';
import '../../src/widgets/song_list_view.dart';
import '../favorites/favorites_page.dart';
import '../recent/recent_page.dart';
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
    _tab = TabController(length: 5, vsync: this);
    _tab.index = ref.read(libraryTabProvider).clamp(0, 4);
    ref.listenManual(libraryTabProvider, (prev, next) {
      final target = next.clamp(0, 4);
      if (next != prev && _tab.index != target) {
        _tab.animateTo(target);
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
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: const [
            Tab(text: '歌单'),
            Tab(text: '全部'),
            Tab(text: '歌手'),
            Tab(text: '专辑'),
            Tab(text: '文件夹'),
          ],
        ),
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
                    _PlaylistsTab(),
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

/// 【歌单】Tab（内置智能歌单 + 我喜欢的音乐大卡片 + 收藏展开）
class _PlaylistsTab extends ConsumerStatefulWidget {
  @override
  ConsumerState<_PlaylistsTab> createState() => _PlaylistsTabState();
}

class _PlaylistsTabState extends ConsumerState<_PlaylistsTab> {
  bool _isFavExpanded = false;

  @override
  Widget build(BuildContext context) {
    final favPaths = ref.watch(favoritesProvider);
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final bottomInset = ref.watch(navBarInsetProvider) + 24;

    return FutureBuilder<List<Song>>(
      key: ValueKey(favPaths.length),
      future: ref
          .read(libraryProvider.notifier)
          .songsByPaths(favPaths.toList()),
      builder: (context, snap) {
        final favSongs = snap.data ?? const <Song>[];
        final isLoadingFav = snap.connectionState != ConnectionState.done;

        return ListView(
          padding: EdgeInsets.fromLTRB(16, 16, 16, bottomInset),
          children: [
            // 核心高亮卡片：【❤️ 我喜欢的音乐】
            _buildFavHeroCard(
              context,
              favCount: favPaths.length,
              favSongs: favSongs,
              isLoading: isLoadingFav,
            ),
            // 嵌入展示【我喜欢的音乐】歌曲列表（平滑高度+透明度展开折叠过渡）
            AnimatedCrossFade(
              duration: const Duration(milliseconds: 300),
              firstCurve: Curves.easeInOutCubic,
              secondCurve: Curves.easeInOutCubic,
              crossFadeState: _isFavExpanded
                  ? CrossFadeState.showSecond
                  : CrossFadeState.showFirst,
              firstChild: const SizedBox(width: double.infinity),
              secondChild: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '我喜欢的音乐 (${favSongs.length})',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () => setState(() => _isFavExpanded = false),
                        icon: const Icon(Icons.keyboard_arrow_up, size: 18),
                        label: const Text('收起'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (isLoadingFav)
                    const Padding(
                      padding: EdgeInsets.all(24.0),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (favSongs.isEmpty)
                    Container(
                      padding: const EdgeInsets.all(24),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: colorScheme.surfaceContainer,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: const Text('暂无收藏的歌曲，点击爱心即可将歌曲加入收藏'),
                    )
                  else
                    Container(
                      decoration: BoxDecoration(
                        color: colorScheme.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: colorScheme.outlineVariant.withValues(alpha: 0.3),
                        ),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: ListView.separated(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: favSongs.length,
                          separatorBuilder: (_, _) => Divider(
                            height: 1,
                            color: colorScheme.outlineVariant.withValues(alpha: 0.2),
                          ),
                          itemBuilder: (context, i) {
                            final song = favSongs[i];
                            return ListTile(
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 4,
                              ),
                              leading: CoverImage(
                                songPath: song.path,
                                width: 44,
                                height: 44,
                                radius: 8,
                              ),
                              title: Text(
                                song.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontWeight: FontWeight.w600),
                              ),
                              subtitle: Text(
                                '${song.artist} · ${song.album}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: const Icon(
                                      Icons.favorite,
                                      color: Colors.redAccent,
                                      size: 20,
                                    ),
                                    tooltip: '取消收藏',
                                    onPressed: () {
                                      ref
                                          .read(favoritesProvider.notifier)
                                          .toggle(song.path);
                                    },
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.play_arrow_rounded),
                                    onPressed: () {
                                      ref
                                          .read(libraryProvider.notifier)
                                          .playList(favSongs, i);
                                    },
                                  ),
                                ],
                              ),
                              onTap: () {
                                ref
                                    .read(libraryProvider.notifier)
                                    .playList(favSongs, i);
                              },
                            );
                          },
                        ),
                      ),
                    ),
                  const SizedBox(height: 24),
                ],
              ),
            ),

            // 智能与系统歌单分组标题
            Padding(
              padding: const EdgeInsets.only(left: 4, top: 12, bottom: 12),
              child: Text(
                '快捷智能歌单',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),

            // 歌单 1：【❤️ 我喜欢的音乐】（标准列表项视图）
            _buildPlaylistItemTile(
              context,
              title: '我喜欢的音乐',
              subtitle: '${favPaths.length} 首歌曲',
              icon: Icons.favorite_rounded,
              gradient: const [Color(0xFFFF416C), Color(0xFFFF4B2B)],
              onTap: () {
                Navigator.of(context, rootNavigator: true).push(
                  MaterialPageRoute(builder: (_) => const FavoritesPage()),
                );
              },
            ),
            const SizedBox(height: 12),

            // 歌单 2：【最近播放】
            _buildPlaylistItemTile(
              context,
              title: '最近播放',
              subtitle: '查看最近播放历史',
              icon: Icons.history_rounded,
              gradient: const [Color(0xFF3AC2A6), Color(0xFFFFB347)],
              onTap: () {
                Navigator.of(context, rootNavigator: true).push(
                  MaterialPageRoute(builder: (_) => const RecentPage()),
                );
              },
            ),
            const SizedBox(height: 12),

            // 歌单 3：【全部本地音乐】
            _buildPlaylistItemTile(
              context,
              title: '全部本地音乐',
              subtitle: '${ref.watch(libraryProvider).songs.length} 首歌曲',
              icon: Icons.library_music_rounded,
              gradient: const [Color(0xFF5B8DEF), Color(0xFF00C6FF)],
              onTap: () {
                ref.read(libraryTabProvider.notifier).state = 1;
              },
            ),
          ],
        );
      },
    );
  }

  /// 流光毛玻璃【我喜欢的音乐】Hero 大卡片
  Widget _buildFavHeroCard(
    BuildContext context, {
    required int favCount,
    required List<Song> favSongs,
    required bool isLoading,
  }) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFFFF416C),
            Color(0xFFFF4B2B),
            Color(0xFF8A2387),
          ],
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFFF416C).withValues(alpha: 0.35),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.2),
                width: 1.5,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 封面卡片 preview 或 Icon
                    if (favSongs.isNotEmpty)
                      CoverImage(
                        songPath: favSongs.first.path,
                        width: 72,
                        height: 72,
                        radius: 16,
                      )
                    else
                      Container(
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: const Icon(
                          Icons.favorite_rounded,
                          size: 38,
                          color: Colors.white,
                        ),
                      ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 4),
                          const Text(
                            '我喜欢的音乐',
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                              letterSpacing: 0.5,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            isLoading ? '加载中...' : '包含 $favCount 首歌曲',
                            style: TextStyle(
                              fontSize: 13,
                              color: Colors.white.withValues(alpha: 0.85),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    // 一键全量顺序播放
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: favSongs.isEmpty
                            ? null
                            : () {
                                ref
                                    .read(libraryProvider.notifier)
                                    .playList(favSongs, 0);
                              },
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: Colors.black87,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        icon: const Icon(Icons.play_arrow_rounded, size: 22),
                        label: const Text(
                          '播放全部',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    // 随机播放
                    IconButton.filledTonal(
                      onPressed: favSongs.isEmpty
                          ? null
                          : () {
                              final shuffled = List<Song>.from(favSongs)
                                ..shuffle();
                              ref
                                  .read(libraryProvider.notifier)
                                  .playList(shuffled, 0);
                            },
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.white.withValues(alpha: 0.2),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.all(12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      icon: const Icon(Icons.shuffle_rounded, size: 20),
                      tooltip: '随机播放',
                    ),
                    const SizedBox(width: 8),
                    // 展开/收起内嵌列表
                    IconButton.filledTonal(
                      onPressed: () {
                        setState(() => _isFavExpanded = !_isFavExpanded);
                      },
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.white.withValues(alpha: 0.2),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.all(12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      icon: Icon(
                        _isFavExpanded
                            ? Icons.keyboard_arrow_up_rounded
                            : Icons.keyboard_arrow_down_rounded,
                        size: 20,
                      ),
                      tooltip: _isFavExpanded ? '收起列表' : '展开列表',
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 标准歌单列表项
  Widget _buildPlaylistItemTile(
    BuildContext context, {
    required String title,
    required String subtitle,
    required IconData icon,
    required List<Color> gradient,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Material(
      color: colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: colorScheme.outlineVariant.withValues(alpha: 0.3),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: gradient,
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: Colors.white, size: 24),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 12,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: colorScheme.outline,
              ),
            ],
          ),
        ),
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
                  padding: EdgeInsets.only(
                    bottom: ref.watch(navBarInsetProvider) + 24,
                  ),
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
      padding: EdgeInsets.only(bottom: ref.watch(navBarInsetProvider) + 24),
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

/// 专辑目录。
class _AlbumsTab extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final albums = ref.watch(libraryProvider.select((s) => s.albums));
    if (albums.isEmpty) return const Center(child: Text('暂无专辑'));
    return ListView.separated(
      padding: EdgeInsets.only(bottom: ref.watch(navBarInsetProvider) + 24),
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
    final bottomPadding = EdgeInsets.only(
      bottom: ref.watch(navBarInsetProvider) + 24,
    );
    return RefreshIndicator(
      onRefresh: _onRefresh,
      child: root.isEmpty
          ? ListView(
              padding: bottomPadding,
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
              padding: bottomPadding,
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
