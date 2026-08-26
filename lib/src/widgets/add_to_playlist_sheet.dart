import 'package:xianyu_music_mobile/src/widgets/predictive_dialog_route.dart';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../library/library_provider.dart';
import '../player/player_provider.dart';
import '../playlist/playlist_provider.dart';
import '../playlist/playlist_store.dart';
import '../plugin/plugin_backup_import.dart';
import 'sheet_dialog.dart';
import 'app_toast.dart';

/// 把播放队列项转成歌单曲目（本地/在线通吃）。
ImportedSong importedSongFromQueueItem(QueueItem item) {
  Map<String, dynamic>? musicInfo;
  String? pluginId;
  String? source;
  String? format;
  final infoJson = item.onlineSongJson;
  if (infoJson != null && infoJson.isNotEmpty) {
    try {
      final j = jsonDecode(infoJson) as Map<String, dynamic>;
      musicInfo = j['musicInfo'] is Map
          ? (j['musicInfo'] as Map).cast<String, dynamic>()
          : null;
      pluginId = j['pluginId'] as String?;
      source = j['source'] as String?;
      format = j['format'] as String?;
    } catch (_) {}
  }
  final isLocal = infoJson == null || infoJson.isEmpty;
  return ImportedSong(
    title: item.title,
    artist: item.artist,
    album: item.album,
    duration: (item.durationMs ~/ 1000),
    coverUrl: item.coverUrl,
    coverThumbPath: item.coverPath,
    localPath: isLocal ? item.path : null,
    pluginId: pluginId,
    source: source,
    format: format,
    musicInfo: musicInfo,
    path: item.path,
  );
}

/// 把本地曲库歌曲转成歌单曲目。
ImportedSong importedSongFromLocal(Song song) => ImportedSong(
      title: song.title,
      artist: song.artist,
      album: song.album,
      duration: song.duration,
      coverThumbPath: song.coverThumbPath,
      localPath: song.path,
      path: song.path,
    );

/// 「添加到歌单」底部弹层：选择已有歌单或新建。
Future<void> showAddToPlaylistSheet(
  BuildContext context,
  WidgetRef ref,
  List<ImportedSong> songs,
) async {
  final scheme = Theme.of(context).colorScheme;
  final manager = ref.read(playlistManagerProvider.notifier);
  await manager.refresh();
  if (!context.mounted) return;

  await showSheetDialog(
    context,
    (_) => Consumer(
      builder: (context, ref, _) {
        final state = ref.watch(playlistManagerProvider);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                  child: Row(
                    children: [
                      Text(
                        '添加到歌单',
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w700),
                      ),
                      const Spacer(),
                      Text(
                        '${songs.length} 首',
                        style: TextStyle(
                            fontSize: 12, color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                    children: [
                      ListTile(
                        leading: Container(
                          width: 42,
                          height: 42,
                          decoration: BoxDecoration(
                            color: scheme.primary.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(Icons.add, color: scheme.primary, size: 22),
                        ),
                        title: const Text('新建歌单',
                            style: TextStyle(fontWeight: FontWeight.w600)),
                        onTap: () async {
                          final name = await _promptName(context, '新建歌单');
                          if (name == null || name.trim().isEmpty) return;
                          await manager.create(name.trim());
                          if (!context.mounted) return;
                          Navigator.of(context).pop();
                          showXianYuToast(context, '已创建歌单「${name.trim()}」');
                        },
                      ),
                      for (final p in state.playlists)
                        ListTile(
                          leading: Container(
                            width: 42,
                            height: 42,
                            decoration: BoxDecoration(
                              color: scheme.primaryContainer,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Icon(Icons.queue_music,
                                size: 20,
                                color: scheme.onPrimaryContainer),
                          ),
                          title: Text(p.name,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text('${p.songs.length} 首',
                              style: const TextStyle(fontSize: 12)),
                          onTap: () async {
                            await manager.addSongs(p.id, songs);
                            if (!context.mounted) return;
                            Navigator.of(context).pop();
                            showXianYuToast(
                                context, '已添加到「${p.name}」(${songs.length} 首)');
                          },
                        ),
                    ],
                  ),
                ),
              ],
          ),
        );
      },
    ),
  );
}

/// 名称输入弹窗（新建/重命名共用）。
Future<String?> _promptName(BuildContext context, String title,
    {String initial = ''}) {
  final ctrl = TextEditingController(text: initial);
  return showPredictiveDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title, style: const TextStyle(fontSize: 16)),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        maxLength: 30,
        decoration: const InputDecoration(hintText: '歌单名称'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(ctrl.text),
          child: const Text('确定'),
        ),
      ],
    ),
  );
}

/// 歌单操作菜单（重命名/删除）。
Future<void> showPlaylistActionsSheet(
  BuildContext context,
  WidgetRef ref,
  ImportedPlaylist playlist,
) async {
  final manager = ref.read(playlistManagerProvider.notifier);
  final scheme = Theme.of(context).colorScheme;
  await showSheetDialog(
    context,
    (_) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 10),
            child: Text(
              playlist.name,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
          ),
          ListTile(
            leading: Icon(Icons.edit_outlined, color: scheme.primary),
            title: const Text('重命名歌单'),
            onTap: () async {
              final name =
                  await _promptName(context, '重命名歌单', initial: playlist.name);
              if (name == null || name.trim().isEmpty) return;
              await manager.rename(playlist.id, name.trim());
              if (context.mounted) Navigator.of(context).pop();
            },
          ),
          ListTile(
            leading: Icon(Icons.delete_outline, color: scheme.error),
            title: Text('删除歌单', style: TextStyle(color: scheme.error)),
            onTap: () async {
              final ok = await showPredictiveDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('删除歌单',
                      style: TextStyle(fontSize: 16)),
                  content: Text('确定删除「${playlist.name}」？该操作不可恢复。'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      child: const Text('取消'),
                    ),
                    FilledButton(
                      style: FilledButton.styleFrom(
                          backgroundColor: scheme.error),
                      onPressed: () => Navigator.of(context).pop(true),
                      child: const Text('删除'),
                    ),
                  ],
                ),
              );
              if (ok != true) return;
              await manager.remove(playlist.id);
              if (context.mounted) Navigator.of(context).pop();
            },
          ),
          const SizedBox(height: 6),
        ],
      ),
    ),
  );
}

/// 名称弹窗导出（歌单页新建按钮复用）。
Future<String?> promptPlaylistName(BuildContext context, String title,
        {String initial = ''}) =>
    _promptName(context, title, initial: initial);
