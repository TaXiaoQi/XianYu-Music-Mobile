import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../src/core/app_colors.dart';
import '../../src/download/download_provider.dart';
import '../../src/favorites/favorites_provider.dart';
import '../../src/navigation/shell.dart';
import '../../src/player/player_provider.dart';
import '../../src/plugin/plugin_catalog.dart';
import '../../src/plugin/plugin_models.dart';
import '../../src/plugin/plugin_provider.dart';
import '../../src/widgets/glass_appbar.dart';
import '../../src/widgets/online_cover.dart';
import '../../src/widgets/flying_cover.dart';
import '../../src/widgets/list_metrics.dart';
import '../../src/widgets/song_actions_sheet.dart';
import '../../src/widgets/song_list_view.dart';
import '../../src/widgets/app_toast.dart';
import '../../src/widgets/mini_player_bar.dart';

enum OnlineDetailType { artist, album, playlist, toplist }

/// 在线详情页参数（经路由 extra 传递）。
class OnlineDetailArgs {
  final OnlineDetailType type;
  final String pluginId;
  final String title;
  final String subtitle;
  final String? coverUrl;
  final Map<String, dynamic> raw;

  const OnlineDetailArgs({
    required this.type,
    required this.pluginId,
    required this.title,
    this.subtitle = '',
    this.coverUrl,
    required this.raw,
  });
}

/// 在线详情页：歌手（歌曲/专辑/简介）、专辑、歌单、榜单详情。
class OnlineDetailPage extends ConsumerStatefulWidget {
  const OnlineDetailPage({super.key, required this.args});

  final OnlineDetailArgs args;

  @override
  ConsumerState<OnlineDetailPage> createState() => _OnlineDetailPageState();
}

