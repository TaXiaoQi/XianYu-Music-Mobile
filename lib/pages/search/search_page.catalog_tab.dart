part of 'search_page.dart';
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

// ==================== 歌手/专辑/歌单 tab ====================

class _CatalogTab extends ConsumerStatefulWidget {
  final _CatalogKind kind;
  final String keyword;
  final _SourceItem source;

  const _CatalogTab({
    required this.kind,
    required this.keyword,
    required this.source,
  });

  @override
  ConsumerState<_CatalogTab> createState() => _CatalogTabState();
}

class _CatalogTabState extends ConsumerState<_CatalogTab>
    with AutomaticKeepAliveClientMixin {
  List<_CatalogItem> _items = const [];
  bool _loading = false;
  String _searchedHash = '';
  _CatalogKind? _searchedKind;
  int _page = 1;
  bool _hasMore = false;
  bool _loadingMore = false;

  /// 歌手/专辑/歌单网格：桌面端搜索目录网格同款按行入场（base 200ms / 行 140ms / 600ms）
  late final StaggerWindow _gridStagger = StaggerWindow(
    baseDelayMs: 200,
    staggerMs: 140,
    rowMs: 600,
    durationMs: 600,
    maxRows: 7,
    onClosed: () {
      if (mounted) setState(() {});
    },
  );

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    if (widget.keyword.trim().isNotEmpty) {
      final q = widget.keyword.trim();
      _search(q, '${widget.source.id}|${widget.kind.name}|$q');
    }
  }

  @override
  void didUpdateWidget(covariant _CatalogTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    final q = widget.keyword.trim();
    if (q.isEmpty) return;
    final hash = '${widget.source.id}|${widget.kind.name}|$q';
    if (hash != _searchedHash) _search(q, hash);
  }

  @override
  void dispose() {
    _gridStagger.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final scheme = Theme.of(context).colorScheme;
    final q = widget.keyword.trim();
    final name = _kindName(widget.kind);

    if (q.isEmpty) {
      return _emptyHint(
          tr('输入关键词搜索{name}', {'name': name}),
          scheme,
          source: widget.source.name);
    }
    if (_loading && _items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_items.isEmpty) {
      return _emptyHint(
          tr('没有找到相关{name}', {'name': name}),
          scheme,
          source: widget.source.name);
    }

    // 歌手/专辑/歌单统一网格（与桌面端搜索目录网格对齐）：歌手圆形头像居中，
    // 专辑/歌单方形封面卡片，与音源榜单页同款
    return _buildCatalogGrid(
      scheme,
      bottomInset: 92.0 + MediaQuery.of(context).padding.bottom,
      showMore: _isLxPlaylist && _loadingMore,
    );
  }

  /// 搜索目录网格：歌手圆形头像居中，专辑/歌单方形封面卡片，与音源榜单页同款
  Widget _buildCatalogGrid(
    ColorScheme scheme, {
    required double bottomInset,
    required bool showMore,
  }) {
    final isArtist = widget.kind == _CatalogKind.artist;
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.depth == 0) {
          // 滚动立即关掉入场窗口（桌面端同款），避免滚动中段的卡片带延迟闪现
          _gridStagger.stop();
          if (n.metrics.axis == Axis.vertical) _maybeLoadMore(n.metrics);
        }
        return false;
      },
      child: LayoutBuilder(
        builder: (context, cons) {
          // 竖屏固定 3 列；横屏列数动态（与榜单页嵌入模式同款 92 上限）
          final landscape =
              MediaQuery.of(context).orientation == Orientation.landscape;
          final cols =
              landscape ? (cons.maxWidth / 92).ceil().clamp(1, 8) : 3;
          return GridView.builder(
            // 水平 14 的页边距与音源榜单页一致，保证 3 列下卡片宽度和间距相同
            padding: EdgeInsets.fromLTRB(
              14,
              _ContentTopInsetScope.of(context),
              14,
              bottomInset,
            ),
            gridDelegate: landscape
                ? (isArtist
                    ? const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 92,
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 10,
                        childAspectRatio: 0.8,
                      )
                    : const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 92,
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 10,
                        childAspectRatio: 0.7,
                      ))
                : (isArtist
                    ? const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3,
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 12,
                        childAspectRatio: 0.8,
                      )
                    : const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3,
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 12,
                        childAspectRatio: 0.72,
                      )),
            itemCount: _items.length + (showMore ? 1 : 0),
            itemBuilder: (context, i) {
              if (i >= _items.length) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                );
              }
              final item = _items[i];
              return _gridStagger.wrap(
                i ~/ cols,
                isArtist
                    ? _artistGridCard(item, compact: landscape)
                    : _catalogGridCard(item, compact: landscape),
              );
            },
          );
        },
      ),
    );
  }

  Widget _catalogGridCard(_CatalogItem item, {required bool compact}) {
    final scheme = Theme.of(context).colorScheme;
    final subtitle = [item.subtitle, item.sourceTag]
        .where((x) => x.isNotEmpty)
        .join(' · ');
    return InkWell(
      borderRadius: BorderRadius.circular(compact ? 10 : 12),
      onTap: () => _open(item),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(compact ? 10 : 12),
              child: _catalogGridCover(item, compact: compact),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            item.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: compact ? 12 : 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (subtitle.isNotEmpty)
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
        ],
      ),
    );
  }

  Widget _catalogGridCover(_CatalogItem item, {required bool compact}) {
    final scheme = Theme.of(context).colorScheme;
    final size = compact ? 92.0 : 200.0;
    final radius = compact ? 10.0 : 12.0;
    if (item.localAlbum != null) {
      return CoverImage(
        songPath: item.localAlbum!.firstSongPath,
        width: size,
        height: size,
        radius: radius,
        icon: Icons.album,
      );
    }
    if (item.localPlaylist != null) {
      return Container(
        color: scheme.secondaryContainer,
        alignment: Alignment.center,
        child: Icon(Icons.queue_music, size: size * 0.4, color: scheme.primary),
      );
    }
    return OnlineCover(url: item.coverUrl, size: size, radius: radius);
  }

  /// 歌手网格卡片：圆形头像 + 居中标题/副标题（桌面端搜索目录网格同款）
  Widget _artistGridCard(_CatalogItem item, {required bool compact}) {
    final scheme = Theme.of(context).colorScheme;
    final subtitle = [item.subtitle, item.sourceTag]
        .where((x) => x.isNotEmpty)
        .join(' · ');
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _open(item),
      child: Column(
        children: [
          SizedBox(
            width: compact ? 72 : 88,
            height: compact ? 72 : 88,
            child: _artistGridAvatar(item),
          ),
          const SizedBox(height: 6),
          Text(
            item.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          if (subtitle.isNotEmpty)
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
        ],
      ),
    );
  }

  Widget _artistGridAvatar(_CatalogItem item) {
    const size = 88.0;
    final a = item.localArtist;
    if (a != null) {
      return CoverImage(
        songPath: a.firstSongPath,
        width: size,
        height: size,
        radius: size / 2,
        icon: Icons.person,
        placeholder: _letterLeading(a.name, Theme.of(context).colorScheme),
      );
    }
    return OnlineCover(url: item.coverUrl, size: size, radius: size / 2);
  }
}

