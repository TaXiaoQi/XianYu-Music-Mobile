import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/auth/account_api.dart';
import '../../src/i18n/i18n.dart';
import '../../src/plugin/plugin_models.dart';
import '../../src/plugin/plugin_provider.dart';
import '../../src/sync/plugin_sync_state.dart';
import '../../src/widgets/app_toast.dart';
import '../../src/widgets/predictive_dialog_route.dart';
import '../../src/widgets/sheet_dialog.dart';

/// 卸载插件确认入口（对齐桌面已同步插件删除范围弹窗）。
///
/// - 未同步插件（未登录或无云端副本）：普通确认框后仅卸载本地
/// - 已同步插件：弹「删除本地/删除全部/仅保留本地」三选一
Future<void> confirmRemovePlugin(
    BuildContext context, WidgetRef ref, PluginSource source) async {
  final api = ref.read(accountApiProvider);
  final loggedIn = (api.ciyuanxiId ?? '').isNotEmpty;
  final hasCloud = loggedIn && await PluginSyncState.isSynced(source.id);
  final manager = ref.read(pluginManagerProvider.notifier);

  if (!hasCloud) {
    if (!context.mounted) return;
    await showPredictiveDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('卸载插件')),
        content: Text(tr('确定要卸载「{name}」吗？', {'name': source.name})),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('取消')),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              manager.remove(source.id);
            },
            child: Text(tr('卸载')),
          ),
        ],
      ),
    );
    return;
  }

  final scheme = Theme.of(context).colorScheme;
  if (!context.mounted) return;
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
                    tr('该插件已同步到云端'),
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
  if (scope == null) return;
  switch (scope) {
    case 'local':
      // 写入「仅删本地」墓碑，下载恢复时跳过，防止删除后被同步回流
      await PluginSyncState.addDownloadSkipIds([source.id]);
      await manager.remove(source.id);
    case 'all':
      await _deleteCloud(context, ref, source.id);
      await manager.remove(source.id);
    default: // 'cloud'：仅删云端，本机保留并写入「仅保留本地」墓碑防上传复活
      final ok = await _deleteCloud(context, ref, source.id);
      if (ok) await PluginSyncState.addUploadSkipIds([source.id]);
  }
}

/// 删除云端插件副本；返回是否成功。失败提示但不中断后续本地动作。
Future<bool> _deleteCloud(
    BuildContext context, WidgetRef ref, String pluginId) async {
  try {
    await ref.read(accountApiProvider).deleteCloudPlugins([pluginId]);
    await PluginSyncState.removeSyncedIds([pluginId]);
    return true;
  } catch (_) {
    if (context.mounted) {
      showXianYuToast(context, tr('云端删除失败，请稍后重试'));
    }
    return false;
  }
}
