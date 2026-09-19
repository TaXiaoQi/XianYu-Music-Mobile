import 'dart:async';

import 'package:xianyu_music_mobile/src/widgets/predictive_dialog_route.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../src/auth/account_api.dart';
import '../../src/core/app_colors.dart';
import '../../src/core/settings.dart';
import '../../src/download/download_provider.dart';
import '../../src/favorites/favorites_provider.dart';
import '../../src/navigation/shell.dart';
import '../../src/player/player_provider.dart';
import '../../src/playlist/playlist_delete.dart';
import '../../src/playlist/playlist_provider.dart';
import '../../src/playlist/playlist_song_delete.dart';
import '../../src/playlist/playlist_store.dart';
import '../../src/plugin/plugin_backup_import.dart';
import '../../src/widgets/add_to_playlist_sheet.dart';
import '../../src/widgets/app_toast.dart';
import '../../src/widgets/batch_action_bar.dart';
import '../../src/widgets/bottom_play_bar_slot.dart';
import '../../src/widgets/cover_image.dart';
import '../../src/widgets/drag_handle.dart';
import '../../src/widgets/flying_cover.dart';
import '../../src/widgets/floating_search_bar.dart';
import '../../src/widgets/glass_appbar.dart';
import '../../src/widgets/list_metrics.dart';
import '../../src/widgets/mini_player_bar.dart';
import '../../src/widgets/sheet_dialog.dart';
import '../../src/widgets/song_list_scroll_fabs.dart';
import '../../src/widgets/song_list_view.dart';
import '../../src/widgets/source_tag.dart';
import '../../src/i18n/i18n.dart';
import '../../src/responsive/landscape.dart';

class PlaylistsPage extends ConsumerWidget {
  const PlaylistsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(playlistManagerProvider);
    final inMusicPane = ref.watch(landscapeLibraryProvider) != null;
    final filter = inMusicPane
        ? ref.watch(landscapeLibraryQueryProvider).trim().toLowerCase()
        : '';
    final scheme = Theme.of(context).colorScheme;
    final manager = ref.read(playlistManagerProvider.notifier);
    final floating = ref.watch(
        settingsProvider.select((s) => s.valueOrNull?.floatingSearchBar ?? false));
    final statusBar = MediaQuery.paddingOf(context).top;
    final paneTop = (floating && inMusicPane) ? statusBar + 66 : 0.0;
    const headerH = 48.0;
    final portraitFloating = !inMusicPane &&
        MediaQuery.of(context).orientation != Orientation.landscape &&
        floating;

    return HideShellChrome(
      child: Scaffold(
        backgroundColor: appScaffoldBackground(context, ref),
        resizeToAvoidBottomInset: false,
        body: RepaintBoundary(child: Stack(
          children: [
            if (portraitFloating && !state.loading && state.playlists.isNotEmpty)
              Positioned.fill(
                child: _PlaylistList(
                  state: state,
                  filter: filter,
                  contentTop: GlassTopBar.height(context) + 6,
                ),
              )
            else
              Padding(
                padding: EdgeInsets.only(
                  top: inMusicPane ? paneTop + headerH + 4 : GlassTopBar.height(context),
                ),
                child: state.loading
                    ? const Center(child: CircularProgressIndicator())
                    : state.playlists.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.queue_music_outlined,
                                    size: 56, color: scheme.outline),
                                const SizedBox(height: 12),
                                Text(tr('还没有歌单'),
                                    style:
                                        TextStyle(color: scheme.onSurfaceVariant)),
                                const SizedBox(height: 4),
                                Text(
                                  tr('点击右上角新建，或在歌曲菜单中选择「添加到歌单」\n也可通过导入歌单页从备份文件、本地文件夹或云端导入'),
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                      fontSize: 12, color: scheme.outline),
                                ),
                                const SizedBox(height: 16),
                                FilledButton.tonalIcon(
                                  onPressed: () => _promptCreate(context, manager),
                                  icon: const Icon(Icons.add, size: 18),
                                  label:   Text(tr('新建歌单')),
                                ),
                                const SizedBox(height: 8),
                                TextButton.icon(
                                  onPressed: () => context.push('/playlist-import'),
                                  icon: const Icon(Icons.file_download_outlined,
                                      size: 16),
                                  label:   Text(tr('导入歌单')),
                                ),
                              ],
                            ),
                          )
                        : _PlaylistList(state: state, filter: filter),
              ),
            if (inMusicPane)
              Positioned(
                top: paneTop,
                left: (inMusicPane && floating) ? 12 : 0,
                right: (inMusicPane && floating) ? 12 : 0,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (floating) ...[
                        BiliPaiIconButton(
                          icon: Icons.add,
                          tooltip: tr('新建歌单'),
                          onTap: () => _promptCreate(context, manager),
                        ),
                        const SizedBox(width: 10),
                        BiliPaiIconButton(
                          icon: Icons.file_download_outlined,
                          tooltip: tr('导入歌单'),
                          onTap: () => context.push('/playlist-import'),
                        ),
                      ] else ...[
                        IconButton(
                          icon: const Icon(Icons.add),
                          tooltip: tr('新建歌单'),
                          onPressed: () => _promptCreate(context, manager),
                        ),
                        IconButton(
                          icon: const Icon(Icons.file_download_outlined),
                          tooltip: tr('导入歌单'),
                          onPressed: () => context.push('/playlist-import'),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            if (!inMusicPane)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: GlassTopBar(
                  leading: const BackButton(),
                  title:   Text(tr('我的歌单')),
                  actions: [
                    IconButton(
                      icon: const Icon(Icons.add),
                      tooltip: tr('新建歌单'),
                      onPressed: () => _promptCreate(context, manager),
                    ),
                    ],
                  ),
                ),
            if (!inMusicPane) const BottomPlayBarSlot(),
          ],
        ),
        ),
      ),
    );
  }

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
      color: appCardFill(context, ref),
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

