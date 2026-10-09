part of 'playlists_page.dart';

/// 歌单歌曲排序：对齐桌面端歌单页（歌曲名/文件名/歌手/添加时间/自定义），
/// 全档带方向——点击未选中的档进入默认向（文本档升序、添加时间新→旧），
/// 再点同档反向；「添加时间」依赖 ImportedSong.addedAt（store 入库层自动
/// 补时间戳），旧数据无时间戳沉底
enum _PlaylistSort {
  custom,
  titleAsc,
  titleDesc,
  nameAsc,
  nameDesc,
  artistAsc,
  artistDesc,
  addedAtAsc,
  addedAtDesc,
}

bool _playlistSortIsDesc(_PlaylistSort sort) => switch (sort) {
      _PlaylistSort.titleDesc ||
      _PlaylistSort.nameDesc ||
      _PlaylistSort.artistDesc ||
      _PlaylistSort.addedAtDesc =>
        true,
      _ => false,
    };

int _playlistSortCompare(_PlaylistSort sort, ImportedSong a, ImportedSong b) {
  switch (sort) {
    case _PlaylistSort.titleAsc || _PlaylistSort.titleDesc:
      final c =
          a.title.toLowerCase().compareTo(b.title.toLowerCase());
      return _playlistSortIsDesc(sort) ? -c : c;
    case _PlaylistSort.artistAsc || _PlaylistSort.artistDesc:
      final c =
          a.artist.toLowerCase().compareTo(b.artist.toLowerCase());
      return _playlistSortIsDesc(sort) ? -c : c;
    case _PlaylistSort.nameAsc || _PlaylistSort.nameDesc:
      String base(ImportedSong s) {
        var v = s.path.split('/').last;
        if (v.contains('\\')) v = v.split('\\').last;
        return v;
      }

      final c = base(a).toLowerCase().compareTo(base(b).toLowerCase());
      return _playlistSortIsDesc(sort) ? -c : c;
    case _PlaylistSort.addedAtAsc || _PlaylistSort.addedAtDesc:
      final aa = a.addedAt?.millisecondsSinceEpoch;
      final bb = b.addedAt?.millisecondsSinceEpoch;
      if (aa == null && bb == null) return 0;
      if (aa == null) return 1; // 旧数据无时间戳沉底（不随方向翻转）
      if (bb == null) return -1;
      final c = aa.compareTo(bb);
      return _playlistSortIsDesc(sort) ? -c : c;
    case _PlaylistSort.custom:
      return 0;
  }
}

PopupMenuItem<_PlaylistSort> _playlistSortItem(
  BuildContext context, {
  required _PlaylistSort value,
  required String label,
  required _PlaylistSort? current,
}) =>
    CheckedPopupMenuItem(
      value: value,
      checked: current == value,
      child: Text(tr(label)),
    );

/// 排序菜单项（桌面端同款交互）：当前档显示方向箭头，点击反向；
/// 未选中的档点击进入默认向（descDefault：添加时间新→旧，文本档升序）
PopupMenuItem<_PlaylistSort> _sortDimensionItem(
  BuildContext context, {
  required _PlaylistSort asc,
  required _PlaylistSort desc,
  required String label,
  required _PlaylistSort? current,
  bool descDefault = false,
}) {
  final isAsc = current == asc;
  final isDesc = current == desc;
  final scheme = Theme.of(context).colorScheme;
  return PopupMenuItem(
    value: isAsc
        ? desc
        : isDesc
            ? asc
            : (descDefault ? desc : asc),
    child: Row(
      children: [
        Expanded(child: Text(tr(label))),
        if (isAsc || isDesc)
          Icon(
            isDesc ? Icons.arrow_downward : Icons.arrow_upward,
            size: 15,
            color: scheme.primary,
          ),
      ],
    ),
  );
}

