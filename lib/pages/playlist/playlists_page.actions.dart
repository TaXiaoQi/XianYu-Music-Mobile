part of 'playlists_page.dart';
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

extension _PlaylistsPageActions on PlaylistsPage {
  Future<void> _promptCreate(
      BuildContext context, PlaylistManager manager) async {
    final name = await _promptName(context, tr('新建歌单'));
    if (name == null || name.trim().isEmpty) return;
    await manager.create(name.trim());
    if (!context.mounted) return;
    showXianYuToast(context, tr('已创建歌单「{name}」', {'name': name.trim()}));
  }
}

Future<String?> _promptName(BuildContext context, String title) {
  final controller = TextEditingController();
  return showPredictiveDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        maxLength: 40,
        decoration:   InputDecoration(hintText: tr('歌单名称')),
        onSubmitted: (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child:   Text(tr('取消')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, controller.text),
          child:   Text(tr('确定')),
        ),
      ],
    ),
  );
}

Future<bool> removePlaylistSongsWithScope(
  BuildContext context,
  WidgetRef ref,
  ImportedPlaylist playlist,
  List<ImportedSong> songs,
) async {
  if (songs.isEmpty) return false;
  final manager = ref.read(playlistManagerProvider.notifier);
  final loggedIn =
      (ref.read(accountApiProvider).ciyuanxiId ?? '').isNotEmpty;
  final synced = loggedIn && (playlist.cloudId ?? '').isNotEmpty;
  String? scope;
  if (synced) {
    scope = await resolvePlaylistSongDeleteScope(context, ref, playlist,
        songCount: songs.length);
    if (scope == null) return false;
    if (!context.mounted) return false;
  }
  Future<void> removeLocal() async {
    for (final s in songs) {
      await manager.removeSong(playlist.id, s.path);
    }
  }

  await applyPlaylistSongDeleteScope(
    context,
    ref,
    scope ?? '',
    playlist,
    songs,
    onLocalRemove: removeLocal,
  );
  return true;
}

extension _PlaylistDetailActions on _PlaylistDetailPageState {
  void _onBatchChanged() {
    if (!_batch.batchMode) {
      ref.read(batchBarLiftProvider.notifier).state = 0;
    }
  }

  void _onQueryChanged(String v) {
    setState(() => _query = v.trim());
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 160), () {
      if (mounted) setState(() {});
    });
  }

  Widget _buildSearchField(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: TextField(
        controller: _searchCtrl,
        textInputAction: TextInputAction.search,
        onChanged: _onQueryChanged,
        decoration: InputDecoration(
          hintText: tr('搜索歌曲、歌手、专辑'),
          border: InputBorder.none,
          isDense: true,
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.clear, size: 18),
                  onPressed: () {
                    _searchCtrl.clear();
                    _onQueryChanged('');
                  },
                ),
        ),
      ),
    );
  }

  Widget _batchToggle(BuildContext context, {bool floating = false}) {
    return ListenableBuilder(
      listenable: _batch,
      builder: (context, _) {
        final active = _batch.batchMode;
        final icon = active
            ? Icons.check_rounded
            : Icons.library_add_check_outlined;
        final tip = active ? tr('完成') : tr('批量');
        void onTap() => active ? _batch.exit() : _batch.enter();
        if (floating) {
          return BiliPaiIconButton(
            icon: icon,
            tooltip: tip,
            color: active ? Theme.of(context).colorScheme.primary : null,
            onTap: onTap,
          );
        }
        return IconButton(
          icon: Icon(icon, size: 22),
          tooltip: tip,
          onPressed: onTap,
        );
      },
    );
  }

  String _collectionKey(ImportedPlaylist playlist) =>
      'playlist:local:${playlist.id}:${playlist.name}';

  bool _isCollectionFavorite(ImportedPlaylist playlist) =>
      ref.read(favoritesProvider).isCollectionFavorite(_collectionKey(playlist));

  Future<void> _toggleCollectionFavorite(ImportedPlaylist playlist) async {
    final wasFav = _isCollectionFavorite(playlist);
    final first = playlist.songs.isNotEmpty ? playlist.songs.first : null;
    await ref.read(favoritesProvider.notifier).toggleCollection(
          kind: 'playlist',
          pluginId: 'local:${playlist.id}',
          title: playlist.name,
          subtitle: tr('{n} 首', {'n': playlist.songs.length}),
          coverUrl: first?.coverUrl,
          raw: const {},
        );
    if (!mounted) return;
    showXianYuToast(
      context,
      wasFav ? tr('已取消收藏：{t}', {'t': playlist.name}) : tr('已收藏：{t}', {'t': playlist.name}),
    );
  }

  Future<void> _updateFromSource(ImportedPlaylist playlist) async {
    if (_updating) return;
    setState(() => _updating = true);
    try {
      await updatePlaylistFromSource(context, ref, playlist);
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }
}
