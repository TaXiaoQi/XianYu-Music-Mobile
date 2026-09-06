import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/account_api.dart';
import '../i18n/i18n.dart';
import '../widgets/app_toast.dart';
import '../widgets/predictive_dialog_route.dart';
import '../widgets/sheet_dialog.dart';
import 'playlist_provider.dart';
import 'playlist_store.dart';

/// 删除歌单确认入口（对齐桌面已同步歌单删除范围弹窗）。
///
/// - 未同步歌单：普通确认框后仅删本地
/// - 已同步歌单（isCloud 或持有 cloudId，对齐桌面 isCloudOrigin）：
///   弹「删除本地/删除全部/仅保留本地」三选一
Future<void> confirmRemovePlaylist(
    BuildContext context, WidgetRef ref, ImportedPlaylist playlist) async {
  final hasCloud = playlist.isCloud || (playlist.cloudId ?? '').isNotEmpty;
  if (!hasCloud) {
    final ok = await showPredictiveDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
            title: Text(tr('删除歌单')),
            content:
                Text(tr('确定要删除「{name}」吗？', {'name': playlist.name})),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(tr('取消')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(tr('删除')),
              ),
            ],
          ),
    );
    if (ok == true) {
      await ref.read(playlistManagerProvider.notifier).remove(playlist.id);
    }
    return;
  }

  final scheme = Theme.of(context).colorScheme;
  final scope = await showSheetDialog<String>(
    context,
    (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 6),
              child: Column(
                children: [
                  Text(
                    tr('该歌单已同步到云端'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    tr('请选择删除范围'),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 12.5, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: Icon(Icons.devices_other_outlined,
                  color: scheme.onSurfaceVariant, size: 22),
              title: Text(tr('删除本地（云端保留）')),
              subtitle: Text(tr('仅删除本机，云端与其他设备保留'),
                  style: const TextStyle(fontSize: 12)),
              onTap: () => Navigator.pop(ctx, 'local'),
            ),
            ListTile(
              leading: Icon(Icons.delete_forever_outlined,
                  color: scheme.error, size: 22),
              title: Text(tr('删除全部')),
              subtitle: Text(tr('本机、云端、其他设备一起删除'),
                  style: const TextStyle(fontSize: 12)),
              onTap: () => Navigator.pop(ctx, 'all'),
            ),
            ListTile(
              leading: Icon(Icons.cloud_off_outlined,
                  color: scheme.error, size: 22),
              title: Text(tr('仅保留本地')),
              subtitle: Text(tr('云端与其他设备删除，本机保留'),
                  style: const TextStyle(fontSize: 12)),
              onTap: () => Navigator.pop(ctx, 'cloud'),
            ),
          ],
        ),
      ),
    ),
  );
  if (scope == null || !context.mounted) return;
  final cloudId = playlist.cloudId ?? '';
  final manager = ref.read(playlistManagerProvider.notifier);
  switch (scope) {
    case 'local':
      await manager.remove(playlist.id);
    case 'all':
      if (cloudId.isNotEmpty) await _deleteCloud(context, ref, cloudId);
      await manager.remove(playlist.id);
    default: // 'cloud'：仅删云端，本机保留并解绑云端标记
      if (cloudId.isNotEmpty) await _deleteCloud(context, ref, cloudId);
      await manager.detachCloud(playlist.id);
  }
}

/// 删除云端副本；失败提示但不中断后续本地动作。
Future<void> _deleteCloud(
    BuildContext context, WidgetRef ref, String cloudId) async {
  try {
    await ref.read(accountApiProvider).deleteCloudPlaylist(cloudId);
  } catch (_) {
    if (context.mounted) {
      showXianYuToast(context, tr('云端删除失败，请稍后重试'));
    }
  }
}
