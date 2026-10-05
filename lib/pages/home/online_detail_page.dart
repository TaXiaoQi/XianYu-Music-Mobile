import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../src/favorites/favorites_provider.dart';
import '../../src/core/app_colors.dart';
import '../../src/core/application_logger.dart';
import '../../src/navigation/shell.dart';
import '../../src/player/player_provider.dart';
import '../../src/plugin/plugin_catalog.dart';
import '../../src/plugin/plugin_host_fallback.dart';
import '../../src/plugin/plugin_models.dart';
import '../../src/plugin/plugin_provider.dart';
import '../../src/plugin/plugin_search.dart';
import '../../src/plugin/sheet_cache.dart';
import '../../src/rust/api.dart' as frb;
import '../../src/widgets/glass_appbar.dart';
import '../../src/widgets/drag_handle.dart';
import '../../src/widgets/online_cover.dart';
import '../../src/widgets/flying_cover.dart';
import '../../src/widgets/list_metrics.dart';
import '../../src/widgets/song_actions_sheet.dart';
import '../../src/widgets/song_list_scroll_fabs.dart';
import '../../src/widgets/song_list_view.dart';
import '../../src/widgets/stagger_in.dart';
import '../../src/widgets/app_toast.dart';
import '../../src/i18n/i18n.dart';

