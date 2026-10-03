part of 'playlists_page.dart';

class _PlaylistList extends ConsumerWidget {
  const _PlaylistList({required this.state, this.filter = '', this.contentTop});

  final ImportedPlaylistState state;

  final String filter;

  final double? contentTop;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasSong = ref.watch(playerProvider.select((s) => s.current != null));
    final filter = this.filter;
    final playlists = filter.isEmpty
        ? state.playlists
        : state.playlists
            .where((p) => p.name.toLowerCase().contains(filter))
            .toList();
    if (playlists.isEmpty) {
      final scheme = Theme.of(context).colorScheme;
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_off,
                size: 40, color: scheme.onSurface.withValues(alpha: 0.25)),
            const SizedBox(height: 12),
            Text(
              filter.isNotEmpty ? tr('没有找到相关歌单') : tr('还没有歌单'),
              style:
                  TextStyle(fontSize: 14, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }
    return ListView.separated(
      padding: EdgeInsets.fromLTRB(
        16,
        contentTop ?? 8,
        16,
        (hasSong ? 92.0 : 150.0) + MediaQuery.of(context).padding.bottom,
      ),
      itemCount: playlists.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) =>
          _PlaylistCard(playlist: playlists[index]),
    );
  }
}

class _PlaylistCard extends ConsumerWidget {
  const _PlaylistCard({required this.playlist});
  final ImportedPlaylist playlist;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;

    final manager = ref.read(playlistManagerProvider.notifier);
    final first = playlist.songs.isNotEmpty ? playlist.songs.first : null;

    return Material(
      color: useLandscape(ref)
          ? themeTint(ref, 'ls-sheets.card', appCardFill(context, ref))
          : appCardFill(context, ref),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide.none,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _openPlaylist(context, ref, playlist.id),
        onLongPress: () => _sheetActions(context, manager, ref),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: first == null
                    ? Icon(Icons.queue_music, color: scheme.primary, size: 22)
                    : CoverImage(
                        songPath: first.path,
                        networkUrl: first.coverUrl,
                        thumbPath: first.coverThumbPath,
                        width: 44,
                        height: 44,
                        radius: 10,
                      ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      playlist.name,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      tr('{n} 首歌曲', {'n': playlist.songs.length}),
                      style: TextStyle(
                          fontSize: 12, color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: Icon(Icons.edit_outlined, size: 20, color: scheme.outline),
                tooltip: tr('重命名'),
                onPressed: () => _rename(context, manager),
              ),
              IconButton(
                icon: Icon(Icons.delete_outline,
                    size: 20, color: scheme.outline),
                tooltip: tr('删除歌单'),
                onPressed: () => confirmRemovePlaylist(context, ref, playlist),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openPlaylist(BuildContext context, WidgetRef ref, String id) {
    if (useLandscape(ref)) {
      ref.read(landscapePlaylistOpenProvider.notifier).state = id;
      return;
    }
    context.push('/playlist/$id');
  }

  void _sheetActions(
      BuildContext context, PlaylistManager manager, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    showSheetDialog<void>(
        context,
        (ctx) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: Icon(Icons.edit_outlined, color: scheme.primary, size: 22),
                  title:   Text(tr('重命名歌单')),
                  onTap: () {
                    Navigator.pop(ctx);
                    _rename(context, manager);
                  },
                ),
                ListTile(
                  leading: Icon(Icons.delete_outline,
                      color: scheme.error, size: 22),
                  title:   Text(tr('删除歌单')),
                  onTap: () {
                    Navigator.pop(ctx);
                    confirmRemovePlaylist(context, ref, playlist);
                  },
                ),
              ],
            ),
          ),
        ),
      );
  }

  Future<void> _rename(BuildContext context, PlaylistManager manager) async {
    final name = await _promptName(context, tr('重命名歌单'));
    if (name == null || name.trim().isEmpty) return;
    await manager.rename(playlist.id, name.trim());
  }
}
