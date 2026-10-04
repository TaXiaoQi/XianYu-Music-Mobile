part of 'search_page.dart';
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

// ==================== 单曲 tab ====================

class _TrackTab extends ConsumerStatefulWidget {
  final String keyword;
  final _SourceItem source;

  const _TrackTab({
    required this.keyword,
    required this.source,
  });

  @override
  ConsumerState<_TrackTab> createState() => _TrackTabState();
}

class _ContentTopInsetScope extends InheritedWidget {
  const _ContentTopInsetScope({required this.inset, required super.child});

  final double inset;

  static double of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_ContentTopInsetScope>()
          ?.inset ??
      0;

  @override
  bool updateShouldNotify(_ContentTopInsetScope oldWidget) =>
      oldWidget.inset != inset;
}

class _TrackTabState extends ConsumerState<_TrackTab>
    with AutomaticKeepAliveClientMixin {
  List<_TrackEntry> _results = const [];
  bool _loading = false;
  String _searchedHash = '';
  List<String> _paths = const [];
  final ScrollController _scroll = ScrollController();
  String _searchError = '';
  late final StaggerWindow _stagger = StaggerWindow(onClosed: () {
    if (mounted) setState(() {});
  });

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    if (widget.keyword.trim().isNotEmpty) {
      final q = widget.keyword.trim();
      _search(q, '${widget.source.id}|$q');
    }
  }

  @override
  void didUpdateWidget(covariant _TrackTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    final q = widget.keyword.trim();
    if (q.isEmpty) return;
    final hash = '${widget.source.id}|$q';
    if (hash != _searchedHash) _search(q, hash);
  }

  @override
  void dispose() {
    _stagger.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final scheme = Theme.of(context).colorScheme;
    final q = widget.keyword.trim();
    final m = ListMetrics.ofRef(ref);
    final favorites = ref.watch(favoritesProvider);

    if (q.isEmpty) {
      return _emptyHint(
          tr('输入关键词搜索音乐'), scheme, source: widget.source.name);
    }
    if (_loading && _results.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_searchError.isNotEmpty && _results.isEmpty) {
      return _emptyHint(
        tr('搜索失败：{e}', {'e': _searchError}),
        scheme,
        source: widget.source.name,
        actionLabel: tr('重试'),
        onAction: () => _search(q, '${widget.source.id}|$q'),
      );
    }
    if (_results.isEmpty) {
      return _emptyHint(
          tr('没有找到相关歌曲'), scheme, source: widget.source.name);
    }

    final bottomInset = 92.0 + MediaQuery.of(context).padding.bottom;
    final topInset = _ContentTopInsetScope.of(context);
    final rowExtent = m.songCover + 2 * m.vPad;
    return Stack(
      children: [
        ListView.builder(
          controller: _scroll,
          padding: EdgeInsets.only(
            top: topInset,
            bottom: bottomInset,
          ),
      itemCount: _results.length,
      itemBuilder: (context, i) {
        final e = _results[i];
        if (e.isLocal) {
          final s = e.localSong!;
          return _stagger.wrap(
            i,
            _rowShell(i, s.path,
            Builder(
              builder: (rowContext) {
                BuildContext? coverCtx;
                return CoverRow(
                background: themeTintOrNull(ref, 'sr.item'),
                cover: Builder(
                  builder: (c) {
                    coverCtx = c;
                    return SongCover(song: s, size: m.songCover);
                  },
                ),
                title: highlightedText(s.title, q, scheme.primary,
                    maxLines: 1,
                    style: TextStyle(
                        fontSize: m.titleSize, fontWeight: FontWeight.w600)),
                subtitle: Text(
                  [s.artist, s.album, tr('本地')]
                      .where((x) => x.isNotEmpty)
                      .join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: m.subtitleSize, color: scheme.onSurfaceVariant),
                ),
                verticalPadding: m.vPad,
                onTap: () async {
                  final from = _coverSourceRect(rowContext, coverCtx);
                  _play(i);
                  if (from == null) return;
                  if (!await FlyingCover.instance.waitTargetReady()) return;
                  await FlyingCover.instance.launch(
                    fromRect: from,
                    songPath: s.path,
                    thumbPath: s.coverThumbPath,
                    radius: m.songRadius,
                  );
                },
                );
              },
            ),
            ),
          );
        }
        final r = e.pluginResult!;
        final item = _queueItem(i);
        final isFav = item != null && favorites.contains(item.path);
        return _stagger.wrap(
          i,
          _rowShell(i, item?.path ?? '',
          Builder(
            builder: (rowContext) {
              BuildContext? coverCtx;
              return CoverRow(
              background: themeTintOrNull(ref, 'sr.item'),
              cover: Builder(
                builder: (c) {
                  coverCtx = c;
                  return OnlineCover(
                      url: r.img, size: m.songCover, radius: m.songRadius);
                },
              ),
              title: highlightedText(r.name, q, scheme.primary,
                  maxLines: 1,
                  style: TextStyle(
                      fontSize: m.titleSize, fontWeight: FontWeight.w600)),
              subtitle: Text(
                [r.singer, r.albumName, widget.source.name]
                    .where((x) => x.isNotEmpty)
                    .join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: m.subtitleSize, color: scheme.onSurfaceVariant),
              ),
              verticalPadding: m.vPad,
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
                Text(
                  r.interval,
                  style: TextStyle(
                      fontSize: m.subtitleSize, color: scheme.outline),
                ),
                IconButton(
                  icon: const Icon(Icons.more_horiz, size: 22),
                  color: scheme.onSurfaceVariant,
                  tooltip: tr('更多'),
                  onPressed: () => _openActions(i),
                ),
              ],
            ),
            onLongPress: () => _openActions(i),
            onTap: () async {
                try {
                  final from = _coverSourceRect(rowContext, coverCtx);
                  _play(i);
                  if (from == null) return;
                  if (!await FlyingCover.instance.waitTargetReady()) return;
                  await FlyingCover.instance.launch(
                    fromRect: from,
                    networkUrl: r.img,
                    radius: m.songRadius,
                  );
                } catch (e) {
                  AppLog.debug('search', '封面飞入动画失败: $e');
                }
              },
            );
            },
          ),
          ),
        );
      },
        ),
        SongListScrollFabs(
          controller: _scroll,
          paths: _paths,
          rowTopOf: (i) => topInset + i * rowExtent,
          itemExtent: rowExtent,
          bottom: bottomInset + 8,
          right: 12,
        ),
      ],
    );
  }

  /// 行首槽位：序号/播放标识（桌面端同款），搜索结果不可拖拽
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
}

