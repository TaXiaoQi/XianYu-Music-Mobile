// 歌曲分享弹层：分享到 QQ 好友 / QQ 空间（网页卡片）与复制分享链接。
//
// 分享以网页卡片落地页深链进行：接收方打开链接拉起重启并播放歌曲。
// 打开菜单不阻塞，点击对应目标时才现场生成分享链接与封面缩略图。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tencent_kit/tencent_kit.dart';

import '../player/player_provider.dart';
import '../widgets/app_toast.dart';
import '../widgets/sheet_dialog.dart';
import 'qq_share_service.dart';
import 'share_service.dart';

/// 弹出歌曲分享菜单：QQ 好友 / QQ 空间 / 复制链接。
Future<void> showSongShareSheet(
  BuildContext context, {
  required WidgetRef ref,
  required QueueItem song,
}) async {
  final scheme = Theme.of(context).colorScheme;
  // 提前捕获 Overlay，避免 await 后跨 async 间隙使用 BuildContext。
  final overlay = Overlay.of(context, rootOverlay: true);

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
              song.title,
              style:
                  const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Text(
              song.artist.isEmpty ? '未知歌手' : song.artist,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          ListTile(
            leading: const Icon(Icons.send, color: Color(0xFF12B7F5), size: 22),
            title: const Text('分享到 QQ 好友'),
            onTap: () {
              Navigator.pop(ctx);
              _shareViaQQ(overlay, ref, song, scene: TencentScene.kScene_QQ);
            },
          ),
          ListTile(
            leading: const Icon(Icons.public, color: Color(0xFF12B7F5), size: 22),
            title: const Text('分享到 QQ 空间'),
            subtitle: const Text('QQ 空间支持网页分享，不支持音乐卡片'),
            onTap: () {
              Navigator.pop(ctx);
              _shareViaQQ(overlay, ref, song, scene: TencentScene.kScene_QZone);
            },
          ),
          ListTile(
            leading: Icon(Icons.link, color: scheme.onSurfaceVariant, size: 22),
            title: const Text('复制分享链接'),
            onTap: () async {
              Navigator.pop(ctx);
              await _copyLink(overlay, ref, song);
            },
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

/// 获取（必要时生成）分享链接；失败返回空串。
Future<String> _ensureUrl(WidgetRef ref, QueueItem song) async {
  final share = ref.read(shareServiceProvider);
  final cached = share.cached(song);
  if (cached != null && cached.isNotEmpty) return cached;
  try {
    return await share.create(song);
  } catch (_) {
    return '';
  }
}

/// 生成并复制分享链接。
Future<void> _copyLink(OverlayState overlay, WidgetRef ref, QueueItem song) async {
  final url = await _ensureUrl(ref, song);
  if (url.isEmpty) {
    showXianYuToastByOverlay(overlay, '生成分享链接失败');
    return;
  }
  await Clipboard.setData(ClipboardData(text: url));
  showXianYuToastByOverlay(overlay, '分享链接已复制');
}

/// 分享网页卡片到指定 QQ 场景（好友 / 空间）。
Future<void> _shareViaQQ(
  OverlayState overlay,
  WidgetRef ref,
  QueueItem song, {
  required int scene,
}) async {
  final url = await _ensureUrl(ref, song);
  if (url.isEmpty) {
    showXianYuToastByOverlay(overlay, '生成分享链接失败');
    return;
  }

  final qq = ref.read(qqShareServiceProvider);
  if (!await qq.isQQInstalled()) {
    await Clipboard.setData(ClipboardData(text: url));
    showXianYuToastByOverlay(overlay, '未安装 QQ，分享链接已复制');
    return;
  }

  var cover = '';
  try {
    cover = await ref.read(shareServiceProvider).resolveCover(song);
  } catch (_) {}

  final artist = song.artist.isEmpty ? '未知歌手' : song.artist;
  final result = await qq.share(
    scene: scene,
    title: song.title,
    summary: '$artist · 来自弦予音乐',
    targetUrl: url,
    coverUrl: cover,
  );

  switch (result) {
    case QqShareResult.success:
      showXianYuToastByOverlay(overlay, '分享成功');
    case QqShareResult.canceled:
      showXianYuToastByOverlay(overlay, '已取消分享');
    default:
      await Clipboard.setData(ClipboardData(text: url));
      showXianYuToastByOverlay(overlay, '分享失败，链接已复制');
  }
}