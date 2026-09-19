import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/i18n/i18n.dart';
import '../plugin/plugin_backup_import.dart';
import '../plugin/plugin_catalog.dart';
import '../plugin/plugin_models.dart';
import '../plugin/plugin_provider.dart';
import '../widgets/add_to_playlist_sheet.dart' show importedSongFromQueueItem;
import '../widgets/app_toast.dart';
import '../widgets/sheet_dialog.dart';
import 'playlist_provider.dart';
import 'playlist_store.dart';

/// 从源端（插件歌单）更新导入的歌单：
/// 1. 用导入时记录的来源重新拉取源端歌曲；
/// 2. 与本地对比得出新增 / 移除；
/// 3. 有移除时弹窗让用户选择「仅添加」或「完全同步」；
///    本软件内手动添加的歌曲（addedInApp）不参与删除。
Future<void> updatePlaylistFromSource(
  BuildContext context,
  WidgetRef ref,
  ImportedPlaylist playlist,
) async {
  final sources = ref.read(pluginManagerProvider).sources;
  final source = sources
      .where((s) => s.id == playlist.sourcePluginId && s.enabled)
      .firstOrNull;
  if (source == null) {
    showXianYuToast(context, tr('音源插件未安装或未启用，无法更新'));
    return;
  }

  List<ImportedSong> sourceSongs;
  try {
    sourceSongs = await _fetchSourceSongs(ref, source, playlist);
  } catch (e) {
    if (context.mounted) {
      showXianYuToast(context, tr('获取源歌单失败：{e}', {'e': e}));
    }
    return;
  }
  if (sourceSongs.isEmpty) {
    if (context.mounted) {
      showXianYuToast(context, tr('源端歌单为空或获取失败'));
    }
    return;
  }

  final sourceKeys = sourceSongs.map((s) => s.path).toSet();
  final localKeys = playlist.songs.map((s) => s.path).toSet();
  final addCount =
      sourceSongs.where((s) => !localKeys.contains(s.path)).length;
  final removeCount = playlist.songs
      .where((s) => !s.addedInApp && !sourceKeys.contains(s.path))
      .length;
  if (addCount == 0 && removeCount == 0) {
    if (context.mounted) {
      showXianYuToast(context, tr('已是最新，与源端一致'));
    }
    return;
  }

  var fullSync = false;
  if (removeCount > 0) {
    if (!context.mounted) return;
    final mode = await _showSyncModeSheet(context, addCount, removeCount);
    if (mode == null || !context.mounted) return;
    fullSync = mode == 'full';
  }

  try {
    await ref.read(playlistManagerProvider.notifier).applySourceSync(
          playlist.id,
          sourceSongs: sourceSongs,
          fullSync: fullSync,
        );
    if (context.mounted) {
      showXianYuToast(
        context,
        fullSync
            ? tr('已完全同步：新增 {n} 首，移除 {m} 首', {'n': addCount, 'm': removeCount})
            : tr('已新增 {n} 首歌曲', {'n': addCount}),
      );
    }
  } catch (e) {
    if (context.mounted) {
      showXianYuToast(context, tr('更新失败：{e}', {'e': e}));
    }
  }
}

Future<List<ImportedSong>> _fetchSourceSongs(
  WidgetRef ref,
  PluginSource source,
  ImportedPlaylist playlist,
) async {
  final engine = await ref.read(pluginEngineProvider.future);
  final catalog = PluginCatalogService(
    engine,
    ref.read(pluginManagerProvider).sources,
  );

  final results = <PluginSearchResult>[];
  final raw = playlist.sourceRaw;
  if (raw != null && raw.isNotEmpty) {
    final seen = <String>{};
    var page = 1;
    var maxPageSize = 0;
    final total = (raw['trackCount'] as num?)?.toInt() ?? 0;
    while (page <= 50) {
      final result =
          await catalog.getMusicSheetInfoWithEnd(source, raw, page: page);
      if (result.songs.isEmpty) break;
      final fresh = result.songs.where((r) {
        final key = '${r.songmid}|${r.name}|${r.singer}';
        return seen.add(key);
      }).toList();
      if (fresh.isEmpty) break;
      results.addAll(fresh);
      if (result.isEnd == true) break;
      if (total > 0 && results.length >= total) break;
      if (result.songs.length > maxPageSize) maxPageSize = result.songs.length;
      if (result.songs.length < maxPageSize) break;
      page++;
    }
  }
  if (results.isEmpty) {
    final url = playlist.sourceUrl;
    if (url != null && url.isNotEmpty) {
      results.addAll(await catalog.importMusicSheet(source, url));
    }
  }
  return results
      .map((r) =>
          importedSongFromQueueItem(PluginCatalogService.toQueueItem(source, r)))
      .toList();
}

/// 同步确认弹窗，样式对齐账号同步的删除范围选择
Future<String?> _showSyncModeSheet(
  BuildContext context,
  int addCount,
  int removeCount,
) {
  final scheme = Theme.of(context).colorScheme;
  return showSheetDialog<String>(
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
                    tr('检测到源端歌单更新'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    tr('新增 {n} 首，源端已移除 {m} 首',
                        {'n': addCount, 'm': removeCount}),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 12.5, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: Icon(Icons.add_circle_outline,
                  color: scheme.onSurfaceVariant, size: 22),
              title: Text(tr('仅添加新歌曲')),
              subtitle: Text(tr('保留本机现有歌曲不变'),
                  style: const TextStyle(fontSize: 12)),
              onTap: () => Navigator.pop(ctx, 'add'),
            ),
            ListTile(
              leading:
                  Icon(Icons.sync, color: scheme.error, size: 22),
              title: Text(tr('完全同步')),
              subtitle: Text(
                  tr('删除本机 {m} 首源端已移除的歌曲，并添加新歌曲',
                      {'m': removeCount}),
                  style: const TextStyle(fontSize: 12)),
              onTap: () => Navigator.pop(ctx, 'full'),
            ),
          ],
        ),
      ),
    ),
  );
}