extension _TrackTabActions on _TrackTabState {
  List<PluginSource> _plugins() => ref.read(pluginManagerProvider).sources;

  Future<void> _search(String q, String hash) async {
    final src = widget.source;
    setState(() {
      _searchedHash = hash;
      _loading = q.isNotEmpty;
      _searchError = '';
      if (q.isEmpty) _results = const [];
    });
    if (q.isEmpty) return;

    final List<_TrackEntry> out = [];
    try {
      if (src.isLocal) {
        final dbPath = await ref.read(dbPathProvider.future);
        final json = await searchLibrarySongs(
            dbPath: dbPath, query: q, limit: BigInt.from(100));
        final list = (jsonDecode(json) as List)
            .map((e) => Song.fromJson(e as Map<String, dynamic>))
            .toList();
        out.addAll(list.map((s) =>
            _TrackEntry(isLocal: true, localSong: s)));
        ref.read(accountApiProvider).reportSearch(q, 'local', list.length);
      } else {
        final engine = await ref.read(pluginEngineProvider.future);
        List<PluginSearchResult> items;
        if (src.type == _SourceType.musicfree) {
          final catalog = PluginCatalogService(engine, _plugins());
          items = await catalog.searchMusic(src.plugin!, q);
        } else {
          items = await engine.searchInPlugin(src.plugin!, src.lxKey!, q);
        }
        out.addAll(items.map((r) => _TrackEntry(
            isLocal: false, pluginSource: src.plugin, pluginResult: r)));
        ref.read(accountApiProvider).reportSearch(q, 'online', items.length);
      }
    } catch (e) {
      AppLogger.instance.log('search', '音源搜索失败 source=${src.id} q=$q error=$e');
      if (!mounted) return;
      if (_searchedHash != hash) return;
      setState(() {
        _searchedHash = '';
        _searchError = e.toString();
        _results = const [];
        _loading = false;
      });
      return;
    }
    if (!mounted) return;
    if (_searchedHash != hash) return;
    setState(() {
      _results = out;
      _paths = _buildPaths(out);
      _loading = false;
      // 结果就位时开窗重播入场（换音源/换关键词等同理）
      _stagger.start();
    });
  }

  List<String> _buildPaths(List<_TrackEntry> out) {
    final engine = ref.read(pluginEngineProvider).valueOrNull;
    if (engine == null) {
      return [
        for (final e in out) e.isLocal ? (e.localSong?.path ?? '') : '',
      ];
    }
    final service = PluginSearchService(engine, _plugins());
    return [
      for (final e in out)
        e.isLocal
            ? (e.localSong?.path ?? '')
            : service.toQueueItem(e.pluginSource!, e.pluginResult!).path,
    ];
  }

  void _play(int index) {
    FocusScope.of(context).unfocus();
    final e = _results[index];
    if (e.isLocal) {
      ref.read(libraryProvider.notifier).playList([e.localSong!], 0);
      return;
    }
    final engine = ref.read(pluginEngineProvider).valueOrNull;
    if (engine == null) return;
    final service = PluginSearchService(engine, _plugins());
    final item = service.toQueueItem(e.pluginSource!, e.pluginResult!);
    ref.read(playerProvider.notifier).playQueue([item], startIndex: 0);
  }

  Rect? _coverSourceRect(BuildContext rowContext, BuildContext? coverCtx) {
    final ro = (coverCtx ?? rowContext).findRenderObject();
    if (ro is RenderBox && ro.hasSize) {
      return ro.localToGlobal(Offset.zero) & ro.size;
    }
    return null;
  }

  void _openActions(int index) {
    final item = _queueItem(index);
    if (item == null) return;
    showSongActionsSheet(context, ref: ref, item: item);
  }

  void _toggleFavorite(int index) {
    final item = _queueItem(index);
    if (item == null) return;
    final wasFav = ref.read(favoritesProvider).contains(item.path);
    ref.read(favoritesProvider.notifier).toggle(item);
    showXianYuToast(
        context, wasFav ? tr('已取消收藏：{t}', {'t': item.title}) : tr('已收藏：{t}', {'t': item.title}));
  }

  QueueItem? _queueItem(int index) {
    final e = _results[index];
    if (e.isLocal) return null;
    final engine = ref.read(pluginEngineProvider).valueOrNull;
    if (engine == null) return null;
    return PluginSearchService(engine, _plugins())
        .toQueueItem(e.pluginSource!, e.pluginResult!);
  }
}

