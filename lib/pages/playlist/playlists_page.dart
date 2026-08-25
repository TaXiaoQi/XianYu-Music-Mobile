import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../src/playlist/playlist_provider.dart';
import '../../src/playlist/playlist_store.dart';
import '../../src/widgets/online_cover.dart';
import '../../src/widgets/sheet_dialog.dart';
import '../../src/core/app_colors.dart';

/// 我的歌单：创建/重命名/删除歌单，查看与播放歌单内容（对齐桌面歌单体系）。
class PlaylistsPage extends ConsumerWidget {
  const PlaylistsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(playlistManagerProvider);
    final scheme = Theme.of(context).colorScheme;
    final manager = ref.read(playlistManagerProvider.notifier);

    return Scaffold(
      backgroundColor: appSurfaceBg(context),
      appBar: AppBar(
        title: const Text('我的歌单'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '新建歌单',
            onPressed: () => _promptCreate(context, manager),
          ),
        ],
      ),
      body: state.loading
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
                          style: TextStyle(color: scheme.onSurfaceVariant)),
                      const SizedBox(height: 4),
                      Text(
                        '点击右上角新建，或在歌曲菜单中选择「添加到歌单」\n也可通过导入歌单页从备份文件、本地文件夹或云端导入',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 12, color: scheme.outline),
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
                        icon: const Icon(Icons.file_download_outlined, size: 16),
                        label: const Text('导入歌单'),
                      ),
                    ],
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 150),
                  itemCount: state.playlists.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) =>
                      _PlaylistCard(playlist: state.playlists[index]),
                ),
    );
  }

  Future<void> _promptCreate(
      BuildContext context, PlaylistManager manager) async {
    final name = await _promptName(context, '新建歌单');
    if (name == null || name.trim().isEmpty) return;
    await manager.create(name.trim());
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('已创建歌单「${name.trim()}」')));
  }
}

/// 输入歌单名称弹窗（新建/重命名共用，不显示当前值）。
Future<String?> _promptName(BuildContext context, String title) {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    useRootNavigator: true,
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
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
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
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => PlaylistDetailPage(playlistId: id),
    ));
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
                    color: const Color(0xFFEC4141), size: 22),
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
    showDialog<void>(
      context: context,
      useRootNavigator: true,
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
    final playlist = state.playlists
        .where((p) => p.id == playlistId)
        .cast<ImportedPlaylist?>()
        .firstWhere((_) => true, orElse: () => null);

    if (playlist == null) {
      return Scaffold(
        backgroundColor: appSurfaceBg(context),
        appBar: AppBar(title: const Text('歌单')),
        body: const Center(child: Text('歌单已不存在')),
      );
    }

    return Scaffold(
      backgroundColor: appSurfaceBg(context),
      appBar: AppBar(
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
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '共 ${playlist.songs.length} 首',
                    style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
                  ),
                ),
                FilledButton.icon(
                  onPressed: playlist.songs.isEmpty
                      ? null
                      : () => manager.play(playlist, 0),
                  icon: const Icon(Icons.play_arrow, size: 18),
                  label: const Text('播放全部'),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: playlist.songs.isEmpty
                ? Center(
                    child: Text('歌单为空，可在歌曲菜单中选择「添加到歌单」',
                        style:
                            TextStyle(fontSize: 13, color: scheme.outline)),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.only(bottom: 150),
                    itemCount: playlist.songs.length,
                    separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
                    itemBuilder: (context, index) {
                      final song = playlist.songs[index];
                      return ListTile(
                        dense: true,
                        leading: OnlineCover(
                          url: song.coverUrl,
                          size: 44,
                          radius: 6,
                        ),
                        title: Text(song.title,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          '${song.artist} · ${song.album}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style:
                              TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                        ),
                        trailing: IconButton(
                          icon: Icon(Icons.close,
                              size: 18, color: scheme.outline),
                          tooltip: '从歌单移除',
                          onPressed: () =>
                              manager.removeSong(playlist.id, song.path),
                        ),
                        onTap: () => manager.play(playlist, index),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