extension _CatalogTabSearch on _CatalogTabState {
  bool get _isLxPlaylist =>
      widget.source.type == _SourceType.lx &&
      widget.kind == _CatalogKind.playlist;

  String _kindName(_CatalogKind k) => switch (k) {
        _CatalogKind.artist => tr('歌手'),
        _CatalogKind.album => tr('专辑'),
        _CatalogKind.playlist => tr('歌单'),
      };

  List<PluginSource> _plugins() => ref.read(pluginManagerProvider).sources;

  Future<void> _search(String q, String hash) async {
    final src = widget.source;
    setState(() {
      _searchedHash = hash;
      _loading = q.isNotEmpty;
      if (q.isEmpty) _items = const [];
      if (_searchedKind != widget.kind) _items = const [];
      _page = 1;
      _hasMore = false;
      _loadingMore = false;
    });
    if (q.isEmpty) return;

    final List<_CatalogItem> out = [];
    try {
      if (src.isLocal) {
        out.addAll(_searchLocal(q));
      } else if (src.type == _SourceType.musicfree) {
        out.addAll(await _searchMusicFree(q));
      } else {
        if (widget.kind == _CatalogKind.playlist) {
          final sheets = await _fetchLxSheets(q, 1);
          _hasMore = sheets.length >= 30;
          out.addAll(_lxSheetsItems(sheets));
        } else {
          out.addAll(await _searchLxDerive(q));
        }
      }
    } catch (e) {
      AppLog.warn('plugin', '[search] ${widget.source.name} 搜索异常: $e');
      if (!mounted) return;
      if (_searchedHash != hash) return;
      setState(() {
        _searchedHash = '';
        _items = const [];
        _loading = false;
      });
      return;
    }
    if (!mounted) return;
    if (_searchedHash != hash) return;
    _gridStagger.start();
    setState(() {
      _items = out;
      _searchedKind = widget.kind;
      _loading = false;
    });
  }

