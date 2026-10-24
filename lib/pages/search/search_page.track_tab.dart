part of 'search_page.dart';

// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

// ==================== 单曲 tab ====================

class _TrackTab extends ConsumerStatefulWidget {
  final String keyword;
  final _SourceItem source;

  const _TrackTab({required this.keyword, required this.source});

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
  // 加载更多：在线源滚到底自动以更大 limit 重取（Rust 按页缓存保证旧页
  // 零重复请求），直到某次无新增即认为该源已取完
  bool _loadingMore = false;
  bool _hasMore = false;
  String _lastQuery = '';
  late final StaggerWindow _stagger = StaggerWindow(
    onClosed: () {
      if (mounted) setState(() {});
    },
  );

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
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
      return _emptyHint(tr('输入关键词搜索音乐'), scheme, source: widget.source.name);
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
      return _emptyHint(tr('没有找到相关歌曲'), scheme, source: widget.source.name);
    }

    final bottomInset = 92.0 + MediaQuery.of(context).padding.bottom;
    final topInset = _ContentTopInsetScope.of(context);
    final rowExtent = m.songCover + 2 * m.vPad;
    // 装有启用的音源插件时不展示「本地」来源后缀（与桌面端对齐：在线歌随时
    // 可播，本地匹配行的来源标记意义不大），插件装卸即时刷新
    final hideLocalTag =
        ref.watch(pluginManagerProvider).sources.any((p) => p.enabled);
    return Stack(
      children: [
        ListView.builder(
          controller: _scroll,
          padding: EdgeInsets.only(top: topInset, bottom: bottomInset),
          itemCount: _results.length + ((_hasMore || _loadingMore) ? 1 : 0),
          itemBuilder: (context, i) {
            if (i >= _results.length) {
              return _loadMoreFooter(scheme);
            }
            final e = _results[i];
            if (e.isLocal) {
              final s = e.localSong!;
              return _stagger.wrap(
                i,
                _rowShell(
                  i,
                  s.path,
                  Builder(
                    builder: (rowContext) {
                      BuildContext? coverCtx;
                      return PressableScale(
                        child: CoverRow(
                          background: themeTintOrNull(ref, 'sr.item'),
                          cover: Builder(
                            builder: (c) {
                              coverCtx = c;
                              return SongCover(song: s, size: m.songCover);
                            },
                          ),
                          title: highlightedText(
                            s.title,
                            q,
                            scheme.primary,
                            maxLines: 1,
                            style: TextStyle(
                              fontSize: m.titleSize,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          subtitle: Text(
                            [
                              s.artist,
                              s.album,
                              if (!hideLocalTag) tr('本地'),
                            ].where((x) => x.isNotEmpty).join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: m.subtitleSize,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                          verticalPadding: m.vPad,
                          onTap: () async {
                            final from = _coverSourceRect(rowContext, coverCtx);
                            _play(i);
                            if (from == null) return;
                            if (!await FlyingCover.instance.waitTargetReady())
                              return;
                            await FlyingCover.instance.launch(
                              fromRect: from,
                              songPath: s.path,
                              thumbPath: s.coverThumbPath,
                              radius: m.songRadius,
                            );
                          },
                        ),
                      );
                    },
                  ),
                ),
              );
            }
            final item = _queueItem(i);
            final isFav = item != null && favorites.contains(item.path);
            final cloudItem = e.cloudItem;
            if (cloudItem != null) {
              // 网盘条目：无封面无专辑，subtitle 展示解析歌手（缺省为盘名）。
              // 头部元数据预探命中时补内嵌封面与时长（无则维持原样）。
              // 播放时同样送出封面飞行动画（无图时飞行占位封面）。
              final cloudMeta = ref.watch(
                cloudHeadMetaProvider,
              )[cloudItem.path];
              return _stagger.wrap(
                i,
                _rowShell(
                  i,
                  cloudItem.path,
                  Builder(
                    builder: (rowContext) {
                      BuildContext? coverCtx;
                      return PressableScale(
                        child: CoverRow(
                          background: themeTintOrNull(ref, 'sr.item'),
                          cover: Builder(
                            builder: (c) {
                              coverCtx = c;
                              return OnlineCover(
                                url: cloudItem.coverUrl,
                                filePath: cloudMeta?.coverPath,
                                size: m.songCover,
                                radius: m.songRadius,
                              );
                            },
                          ),
                          title: highlightedText(
                            cloudItem.title,
                            q,
                            scheme.primary,
                            maxLines: 1,
                            style: TextStyle(
                              fontSize: m.titleSize,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          subtitle: Text(
                            [
                              cloudItem.artist,
                              cloudItem.album,
                              if (cloudMeta?.durationSecs != null)
                                _fmtDuration(cloudMeta!.durationSecs!),
                            ].where((x) => x.isNotEmpty).join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: m.subtitleSize,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                          verticalPadding: m.vPad,
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              PressableScale(
                                pressScale: 0.88,
                                child: IconButton(
                                  icon: Icon(
                                    isFav
                                        ? Icons.favorite
                                        : Icons.favorite_border,
                                    size: 20,
                                    color: isFav
                                        ? scheme.primary
                                        : scheme.onSurfaceVariant,
                                  ),
                                  tooltip: tr('收藏'),
                                  onPressed: () => _toggleFavorite(i),
                                ),
                              ),
                              PressableScale(
                                pressScale: 0.88,
                                child: IconButton(
                                  icon: const Icon(Icons.more_horiz, size: 22),
                                  color: scheme.onSurfaceVariant,
                                  tooltip: tr('更多'),
                                  onPressed: () => _openActions(i),
                                ),
                              ),
                              // 来源标与时长上下叠放（收藏页同款行尾）
                              SongTrailingMeta(
                                path: cloudItem.path,
                                isOnline: true,
                                durationText:
                                    cloudMeta?.durationSecs != null
                                        ? _fmtDuration(cloudMeta!.durationSecs!)
                                        : null,
                                fontSize: m.subtitleSize,
                              ),
                            ],
                          ),
                          onLongPress: () => _openActions(i),
                          onTap: () async {
                            try {
                              final from = _coverSourceRect(
                                rowContext,
                                coverCtx,
                              );
                              _play(i);
                              if (from == null) return;
                              if (!await FlyingCover.instance.waitTargetReady())
                                return;
                              await FlyingCover.instance.launch(
                                fromRect: from,
                                songPath: cloudItem.path,
                                networkUrl: cloudItem.coverUrl,
                                // 网盘条目无 URL 封面：预探命中的内嵌封面
                                // 本地路径作为飞行源，否则动画只能用占位块
                                thumbPath: cloudMeta?.coverPath,
                                radius: m.songRadius,
                              );
                            } catch (e) {
                              AppLog.debug('search', '封面飞入动画失败: $e');
                            }
                          },
                        ),
                      );
                    },
                  ),
                ),
              );
            }
            final r = e.pluginResult!;
            return _stagger.wrap(
              i,
              _rowShell(
                i,
                item?.path ?? '',
                Builder(
                  builder: (rowContext) {
                    BuildContext? coverCtx;
                    return PressableScale(
                      child: CoverRow(
                        background: themeTintOrNull(ref, 'sr.item'),
                        cover: Builder(
                          builder: (c) {
                            coverCtx = c;
                            return OnlineCover(
                              url: r.img,
                              size: m.songCover,
                              radius: m.songRadius,
                            );
                          },
                        ),
                        title: highlightedText(
                          r.name,
                          q,
                          scheme.primary,
                          maxLines: 1,
                          style: TextStyle(
                            fontSize: m.titleSize,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        subtitle: Text(
                          [
                            r.singer,
                            r.albumName,
                            widget.source.name,
                          ].where((x) => x.isNotEmpty).join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: m.subtitleSize,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        verticalPadding: m.vPad,
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            PressableScale(
                              pressScale: 0.88,
                              child: IconButton(
                                icon: Icon(
                                  isFav
                                      ? Icons.favorite
                                      : Icons.favorite_border,
                                  size: 20,
                                  color: isFav
                                      ? scheme.primary
                                      : scheme.onSurfaceVariant,
                                ),
                                tooltip: tr('收藏'),
                                onPressed: () => _toggleFavorite(i),
                              ),
                            ),
                            PressableScale(
                              pressScale: 0.88,
                              child: IconButton(
                                icon: const Icon(Icons.more_horiz, size: 22),
                                color: scheme.onSurfaceVariant,
                                tooltip: tr('更多'),
                                onPressed: () => _openActions(i),
                              ),
                            ),
                            // 来源标与时长上下叠放（收藏页同款行尾）
                            SongTrailingMeta(
                              path: item?.path ?? '',
                              isOnline: true,
                              source: widget.source.name,
                              durationText: r.interval,
                              fontSize: m.subtitleSize,
                            ),
                          ],
                        ),
                        onLongPress: () => _openActions(i),
                        onTap: () async {
                          try {
                            final from = _coverSourceRect(rowContext, coverCtx);
                            _play(i);
                            if (from == null) return;
                            if (!await FlyingCover.instance.waitTargetReady())
                              return;
                            await FlyingCover.instance.launch(
                              fromRect: from,
                              networkUrl: r.img,
                              radius: m.songRadius,
                            );
                          } catch (e) {
                            AppLog.debug('search', '封面飞入动画失败: $e');
                          }
                        },
                      ),
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
      Padding(padding: const EdgeInsets.only(left: 34), child: row),
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

  /// 秒 → m:ss（超 1 小时 h:mm:ss）。
  String _fmtDuration(int secs) {
    final h = secs ~/ 3600;
    final m = (secs % 3600) ~/ 60;
    final s = secs % 60;
    final mm = h > 0 ? m.toString().padLeft(2, '0') : '$m';
    return '${h > 0 ? '$h:' : ''}$mm:${s.toString().padLeft(2, '0')}';
  }

  Future<void> _search(String q, String hash) async {
    final src = widget.source;
    setState(() {
      _searchedHash = hash;
      _loading = q.isNotEmpty;
      _searchError = '';
      if (q.isEmpty) _results = const [];
    });
    if (q.isEmpty) return;

    // 链路内多处 await 之后还要读 provider：WidgetRef 在组件销毁后会抛
    // "Cannot use ref after the widget was disposed"（云盘搜索分支曾踩坑），
    // 统一在搜索发起前捕获容器，后续一律走容器读取
    final container = ProviderScope.containerOf(context, listen: false);
    final List<_TrackEntry> out = [];
    // 新一轮搜索重置加载更多状态并记录查询词（滚动追加用它对齐当前结果）
    _lastQuery = q;
    _hasMore = false;
    _loadingMore = false;
    try {
      if (src.isLocal) {
        final dbPath = await container.read(dbPathProvider.future);
        final json = await searchLibrarySongs(
          dbPath: dbPath,
          query: q,
          limit: BigInt.from(100),
        );
        final list = (jsonDecode(json) as List)
            .map((e) => Song.fromJson(e as Map<String, dynamic>))
            .toList();
        out.addAll(list.map((s) => _TrackEntry(isLocal: true, localSong: s)));
        container.read(accountApiProvider).reportSearch(q, 'local', list.length);
      } else if (src.type == _SourceType.cloud) {
        // 网盘来源：取该盘首个账号凭据做文件名搜索，逐个预构造可播放条目。
        // 有已选文件夹的账号只遍历选定范围，避免全盘搜索
        final pid = src.cloudProviderId!;
        final provider = cloudProviderById(pid);
        if (provider == null) throw StateError(tr('该网盘暂未支持'));
        final accounts = await CloudCredentialsStore.instance.accountsFor(pid);
        if (accounts.isEmpty) throw StateError(tr('网盘账号未绑定或已失效'));
        final acc = accounts.first;
        final roots = await CloudFolderSelectionStore.instance.pathsFor(
          pid,
          acc.accountId,
        );
        // 没选目录默认全部目录：盘侧搜索失败自动回退根目录全盘遍历
        final files = await cloudKeywordSearchAudio(
          provider: provider,
          cred: acc.cred,
          selectedRoots: roots,
          keyword: q,
        );
        for (final f in files) {
          final ctx = CloudPlayContext(
            provider: pid,
            accountId: acc.accountId,
            file: f,
          );
          // 列表期头部元数据预探调度（内嵌封面/时长）：去重、限并发、失败静默
          container.read(cloudHeadMetaProvider.notifier).scheduleCloudContext(ctx);
          final parts = parseCloudFileName(f.name);
          out.add(
            _TrackEntry(
              isLocal: false,
              cloudItem: cloudPlayQueueItem(
                ctx,
                title: parts.title,
                artist: parts.artist ?? provider.displayName,
              ),
            ),
          );
        }
        container
            .read(accountApiProvider)
            .reportSearch(q, 'cloud:$pid', files.length);
      } else {
        final engine = await container.read(pluginEngineProvider.future);
        List<PluginSearchResult> items;
        if (src.type == _SourceType.musicfree) {
          final catalog = PluginCatalogService(
            engine,
            container.read(pluginManagerProvider).sources,
          );
          items = await catalog.searchMusic(src.plugin!, q);
        } else {
          items = await engine.searchInPlugin(src.plugin!, src.lxKey!, q);
        }
        out.addAll(
          items.map(
            (r) => _TrackEntry(
              isLocal: false,
              pluginSource: src.plugin,
              pluginResult: r,
            ),
          ),
        );
        container
            .read(accountApiProvider)
            .reportSearch(q, 'online', items.length);
      }
    } catch (e) {
      AppLog.warn('search', '音源搜索失败 source=${src.id} q=$q error=$e');
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
    final online = !src.isLocal && src.type != _SourceType.cloud;
    setState(() {
      _results = out;
      _paths = _buildPaths(out);
      _loading = false;
      // 首批结果不足 90 条说明上游已在末页（Rust 翻页提前收敛），没有更多
      _hasMore = online && out.length >= 90;
      // 结果就位时开窗重播入场（换音源/换关键词等同理）
      _stagger.start();
    });
  }

  /// 滚动近底部触发追加：以「当前条数+90」重取，旧页命中按页缓存，
  /// 只拉新页；某次结果无增长即判定该源已取完
  void _onScroll() {
    if (!_hasMore || _loadingMore || _loading) return;
    if (!_scroll.hasClients) return;
    if (_scroll.position.extentAfter < 600) _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    final src = widget.source;
    if (src.isLocal || src.type == _SourceType.cloud) return;
    final q = _lastQuery;
    if (q.isEmpty) return;
    final hash = '${src.id}|$q';
    if (hash != _searchedHash) return;
    final container = ProviderScope.containerOf(context, listen: false);
    final want = _results.length + 90;
    setState(() => _loadingMore = true);
    try {
      List<PluginSearchResult> items;
      if (src.type == _SourceType.musicfree) {
        final catalog = PluginCatalogService(
          await container.read(pluginEngineProvider.future),
          container.read(pluginManagerProvider).sources,
        );
        items = await catalog.searchMusic(src.plugin!, q, limit: want);
      } else {
        final engine = await container.read(pluginEngineProvider.future);
        items = await engine.searchInPlugin(
          src.plugin!,
          src.lxKey!,
          q,
          limit: want,
        );
      }
      if (!mounted) return;
      if (_searchedHash != hash) return;
      final entries = [
        for (final r in items)
          _TrackEntry(isLocal: false, pluginSource: src.plugin, pluginResult: r),
      ];
      if (entries.length <= _results.length) {
        setState(() {
          _hasMore = false;
          _loadingMore = false;
        });
      } else {
        setState(() {
          _results = entries;
          _paths = _buildPaths(entries);
          _loadingMore = false;
          _hasMore = entries.length >= want;
        });
      }
    } catch (e) {
      AppLog.warn('search', '加载更多失败 source=${src.id} q=$q error=$e');
      if (!mounted) return;
      setState(() {
        _loadingMore = false;
        _hasMore = false;
      });
    }
  }

  Widget _loadMoreFooter(ColorScheme scheme) {
    if (_loadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 18),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (_hasMore) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Center(
        child: Text(
          tr('已显示全部结果'),
          style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
        ),
      ),
    );
  }

  List<String> _buildPaths(List<_TrackEntry> out) {
    final engine = ref.read(pluginEngineProvider).valueOrNull;
    if (engine == null) {
      return [
        for (final e in out)
          e.isLocal ? (e.localSong?.path ?? '') : (e.cloudItem?.path ?? ''),
      ];
    }
    final service = PluginSearchService(engine, _plugins());
    return [
      for (final e in out)
        e.isLocal
            ? (e.localSong?.path ?? '')
            : (e.cloudItem?.path ??
                  service.toQueueItem(e.pluginSource!, e.pluginResult!).path),
    ];
  }

  void _play(int index) {
    FocusScope.of(context).unfocus();
    final e = _results[index];
    if (e.isLocal) {
      ref.read(libraryProvider.notifier).playList([e.localSong!], 0);
      return;
    }
    // 网盘条目：预构造的 QueueItem 直接入队（播放层按 cloud:// 直连）
    final cloudItem = e.cloudItem;
    if (cloudItem != null) {
      ref.read(playerProvider.notifier).playQueue([cloudItem], startIndex: 0);
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
      context,
      wasFav
          ? tr('已取消收藏：{t}', {'t': item.title})
          : tr('已收藏：{t}', {'t': item.title}),
    );
  }

  QueueItem? _queueItem(int index) {
    final e = _results[index];
    if (e.isLocal) return null;
    // 网盘条目：直接用预构造的 QueueItem（收藏/动作面板通用 path 机制）
    final cloudItem = e.cloudItem;
    if (cloudItem != null) return cloudItem;
    final engine = ref.read(pluginEngineProvider).valueOrNull;
    if (engine == null) return null;
    return PluginSearchService(
      engine,
      _plugins(),
    ).toQueueItem(e.pluginSource!, e.pluginResult!);
  }
}
