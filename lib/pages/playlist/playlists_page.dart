import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/playlist/playlist_provider.dart';
import '../../src/playlist/playlist_store.dart';

/// 我的歌单：查看/播放导入的备份歌单。
class PlaylistsPage extends ConsumerWidget {
  const PlaylistsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(playlistManagerProvider);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('我的歌单')),
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
                      Text('还没有导入的歌单',
                          style: TextStyle(color: scheme.onSurfaceVariant)),
                      const SizedBox(height: 4),
                      Text(
                        '在「插件」页导入 BakaMusic / MusicFree / 洛雪备份文件',
                        style: TextStyle(fontSize: 12, color: scheme.outline),
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
}

class _PlaylistCard extends ConsumerWidget {
  const _PlaylistCard({required this.playlist});
  final ImportedPlaylist playlist;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final manager = ref.read(playlistManagerProvider.notifier);

    return Material(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _openPlaylist(context, ref),
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

  void _openPlaylist(BuildContext context, WidgetRef ref) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => _PlaylistDetailPage(playlist: playlist),
    ));
  }

  void _confirmRemove(BuildContext context, PlaylistManager manager) {
    showDialog<void>(
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

class _PlaylistDetailPage extends ConsumerWidget {
  const _PlaylistDetailPage({required this.playlist});
  final ImportedPlaylist playlist;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final manager = ref.read(playlistManagerProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: Text(playlist.name)),
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
                  onPressed: () => manager.play(playlist, 0),
                  icon: const Icon(Icons.play_arrow, size: 18),
                  label: const Text('播放全部'),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.only(bottom: 150),
              itemCount: playlist.songs.length,
              separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
              itemBuilder: (context, index) {
                final song = playlist.songs[index];
                return ListTile(
                  dense: true,
                  leading: song.coverUrl != null && song.coverUrl!.isNotEmpty
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: Image.network(
                            song.coverUrl!,
                            width: 44,
                            height: 44,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => _placeholder(scheme),
                          ),
                        )
                      : _placeholder(scheme),
                  title: Text(song.title,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    '${song.artist} · ${song.album}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                  trailing: song.isLocal
                      ? Icon(Icons.audio_file, size: 16, color: scheme.outline)
                      : Icon(Icons.cloud_outlined,
                          size: 16, color: scheme.outline),
                  onTap: () => manager.play(playlist, index),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _placeholder(ColorScheme scheme) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Icon(Icons.music_note, color: scheme.outline, size: 20),
    );
  }
}
