import 'package:xianyu_music_mobile/src/widgets/predictive_dialog_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../src/core/app_colors.dart';
import '../../src/core/settings.dart';
import '../../src/download/download_provider.dart';
import '../../src/favorites/favorites_provider.dart';
import '../../src/navigation/shell.dart';
import '../../src/player/player_provider.dart';
import '../../src/playlist/playlist_provider.dart';
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

/// 我的歌单：创建/重命名/删除歌单，查看与播放歌单内容（对齐桌面歌单体系）。
class PlaylistsPage extends ConsumerWidget {
  const PlaylistsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(playlistManagerProvider);
    // 面板模式下隐藏本页顶部 GlassTopBar（由外层横屏胶囊顶栏占位）。
    final inMusicPane = ref.watch(landscapeLibraryProvider) != null;
    // 横屏 pane 内：全局顶栏搜索承担本地过滤（按歌单名过滤）。
    final filter = inMusicPane
        ? ref.watch(landscapeLibraryQueryProvider).trim().toLowerCase()
        : '';
    final scheme = Theme.of(context).colorScheme;
    final manager = ref.read(playlistManagerProvider.notifier);
    // 横屏音乐库 pane 模式下统一继承壳层全局顶栏：页内仅保留「新建/导入」
    // 内容头，位于全局顶栏下方（悬浮模式按顶栏高度下移）。
    final floating = ref.watch(
        settingsProvider.select((s) => s.valueOrNull?.floatingSearchBar ?? false));
    final statusBar = MediaQuery.paddingOf(context).top;
    final paneTop = (floating && inMusicPane) ? statusBar + 66 : 0.0;
    const headerH = 48.0;