  List<_CatalogItem> _searchLocal(String q) {
    final lower = q.toLowerCase();
    final tag = tr('本地');
    final out = <_CatalogItem>[];
    try {
      switch (widget.kind) {
        case _CatalogKind.artist:
          final artists = ref.read(libraryProvider).artists;
          for (final a in artists) {
            if (a.name.toLowerCase().contains(lower)) {
              out.add(_CatalogItem(
                kind: 'artist',
                title: a.name,
                subtitle: tr('{n} 首', {'n': a.count}),
                sourceTag: tag,
                localArtist: a,
              ));
            }
          }
        case _CatalogKind.album:
          final albums = ref.read(libraryProvider).albums;
          for (final a in albums) {
            if (a.name.toLowerCase().contains(lower) ||
                a.artist.toLowerCase().contains(lower)) {
              out.add(_CatalogItem(
                kind: 'album',
                title: a.name,
                subtitle: tr('{artist} · {n} 首', {'artist': a.artist, 'n': a.count}),
                sourceTag: tag,
                localAlbum: a,
              ));
            }
          }
        case _CatalogKind.playlist:
          final playlists = ref.read(playlistManagerProvider).playlists;
          for (final p in playlists) {
            if (p.name.toLowerCase().contains(lower)) {
              out.add(_CatalogItem(
                kind: 'playlist',
                title: p.name,
                subtitle: tr('{n} 首', {'n': p.songs.length}),
                sourceTag: tag,
                localPlaylist: p,
              ));
            }
          }
      }
    } catch (e) { AppLog.warn('search', '本地目录搜索失败: $e'); }
    return out;
  }

  Future<List<_CatalogItem>> _searchMusicFree(String q) async {
    final engine = await ref.read(pluginEngineProvider.future);
    final source = widget.source;
    final catalog = PluginCatalogService(engine, _plugins());
    final out = <_CatalogItem>[];
    final tag = source.name;
    try {
      switch (widget.kind) {
        case _CatalogKind.artist:
          final list = await catalog.searchArtists(source.plugin!, q);
          for (final a in list) {
            out.add(_CatalogItem(
              kind: 'artist',
              title: a.name,
              coverUrl: a.avatarUrl,
              sourceTag: tag,
              onlinePlugin: source.plugin,
              onlineRaw: a.raw,
            ));
          }
        case _CatalogKind.album:
          final list = await catalog.searchAlbums(source.plugin!, q);
          for (final a in list) {
            out.add(_CatalogItem(
              kind: 'album',
              title: a.name,
              subtitle: a.artist,
              coverUrl: a.coverUrl,
              sourceTag: tag,
              onlinePlugin: source.plugin,
              onlineRaw: a.raw,
            ));
          }
        case _CatalogKind.playlist:
          final list = await catalog.searchSheets(source.plugin!, q);
          for (final s in list) {
            out.add(_CatalogItem(
              kind: 'playlist',
              title: s.title,
              subtitle: s.subtitle,
              coverUrl: s.coverUrl,
              sourceTag: tag,
              onlinePlugin: source.plugin,
              onlineRaw: s.raw,
            ));
          }
      }
    } catch (e) { AppLog.warn('search', 'MusicFree 目录搜索失败: $e'); }
    return out;
  }

  Future<List<_CatalogItem>> _searchLxDerive(String q) async {
    final engine = await ref.read(pluginEngineProvider.future);
    final source = widget.source;
    final songs = await engine
        .searchInPlugin(source.plugin!, source.lxKey ?? '', q, limit: 60);
    final isArtist = widget.kind == _CatalogKind.artist;
    final map = <String, _CatalogItem>{};
    for (final s in songs) {
      final key = isArtist ? s.singer.trim() : s.albumName.trim();
      if (key.isEmpty) continue;
      final existing = map[key];
      if (existing != null) {
        existing.directSongs.add(s);
        continue;
      }
      map[key] = _CatalogItem(
        kind: isArtist ? 'artist' : 'album',
        title: key,
        subtitle: isArtist ? '' : s.singer,
        coverUrl: s.img,
        sourceTag: source.name,
        directSource: source.plugin,
        directSongs: [s],
      );
    }
    return map.values.toList();
  }

