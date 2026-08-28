import 'package:xianyu_music_mobile/src/widgets/predictive_dialog_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../src/core/app_colors.dart';
import '../../src/navigation/shell.dart';
import '../../src/player/player_provider.dart';
import '../../src/playlist/playlist_provider.dart';
import '../../src/playlist/playlist_store.dart';
import '../../src/plugin/plugin_backup_import.dart';
import '../../src/widgets/app_toast.dart';
import '../../src/widgets/bottom_play_bar_slot.dart';
import '../../src/widgets/cover_image.dart';
import '../../src/widgets/drag_handle.dart';
import '../../src/widgets/flying_cover.dart';
import '../../src/widgets/glass_appbar.dart';
import '../../src/widgets/list_metrics.dart';
import '../../src/widgets/sheet_dialog.dart';
import '../../src/widgets/song_list_view.dart';
import '../../src/i18n/i18n.dart';

/// 我的歌单：创建/重命名/删除歌单，查看与播放歌单内容（对齐桌面歌单体系）。
class PlaylistsPage extends ConsumerWidget {
  const PlaylistsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(playlistManagerProvider);
    final scheme = Theme.of(context).colorScheme;
    final manager = ref.read(playlistManagerProvider.notifier);

    return HideShellChrome(
      child: Scaffold(
        backgroundColor: appScaffoldBackground(context, ref),
        resizeToAvoidBottomInset: false,
        body: RepaintBoundary(child: Stack(
          children: [
            Padding(
              padding: EdgeInsets.only(top: GlassTopBar.height(context)),
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
                      : _PlaylistList(state: state),
            ),
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
            const BottomPlayBarSlot(),
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
  const _PlaylistList({required this.state});

  final ImportedPlaylistState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasSong = ref.watch(playerProvider.select((s) => s.current != null));
    return ListView.separated(
      padding: EdgeInsets.fromLTRB(
        16,
        8,
        16,
        (hasSong ? 92.0 : 150.0) + MediaQuery.of(context).padding.bottom,
      ),
      itemCount: state.playlists.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) =>
          _PlaylistCard(playlist: state.playlists[index]),
    );
  }
}

class _PlaylistCard extends ConsumerWidget {
  const _PlaylistCard({required this.playlist});
  final ImportedPlaylist playlist;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final glass = ref.watch(wallpaperActiveProvider);
    final manager = ref.read(playlistManagerProvider.notifier);
    final first = playlist.songs.isNotEmpty ? playlist.songs.first : null;

    return Material(
      color: glass ? glassControlFill : appCardColor(context),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: glass ? BorderSide(color: glassControlBorder) : BorderSide.none,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _openPlaylist(context, playlist.id),
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

  void _openPlaylist(BuildContext context, String id) {
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
class PlaylistDetailPage extends ConsumerWidget {
  const PlaylistDetailPage({super.key, required this.playlistId});
  final String playlistId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(playlistManagerProvider);
    final scheme = Theme.of(context).colorScheme;
    final manager = ref.read(playlistManagerProvider.notifier);
    final playlist = state.playlists
        .where((p) => p.id == playlistId)
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
                            onRemove: (index) =>
                                manager.removeSong(playlist.id, playlist.songs[index].path),
                          ),
                  ),
                ],
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: GlassTopBar(
                leading: const BackButton(),
                title: Text(playlist.name),
                actions: [
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
            const BottomPlayBarSlot(),
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
  });

  final String name;
  final ImportedSong? song;
  final int count;
  final VoidCallback? onPlayAll;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final s = song;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
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
                FilledButton.icon(
                  onPressed: onPlayAll,
                  icon: const Icon(Icons.play_arrow, size: 18),
                  label:   Text(tr('播放全部'), style: TextStyle(fontSize: 13)),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    minimumSize: const Size(0, 34),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 歌单歌曲列表：按公告的列表项尺寸（ListSize）缩放；长按行首把手可拖动排序。
class _PlaylistSongs extends ConsumerWidget {
  const _PlaylistSongs({
    required this.playlist,
    required this.manager,
    required this.onRemove,
  });

  final ImportedPlaylist playlist;
  final PlaylistManager manager;
  final void Function(int index) onRemove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final m = ListMetrics.ofRef(ref);
    final hasSong = ref.watch(playerProvider.select((s) => s.current != null));
    final songs = playlist.songs;

    void onReorder(int oldIndex, int newIndex) {
      if (newIndex < 0 || newIndex >= songs.length || newIndex == oldIndex) return;
      final paths = songs.map((s) => s.path).toList();
      final moved = paths.removeAt(oldIndex);
      // onReorderItem 的 newIndex 已随移除项调整，直接作为目标下标。
      paths.insert(newIndex.clamp(0, paths.length), moved);
      manager.reorderSongs(playlist.id, paths);
    }

    return ReorderableListView.builder(
      // 顶级列表：拖到边缘时自动滚动，跨越整个歌单长列表也能连续排序。
      padding: EdgeInsets.only(
        bottom: (hasSong ? 92.0 : 150.0) +
            MediaQuery.of(context).padding.bottom,
      ),
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
                if (ok) manager.play(playlist, index);
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
                        fontSize: m.titleSize, fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    '${song.artist} · ${song.album}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: m.subtitleSize, color: scheme.onSurfaceVariant),
                  ),
                  trailing: IconButton(
                    icon: Icon(Icons.close,
                        size: 18, color: scheme.outline),
                    tooltip: tr('从歌单移除'),
                    onPressed: () => onRemove(index),
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
    );
  }
}