class _AlbumHeader extends StatelessWidget {
  const _AlbumHeader({
    required this.name,
    required this.song,
    required this.count,
    required this.onPlayAll,
    this.onUpdate,
    this.updating = false,
    this.favoriteLabel,
    this.isFavorite = false,
    this.onToggleFavorite,
    this.currentSort,
    this.onSelectSort,
    this.trailing,
  });

  final String name;
  final ImportedSong? song;
  final int count;
  final VoidCallback? onPlayAll;
  final VoidCallback? onUpdate;
  final bool updating;
  final String? favoriteLabel;
  final bool isFavorite;
  final VoidCallback? onToggleFavorite;
  final _PlaylistSort? currentSort;
  final ValueChanged<_PlaylistSort>? onSelectSort;

  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final s = song;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Row(
        children: [
          s == null
              ? Container(
                  width: 76,
                  height: 76,
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  alignment: Alignment.center,
                  child: Icon(Icons.queue_music,
                      size: 30, color: scheme.primary),
                )
              : CoverImage(
                  songPath: s.path,
                  networkUrl: s.coverUrl,
                  thumbPath: s.coverThumbPath,
                  width: 76,
                  height: 76,
                  radius: 12,
                ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  tr('{n} 首', {'n': count}),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 12.5, color: scheme.onSurfaceVariant),
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
                    if (onUpdate != null) ...[
                      const SizedBox(width: 8),
                      Tooltip(
                        message: tr('从源端更新'),
                        child: IconButton.filledTonal(
                          onPressed: updating ? null : onUpdate,
                          icon: updating
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2),
                                )
                              : Icon(Icons.sync,
                                  size: 18, color: scheme.primary),
                          style: IconButton.styleFrom(
                            minimumSize: const Size(38, 34),
                          ),
                        ),
                      ),
                    ],
                    if (onToggleFavorite != null) ...[
                      const SizedBox(width: 8),
                      Tooltip(
                        message: favoriteLabel ?? '',
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
                    if (onSelectSort != null) ...[
                      const SizedBox(width: 8),
                      PopupMenuButton<_PlaylistSort>(
                        tooltip: tr('排序方式'),
                        onSelected: onSelectSort,
                        icon: Icon(Icons.swap_vert,
                            size: 18, color: scheme.primary),
                        style: IconButton.styleFrom(
                          minimumSize: const Size(38, 34),
                        ),
                        itemBuilder: (context) => [
                          _sortDimensionItem(context,
                              asc: _PlaylistSort.titleAsc,
                              desc: _PlaylistSort.titleDesc,
                              label: '歌曲名',
                              current: currentSort),
                          _sortDimensionItem(context,
                              asc: _PlaylistSort.nameAsc,
                              desc: _PlaylistSort.nameDesc,
                              label: '文件名',
                              current: currentSort),
                          _sortDimensionItem(context,
                              asc: _PlaylistSort.artistAsc,
                              desc: _PlaylistSort.artistDesc,
                              label: '歌手',
                              current: currentSort),
                          _sortDimensionItem(context,
                              asc: _PlaylistSort.addedAtAsc,
                              desc: _PlaylistSort.addedAtDesc,
                              label: '添加时间',
                              current: currentSort,
                              descDefault: true),
                          _playlistSortItem(context,
                              value: _PlaylistSort.custom,
                              label: '自定义',
                              current: currentSort),
                        ],
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

class _PlaylistSongs extends ConsumerStatefulWidget {
  const _PlaylistSongs({
    required this.playlist,
    required this.manager,
    required this.onRemove,
    required this.batch,
    required this.sort,
    this.filter = '',
  });

  final ImportedPlaylist playlist;
  final PlaylistManager manager;
  final void Function(int index) onRemove;
  final SongBatchController batch;
  final _PlaylistSort sort;
  final String filter;

  @override
  ConsumerState<_PlaylistSongs> createState() => _PlaylistSongsState();
}

class _PlaylistSongsState extends ConsumerState<_PlaylistSongs> {
  final ScrollController _controller = ScrollController();
  final ScrollController _batchController = ScrollController();

  /// 与本地音乐列表同款入场错峰动画（40ms/行，最多 14 行）
  late final StaggerWindow _stagger = StaggerWindow(onClosed: () {
    if (mounted) setState(() {});
  });

  @override
  void initState() {
    super.initState();
    _stagger.start();
  }

  @override
  void dispose() {
    _stagger.dispose();
    _controller.dispose();
    _batchController.dispose();
    super.dispose();
  }

  List<ImportedSong> _selected(List<ImportedSong> songs) =>
      songs.where((s) => widget.batch.selected.contains(s.path)).toList();

  Future<void> _batchPlay(List<ImportedSong> songs) async {
    final sel = _selected(songs);
    if (sel.isEmpty) return;
    final items = sel.map(_queueItemFromImported).toList();
    await ref.read(playerProvider.notifier).playQueue(items, startIndex: 0);
    widget.batch.exit();
  }

  Future<void> _batchAddToFavorites(List<ImportedSong> songs) async {
    final sel = _selected(songs);
    if (sel.isEmpty) return;
    final fav = ref.read(favoritesProvider.notifier);
    await fav.addAll(sel.map(_queueItemFromImported).toList());
    if (!mounted) return;
    showXianYuToast(context, tr('已收藏 {n} 首歌曲', {'n': sel.length}));
    widget.batch.exit();
  }

  Future<void> _batchAddToPlaylist(List<ImportedSong> songs) async {
    final sel = _selected(songs);
    if (sel.isEmpty) return;
    await showAddToPlaylistSheet(context, ref, sel);
    widget.batch.exit();
  }

  Future<void> _batchDownload(List<ImportedSong> songs) async {
    final selected = _selected(songs);
    if (selected.isEmpty) return;
    final dn = ref.read(downloadProvider.notifier);
    if (!await dn.requireDownloadDir(context)) return;
    final localSkipped = selected.where((s) => s.isLocal).length;
    var downloadedSkipped = 0;
    final toDownload = <ImportedSong>[];
    for (final s in selected.where((s) => !s.isLocal)) {
      if (await dn.isAlreadyDownloaded(s.path)) {
        downloadedSkipped++;
      } else {
        toDownload.add(s);
      }
    }
    if (!mounted) return;
    if (localSkipped > 0) {
      showXianYuToast(
          context, tr('已跳过 {n} 首本地歌曲', {'n': localSkipped}));
    }
    if (downloadedSkipped > 0) {
      showXianYuToast(
          context, tr('已跳过 {n} 首已下载歌曲', {'n': downloadedSkipped}));
    }
    if (toDownload.isEmpty) {
      showXianYuToast(context, tr('没有可下载的在线歌曲'));
      return;
    }
    for (final s in toDownload) {
      dn.download(_queueItemFromImported(s));
    }
    showXianYuToast(context, tr('开始下载 {n} 首歌曲', {'n': toDownload.length}));
    widget.batch.exit();
  }

  Future<void> _confirmBatchRemove(List<ImportedSong> songs) async {
    final sel = _selected(songs);
    if (sel.isEmpty) return;
    final loggedIn =
        (ref.read(accountApiProvider).ciyuanxiId ?? '').isNotEmpty;
    final synced =
        loggedIn && (widget.playlist.cloudId ?? '').isNotEmpty;
    if (synced) {
      final removed = await removePlaylistSongsWithScope(
          context, ref, widget.playlist, sel);
      if (removed) widget.batch.exit();
      return;
    }
    final ok = await showPredictiveDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('从歌单移除')),
        content: Text(tr('确定要从歌单移除选中的 {n} 首歌曲吗？', {'n': sel.length})),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('移除')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    for (final s in sel) {
      await widget.manager.removeSong(widget.playlist.id, s.path);
    }
    widget.batch.exit();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.batch,
      builder: (context, _) {
        final scheme = Theme.of(context).colorScheme;
        final m = ListMetrics.ofRef(ref);
        final hasSong =
            ref.watch(playerProvider.select((s) => s.current != null));
        final songs = widget.playlist.songs;
        final inBatch = widget.batch.batchMode;
        final batch = widget.batch;

        final q = widget.filter.trim().toLowerCase();
        final filtered = q.isEmpty
            ? null
            : <int>[
                for (var i = 0; i < songs.length; i++)
                  if (songs[i].title.toLowerCase().contains(q) ||
                      songs[i].artist.toLowerCase().contains(q))
                    i
              ];
        final indices = filtered ??
            List<int>.generate(songs.length, (i) => i);
        // 视图排序只重排显示索引（orig 映射不变，播放/移除仍按原位置）；
        // 自定义序即歌单本体顺序，仅在自定义档下可拖拽重排
        if (widget.sort != _PlaylistSort.custom) {
          indices.sort((a, b) {
            final c = _playlistSortCompare(widget.sort, songs[a], songs[b]);
            return c != 0 ? c : a.compareTo(b);
          });
        }
        final sortable = widget.sort != _PlaylistSort.custom || filtered != null;
        final visSongs = indices.map((i) => songs[i]).toList();

        void onReorder(int oldIndex, int newIndex) {
          if (newIndex < 0 ||
              newIndex >= songs.length ||
              newIndex == oldIndex) {
            return;
          }
          final paths = songs.map((s) => s.path).toList();
          final moved = paths.removeAt(oldIndex);
          paths.insert(newIndex.clamp(0, paths.length), moved);
          widget.manager.reorderSongs(widget.playlist.id, paths);
        }

        final rowExtent = m.songCover + 2 * m.vPad;
        final bottomPad = (hasSong ? 92.0 : 150.0) +
            MediaQuery.of(context).padding.bottom +
            (inBatch ? 140 : 0);

        Widget batchRow(int display) {
          final song = songs[indices[display]];
          final row = CoverRow(
            cover: CoverImage(
              songPath: song.path,
              networkUrl: song.coverUrl,
              thumbPath: song.coverThumbPath,
              width: m.songCover,
              height: m.songCover,
              radius: m.songRadius,
              icon: Icons.music_note,
            ),
            onTap: () => batch.toggle(song.path),
            verticalPadding: m.vPad,
            horizontalPadding: 0,
            title: Text(
              song.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: m.titleSize, fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              '${song.artist} · ${song.album}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: m.subtitleSize, color: scheme.onSurfaceVariant),
            ),
            trailing: SourceTag(
              path: song.path,
              isOnline: !song.isLocal,
              source: song.source,
              pluginId: song.pluginId,
            ),
          );
          return wrapBatchRow(
            context,
            row: row,
            selected: batch.isSelected(song.path),
            onToggle: () => batch.toggle(song.path),
          );
        }

        Widget songRow(int display, {bool draggable = false}) {
          final orig = indices[display];
          final song = songs[orig];
          return RepaintBoundary(
            key: ValueKey('${song.path}_$orig'),
            child: _stagger.wrap(
              display,
              Builder(
                builder: (rowContext) {
                BuildContext? coverCtx;
                final g = songRowPlay(ref, onPlay: () async {
                  final ok = await launchFlyCover(
                    rowContext,
                    coverContext: coverCtx,
                    coverSize: m.songCover,
                    vPad: m.vPad,
                    songPath: song.path,
                    networkUrl: song.coverUrl,
                    thumbPath: song.coverThumbPath,
                    radius: m.songRadius,
                  );
                  if (ok) widget.manager.play(widget.playlist, orig);
                });
                final row = g.wrap(
                  CoverRow(
                    cover: Builder(
                      builder: (c) {
                        coverCtx = c;
                        return CoverImage(
                          songPath: song.path,
                          networkUrl: song.coverUrl,
                          thumbPath: song.coverThumbPath,
                          width: m.songCover,
                          height: m.songCover,
                          radius: m.songRadius,
                        );
                      },
                    ),
                    onTap: g.onTap,
                    verticalPadding: m.vPad,
                    horizontalPadding: 0,
                    title: Text(
                      song.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: m.titleSize,
                          fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      '${song.artist} · ${song.album}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: m.subtitleSize,
                          color: scheme.onSurfaceVariant),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SourceTag(
                          path: song.path,
                          isOnline: !song.isLocal,
                          source: song.source,
                          pluginId: song.pluginId,
                        ),
                        const SizedBox(width: 4),
                        IconButton(
                          icon: Icon(Icons.close,
                              size: 18, color: scheme.outline),
                          tooltip: tr('从歌单移除'),
                          onPressed: () => widget.onRemove(orig),
                        ),
                      ],
                    ),
                  ),
                );
                return Stack(
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(left: 44),
                      child: row,
                    ),
                    Positioned(
                      left: 8,
                      top: 0,
                      bottom: 0,
                      width: 36,
                      child: Center(
                        child: SongRowLeading(
                          index: display,
                          songPath: song.path,
                          draggable: draggable,
                        ),
                      ),
                    ),
                  ],
                );
              },
              ),
            ),
          );
        }

        return Stack(
          children: [
            if (inBatch)
              ListView.builder(
                controller: _batchController,
                padding: EdgeInsets.only(bottom: bottomPad),
                itemExtent: rowExtent,
                addAutomaticKeepAlives: false,
                itemCount: indices.length,
                itemBuilder: (context, display) => RepaintBoundary(
                  key: ValueKey(
                      'batch_${songs[indices[display]].path}_${indices[display]}'),
                  child: _stagger.wrap(display, batchRow(display)),
                ),
              )
            else if (sortable)
              ListView.builder(
                controller: _controller,
                padding: EdgeInsets.only(bottom: bottomPad),
                itemExtent: rowExtent,
                addAutomaticKeepAlives: false,
                itemCount: indices.length,
                itemBuilder: (context, index) => songRow(index),
              )
            else
              ReorderableListView.builder(
                scrollController: _controller,
                padding: EdgeInsets.only(bottom: bottomPad),
                buildDefaultDragHandles: false,
                proxyDecorator: (child, index, animation) =>
                    Material(type: MaterialType.transparency, child: child),
                itemCount: songs.length,
                onReorderItem: onReorder,
                itemBuilder: (context, index) =>
                    songRow(index, draggable: true),
              ),
            if (inBatch)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: BatchActionBar(
                  selectedCount: batch.selectedCount,
                  totalCount: indices.length,
                  showPlay: true,
                  showFavorite: true,
                  showPlaylist: true,
                  showDownload: true,
                  showRemove: true,
                  onSelectAll: () =>
                      batch.toggleSelectAll({for (final s in visSongs) s.path}),
                  onPlay: () => _batchPlay(visSongs),
                  onFavorite: () => _batchAddToFavorites(visSongs),
                  onPlaylist: () => _batchAddToPlaylist(visSongs),
                  onDownload: () => _batchDownload(visSongs),
                  onRemove: () => _confirmBatchRemove(visSongs),
                  onDone: batch.exit,
                ),
              ),
            if (!inBatch && !sortable)
              SongListScrollFabs(
                controller: _controller,
                paths: songs.map((s) => s.path).toList(),
                rowTopOf: (i) => i * rowExtent,
                itemExtent: rowExtent,
                bottom: bottomPad + 8,
                right: 12,
              ),
          ],
        );
      },
    );
  }
}

QueueItem _queueItemFromImported(ImportedSong song) {
  if (song.isLocal) {
    return QueueItem(
      path: song.path,
      title: song.title,
      artist: song.artist,
      album: song.album,
      durationMs: song.duration * 1000,
    );
  }
  final songJson = <String, dynamic>{
    'pluginId': song.pluginId,
    'source': song.source,
    'format': song.format,
    'musicInfo': song.musicInfo,
  };
  return QueueItem(
    path: song.path,
    title: song.title,
    artist: song.artist,
    album: song.album,
    durationMs: song.duration * 1000,
    coverUrl: song.coverUrl,
    onlineSongJson: jsonEncodeSafe(songJson),
    onlineQuality: '320k',
  );
}