enum OnlineDetailType { artist, album, playlist, toplist }

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
  PluginSearchService? _searchService;
  PluginSource? _source;
  String? _lxSource;
  bool _sourceMissing = false;
  String _cacheKey = '';
  late final TabController? _tab;
  int _activeTab = 0;
  final ScrollController _songScroll = ScrollController();
  int _coverFetchVersion = 0;
  late final StaggerWindow _stagger = StaggerWindow(onClosed: () {
    if (mounted) setState(() {});
  });

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
    _stagger.dispose();
    _tab?.dispose();
    _songScroll.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    // 缓存优先（不依赖引擎/网络）：收藏歌单先展示上次结果再后台刷新
    if (widget.args.type == OnlineDetailType.playlist) {
      _cacheKey = SheetCache.keyFor(
          pluginId: widget.args.pluginId,
          title: widget.args.title,
          raw: widget.args.raw);
      final cached = await SheetCache.load(_cacheKey);
      if (cached != null && cached.isNotEmpty && mounted) {
        setState(() {
          _songs = cached;
          _loading = false;
          _stagger.start();
        });
      }
    }
    final engine = await ref.read(pluginEngineProvider.future);
    final sources = ref.read(pluginManagerProvider).sources;
    var source = sources.where((s) => s.id == widget.args.pluginId).toList();
    // 收藏歌单绑定的插件可能已被删除/换 id；LX host 取数只依赖 lxKey，
    // 回退到任一启用的同源 LX 插件
    if (source.isEmpty) {
      final lxKey = widget.args.raw['_lxSource'];
      if (lxKey is String && lxKey.isNotEmpty) {
        source = sources
            .where((s) =>
                s.enabled &&
                s.format == PluginFormat.lx &&
                s.sources.contains(lxKey))
            .toList();
      }
    }
    if (source.isEmpty || !mounted) {
      if (_songs.isEmpty) {
        setState(() {
          _loading = false;
          _sourceMissing = true;
        });
      }
      return;
    }
    _source = source.first;
    _catalog = PluginCatalogService(engine, sources);
    _searchService = PluginSearchService(engine, sources);
    _lxSource = widget.args.raw['_lxSource'] is String
        ? widget.args.raw['_lxSource'] as String
        : null;
    await _loadSongs(reset: true, silent: _songs.isNotEmpty);
    if (widget.args.type == OnlineDetailType.artist) {
      await _loadAlbums();
    }
  }

  /// reset+silent（缓存命中后的后台刷新）：以最新第一页覆盖头部，
  /// 保留缓存中已翻到的后续内容；非 silent 的 reset 直接用最新结果。
  void _applySongs(List<PluginSearchResult> list,
      {required int page,
      required bool reset,
      bool silent = false,
      bool? pluginIsEnd}) {
    final before = _songs.length;
    final merged = reset
        ? (silent && _songs.isNotEmpty
            ? [...list, ..._songs.skip(list.length)]
            : list)
        : () {
            final seen = _songs.map((s) => '${s.source}:${s.songmid}').toSet();
            return [
              ..._songs,
              ...list.where((s) => seen.add('${s.source}:${s.songmid}'))
            ];
          }();
    setState(() {
      _songs = merged;
      if (reset) {
        if (!silent) _loading = false;
        if (!silent) _stagger.start();
      }
      if (widget.args.type != OnlineDetailType.playlist && reset) {
        _isEnd = true;
      }
      if (pluginIsEnd ?? list.length < 30) _isEnd = true;
      // 加载更多零新增（重复数据）说明已到底，防止触底反复拉取
      if (!reset && merged.length == before) _isEnd = true;
      _page = page;
      _loadingMore = false;
    });
    if (_cacheKey.isNotEmpty) {
      SheetCache.save(_cacheKey, _songs);
    }
  }

  Future<void> _loadSongs({bool reset = false, bool silent = false}) async {
    final catalog = _catalog;
    final source = _source;
    if (catalog == null || source == null) return;
    if (reset) {
      if (!silent) _loading = true;
      _page = 1;
      _isEnd = false;
    } else {
      if (_isEnd || _loadingMore) return;
      setState(() => _loadingMore = true);
    }
    final page = reset ? 1 : _page + 1;
    final raw = widget.args.raw;
    final List<PluginSearchResult> list;
    bool? pluginIsEnd;
    if (_lxSource != null) {
      list = await _loadLxSongs(raw, page: page, reset: reset);
      if (!mounted) return;
      _applySongs(list, page: page, reset: reset, silent: silent);
      _backfillCovers();
      return;
    }
    switch (widget.args.type) {
      case OnlineDetailType.artist:
        list = await catalog.getArtistWorks(source, raw, page: page);
      case OnlineDetailType.album:
        final r = await catalog.getAlbumSongs(source, raw, page: page);
        list = r.songs;
        pluginIsEnd = r.isEnd;
      case OnlineDetailType.toplist:
        list = await catalog.getTopListDetail(source, raw, page: page);
      case OnlineDetailType.playlist:
        final item = Map<String, dynamic>.from(raw);
        if (item['_isAlbum'] == true) {
          item.remove('_isAlbum');
          final r = await catalog.getAlbumSongs(source, item, page: page);
          list = r.songs;
          pluginIsEnd = r.isEnd;
        } else {
          final r =
              await catalog.getMusicSheetInfoWithEnd(source, raw, page: page);
          list = r.songs;
          pluginIsEnd = r.isEnd;
        }
    }
    if (!mounted) return;
    _applySongs(list,
        page: page, reset: reset, silent: silent, pluginIsEnd: pluginIsEnd);
    _backfillCovers();
  }

  Future<List<PluginSearchResult>> _loadLxSongs(
    Map<String, dynamic> raw, {
    required int page,
    required bool reset,
  }) async {
    final source = _source!;
    final lxKey = _lxSource!;
    switch (widget.args.type) {
      case OnlineDetailType.artist:
        return lxHostSearchFallback(source, lxKey, widget.args.title,
            limit: 60);
      case OnlineDetailType.album:
        var results = <PluginSearchResult>[];
        final albumId =
            (raw['albumMid'] ?? raw['albumId'] ?? '').toString();
        if (albumId.isNotEmpty) {
          try {
            final json = await frb.lxAlbumSongs(
              source: lxKey,
              albumId: albumId,
              page: page,
              limit: 60,
            );
            final list = jsonDecode(json);
            if (list is List) {
              results = list
                  .whereType<Map>()
                  .map((e) => e.cast<String, dynamic>())
                  .where((m) =>
                      (m['songmid'] ?? m['song_id'] ?? '').toString().isNotEmpty)
                  .map((m) => lxSearchItemToResult(lxKey, m))
                  .toList();
            }
          } catch (e, st) {
            AppLog.warn('plugin',
                '[lxAlbumSongs] $lxKey album=$albumId EXCEPTION: $e\n$st');
          }
        }
        if (results.isEmpty && reset) {
          final searchResult = await lxHostSearchFallback(
              source, lxKey, widget.args.title, limit: 60);
          final nameNorm = widget.args.title.trim().toLowerCase();
          results = searchResult.where((s) {
            final albumNorm = s.albumName.trim().toLowerCase();
            return albumNorm == nameNorm ||
                albumNorm.contains(nameNorm) ||
                nameNorm.contains(albumNorm);
          }).toList();
          if (results.isEmpty) results = searchResult;
        }
        return results;
      case OnlineDetailType.playlist:
        final playlistId = (raw['_lxPlaylistId'] ?? '').toString();
        return lxHostPlaylistTracksFallback(source, lxKey, playlistId,
            page: page);
      case OnlineDetailType.toplist:
        final boardId = (raw['id'] ?? '').toString();
        final songs =
            await lxToplistBoardSongsFallback(lxKey, boardId, page: page);
        return songs.map((m) => lxSearchItemToResult(lxKey, m)).toList();
    }
  }

  Future<List<MfAlbumItem>> _deriveLxAlbums() async {
    final source = _source!;
    final songs = await lxHostSearchFallback(
        source, _lxSource!, widget.args.title, limit: 60);
    final map = <String, MfAlbumItem>{};
    for (final s in songs) {
      final name = s.albumName.trim();
      if (name.isEmpty) continue;
      final id = s.albumId ?? s.albumMid ?? name;
      final key = '${s.source}:$id';
      final existing = map[key];
      if (existing != null) {
        if ((existing.coverUrl == null || existing.coverUrl!.isEmpty) &&
            (s.img != null && s.img!.isNotEmpty)) {
          map[key] = MfAlbumItem(
            id: existing.id,
            name: existing.name,
            artist: existing.artist,
            coverUrl: s.img,
            platform: existing.platform,
            pluginId: existing.pluginId,
            raw: existing.raw,
          );
        }
        continue;
      }
      map[key] = MfAlbumItem(
        id: id,
        name: name,
        artist: s.singer,
        coverUrl: s.img,
        platform: s.source,
        pluginId: source.id,
        raw: <String, dynamic>{
          '_lxSource': _lxSource!,
          'id': id,
          'name': name,
          'albumId': s.albumId,
          'albumMid': s.albumMid,
        },
      );
    }
    return map.values.toList();
  }

  void _backfillCovers() {
    final source = _source;
    if (source == null) return;
    if (lxPlatformCodeOf(source) == null) return;
    final version = ++_coverFetchVersion;
    final pending = <int>[];
    for (var i = 0; i < _songs.length; i++) {
      final r = _songs[i];
      if ((r.img == null || r.img!.isEmpty) && r.songmid.isNotEmpty) {
        pending.add(i);
      }
    }
    if (pending.isEmpty) return;
    var cursor = 0;
    Future<void> worker() async {
      while (cursor < pending.length) {
        final idx = pending[cursor++];
        if (version != _coverFetchVersion || !mounted) return;
        final r = _songs[idx];
        final cover = await fetchLxCoverForSong(source, r);
        if (cover == null || version != _coverFetchVersion || !mounted) return;
        if (idx >= _songs.length) continue;
        setState(() => _songs[idx] = _songs[idx].copyWith(img: cover));
      }
    }

    final n = pending.length < 3 ? pending.length : 3;
    for (var i = 0; i < n; i++) {
      unawaited(worker());
    }
  }

  Future<void> _loadAlbums() async {
    final catalog = _catalog;
    final source = _source;
    if (catalog == null || source == null) return;
    final List<MfAlbumItem> albums;
    if (_lxSource != null) {
      albums = await _deriveLxAlbums();
    } else {
      albums = await catalog.getArtistAlbums(source, widget.args.raw);
    }
    if (!mounted) return;
    setState(() => _albums = albums);
  }

  Future<void> _loadIntro() async {
    final catalog = _catalog;
    final source = _source;
    if (catalog == null || source == null) return;
    if (_lxSource != null) {
      if (!mounted) return;
      setState(() {
        _intro = '';
        _introLoaded = true;
      });
      return;
    }
    final intro = await catalog.getArtistInfo(source, widget.args.raw);
    if (!mounted) return;
    setState(() {
      _intro = intro;
      _introLoaded = true;
    });
  }

  void _playAll() => _play(0);

  QueueItem _queueItemOf(PluginSearchResult r) {
    final source = _source!;
    if (_lxSource != null && _searchService != null) {
      return _searchService!.toQueueItem(source, r);
    }
    return PluginCatalogService.toQueueItem(source, r);
  }

  void _play(int index) {
    final source = _source;
    if (source == null) return;
    final queue = _songs.map(_queueItemOf).toList();
    if (queue.isEmpty) return;
    ref.read(playerProvider.notifier).playQueue(queue, startIndex: index);
  }

  QueueItem? _queueItem(int index) {
    final source = _source;
    if (source == null) return null;
    return _queueItemOf(_songs[index]);
  }

  void _toggleFavorite(int index) {
    final item = _queueItem(index);
    if (item == null) return;
    final wasFav = ref.read(favoritesProvider).contains(item.path);
    ref.read(favoritesProvider.notifier).toggle(item);
    showXianYuToast(context, wasFav ? tr('已取消收藏：{t}', {'t': item.title}) : tr('已收藏：{t}', {'t': item.title}));
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
    final item = _queueItemOf(_songs[index]);
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
            tabs:   [
              Tab(text: tr('歌曲')),
              Tab(text: tr('专辑')),
              Tab(text: tr('简介')),
            ],
          )
        : null;

    return Scaffold(
      backgroundColor: appScaffoldBackground(context, ref),
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
                      : (isArtist ? tr('歌手') : switch (a.type) {
                          OnlineDetailType.album => tr('专辑'),
                          OnlineDetailType.toplist => tr('榜单'),
                          _ => tr('歌单'),
                        }),
                  coverUrl: a.coverUrl,
                  circular: isArtist,
                  songCount: _songs.length,
                  onPlayAll: _songs.isNotEmpty ? _playAll : null,
                  favoriteLabel: switch (a.type) {
                    OnlineDetailType.album => tr('收藏整张专辑'),
                    _ => tr('收藏整张歌单'),
                  },
                  isFavorite: ref.watch(favoritesProvider).isCollectionFavorite(
                      '${a.type.name}:${a.pluginId}:${a.title}'),
                  onToggleFavorite:
                      isArtist || a.type == OnlineDetailType.toplist
                          ? null
                          : () => _toggleCollectionFavorite(),
                ),
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
        child: Text(
          _sourceMissing ? tr('音源不可用') : tr('暂无歌曲'),
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
      );
    }
    return Stack(
      children: [
        NotificationListener<ScrollNotification>(
          onNotification: (n) {
            if (n.metrics.pixels > n.metrics.maxScrollExtent - 300) {
              _loadSongs();
            }
            return false;
          },
          child: ListView.separated(
            controller: _songScroll,
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
                    tr('已经到底啦'),
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
          return _stagger.wrap(
            i,
            _rowShell(i, _queueItemOf(r).path,
            Builder(
              builder: (rowContext) {
              BuildContext? coverCtx;
              final g = songRowPlay(ref, onPlay: () async {
                final ok = await launchFlyCover(
                  rowContext,
                  coverContext: coverCtx,
                  coverSize: m.songCover,
                  vPad: m.vPad,
                  networkUrl: r.img,
                  radius: m.songRadius,
                );
                if (ok) _play(i);
              });
              return g.wrap(
                CoverRow(
                  cover: Builder(
                    builder: (c) {
                      coverCtx = c;
                      return OnlineCover(
                          url: r.img, size: m.songCover, radius: m.songRadius);
                    },
                  ),
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
                        tooltip: tr('收藏'),
                        onPressed: () => _toggleFavorite(i),
                      ),
                      if (r.interval.isNotEmpty)
                        Text(
                          r.interval,
                          style: TextStyle(
                              fontSize: m.subtitleSize,
                              color: scheme.onSurfaceVariant),
                        ),
                      IconButton(
                        icon: const Icon(Icons.more_horiz, size: 22),
                        color: scheme.onSurfaceVariant,
                        tooltip: tr('更多'),
                        onPressed: () => _songActions(i),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
          ),
        );
        },
        ),
        ),
        SongListScrollFabs(
          controller: _songScroll,
          paths: [for (final r in _songs) _queueItemOf(r).path],
          rowTopOf: (i) => 6 + i * (m.songCover + 2 * m.vPad),
          itemExtent: m.songCover + 2 * m.vPad,
          bottom: MediaQuery.of(context).padding.bottom + 100 + 8,
          right: 12,
        ),
      ],
    );
  }

  /// 行首槽位：序号/播放标识（桌面端同款），在线详情不可拖拽
  Widget _rowShell(int i, String songPath, Widget row) => Stack(
        children: [
          Padding(padding: const EdgeInsets.only(left: 44), child: row),
          Positioned(
            left: 8,
            top: 0,
            bottom: 0,
            width: 36,
            child: Center(
              child: SongRowLeading(index: i, songPath: songPath),
            ),
          ),
        ],
      );

  Widget _buildAlbumList(ColorScheme scheme) {
    if (_albums.isEmpty) {
      return Center(
        child: Text(tr('暂无专辑'), style: TextStyle(color: scheme.onSurfaceVariant)),
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
        child: Text(tr('暂无简介'), style: TextStyle(color: scheme.onSurfaceVariant)),
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
                  songCount > 0 ? tr('{sub} · {n} 首', {'sub': subtitle, 'n': songCount}) : subtitle,
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
                      label:   Text(tr('播放全部'), style: TextStyle(fontSize: 13)),
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
