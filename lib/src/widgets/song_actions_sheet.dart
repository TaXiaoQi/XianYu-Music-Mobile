import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../download/download_provider.dart';
import '../favorites/favorites_provider.dart';
import '../player/player_provider.dart';
import 'add_to_playlist_sheet.dart';
import 'song_info_dialog.dart';

/// 通用歌曲操作弹层：收藏 / 添加到歌单 / 歌曲信息 / 下载。
/// 任何来源的歌曲统一以 QueueItem 表示（本地或在线）。
Future<void> showSongActionsSheet(
  BuildContext context, {
  required WidgetRef ref,
  required QueueItem item,
  VoidCallback? onPlay,
}) async {
  final scheme = Theme.of(context).colorScheme;
  final favorites = ref.read(favoritesProvider.notifier);
  final isFav = favorites.isFavorite(item.path);

  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) {
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Text(
                item.title,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Text(
                item.artist.isEmpty ? '未知歌手' : item.artist,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            ListTile(
              leading: Icon(isFav ? Icons.favorite : Icons.favorite_border,
                  color: const Color(0xFFEC4141), size: 22),
              title: Text(isFav ? '取消收藏' : '收藏'),
              onTap: () {
                Navigator.pop(ctx);
                favorites.toggle(item);
              },
            ),
            ListTile(
              leading: Icon(Icons.playlist_add, color: scheme.primary, size: 22),
              title: const Text('添加到歌单'),
              onTap: () {
                Navigator.pop(ctx);
                showAddToPlaylistSheet(
                    ctx, ref, [importedSongFromQueueItem(item)]);
              },
            ),
            ListTile(
              leading: Icon(Icons.info_outline,
                  color: scheme.onSurfaceVariant, size: 22),
              title: const Text('歌曲信息'),
              onTap: () {
                Navigator.pop(ctx);
                showSongInfoDialog(ctx, ref, item);
              },
            ),
            if (item.isOnline)
              ListTile(
                leading:
                    Icon(Icons.download_outlined, color: scheme.primary, size: 22),
                title: const Text('下载'),
                onTap: () {
                  Navigator.pop(ctx);
                  ref.read(downloadProvider.notifier).download(item);
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    SnackBar(content: Text('开始下载：${item.title}')),
                  );
                },
              ),
            if (onPlay != null)
              ListTile(
                leading: Icon(Icons.play_arrow, color: scheme.primary, size: 22),
                title: const Text('播放'),
                onTap: () {
                  Navigator.pop(ctx);
                  onPlay();
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
}
