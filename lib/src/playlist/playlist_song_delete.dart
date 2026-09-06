import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/account_api.dart';
import '../i18n/i18n.dart';
import '../plugin/plugin_backup_import.dart';
import '../sync/playlist_song_sync_state.dart';
import '../widgets/sheet_dialog.dart';
import 'playlist_store.dart';

/// 歌单内移除单曲的删除范围确认（对齐桌面已同步歌单删除范围弹窗与收藏删除范围弹窗）。
///
/// [resolvePlaylistSongDeleteScope]：歌单已同步（已登录且持有 cloudId）时
/// 弹「删除本地/删除全部/仅保留本地」三选一；未同步或取消返回 null（调用方走原流程）。
/// [applyPlaylistSongDeleteScope]：按范围应用删除动作，歌曲级删除经墓碑在同步时传播。
///
/// 歌曲身份键与收藏同步一致，按 path 匹配。

/// 已同步歌单弹出删除范围选择；返回 'local' | 'all' | 'cloud'，取消或未同步返回 null。
Future<String?> resolvePlaylistSongDeleteScope(
    BuildContext context, WidgetRef ref, ImportedPlaylist playlist,
    {required int songCount}) async {
  final api = ref.read(accountApiProvider);
  final loggedIn = (api.ciyuanxiId ?? '').isNotEmpty;
  final cloudId = playlist.cloudId ?? '';
  if (!loggedIn || cloudId.isEmpty) return null;
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
                    tr('歌单已同步到云端'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    songCount > 1
                        ? tr('请选择删除范围（共 {n} 首）', {'n': songCount})
                        : tr('请选择删除范围'),
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

/// 按范围应用歌单内单曲删除：
/// - local：缓存上传载荷写「仅删本地」墓碑后执行 [onLocalRemove]（上传时回填云端保留、下载跳过回灌）
/// - all：写「待上报删除」墓碑后执行 [onLocalRemove]（下次上传随 deletedSongPaths 上报，传播全端）
/// - cloud：写「仅保留本地」墓碑（本机不动，上传时剔除出载荷并上报云端删除）
Future<void> applyPlaylistSongDeleteScope(
  BuildContext context,
  WidgetRef ref,
  String scope,
  ImportedPlaylist playlist,
  List<ImportedSong> songs, {
  required Future<void> Function() onLocalRemove,
}) async {
  final cloudId = playlist.cloudId ?? '';
  if (cloudId.isEmpty || songs.isEmpty) {
    await onLocalRemove();
    return;
  }
  switch (scope) {
    case 'local':
      final payloads = <String, String>{
        for (final s in songs) s.path: jsonEncode(songToSyncPayload(s)),
      };
      await PlaylistSongSyncState.addCloudKeepSongs(cloudId, payloads);
      await onLocalRemove();
    case 'all':
      await PlaylistSongSyncState.addPendingDeletedSongs(
          cloudId, songs.map((s) => s.path));
      await onLocalRemove();
    default: // 'cloud'
      await PlaylistSongSyncState.addLocalOnlySongs(
          cloudId, songs.map((s) => s.path));
  }
}

/// 构造与同步上传一致的载荷（同 SyncNotifier._songToSyncPayload）。
Map<String, dynamic> songToSyncPayload(ImportedSong s) => {
      ...s.toJson(),
      'name': s.title,
      'duration': s.duration * 1000,
      // 与桌面端 classifySyncSong 对齐：标记本地/在线，供下载端恢复来源类型。
      'syncType': s.path.startsWith('lx://') ||
              s.path.startsWith('plugin://') ||
              s.path.startsWith('http://') ||
              s.path.startsWith('https://')
          ? 'online'
          : 'local',
    };