class PlaylistDetailPage extends ConsumerStatefulWidget {
  const PlaylistDetailPage({
    super.key,
    required this.playlistId,
    this.embedded = false,
  });
  final String playlistId;

  final bool embedded;

  @override
  ConsumerState<PlaylistDetailPage> createState() =>
      _PlaylistDetailPageState();
}

class _PlaylistDetailPageState extends ConsumerState<PlaylistDetailPage> {
  final SongBatchController _batch = SongBatchController();

  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _batch.addListener(_onBatchChanged);
  }

  void _onBatchChanged() {
    if (!_batch.batchMode) {
      ref.read(batchBarLiftProvider.notifier).state = 0;
    }
  }

  @override
  void didUpdateWidget(PlaylistDetailPage old) {
    super.didUpdateWidget(old);
    if (old.playlistId != widget.playlistId) _batch.exit();
  }

  @override
  void dispose() {
    _batch.removeListener(_onBatchChanged);
    _batch.dispose();
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
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

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(playlistManagerProvider);
    final scheme = Theme.of(context).colorScheme;
    final manager = ref.read(playlistManagerProvider.notifier);
    final favState = ref.watch(favoritesProvider);
    final playlist = state.playlists
        .where((p) => p.id == widget.playlistId)
        .cast<ImportedPlaylist?>()
        .firstWhere((_) => true, orElse: () => null);

    if (playlist == null) {
      return HideShellChrome(
        child: Scaffold(
          backgroundColor: appScaffoldBackground(context, ref),
          body: Stack(
            children: [
              Padding(
                padding: EdgeInsets.only(top: GlassTopBar.height(context)),
                child:   Center(child: Text(tr('歌单已不存在'))),
              ),
              if (!widget.embedded)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: GlassTopBar(
                    leading: const BackButton(),
                    title:   Text(tr('歌单')),
                  ),
                ),
            ],
          ),
        ),
      );
    }

    final showBatch = playlist.songs.isNotEmpty;
    final floating = ref.watch(
        settingsProvider.select((s) => s.valueOrNull?.floatingSearchBar ?? false));
    final statusBar = MediaQuery.paddingOf(context).top;
    final portraitFloating = !widget.embedded &&
        MediaQuery.of(context).orientation == Orientation.portrait &&
        floating;

    return HideShellChrome(
      child: Scaffold(
        backgroundColor: appScaffoldBackground(context, ref),
        body: Stack(
          children: [
            Padding(
              padding: EdgeInsets.only(
                  top: portraitFloating
                      ? statusBar + 8 + 44 + 14
                      : GlassTopBar.height(context)),
              child: Column(
                children: [
                  _AlbumHeader(
                    name: playlist.name,
                    song: playlist.songs.isNotEmpty
                        ? playlist.songs.first
                        : null,
                    count: playlist.songs.length,
                    onPlayAll: playlist.songs.isEmpty
                        ? null
                        : () => manager.play(playlist, 0),
                    favoriteLabel: tr('收藏整张歌单'),
                    isFavorite:
                        favState.isCollectionFavorite(_collectionKey(playlist)),
                    onToggleFavorite:
                        () => _toggleCollectionFavorite(playlist),
                    trailing: widget.embedded && showBatch
                        ? _batchToggle(context, floating: floating)
                        : null,
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: playlist.songs.isEmpty
                        ? Center(
                            child: Text(
                              tr('歌单为空，可在歌曲菜单中选择「添加到歌单」'),
                              style: TextStyle(
                                  fontSize: 13, color: scheme.outline),
                            ),
                          )
                        : _PlaylistSongs(
                            playlist: playlist,
                            manager: manager,
                            batch: _batch,
                            filter: _query,
                            onRemove: (index) => removePlaylistSongsWithScope(
                                context, ref, playlist, [playlist.songs[index]]),
                          ),
                  ),
                ],
              ),
            ),
            if (!widget.embedded)
              Positioned(
                top: portraitFloating ? statusBar + 8 : 0,
                left: portraitFloating ? 12 : 0,
                right: portraitFloating ? 12 : 0,
                child: portraitFloating
                    ? FloatingSearchTopBar(
                        onBack: () => context.pop(),
                        field: FloatingGlassSearchField(
                          controller: _searchCtrl,
                          onChanged: _onQueryChanged,
                          showClear: _query.isNotEmpty,
                          onClear: () {
                            _searchCtrl.clear();
                            _onQueryChanged('');
                          },
                          hint: tr('搜索歌曲、歌手、专辑'),
                        ),
                        action: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (showBatch)
                              _batchToggle(context, floating: true),
                            const SizedBox(width: 10),
                            BiliPaiIconButton(
                              icon: Icons.edit_outlined,
                              tooltip: tr('重命名'),
                              onTap: () async {
                                final name =
                                    await _promptName(context, tr('重命名歌单'));
                                if (name == null || name.trim().isEmpty) return;
                                await manager
                                    .rename(playlist.id, name.trim());
                              },
                            ),
                          ],
                        ),
                      )
                    : GlassTopBar(
                        leading: const BackButton(),
                        title: _buildSearchField(context),
                        actions: [
                          if (showBatch) _batchToggle(context),
                          IconButton(
                            icon: const Icon(Icons.edit_outlined, size: 20),
                            tooltip: tr('重命名'),
                            onPressed: () async {
                              final name =
                                  await _promptName(context, tr('重命名歌单'));
                              if (name == null || name.trim().isEmpty) return;
                              await manager
                                  .rename(playlist.id, name.trim());
                            },
                          ),
                        ],
                      ),
              ),
            if (!widget.embedded) const BottomPlayBarSlot(),
          ],
        ),
      ),
    );
  }
}

