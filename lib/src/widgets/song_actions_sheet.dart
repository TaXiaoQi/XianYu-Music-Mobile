import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../download/download_provider.dart';
import '../favorites/favorites_provider.dart';
import '../player/player_provider.dart';
import 'add_to_playlist_sheet.dart';
import 'sheet_dialog.dart';
import 'song_info_dialog.dart';
import 'app_toast.dart';
import '../i18n/i18n.dart';

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

  await showSheetDialog<void>(
    context,
    (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
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
                item.artist.isEmpty ? tr('未知歌手') : item.artist,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            ListTile(
              leading: Icon(isFav ? Icons.favorite : Icons.favorite_border,
                  color: scheme.primary, size: 22),
              title: Text(isFav ? tr('取消收藏') : tr('收藏')),
              onTap: () {
                Navigator.pop(ctx);
                favorites.toggle(item);
              },
            ),
            ListTile(
              leading: Icon(Icons.playlist_play, color: scheme.primary, size: 22),
              title:   Text(tr('下一首播放')),
              onTap: () {
                Navigator.pop(ctx);
                ref.read(playerProvider.notifier).playNextShare(item);
                showXianYuToast(ctx, tr('已添加至下一首播放'));
              },
            ),
            ListTile(
              leading: Icon(Icons.playlist_add, color: scheme.primary, size: 22),
              title:   Text(tr('添加到歌单')),
              onTap: () {
                Navigator.pop(ctx);
                showAddToPlaylistSheet(
                    ctx, ref, [importedSongFromQueueItem(item)]);
              },
            ),
            ListTile(
              leading: Icon(Icons.info_outline,
                  color: scheme.onSurfaceVariant, size: 22),
              title:   Text(tr('歌曲信息')),
              onTap: () {
                Navigator.pop(ctx);
                showSongInfoDialog(ctx, ref, item);
              },
            ),
            if (item.isOnline)
              ListTile(
                leading:
                    Icon(Icons.download_outlined, color: scheme.primary, size: 22),
                title:   Text(tr('下载')),
                onTap: () {
                  Navigator.pop(ctx);
                  ref.read(downloadProvider.notifier).download(item);
                  showXianYuToast(
                    ctx,
                    tr('开始下载：{title}，请留意通知查看下载进度', {'title': item.title}),
                  );
                },
              ),
            if (onPlay != null)
              ListTile(
                leading: Icon(Icons.play_arrow, color: scheme.primary, size: 22),
                title:   Text(tr('播放')),
                onTap: () {
                  Navigator.pop(ctx);
                  onPlay();
                },
              ),
            const SizedBox(height: 8),
        ],
      ),
    ),
  );
}
