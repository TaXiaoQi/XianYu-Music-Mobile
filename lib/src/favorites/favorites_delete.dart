import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth/account_api.dart';
import '../i18n/i18n.dart';
import '../sync/favorites_sync_state.dart';
import '../widgets/app_toast.dart';
import '../widgets/sheet_dialog.dart';

/// 收藏删除范围确认（对齐桌面收藏删除范围弹窗）。
///
/// [resolveFavoriteDeleteScope]：已登录且任一 path 在「上次已同步」集合中时
/// 弹「删除本地/删除全部/仅保留本地」三选一；否则返回 null（调用方走原确认流程）。
/// [applyFavoriteDeleteScope]：按范围应用删除动作。

/// 已同步收藏弹出删除范围选择；返回 'local' | 'all' | 'cloud'，取消或未同步返回 null。
Future<String?> resolveFavoriteDeleteScope(
    BuildContext context, WidgetRef ref, List<String> paths) async {
  final api = ref.read(accountApiProvider);
  final loggedIn = (api.ciyuanxiId ?? '').isNotEmpty;
  if (!loggedIn || paths.isEmpty) return null;
  final prefs = await SharedPreferences.getInstance();
  final synced = prefs.getStringList('synced_favorites_paths') ?? const <String>[];
  if (!paths.any(synced.contains)) return null;
  if (!context.mounted) return null;

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
                    tr('收藏已同步到云端'),
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
  return scope;
}

/// 按范围应用收藏删除：
/// - local：写「仅删本地」墓碑后执行 [onLocalRemove]（上传时排除出 delete_paths、下载合并跳过回灌）
/// - all：直接执行 [onLocalRemove]（diff 天然传播到云端）
/// - cloud：立即删除云端副本并写「仅保留本地」墓碑，本机不动
Future<void> applyFavoriteDeleteScope(
  BuildContext context,
  WidgetRef ref,
  String scope,
  List<String> paths, {
  required Future<void> Function() onLocalRemove,
}) async {
  switch (scope) {
    case 'local':
      await FavoritesSyncState.addCloudKeepPaths(paths);
      await onLocalRemove();
    case 'all':
      await onLocalRemove();
    default: // 'cloud'
      final ok = await _deleteCloud(context, ref, paths);
      if (ok) await FavoritesSyncState.addLocalOnlyPaths(paths);
  }
}

/// 删除云端收藏副本（merge 模式空集合 + delete_paths）；失败提示并返回 false。
Future<bool> _deleteCloud(
    BuildContext context, WidgetRef ref, List<String> paths) async {
  try {
    await ref
        .read(accountApiProvider)
        .uploadFavorites(const <Map<String, dynamic>>[], deletePaths: paths);
    return true;
  } catch (_) {
    if (context.mounted) {
      showXianYuToast(context, tr('云端删除失败，请稍后重试'));
    }
    return false;
  }
}