class _AlbumHeader extends StatelessWidget {
  const _AlbumHeader({
    required this.name,
    required this.song,
    required this.count,
    required this.onPlayAll,
    this.favoriteLabel,
    this.isFavorite = false,
    this.onToggleFavorite,
    this.trailing,
  });

  final String name;
  final ImportedSong? song;
  final int count;
  final VoidCallback? onPlayAll;
  final String? favoriteLabel;
  final bool isFavorite;
  final VoidCallback? onToggleFavorite;

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
    this.filter = '',
  });

  final ImportedPlaylist playlist;
  final PlaylistManager manager;
  final void Function(int index) onRemove;
  final SongBatchController batch;
  final String filter;

  @override
  ConsumerState<_PlaylistSongs> createState() => _PlaylistSongsState();
}

class _PlaylistSongsState extends ConsumerState<_PlaylistSongs> {
  final ScrollController _controller = ScrollController();
  final ScrollController _batchController = ScrollController();

  @override
  void dispose() {
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

        Widget songRow(int display) {
          final orig = indices[display];
          final song = songs[orig];
          return RepaintBoundary(
            key: ValueKey('${song.path}_$orig'),
            child: Builder(
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
                      child: Center(child: DragHandle(index: orig)),
                    ),
                  ],
                );
              },
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
                  child: batchRow(display),
                ),
              )
            else if (filtered != null)
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
                itemBuilder: (context, index) => songRow(index),
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
            if (!inBatch && filtered == null)
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