class _OnlineDetailPageState extends ConsumerState<OnlineDetailPage>
    with HidesShellChrome, SingleTickerProviderStateMixin {
  List<PluginSearchResult> _songs = const [];
  List<MfAlbumItem> _albums = const [];
  String _intro = '';
  bool _loading = true;
  bool _loadingMore = false;
  bool _isEnd = false;
  bool _introLoaded = false;
  int _page = 1;
  PluginCatalogService? _catalog;
  PluginSource? _source;
  late final TabController? _tab;
  int _activeTab = 0;

  @override
  void initState() {
    super.initState();
    final isArtist = widget.args.type == OnlineDetailType.artist;
    if (isArtist) {
      final tab = TabController(length: 3, vsync: this);
      tab.addListener(() {
        if (!tab.indexIsChanging) {
          setState(() => _activeTab = tab.index);
          if (_activeTab == 2 && !_introLoaded) _loadIntro();
          if (_activeTab == 1 && _albums.isEmpty) _loadAlbums();
        }
      });
      _tab = tab;
    } else {
      _tab = null;
    }
    Future.microtask(_init);
  }

  @override
  void dispose() {
    _tab?.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final engine = await ref.read(pluginEngineProvider.future);
    final sources = ref.read(pluginManagerProvider).sources;
    final source =
        sources.where((s) => s.id == widget.args.pluginId).toList();
    if (source.isEmpty || !mounted) {
      setState(() => _loading = false);
      return;
    }
    _source = source.first;
    _catalog = PluginCatalogService(engine, sources);
    await _loadSongs(reset: true);
    if (widget.args.type == OnlineDetailType.artist) {
      // 专辑预取：列表页点进歌手默认在歌曲 tab，专辑后台备好切 tab 即显。
      await _loadAlbums();
    }
  }

  Future<void> _loadSongs({bool reset = false}) async {
    final catalog = _catalog;
    final source = _source;
    if (catalog == null || source == null) return;
    if (reset) {
      setState(() {
        _loading = true;
        _page = 1;
        _isEnd = false;
      });
    } else {
      if (_isEnd || _loadingMore) return;
      setState(() => _loadingMore = true);
    }
    final page = reset ? 1 : _page + 1;
    final raw = widget.args.raw;
    final List<PluginSearchResult> list;
    switch (widget.args.type) {
      case OnlineDetailType.artist:
        list = await catalog.getArtistWorks(source, raw, page: page);
      case OnlineDetailType.album:
        list = await catalog.getAlbumSongs(source, raw, page: page);
      case OnlineDetailType.toplist:
        list = await catalog.getTopListDetail(source, raw, page: page);
      case OnlineDetailType.playlist:
        final item = Map<String, dynamic>.from(raw);
        if (item['_isAlbum'] == true) {
          item.remove('_isAlbum');
          list = await catalog.getAlbumSongs(source, item, page: page);
        } else {
          list = await catalog.getMusicSheetInfo(source, raw, page: page);
        }
    }
    if (!mounted) return;
    setState(() {
      if (reset) {
        _songs = list;
        _loading = false;
      } else {
        _songs = [..._songs, ...list];
      }
      // 不足一页视为到底（多数插件一页 30~100）。
      if (list.length < 30) _isEnd = true;
      _page = page;
      _loadingMore = false;
    });
  }

  Future<void> _loadAlbums() async {
    final catalog = _catalog;
    final source = _source;
    if (catalog == null || source == null) return;
    final albums = await catalog.getArtistAlbums(source, widget.args.raw);
    if (!mounted) return;
    setState(() => _albums = albums);
  }

  Future<void> _loadIntro() async {
    final catalog = _catalog;
    final source = _source;
    if (catalog == null || source == null) return;
    final intro = await catalog.getArtistInfo(source, widget.args.raw);
    if (!mounted) return;
    setState(() {
      _intro = intro;
      _introLoaded = true;
    });
  }

  void _playAll() => _play(0);

  void _play(int index) {
    final source = _source;
    if (source == null) return;
    final queue = _songs
        .map((r) => PluginCatalogService.toQueueItem(source, r))
        .toList();
    if (queue.isEmpty) return;
    ref.read(playerProvider.notifier).playQueue(queue, startIndex: index);
  }

  void _download(int index) {
    final source = _source;
    if (source == null) return;
    final item = PluginCatalogService.toQueueItem(source, _songs[index]);
    ref.read(downloadProvider.notifier).download(item);
    showXianYuToast(context, '开始下载：${item.title}');
  }

  QueueItem? _queueItem(int index) {
    final source = _source;
    if (source == null) return null;
    return PluginCatalogService.toQueueItem(source, _songs[index]);
  }

  void _toggleFavorite(int index) {
    final item = _queueItem(index);
    if (item == null) return;
    final wasFav = ref.read(favoritesProvider).contains(item.path);
    ref.read(favoritesProvider.notifier).toggle(item);
    showXianYuToast(context, wasFav ? '已取消收藏：${item.title}' : '已收藏：${item.title}');
  }

  void _toggleCollectionFavorite() {
    final a = widget.args;
    ref.read(favoritesProvider.notifier).toggleCollection(
          kind: a.type.name,
          pluginId: a.pluginId,
          title: a.title,
          subtitle: a.subtitle,
          coverUrl: a.coverUrl,
          raw: a.raw,
        );
  }

  void _songActions(int index) {
    final source = _source;
    if (source == null) return;
    final item = PluginCatalogService.toQueueItem(source, _songs[index]);
    showSongActionsSheet(
      context,
      ref: ref,
      item: item,
      onPlay: () => _play(index),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final a = widget.args;
    final isArtist = a.type == OnlineDetailType.artist;
    final artistTab = isArtist && _tab != null
        ? TabBar(
            controller: _tab,
            labelColor: scheme.primary,
            unselectedLabelColor: scheme.onSurfaceVariant,
            indicatorColor: scheme.primary,
            indicatorSize: TabBarIndicatorSize.label,
            dividerColor: Colors.transparent,
            tabs: const [
              Tab(text: '歌曲'),
              Tab(text: '专辑'),
              Tab(text: '简介'),
            ],
          )
        : null;

    return Scaffold(
      backgroundColor: appSurfaceBg(context),
      body: Stack(
        children: [
          Padding(
            padding: EdgeInsets.only(top: GlassTopBar.height(context)),
            child: Column(
              children: [
                _Header(
                  title: a.title,
                  subtitle: a.subtitle.isNotEmpty
                      ? a.subtitle
                      : (isArtist ? '歌手' : switch (a.type) {
                          OnlineDetailType.album => '专辑',
                          OnlineDetailType.toplist => '榜单',
                          _ => '歌单',
                        }),
                  coverUrl: a.coverUrl,
                  circular: isArtist,
                  songCount: _songs.length,
                  onPlayAll: _songs.isNotEmpty ? _playAll : null,
                  favoriteLabel: switch (a.type) {
                    OnlineDetailType.album => '收藏整张专辑',
                    OnlineDetailType.toplist => '收藏榜单',
                    _ => '收藏整张歌单',
                  },
                  isFavorite: ref.watch(favoritesProvider).isCollectionFavorite(
                      '${a.type.name}:${a.pluginId}:${a.title}'),
                  onToggleFavorite: isArtist
                      ? null
                      : () => _toggleCollectionFavorite(),
                ),
                // 歌手 tab 位于头像下方（参考桌面端 ArtistDetailHeader）。
                if (artistTab != null) ...[
                  const SizedBox(height: 2),
                  artistTab,
                ],
                Expanded(
                  child: isArtist && _tab != null
                      ? TabBarView(
                          controller: _tab,
                          children: [
                            _buildSongList(),
                            _buildAlbumList(scheme),
                            _buildIntro(scheme),
                          ],
                        )
                      : _buildSongList(),
                ),
              ],
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: GlassTopBar(
              leading: IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => context.pop(),
              ),
              title: Text(a.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ),
          // 底部迷你播放条：与收藏/最近/下载等列表页一致，有曲目时承载当前播放。
          if (_songs.isNotEmpty)
            Positioned(
              left: 14,
              right: 14,
              bottom: MediaQuery.of(context).padding.bottom + 12,
              child: const MiniPlayerBar(),
            ),
        ],
      ),
    );
  }

  Widget _buildSongList() {
    final scheme = Theme.of(context).colorScheme;
    final m = ListMetrics.ofRef(ref);
    final favorites = ref.watch(favoritesProvider);
    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_songs.isEmpty) {
      return Center(
        child: Text('暂无歌曲', style: TextStyle(color: scheme.onSurfaceVariant)),
      );
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.pixels > n.metrics.maxScrollExtent - 300) {
          _loadSongs();
        }
        return false;
      },
      child: ListView.separated(
        padding: EdgeInsets.only(
            top: 6, bottom: MediaQuery.of(context).padding.bottom + 100),
        itemCount: _songs.length + 1,
        separatorBuilder: (_, _) => const SizedBox.shrink(),
        itemBuilder: (context, i) {
          if (i == _songs.length) {
            if (_isEnd) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Center(
                  child: Text(
                    '已经到底啦',
                    style: TextStyle(
                        fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                ),
              );
            }
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 14),
              child: Center(
                child: SizedBox(
                    width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
              ),
            );
          }
          final r = _songs[i];
          final item = _queueItem(i);
          final isFav = item != null && favorites.contains(item.path);
          return Builder(
            builder: (rowContext) {
              final g = songRowPlay(ref, onPlay: () {
                launchFlyCover(
                  rowContext,
                  coverSize: m.songCover,
                  vPad: m.vPad,
                  networkUrl: r.img,
                  radius: m.songRadius,
                );
                _play(i);
              });
              return g.wrap(
                CoverRow(
                  cover: OnlineCover(
                      url: r.img, size: m.songCover, radius: m.songRadius),
                  onTap: g.onTap,
                  onLongPress: () => _songActions(i),
                  verticalPadding: m.vPad,
                  title: Text(
                    r.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: m.titleSize, fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    r.singer.isEmpty ? r.albumName : '${r.singer} · ${r.albumName}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: m.subtitleSize,
                        color: scheme.onSurfaceVariant),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: Icon(
                          isFav ? Icons.favorite : Icons.favorite_border,
                          size: 20,
                          color: isFav ? scheme.primary : scheme.onSurfaceVariant,
                        ),
                        tooltip: '收藏',
                        onPressed: () => _toggleFavorite(i),
                      ),
                      IconButton(
                        icon: Icon(Icons.download_outlined,
                            size: 20, color: scheme.primary),
                        tooltip: '下载',
                        onPressed: () => _download(i),
                      ),
                      if (r.interval.isNotEmpty)
                        Text(
                          r.interval,
                          style: TextStyle(
                              fontSize: m.subtitleSize,
                              color: scheme.onSurfaceVariant),
                        ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildAlbumList(ColorScheme scheme) {
    if (_albums.isEmpty) {
      return Center(
        child: Text('暂无专辑', style: TextStyle(color: scheme.onSurfaceVariant)),
      );
    }
    final m = ListMetrics.ofRef(ref);
    return ListView.separated(
      padding: EdgeInsets.only(
          top: 6, bottom: MediaQuery.of(context).padding.bottom + 24),
      itemCount: _albums.length,
      separatorBuilder: (_, _) => const SizedBox.shrink(),
      itemBuilder: (context, i) {
        final album = _albums[i];
        return CoverRow(
          cover: OnlineCover(
              url: album.coverUrl, size: m.songCover, radius: m.songRadius),
          title: Text(
            album.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: m.titleSize, fontWeight: FontWeight.w600),
          ),
          subtitle: album.artist.isEmpty
              ? null
              : Text(
                  album.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: m.subtitleSize, color: scheme.onSurfaceVariant),
                ),
          verticalPadding: m.vPad,
          trailing:
              Icon(Icons.chevron_right, size: 20, color: scheme.onSurfaceVariant),
          onTap: () => context.push(
            '/online-detail',
            extra: OnlineDetailArgs(
              type: OnlineDetailType.album,
              pluginId: album.pluginId,
              title: album.name,
              subtitle: album.artist,
              coverUrl: album.coverUrl,
              raw: album.raw,
            ),
          ),
        );
      },
    );
  }

  Widget _buildIntro(ColorScheme scheme) {
    if (!_introLoaded) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_intro.isEmpty) {
      return Center(
        child: Text('暂无简介', style: TextStyle(color: scheme.onSurfaceVariant)),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        Text(
          _intro,
          style: TextStyle(
            fontSize: 14,
            height: 1.8,
            color: scheme.onSurface.withValues(alpha: 0.85),
          ),
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.title,
    required this.subtitle,
    required this.coverUrl,
    required this.circular,
    required this.songCount,
    required this.onPlayAll,
    required this.favoriteLabel,
    required this.isFavorite,
    required this.onToggleFavorite,
  });

  final String title;
  final String subtitle;
  final String? coverUrl;
  final bool circular;
  final int songCount;
  final VoidCallback? onPlayAll;
  final String favoriteLabel;
  final bool isFavorite;
  final VoidCallback? onToggleFavorite;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        children: [
          OnlineCover(
            url: coverUrl,
            size: 76,
            radius: circular ? 38 : 12,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  songCount > 0 ? '$subtitle · $songCount 首' : subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    FilledButton.icon(
                      onPressed: onPlayAll,
                      icon: const Icon(Icons.play_arrow, size: 18),
                      label: const Text('播放全部', style: TextStyle(fontSize: 13)),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        minimumSize: const Size(0, 34),
                      ),
                    ),
                    if (onToggleFavorite != null) ...[
                      const SizedBox(width: 8),
                      Tooltip(
                        message: favoriteLabel,
                        child: IconButton.filledTonal(
                          onPressed: onToggleFavorite,
                          icon: Icon(
                            isFavorite ? Icons.favorite : Icons.favorite_border,
                            size: 18,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          style: IconButton.styleFrom(
                            minimumSize: const Size(38, 34),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