    return HideShellChrome(
      child: Scaffold(
        backgroundColor: appScaffoldBackground(context, ref),
        resizeToAvoidBottomInset: false,
        body: RepaintBoundary(child: Stack(
          children: [
            Padding(
              padding: EdgeInsets.only(
                // 面板模式下内容头在全局顶栏下方，内容按其避让；非面板模式
                // 沿用完整 GlassTopBar 高度避让。
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
            // 内容头：面板模式仅保留右侧「新建/导入」（悬浮玻璃圆钮 / 固定普通钮）；
            // 非面板模式渲染完整 GlassTopBar。
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
            // 统一播放条由外壳承载：横屏面板模式下不渲染页内嵌条。
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

/// 输入歌单名称弹窗（新建/重命名共用，不显示当前值）。
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

/// 我的歌单列表：独立订阅播放状态以调整底部留白，避免播放状态翻转波及页头。
class _PlaylistList extends ConsumerWidget {
  const _PlaylistList({required this.state, this.filter = ''});

  final ImportedPlaylistState state;

  /// 横屏音乐库 pane 的本地过滤关键词（已小写）；空=不过滤。
  final String filter;

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
        8,
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

    // 壁纸感知卡片底色：常规模式 = appCardColor；壁纸模式 = 反色色块
    //（对齐音源/榜单页 appCardFill），避免卡片在壁纸上沉成纯黑。
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
        onLongPress: () => _sheetActions(context, manager),
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
                onPressed: () => _confirmRemove(context, manager),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openPlaylist(BuildContext context, WidgetRef ref, String id) {
    // 横屏：右侧容器内嵌歌单详情，不开二级路由。
    if (useLandscape(ref)) {
      ref.read(landscapePlaylistOpenProvider.notifier).state = id;
      return;
    }
    // 走 go_router 顶层路由压 root navigator，保证返回行为与 shell 一致。
    context.push('/playlist/$id');
  }

  void _sheetActions(BuildContext context, PlaylistManager manager) {
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
                    _confirmRemove(context, manager);
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

  void _confirmRemove(BuildContext context, PlaylistManager manager) {
    showPredictiveDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title:   Text(tr('删除歌单')),
        content: Text(tr('确定要删除「{name}」吗？', {'name': playlist.name})),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child:   Text(tr('取消')),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              manager.remove(playlist.id);
            },
            child:   Text(tr('删除')),
          ),
        ],
      ),
    );
  }
}

/// 歌单详情：从 provider 实时取最新数据，增删歌曲即时刷新。
/// 批量模式（[SongBatchController]）下切换为勾选列表 + 底部批量操作栏。
class PlaylistDetailPage extends ConsumerStatefulWidget {
  const PlaylistDetailPage({
    super.key,
    required this.playlistId,
    this.embedded = false,
  });
  final String playlistId;

  /// 横屏右侧容器内嵌（壳层 [_PlaylistDetailPane]），不开二级路由：
  /// 顶栏由全局横屏顶栏承接（搜索框左侧回退按钮负责闭合容器）。
  final bool embedded;

  @override
  ConsumerState<PlaylistDetailPage> createState() =>
      _PlaylistDetailPageState();
}

class _PlaylistDetailPageState extends ConsumerState<PlaylistDetailPage> {
  /// 批量选择控制器（顶栏入口 + 列表 + 底部批量操作栏共用）。
  final SongBatchController _batch = SongBatchController();

  @override
  void initState() {
    super.initState();
    // 批量模式关闭即复位播放条托起量（绑定退出事件，不依赖批量栏卸载时序）。
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
    // 横屏容器在切换不同歌单时复用同一 State，重置批量状态避免串选。
    if (old.playlistId != widget.playlistId) _batch.exit();
  }

  @override
  void dispose() {
    _batch.removeListener(_onBatchChanged);
    _batch.dispose();
    super.dispose();
  }

  /// 批量模式切换按钮：未进入时显示「批量」，进入后变为「完成」。
  /// [floating] 为真时用 BiliPai 玻璃圆钮（面板悬浮形态），否则普通图标钮。
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

  /// 本地歌单收藏唯一键（对齐桌面 buildLocalPlaylistCollectionKey：
  /// 用歌单 ID 保证重命名后收藏不丢失）。
  String _collectionKey(ImportedPlaylist playlist) =>
      'playlist:local:${playlist.id}:${playlist.name}';

  bool _isCollectionFavorite(ImportedPlaylist playlist) =>
      ref.read(favoritesProvider).isCollectionFavorite(_collectionKey(playlist));

  /// 收藏/取消收藏整张本地歌单。
  Future<void> _toggleCollectionFavorite(ImportedPlaylist playlist) async {
    final wasFav = _isCollectionFavorite(playlist);
    final first = playlist.songs.isNotEmpty ? playlist.songs.first : null;
    await ref.read(favoritesProvider.notifier).toggleCollection(
          kind: 'playlist',
          // 本地歌单用稳定 ID 标记来源（收藏页据此区分本地/在线）。
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

    // 有内容时才提供批量入口（顶栏动作 / 面板头部）。
    final showBatch = playlist.songs.isNotEmpty;
    final floating = ref.watch(
        settingsProvider.select((s) => s.valueOrNull?.floatingSearchBar ?? false));

    return HideShellChrome(
      child: Scaffold(
        backgroundColor: appScaffoldBackground(context, ref),
        body: Stack(
          children: [
            Padding(
              padding: EdgeInsets.only(top: GlassTopBar.height(context)),
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
                    // 收藏整张歌单（对齐桌面：本地歌单详情提供「收藏整张」）。
                    favoriteLabel: tr('收藏整张歌单'),
                    isFavorite:
                        favState.isCollectionFavorite(_collectionKey(playlist)),
                    onToggleFavorite:
                        () => _toggleCollectionFavorite(playlist),
                    // 面板模式下无页内顶栏，批量入口并入头部右侧。
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
                            onRemove: (index) => manager.removeSong(
                                playlist.id, playlist.songs[index].path),
                          ),
                  ),
                ],
              ),
            ),
            if (!widget.embedded)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: GlassTopBar(
                  leading: const BackButton(),
                  title: Text(playlist.name),
                  actions: [
                    if (showBatch) _batchToggle(context),
                    IconButton(
                      icon: const Icon(Icons.edit_outlined, size: 20),
                      tooltip: tr('重命名'),
                      onPressed: () async {
                        final name = await _promptName(context, tr('重命名歌单'));
                        if (name == null || name.trim().isEmpty) return;
                        await manager.rename(playlist.id, name.trim());
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

/// 歌单详情头部：对齐在线专辑页样式（封面 + 名称 + 数量 + 播放全部）。
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

  /// 头部右侧追加控件（面板模式下承载批量入口）。
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

/// 歌单歌曲列表：按公告的列表项尺寸（ListSize）缩放；长按行首把手可拖动排序。
/// 右下角悬浮「回到顶部 / 定位播放」按钮（对齐收藏页单曲列表）。
/// 批量模式（[SongBatchController.batchMode]）下切换为勾选列表 + 底部批量操作栏。
class _PlaylistSongs extends ConsumerStatefulWidget {
  const _PlaylistSongs({
    required this.playlist,
    required this.manager,
    required this.onRemove,
    required this.batch,
  });

  final ImportedPlaylist playlist;
  final PlaylistManager manager;
  final void Function(int index) onRemove;
  final SongBatchController batch;

  @override
  ConsumerState<_PlaylistSongs> createState() => _PlaylistSongsState();
}

class _PlaylistSongsState extends ConsumerState<_PlaylistSongs> {
  /// 常规列表（可拖拽排序 + 悬浮按钮）控制器。
  final ScrollController _controller = ScrollController();
  /// 批量模式列表专用控制器：与 [_controller] 分离，避免进出批量模式时
  /// ReorderableListView↔ListView 复用同一控制器导致多滚动视图断言崩溃。
  final ScrollController _batchController = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    _batchController.dispose();
    super.dispose();
  }

  List<ImportedSong> _selected(List<ImportedSong> songs) =>
      songs.where((s) => widget.batch.selected.contains(s.path)).toList();

  /// 批量播放：选中歌曲入队并起播。
  Future<void> _batchPlay(List<ImportedSong> songs) async {
    final sel = _selected(songs);
    if (sel.isEmpty) return;
    final items = sel.map(_queueItemFromImported).toList();
    await ref.read(playerProvider.notifier).playQueue(items, startIndex: 0);
    widget.batch.exit();
  }

  /// 批量添加到我的收藏（对齐桌面端「添加至我喜欢」）。
  Future<void> _batchAddToFavorites(List<ImportedSong> songs) async {
    final sel = _selected(songs);
    if (sel.isEmpty) return;
    final fav = ref.read(favoritesProvider.notifier);
    for (final s in sel) {
      fav.add(_queueItemFromImported(s));
    }
    showXianYuToast(context, tr('已收藏 {n} 首歌曲', {'n': sel.length}));
    widget.batch.exit();
  }

  /// 批量添加到其它歌单。
  Future<void> _batchAddToPlaylist(List<ImportedSong> songs) async {
    final sel = _selected(songs);
    if (sel.isEmpty) return;
    await showAddToPlaylistSheet(context, ref, sel);
    widget.batch.exit();
  }

  /// 批量下载在线歌曲（本地歌曲与已下载歌曲自动跳过，对齐桌面端）。
  Future<void> _batchDownload(List<ImportedSong> songs) async {
    final selected = _selected(songs);
    if (selected.isEmpty) return;
    final dn = ref.read(downloadProvider.notifier);
    // 未设置自定义下载目录/无「所有文件访问」权限：禁止批量下载并提示。
    if (!await dn.requireDownloadDir(context)) return;
    // 本地歌曲不计入下载，提示跳过。
    final localSkipped = selected.where((s) => s.isLocal).length;
    // 在线歌曲里已下载（下载历史 + 文件仍存在）的一并跳过，避免重复下载。
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

  /// 批量从歌单移除（确认弹窗后逐个移除）。
  Future<void> _confirmBatchRemove(List<ImportedSong> songs) async {
    final sel = _selected(songs);
    if (sel.isEmpty) return;
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

        void onReorder(int oldIndex, int newIndex) {
          if (newIndex < 0 ||
              newIndex >= songs.length ||
              newIndex == oldIndex) {
            return;
          }
          final paths = songs.map((s) => s.path).toList();
          final moved = paths.removeAt(oldIndex);
          // onReorderItem 的 newIndex 已随移除项调整，直接作为目标下标。
          paths.insert(newIndex.clamp(0, paths.length), moved);
          widget.manager.reorderSongs(widget.playlist.id, paths);
        }

        final rowExtent = m.songCover + 2 * m.vPad;
        final bottomPad = (hasSong ? 92.0 : 150.0) +
            MediaQuery.of(context).padding.bottom +
            (inBatch ? 140 : 0);

        // 批量模式行：整行点按切换选中，行首由 wrapBatchRow 挂勾选。
        Widget batchRow(int index) {
          final song = songs[index];
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

        return Stack(
          children: [
            // 批量模式禁用拖动排序（行首把手被勾选槽替代），统一走扁平列表，
            // 且专用 [_batchController] 避免与常规列表复用控制器。
            if (inBatch)
              ListView.builder(
                controller: _batchController,
                padding: EdgeInsets.only(bottom: bottomPad),
                itemExtent: rowExtent,
                addAutomaticKeepAlives: false,
                itemCount: songs.length,
                itemBuilder: (context, index) => RepaintBoundary(
                  key: ValueKey('batch_${songs[index].path}_$index'),
                  child: batchRow(index),
                ),
              )
            else
              ReorderableListView.builder(
                scrollController: _controller,
                // 顶级列表：拖到边缘时自动滚动，跨越整个歌单长列表也能连续排序。
                padding: EdgeInsets.only(bottom: bottomPad),
                buildDefaultDragHandles: false,
                // 拖动时被拖项作为 proxy 插入根 Overlay 展示，该层没有 Material 祖先；
                // 行内 CoverRow 的 InkWell 会在拖起瞬间以 debugCheckHasMaterial 报错
                // （表现「拖动就报错」）。补一层透明 Material 提供水波纹上下文。
                proxyDecorator: (child, index, animation) =>
                    Material(type: MaterialType.transparency, child: child),
                itemCount: songs.length,
                onReorderItem: onReorder,
                itemBuilder: (context, index) {
                  final song = songs[index];
                  // ReorderableListView 要求 itemBuilder 最外层携带 key 才能拖拽，同时用
                  // RepaintBoundary 隔离合成层，避免多行时可见行每帧整体重绘抽帧。
                  // 用「路径 + 下标」复合 Key：同一首歌可重复加入歌单，若仅用 path 作 key
                  // 会在相邻重复项间拖拽时触发重复 Key 断言报错。
                  return RepaintBoundary(
                    key: ValueKey('${song.path}_$index'),
                    child: Builder(
                      builder: (rowContext) {
                        // 捕获封面自身 context：飞封面直接取封面 RenderBox 的全局矩形，与列表封面像素级一致。
                        BuildContext? coverCtx;
                        final g = songRowPlay(ref, onPlay: () async {
                          // 等封面落地后再播放：播放条封面随落地同步更新，
                          // 避免飞行过程中播放条封面提前切换。
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
                          if (ok) widget.manager.play(widget.playlist, index);
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
                                  onPressed: () => widget.onRemove(index),
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
                              child: Center(child: DragHandle(index: index)),
                            ),
                          ],
                        );
                      },
                    ),
                  );
                },
              ),
            // 批量操作栏：悬浮在内容底部（避开播放条/安全区）。
            if (inBatch)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: BatchActionBar(
                  selectedCount: batch.selectedCount,
                  totalCount: songs.length,
                  showPlay: true,
                  showFavorite: true,
                  showPlaylist: true,
                  showDownload: true,
                  showRemove: true,
                  onSelectAll: () => batch.toggleSelectAll(
                      {for (final s in songs) s.path}),
                  onPlay: () => _batchPlay(songs),
                  onFavorite: () => _batchAddToFavorites(songs),
                  onPlaylist: () => _batchAddToPlaylist(songs),
                  onDownload: () => _batchDownload(songs),
                  onRemove: () => _confirmBatchRemove(songs),
                  onDone: batch.exit,
                ),
              ),
            if (!inBatch)
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

/// 把歌单曲目转成播放队列项（本地/在线通吃，与 PlaylistManager._toQueueItem 对齐）。
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
