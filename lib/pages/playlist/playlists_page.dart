import 'dart:async';

import 'package:xianyu_music_mobile/src/widgets/predictive_dialog_route.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../src/auth/account_api.dart';
import '../../src/core/app_colors.dart';
import '../../src/theme/theme_tint.dart';
import '../../src/core/settings.dart';
import '../../src/download/download_provider.dart';
import '../../src/favorites/favorites_provider.dart';
import '../../src/navigation/shell.dart';
import '../../src/player/player_provider.dart';
import '../../src/playlist/playlist_delete.dart';
import '../../src/playlist/playlist_provider.dart';
import '../../src/playlist/playlist_song_delete.dart';
import '../../src/playlist/playlist_source_update.dart';
import '../../src/playlist/playlist_store.dart';
import '../../src/plugin/plugin_backup_import.dart';
import '../../src/widgets/add_to_playlist_sheet.dart';
import '../../src/widgets/app_toast.dart';
import '../../src/widgets/batch_action_bar.dart';
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
import '../../src/widgets/stagger_in.dart';
import '../../src/widgets/source_tag.dart';
import '../../src/i18n/i18n.dart';
import '../../src/responsive/landscape.dart';
part 'playlists_page.actions.dart';
part 'playlists_page.list.dart';
part 'playlists_page.songs.dart';

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
          ],
        ),
        ),
      ),
    );
  }
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

class _PlaylistDetailPageState extends ConsumerState<PlaylistDetailPage>
    with HidesShellChrome {
  final SongBatchController _batch = SongBatchController();

  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';
  Timer? _debounce;
  bool _updating = false;
  _PlaylistSort _sort = _PlaylistSort.custom;

  /// 排序档位持久化（与桌面端同 key 语义）
  static const _sortPrefsKey = 'player_playlist_sort_mode';

  _PlaylistSort? _parseSort(String? v) => _PlaylistSort.values
      .where((s) => s.name == v)
      .firstOrNull;

  Future<void> _loadSortMode() async {
    final prefs = await SharedPreferences.getInstance();
    final v = _parseSort(prefs.getString(_sortPrefsKey));
    if (v != null && mounted && v != _sort) {
      setState(() => _sort = v);
    }
  }

  void _selectSort(_PlaylistSort s) {
    setState(() => _sort = s);
    SharedPreferences.getInstance().then(
      (prefs) => prefs.setString(_sortPrefsKey, s.name),
    );
  }

  @override
  void initState() {
    super.initState();
    _loadSortMode();
    _batch.addListener(_onBatchChanged);
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
                    onUpdate: playlist.hasSource
                        ? () => _updateFromSource(playlist)
                        : null,
                    updating: _updating,
                    favoriteLabel: tr('收藏整张歌单'),
                    isFavorite:
                        favState.isCollectionFavorite(_collectionKey(playlist)),
                    onToggleFavorite:
                        () => _toggleCollectionFavorite(playlist),
                    currentSort: _sort,
                    onSelectSort: _selectSort,
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
                            sort: _sort,
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
          ],
        ),
      ),
    );
  }
}
