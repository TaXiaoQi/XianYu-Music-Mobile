import 'package:xianyu_music_mobile/src/widgets/predictive_dialog_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../src/core/app_colors.dart';
import '../../src/navigation/shell.dart';
import '../../src/player/player_provider.dart';
import '../../src/playlist/playlist_provider.dart';
import '../../src/playlist/playlist_store.dart';
import '../../src/widgets/app_toast.dart';
import '../../src/widgets/flying_cover.dart';
import '../../src/widgets/glass_appbar.dart';
import '../../src/widgets/list_metrics.dart';
import '../../src/widgets/mini_player_bar.dart';
import '../../src/widgets/online_cover.dart';
import '../../src/widgets/sheet_dialog.dart';
import '../../src/widgets/song_list_view.dart';

/// 我的歌单：创建/重命名/删除歌单，查看与播放歌单内容（对齐桌面歌单体系）。
class PlaylistsPage extends ConsumerWidget {
  const PlaylistsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(playlistManagerProvider);
    final scheme = Theme.of(context).colorScheme;
    final manager = ref.read(playlistManagerProvider.notifier);
    final hasSong = ref.watch(playerProvider.select((s) => s.current != null));

    return HideShellChrome(
      child: Scaffold(
        backgroundColor: appSurfaceBg(context),
        body: Stack(
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
                              Text('还没有歌单',
                                  style:
                                      TextStyle(color: scheme.onSurfaceVariant)),
                              const SizedBox(height: 4),
                              Text(
                                '点击右上角新建，或在歌曲菜单中选择「添加到歌单」\n也可通过导入歌单页从备份文件、本地文件夹或云端导入',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    fontSize: 12, color: scheme.outline),
                              ),
                              const SizedBox(height: 16),
                              FilledButton.tonalIcon(
                                onPressed: () => _promptCreate(context, manager),
                                icon: const Icon(Icons.add, size: 18),
                                label: const Text('新建歌单'),
                              ),
                              const SizedBox(height: 8),
                              TextButton.icon(
                                onPressed: () => context.push('/playlist-import'),
                                icon: const Icon(Icons.file_download_outlined,
                                    size: 16),
                                label: const Text('导入歌单'),
                              ),
                            ],
                          ),
                        )
                      : ListView.separated(
                          padding: EdgeInsets.fromLTRB(
                            16,
                            8,
                            16,
                            (hasSong ? 92.0 : 150.0) +
                                MediaQuery.of(context).padding.bottom,
                          ),
                          itemCount: state.playlists.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 8),
                          itemBuilder: (context, index) =>
                              _PlaylistCard(playlist: state.playlists[index]),
                        ),
            ),
            if (hasSong)
              Positioned(
                left: 14,
                right: 14,
                bottom: MediaQuery.of(context).padding.bottom + 12,
                child: const MiniPlayerBar(),
              ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: GlassTopBar(
                leading: const BackButton(),
                title: const Text('我的歌单'),
                actions: [
                  IconButton(
                    icon: const Icon(Icons.add),
                    tooltip: '新建歌单',
                    onPressed: () => _promptCreate(context, manager),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _promptCreate(
      BuildContext context, PlaylistManager manager) async {
    final name = await _promptName(context, '新建歌单');
    if (name == null || name.trim().isEmpty) return;
    await manager.create(name.trim());
    if (!context.mounted) return;
    showXianYuToast(context, '已创建歌单「${name.trim()}」');
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
        decoration: const InputDecoration(hintText: '歌单名称'),
        onSubmitted: (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, controller.text),
          child: const Text('确定'),
        ),
      ],
    ),
  );
}

class _PlaylistCard extends ConsumerWidget {
  const _PlaylistCard({required this.playlist});
  final ImportedPlaylist playlist;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final manager = ref.read(playlistManagerProvider.notifier);

