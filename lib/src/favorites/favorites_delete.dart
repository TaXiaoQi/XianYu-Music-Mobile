import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth/account_api.dart';
import '../i18n/i18n.dart';
import '../sync/favorites_sync_state.dart';
import '../widgets/app_toast.dart';
import '../widgets/sheet_dialog.dart';

Future<bool> shouldAskFavoriteDeleteScope(
    WidgetRef ref, List<String> paths) async {
  final api = ref.read(accountApiProvider);
  final loggedIn = (api.ciyuanxiId ?? '').isNotEmpty;
  if (!loggedIn || paths.isEmpty) return false;
  final prefs = await SharedPreferences.getInstance();
  final synced = prefs.getStringList('synced_favorites_paths') ?? const <String>[];
  return paths.any(synced.contains);
}

Future<String?> resolveFavoriteDeleteScope(
    BuildContext context, WidgetRef ref, List<String> paths) async {
  if (!await shouldAskFavoriteDeleteScope(ref, paths)) return null;
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
    default:
      final ok = await _deleteCloud(context, ref, paths);
      if (ok) await FavoritesSyncState.addLocalOnlyPaths(paths);
  }
}

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