  Future<List<Map<String, dynamic>>> _fetchLxSheets(String q, int page) async {
    final source = widget.source;
    return lxHostPlaylistSearchFallback(
      source.plugin!,
      source.lxKey ?? '',
      q,
      page: page,
      limit: 30,
    );
  }

  List<_CatalogItem> _lxSheetsItems(List<Map<String, dynamic>> sheets) {
    final source = widget.source;
    final out = <_CatalogItem>[];
    for (final s in sheets) {
      final trackCount = s['trackCount'];
      final playCount = s['playCount'];
      final parts = <String>[
        if ((s['artist'] as String?)?.isNotEmpty == true) s['artist'] as String,
        if (trackCount is num && trackCount > 0)
          tr('{n} 首', {'n': trackCount.toInt()}),
        if (playCount is num && playCount > 0) _formatPlayCount(playCount),
      ];
      out.add(_CatalogItem(
        kind: 'playlist',
        title: s['title'] as String,
        subtitle: parts.join(' · '),
        coverUrl: s['coverUrl'] as String?,
        sourceTag: source.name,
        onlinePlugin: source.plugin,
        onlineRaw: s,
      ));
    }
    return out;
  }

  Future<void> _loadNextLxPage() async {
    if (_loading || _loadingMore || !_hasMore) return;
    final q = widget.keyword.trim();
    if (q.isEmpty) return;
    setState(() => _loadingMore = true);
    final next = _page + 1;
    try {
      final sheets = await _fetchLxSheets(q, next);
      if (!mounted) return;
      final add = _lxSheetsItems(sheets);
      setState(() {
        if (add.isNotEmpty) {
          _items = [..._items, ...add];
          _page = next;
        }
        _hasMore = sheets.length >= 30;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _hasMore = false;
        _loadingMore = false;
      });
    }
  }

  void _maybeLoadMore(ScrollMetrics metrics) {
    if (!_isLxPlaylist) return;
    if (metrics.extentAfter > 320) return;
    _loadNextLxPage();
  }

  void _open(_CatalogItem item) {
    FocusScope.of(context).unfocus();
    if (item.localArtist != null) {
      final a = item.localArtist!;
      context.push('/song-list', extra: SongListArgs(
        title: a.name,
        loader: () =>
            ref.read(libraryProvider.notifier).songsByArtist(a.name),
      ));
      return;
    }
    if (item.localAlbum != null) {
      final a = item.localAlbum!;
      context.push('/song-list', extra: SongListArgs(
        title: a.name,
        loader: () =>
            ref.read(libraryProvider.notifier).songsByAlbum(a.key),
      ));
      return;
    }
    if (item.localPlaylist != null) {
      ref
          .read(playlistManagerProvider.notifier)
          .play(item.localPlaylist!, 0);
      return;
    }
    final engine = ref.read(pluginEngineProvider).valueOrNull;
    if (engine == null) return;
    if (item.isDirectPlay) {
      final source = item.directSource!;
      final first = item.directSongs.first;
      final isAlbum = item.kind == 'album';
      final lxKey = first.source;
      final raw = <String, dynamic>{
        '_lxSource': lxKey,
        'name': item.title,
        if (isAlbum) ...{
          'id': first.albumId ?? first.albumMid ?? item.title,
          'albumId': first.albumId,
          'albumMid': first.albumMid,
        },
      };
      context.push(
        '/online-detail',
        extra: OnlineDetailArgs(
          type: isAlbum ? OnlineDetailType.album : OnlineDetailType.artist,
          pluginId: source.id,
          title: item.title,
          subtitle: item.subtitle,
          coverUrl: item.coverUrl,
          raw: raw,
        ),
      );
      return;
    }
    context.push(
      '/online-detail',
      extra: OnlineDetailArgs(
        type: switch (item.kind) {
          'artist' => OnlineDetailType.artist,
          'album' => OnlineDetailType.album,
          _ => OnlineDetailType.playlist,
        },
        pluginId: item.onlinePlugin?.id ?? '',
        title: item.title,
        subtitle: item.subtitle,
        coverUrl: item.coverUrl,
        raw: item.onlineRaw ?? const {},
      ),
    );
  }
}