    return Material(
      color: appCardColor(context),
      borderRadius: BorderRadius.circular(16),
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
                child: Icon(Icons.queue_music, color: scheme.primary, size: 22),
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
                      '${playlist.songs.length} 首歌曲',
                      style: TextStyle(
                          fontSize: 12, color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: Icon(Icons.edit_outlined, size: 20, color: scheme.outline),
                tooltip: '重命名',
                onPressed: () => _rename(context, manager),
              ),
              IconButton(
                icon: Icon(Icons.delete_outline,
                    size: 20, color: scheme.outline),
                tooltip: '删除歌单',
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
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(Icons.edit_outlined, color: scheme.primary, size: 22),
                title: const Text('重命名歌单'),
                onTap: () {
                  Navigator.pop(ctx);
                  _rename(context, manager);
                },
              ),
              ListTile(
                leading: Icon(Icons.delete_outline,
                    color: scheme.error, size: 22),
                title: const Text('删除歌单'),
                onTap: () {
                  Navigator.pop(ctx);
                  _confirmRemove(context, manager);
                },
              ),
            ],
          ),
        ),
      );
  }

  Future<void> _rename(BuildContext context, PlaylistManager manager) async {
    final name = await _promptName(context, '重命名歌单');
    if (name == null || name.trim().isEmpty) return;
    await manager.rename(playlist.id, name.trim());
  }

  void _confirmRemove(BuildContext context, PlaylistManager manager) {
    showPredictiveDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除歌单'),
        content: Text('确定要删除「${playlist.name}」吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              manager.remove(playlist.id);
            },
            child: const Text('删除'),
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
    final hasSong = ref.watch(playerProvider.select((s) => s.current != null));
    final playlist = state.playlists
        .where((p) => p.id == playlistId)
        .cast<ImportedPlaylist?>()
        .firstWhere((_) => true, orElse: () => null);

    if (playlist == null) {
      return HideShellChrome(
        child: Scaffold(
          backgroundColor: appSurfaceBg(context),
          body: Stack(
            children: [
              Padding(
                padding: EdgeInsets.only(top: GlassTopBar.height(context)),
                child: const Center(child: Text('歌单已不存在')),
              ),
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: GlassTopBar(
                  leading: const BackButton(),
                  title: const Text('歌单'),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return HideShellChrome(
      child: Scaffold(
        backgroundColor: appSurfaceBg(context),
        body: Stack(
          children: [
            Padding(
              padding: EdgeInsets.only(top: GlassTopBar.height(context)),
              child: Column(
                children: [
                  _AlbumHeader(
                    name: playlist.name,
                    coverUrl: playlist.songs.isNotEmpty
                        ? playlist.songs.first.coverUrl
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
                              '歌单为空，可在歌曲菜单中选择「添加到歌单」',
                              style: TextStyle(
                                  fontSize: 13, color: scheme.outline),
                            ),
                          )
                        : _PlaylistSongs(
                            playlist: playlist,
                            manager: manager,
                            hasSong: hasSong,
                            onRemove: (index) =>
                                manager.removeSong(playlist.id, playlist.songs[index].path),
                          ),
                  ),
                ],
              ),
            ),
            if (hasSong)
              Positioned(
                left: 14,
                right: 14,
                bottom: MediaQuery.of(context).padding.bottom + 12,
                child: const MiniPlayerBar(),
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
                    tooltip: '重命名',
                    onPressed: () async {
                      final name = await _promptName(context, '重命名歌单');
                      if (name == null || name.trim().isEmpty) return;
                      await manager.rename(playlist.id, name.trim());
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

/// 歌单详情头部：对齐在线专辑页样式（封面 + 名称 + 数量 + 播放全部）。
class _AlbumHeader extends StatelessWidget {
  const _AlbumHeader({
    required this.name,
    required this.coverUrl,
    required this.count,
    required this.onPlayAll,
  });

  final String name;
  final String? coverUrl;
  final int count;
  final VoidCallback? onPlayAll;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        children: [
          coverUrl == null || coverUrl!.isEmpty
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
              : OnlineCover(url: coverUrl, size: 76, radius: 12),
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
                  '$count 首',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 12.5, color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: onPlayAll,
                  icon: const Icon(Icons.play_arrow, size: 18),
                  label: const Text('播放全部', style: TextStyle(fontSize: 13)),
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

/// 歌单歌曲列表：按公告的列表项尺寸（ListSize）缩放。
class _PlaylistSongs extends ConsumerWidget {
  const _PlaylistSongs({
    required this.playlist,
    required this.manager,
    required this.hasSong,
    required this.onRemove,
  });

  final ImportedPlaylist playlist;
  final PlaylistManager manager;
  final bool hasSong;
  final void Function(int index) onRemove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final m = ListMetrics.ofRef(ref);
    return ListView.builder(
      padding: EdgeInsets.only(
        bottom: (hasSong ? 92.0 : 150.0) +
            MediaQuery.of(context).padding.bottom,
      ),
      itemCount: playlist.songs.length,
      itemBuilder: (context, index) {
        final song = playlist.songs[index];
        final g = songRowPlay(ref, onPlay: () {
          launchFlyCover(
            context,
            coverSize: m.songCover,
            vPad: m.vPad,
            networkUrl: song.coverUrl,
            radius: m.songRadius,
          );
          manager.play(playlist, index);
        });
        return g.wrap(
          CoverRow(
            cover: OnlineCover(
                url: song.coverUrl, size: m.songCover, radius: m.songRadius),
            onTap: g.onTap,
            verticalPadding: m.vPad,
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
              tooltip: '从歌单移除',
              onPressed: () => onRemove(index),
            ),
          ),
        );
      },
    );
  }
}
