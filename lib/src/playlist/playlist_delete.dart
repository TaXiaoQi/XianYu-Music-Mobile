import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/account_api.dart';
import '../core/application_logger.dart';
import '../i18n/i18n.dart';
import '../sync/playlist_song_sync_state.dart';
import '../widgets/app_toast.dart';
import '../widgets/predictive_dialog_route.dart';
import '../widgets/press_scale.dart';
import '../widgets/sheet_dialog.dart';
import 'playlist_provider.dart';
import 'playlist_store.dart';

Future<void> confirmRemovePlaylist(
    BuildContext context, WidgetRef ref, ImportedPlaylist playlist) async {
  // 三选一的前提是本地知道云端条目 id：无 cloudId 时即使 isCloud=true 也删不了
  // 云端（弹了"删除全部/仅保留本地"也无从生效），回落普通删除避免误导。
  final cloudId = playlist.cloudId ?? '';
  final hasCloud = cloudId.isNotEmpty;
  if (!hasCloud) {
    final ok = await showPredictiveDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
            title: Text(tr('删除歌单')),
            content:
                Text(tr('确定要删除「{name}」吗？', {'name': playlist.name})),
            actions: [
              PressableScale(
                pressScale: 0.92,
                child: TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(tr('取消')),
                ),
              ),
              PressableScale(
                pressScale: 0.92,
                child: FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(tr('删除')),
                ),
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
            PressableScale(
              child: ListTile(
              leading: Icon(Icons.devices_other_outlined,
                  color: scheme.onSurfaceVariant, size: 22),
              title: Text(tr('删除本地（云端保留）')),
              subtitle: Text(tr('仅删除本机，云端与其他设备保留'),
                  style: const TextStyle(fontSize: 12)),
              onTap: () => Navigator.pop(ctx, 'local'),
              ),
            ),
            PressableScale(
              child: ListTile(
              leading: Icon(Icons.delete_forever_outlined,
                  color: scheme.error, size: 22),
              title: Text(tr('删除全部')),
              subtitle: Text(tr('本机、云端、其他设备一起删除'),
                  style: const TextStyle(fontSize: 12)),
              onTap: () => Navigator.pop(ctx, 'all'),
              ),
            ),
            PressableScale(
              child: ListTile(
              leading: Icon(Icons.cloud_off_outlined,
                  color: scheme.error, size: 22),
              title: Text(tr('仅保留本地')),
              subtitle: Text(tr('云端与其他设备删除，本机保留'),
                  style: const TextStyle(fontSize: 12)),
              onTap: () => Navigator.pop(ctx, 'cloud'),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  if (scope == null || !context.mounted) return;
  final manager = ref.read(playlistManagerProvider.notifier);
  AppLog.debug('playlist', '删除歌单 scope=$scope cloudId=$cloudId');
  switch (scope) {
    case 'local':
      // 记录下载跳过，防止下次同步 diff 把云端歌单重新 create 回来
      await PlaylistSongSyncState.addDownloadSkipPlaylistIds([cloudId]);
      await manager.remove(playlist.id);
    case 'all':
      // 本地先删、UI 立即生效：云端删除若挂死（底层 fetchTimeoutMs 未生效时
      // 请求会无限等待），原实现整条 await 链停在半路，本地删除走不到，
      // 用户感知为"选了删除全部没反应"。云端删失败时保留下载跳过记录，
      // 防止下次同步 diff 把云端歌单重新拉回来。
      await manager.remove(playlist.id);
      // 本地已删完，context 仍挂在此页；_deleteCloud 内部对 toast 有 mounted 守卫
      // ignore: use_build_context_synchronously
      final cloudOk = await _deleteCloud(context, ref, cloudId);
      AppLog.debug('playlist', '删除歌单(all) 云端删除 ok=$cloudOk');
      if (cloudOk) {
        await PlaylistSongSyncState.removeDownloadSkipPlaylistIds([cloudId]);
      }
    default:
      // 仅保留本地：云端删除失败时不解除绑定——detach 后上传同步会把它
      // 当新歌单重新传回云端，删除等于没发生；保留 cloudId 等用户重试。
      if (await _deleteCloud(context, ref, cloudId)) {
        await PlaylistSongSyncState.removeDownloadSkipPlaylistIds([cloudId]);
        await manager.detachCloud(playlist.id);
      }
  }
}

/// 云端歌单删除。返回是否成功；Dart 侧硬超时兜底——底层超时失效导致请求
/// 挂死时，20s 后放行失败路径，不再阻塞调用方收尾。
Future<bool> _deleteCloud(
    BuildContext context, WidgetRef ref, String cloudId) async {
  try {
    await ref
        .read(accountApiProvider)
        .deleteCloudPlaylist(cloudId)
        .timeout(const Duration(seconds: 20));
    return true;
  } catch (e) {
    AppLog.warn('playlist', '云端歌单删除失败: $e');
    if (context.mounted) {
      showXianYuToast(context, tr('云端删除失败，请稍后重试'));
    }
    return false;
  }
}
