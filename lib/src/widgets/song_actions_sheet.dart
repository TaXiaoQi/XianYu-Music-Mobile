import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../download/download_provider.dart';
import '../favorites/favorites_provider.dart';
import '../player/player_provider.dart';
import '../core/settings.dart';
import 'add_to_playlist_sheet.dart';
import '../share/share_sheet.dart';
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
              leading: Icon(Icons.share_outlined, color: scheme.primary, size: 22),
              title:   Text(tr('分享')),
              onTap: () {
                Navigator.pop(ctx);
                showSongShareSheet(context, ref: ref, song: item);
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
                onTap: () async {
                  final dn = ref.read(downloadProvider.notifier);
                  // 未设置自定义下载目录/无「所有文件访问」权限：禁止下载并提示（面板不关闭）。
                  if (!await dn.requireDownloadDir(ctx)) {
                    return;
                  }
                  // await 期间面板可能已被用户下滑关闭，此时操作失效 ctx
                  // 会触发 framework ancestor 断言崩溃。
                  if (!ctx.mounted) return;
                  // 「每次询问我」：关闭面板后先弹音质选择，再开始下载。
                  final behavior =
                      ref.read(settingsProvider).valueOrNull?.downloadBehavior ??
                          'default';
                  if (behavior == 'ask') {
                    Navigator.pop(ctx);
                    final quality = await _pickDownloadQuality(context, ref);
                    if (quality == null || !context.mounted) return;
                    ref
                        .read(downloadProvider.notifier)
                        .download(item, quality: quality);
                    showXianYuToast(
                      context,
                      tr('开始下载：{title}，请留意通知查看下载进度',
                          {'title': item.title}),
                    );
                    return;
                  }
                  Navigator.pop(ctx);
                  dn.download(item);
                  // 面板 ctx 已随 pop 进入退出动画，toast 用外层页面 context。
                  showXianYuToast(
                    context,
                    tr('开始下载：{title}，请留意通知查看下载进度',
                        {'title': item.title}),
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

/// 「每次询问我」下载音质选择：复用设置页同一套 12 档音质阶梯。
/// 默认高亮设置的下载音质，返回 null 表示取消。
Future<String?> _pickDownloadQuality(BuildContext ctx, WidgetRef ref) async {
  final current =
      ref.read(settingsProvider).valueOrNull?.downloadQuality ?? '320k';
  final options = <(String, String, String)>[
    (tr('低清'), 'mgg', tr('96k · 极速云端试听')),
    ('128k', '128k', '128k'),
    ('192k', '192k', '192k'),
    ('HQ', '320k', tr('高品质 · 320k')),
    ('SQ', 'flac', tr('无损 · FLAC')),
    ('Hi-Res', 'flac24bit', tr('高解析 · FLAC 24bit')),
    (tr('高解析度'), 'hires', tr('Hi-Res 高解析无损')),
    (tr('黑胶'), 'vinyl', tr('黑胶音色 · 无损')),
    (tr('杜比全景声'), 'dolby', tr('Dolby Atmos 沉浸环绕')),
    (tr('臻品音质'), 'atmos', tr('臻品立体空间声场')),
    (tr('臻品全景声'), 'atmos_plus', tr('臻品全空间沉浸声')),
    (tr('臻品母带'), 'master', tr('母带级无损臻品')),
  ];
  return showSheetDialog<String>(
    ctx,
    (dialogContext) => ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(dialogContext).size.height * 0.6,
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (label, value, subtitle) in options)
              ListTile(
                title: Text(label),
                subtitle: Text(subtitle),
                trailing: value == current
                    ? Icon(Icons.check,
                        color: Theme.of(dialogContext).colorScheme.primary)
                    : null,
                selected: value == current,
                onTap: () => Navigator.pop(dialogContext, value),
              ),
          ],
        ),
      ),
    ),
  );
}
