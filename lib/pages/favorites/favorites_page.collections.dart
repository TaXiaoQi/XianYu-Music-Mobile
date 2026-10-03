part of 'favorites_page.dart';

class _CollectionsTab extends ConsumerWidget {
  const _CollectionsTab({
    required this.fav,
    required this.kind,
    this.filter = '',
    this.topInset = 0,
  });

  final FavoritesState fav;
  final String kind;

  final String filter;

  final double topInset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final hasSong = ref.watch(playerProvider.select((s) => s.current != null));
    final filter = this.filter;
    final items = fav.collections
        .where((c) =>
            c.kind == kind &&
            (filter.isEmpty ||
                c.title.toLowerCase().contains(filter) ||
                c.subtitle.toLowerCase().contains(filter)))
        .toList();
    if (items.isEmpty) {
      final kindName = kind == 'album' ? tr('专辑') : tr('歌单');
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              kind == 'album'
                  ? Icons.album_outlined
                  : Icons.queue_music_outlined,
              size: 48,
              color: scheme.onSurface.withValues(alpha: 0.25),
            ),
            const SizedBox(height: 12),
            Text(
              filter.isNotEmpty
                  ? tr('没有找到相关{kind}', {'kind': kindName})
                  : tr('暂无收藏{kind}', {'kind': kindName}),
              style:
                  TextStyle(fontSize: 14, color: scheme.onSurfaceVariant),
            ),
            if (!filter.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                tr('在在线详情页点击收藏按钮'),
                style:
                    TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ],
          ],
        ),
      );
    }
    final m = ListMetrics.ofRef(ref);
    return ListView.builder(
      padding: EdgeInsets.only(
        top: topInset,
        bottom: (hasSong ? 92.0 : 24.0) +
            MediaQuery.of(context).padding.bottom,
      ),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final c = items[i];
        final type = c.kind == 'album'
            ? OnlineDetailType.album
            : OnlineDetailType.playlist;
        return CoverRow(
          cover: OnlineCover(
            url: c.coverUrl,
            size: m.songCover,
            radius: m.songRadius,
          ),
          title: Text(
            c.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: m.titleSize, fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            [
              if (c.subtitle.isNotEmpty) c.subtitle,
              _pluginName(ref, c.pluginId),
            ].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: m.subtitleSize, color: scheme.onSurfaceVariant),
          ),
          verticalPadding: m.vPad,
          trailing: IconButton(
            icon: Icon(Icons.favorite,
                size: 20, color: scheme.primary),
            tooltip: tr('取消收藏'),
            onPressed: () => ref.read(favoritesProvider.notifier).toggleCollection(
                  kind: c.kind,
                  pluginId: c.pluginId,
                  title: c.title,
                  subtitle: c.subtitle,
                  coverUrl: c.coverUrl,
                  raw: c.raw,
                ),
          ),
          onTap: () => _openCollection(context, c, type),
        );
      },
    );
  }

  void _openCollection(
    BuildContext context, FavoriteCollection c, OnlineDetailType type) {
    if (c.pluginId.startsWith('local:')) {
      final id = c.pluginId.substring('local:'.length);
      context.push('/playlist/$id');
      return;
    }
    context.push(
        '/online-detail',
        extra: OnlineDetailArgs(
          type: type,
          pluginId: c.pluginId,
          title: c.title,
          subtitle: c.subtitle,
          coverUrl: c.coverUrl,
          raw: c.raw,
        ));
  }

  String _pluginName(WidgetRef ref, String id) {
    final source = ref
        .read(pluginManagerProvider)
        .sources
        .where((s) => s.id == id)
        .firstOrNull;
    return source?.name ?? '';
  }
}

class _FavoriteTile extends ConsumerWidget {
  const _FavoriteTile({
    required this.entry,
    required this.onPlay,
    required this.onRemove,
  });

  final FavoriteEntry entry;
  final VoidCallback onPlay;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final m = ListMetrics.ofRef(ref);
    BuildContext? coverCtx;
    Future<void> play() async {
      final ok = await launchFlyCover(
        context,
        coverContext: coverCtx,
        coverSize: m.songCover,
        vPad: m.vPad,
        songPath: entry.path,
        networkUrl: entry.coverUrl,
        radius: m.songRadius,
      );
      if (ok) onPlay();
    }

    final g = songRowPlay(ref, onPlay: play);
    void openActions() => showSongActionsSheet(
          context,
          ref: ref,
          item: entry.toQueueItem(),
          onPlay: play,
        );
    return g.wrap(
      CoverRow(
        cover: Builder(
          builder: (c) {
            coverCtx = c;
            return CoverImage(
              songPath: entry.path,
              networkUrl: entry.coverUrl,
              width: m.songCover,
              height: m.songCover,
              radius: m.songRadius,
              icon: Icons.music_note,
            );
          },
        ),
        onTap: g.onTap,
        onLongPress: openActions,
        title: Text(entry.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style:
                TextStyle(fontSize: m.titleSize, fontWeight: FontWeight.w600)),
        subtitle: Text(
          entry.artist,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style:
              TextStyle(fontSize: m.subtitleSize, color: scheme.onSurfaceVariant),
        ),
        verticalPadding: m.vPad,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SourceTag(
              path: entry.path,
              isOnline: entry.isOnline,
              source: entry.source,
              onlineSongJson: entry.onlineSongJson,
            ),
            const SizedBox(width: 4),
            IconButton(
              icon: Icon(Icons.favorite,
                  size: 20, color: scheme.primary),
              tooltip: tr('取消收藏'),
              onPressed: onRemove,
            ),
            IconButton(
              icon: const Icon(Icons.more_horiz, size: 22),
              color: scheme.onSurfaceVariant,
              tooltip: tr('更多'),
              onPressed: openActions,
            ),
          ],
        ),
      ),
    );
  }
}
