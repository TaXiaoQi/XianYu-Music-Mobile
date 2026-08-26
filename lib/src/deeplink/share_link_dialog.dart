import 'package:flutter/material.dart';

import '../widgets/online_cover.dart';
import '../widgets/modern_dialog.dart';
import '../widgets/predictive_dialog_route.dart';

/// 分享预览弹窗的用户动作。
enum ShareLinkPreviewAction { play, playNext, cancel }

/// 分享链接预览弹窗：封面 / 歌名 / 歌手 / 来源（插件或本地）+ 播放 / 下一首播放 / 取消。
///
/// 复用统一弹窗卡片样式（ModernDialogCard，与调试页弹窗同款视觉），
/// 压在 root Navigator 上；按用户点按返回对应动作，返回手势/系统返回视作取消。
Future<ShareLinkPreviewAction> showShareLinkPreviewDialog({
  required BuildContext context,
  required String name,
  required String artist,
  required String sourceLabel,
  String? cover,
}) async {
  final res = await showPredictiveDialog<ShareLinkPreviewAction>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) {
      final scheme = Theme.of(ctx).colorScheme;
      return ModernDialogCard(
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '分享歌曲',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.2,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '收到一首分享歌曲，可立即播放或加入队列',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.45,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  children: [
                    OnlineCover(
                      url: cover,
                      size: 84,
                      radius: 10,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 7),
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: scheme.primary.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Text(
                                  '来源',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: scheme.primary,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  sourceLabel,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () =>
                        Navigator.of(ctx).pop(ShareLinkPreviewAction.cancel),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 11,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: () =>
                        Navigator.of(ctx).pop(ShareLinkPreviewAction.playNext),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: scheme.primary,
                      side: BorderSide(
                        color: scheme.primary.withValues(alpha: 0.45),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 11,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text('下一首播放'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () =>
                        Navigator.of(ctx).pop(ShareLinkPreviewAction.play),
                    style: FilledButton.styleFrom(
                      backgroundColor: scheme.primary,
                      foregroundColor: scheme.onPrimary,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 11,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text('播放'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
  return res ?? ShareLinkPreviewAction.cancel;
}