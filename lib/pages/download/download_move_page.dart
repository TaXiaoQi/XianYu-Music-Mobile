import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/core/app_colors.dart';
import '../../src/core/application_logger.dart';
import '../../src/download/download_provider.dart';
import '../../src/library/library_provider.dart';
import '../../src/library/ohos_folder_channel.dart';
import '../../src/navigation/shell.dart';
import '../../src/rust/api.dart';
import '../../src/widgets/app_toast.dart';
import '../../src/widgets/cover_image.dart';
import '../../src/widgets/glass_appbar.dart';
import '../../src/widgets/predictive_dialog_route.dart';
import '../../src/i18n/i18n.dart';

/// 鸿蒙「批量移动」：把下载到沙盒的歌曲批量移动/导出到公共目录。
///
/// 鸿蒙无持久化文件夹授权，公共目录只能经系统 folder picker 的前台
/// 临时授权写入：选一次目标文件夹 → 批量复制（目标同名跳过不覆盖）→
/// 默认移动模式删除沙盒原件并删除下载记录 → 后台重扫曲库，条目由
/// 扫描 diff 自动清除。导出失败/跳过的原件一律不删。
class DownloadMovePage extends ConsumerStatefulWidget {
  const DownloadMovePage({super.key});

  @override
  ConsumerState<DownloadMovePage> createState() => _DownloadMovePageState();
}

class _DownloadMovePageState extends ConsumerState<DownloadMovePage> {
  final Set<String> _selected = {};
  bool _busy = false;
  bool _keepOriginal = false;

  List<DownloadHistoryEntry> _available(List<DownloadHistoryEntry> history) =>
      [
        for (final e in history)
          if (File(e.filePath).existsSync()) e,
      ];

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(downloadProvider);
    final scheme = Theme.of(context).colorScheme;
    final entries = _available(state.history);
    final allSelected =
        entries.isNotEmpty && _selected.length == entries.length;

    return HideShellChrome(
      child: Scaffold(
        backgroundColor: appScaffoldBackground(context, ref),
        body: Stack(
          children: [
            Padding(
              padding: EdgeInsets.only(top: GlassTopBar.height(context)),
              child: entries.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.folder_copy_outlined,
                              size: 48,
                              color:
                                  scheme.onSurface.withValues(alpha: 0.25)),
                          const SizedBox(height: 12),
                          Text(
                            tr('暂无可移动的歌曲\n先在搜索结果或播放页下载音乐'),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                fontSize: 14,
                                color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.only(bottom: 120),
                      itemCount: entries.length,
                      itemBuilder: (context, i) =>
                          _entryTile(context, entries[i], scheme),
                    ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: GlassTopBar(
                leading: const BackButton(),
                title: Text(tr('批量移动')),
                actions: [
                  if (entries.isNotEmpty)
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => setState(() {
                                if (allSelected) {
                                  _selected.clear();
                                } else {
                                  _selected
                                    ..clear()
                                    ..addAll(
                                        entries.map((e) => e.songPath));
                                }
                              }),
                      child: Text(allSelected ? tr('全不选') : tr('全选')),
                    ),
                ],
              ),
            ),
            if (entries.isNotEmpty)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _bottomBar(context, scheme),
              ),
          ],
        ),
      ),
    );
  }

  Widget _entryTile(
      BuildContext context, DownloadHistoryEntry e, ColorScheme scheme) {
    final selected = _selected.contains(e.songPath);
    return InkWell(
      onTap: _busy
          ? null
          : () => setState(() {
                selected ? _selected.remove(e.songPath) : _selected.add(e.songPath);
              }),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            Checkbox(
              value: selected,
              onChanged: _busy
                  ? null
                  : (v) => setState(() {
                        v == true
                            ? _selected.add(e.songPath)
                            : _selected.remove(e.songPath);
                      }),
            ),
            CoverImage(
              songPath: e.filePath,
              width: 44,
              height: 44,
              radius: 8,
              icon: Icons.music_note,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(e.title ?? e.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(
                    '${e.artist ?? ''}${e.artist?.isNotEmpty == true ? ' · ' : ''}${e.quality}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bottomBar(BuildContext context, ColorScheme scheme) {
    final n = _selected.length;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.96),
        border: Border(
            top: BorderSide(color: scheme.outlineVariant, width: 0.5)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  n == 0 ? tr('选择要移动的歌曲') : tr('已选 {n} 首', {'n': n}),
                  style: TextStyle(
                      fontSize: 13, color: scheme.onSurfaceVariant),
                ),
              ),
              FilledButton.icon(
                onPressed: _busy || n == 0 ? null : _moveSelected,
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child:
                            CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.drive_file_move, size: 18),
                label: Text(tr('移动到文件夹')),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _moveSelected() async {
    final state = ref.read(downloadProvider);
    final entries = _available(state.history)
        .where((e) => _selected.contains(e.songPath))
        .toList();
    if (entries.isEmpty) return;

    bool keep = _keepOriginal;
    final confirmed = await showPredictiveDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(tr('移动 {n} 首歌曲', {'n': entries.length})),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tr('通过系统文件选择器选择目标文件夹，同名文件将跳过不覆盖。')),
              const SizedBox(height: 12),
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => setState(() => keep = !keep),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Checkbox(
                        value: keep,
                        onChanged: (v) => setState(() => keep = v ?? false),
                      ),
                      Text(tr('保留原文件（仅导出副本）')),
                    ],
                  ),
                ),
              ),
              if (!keep)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    tr('移动后原文件删除，歌曲将从曲库移除'),
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.error),
                  ),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('取消')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr('选择文件夹')),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    _keepOriginal = keep;
    setState(() => _busy = true);

    try {
      AppLog.debug('move', '批量移动开始: ${entries.length} 个文件 keepOriginal=$_keepOriginal');
      final uri = await OhosFolderChannel.pickFolder();
      if (uri == null) {
        AppLog.debug('move', 'pickFolder 取消或失败');
        if (!mounted) return;
        return;
      }
      AppLog.debug('move', 'pickFolder 完成: $uri');

      final result = await OhosFolderChannel.exportFiles(
        folderUri: uri,
        paths: [for (final e in entries) e.filePath],
      );
      if (!mounted) return;
      AppLog.debug('move',
          'exportFiles: exported=${result.exported} skipped=${result.skipped.length} '
          'failed=${result.failed.length}${result.failed.isEmpty ? '' : ' 列表=${result.failed.take(5)}'}');

      final exportedCount = result.exported;
      String msg;
      if (exportedCount == 0 && result.skipped.isEmpty) {
        showXianYuToast(context, tr('导出失败，请重试'));
        return;
      }

      if (!keep) {
        final okPaths = result.succeededOf([for (final e in entries) e.filePath]);
        final notifier = ref.read(downloadProvider.notifier);
        var moved = 0;
        final delFailed = <String>[];
        for (final e in entries) {
          if (!okPaths.contains(e.filePath)) continue;
          try {
            await deleteMusicFile(path: e.filePath);
            notifier.removeHistory(e.songPath);
            moved++;
          } catch (err) {
            // 删除失败：原件保留，记录保留，不下账
            delFailed.add('${e.filePath}: $err');
          }
        }
        if (delFailed.isNotEmpty) {
          AppLog.warn('move', '删除原件失败 ${delFailed.length} 个: ${delFailed.take(5)}');
        }
        AppLog.debug('move', '移动完成: 导出 ${result.exported}，删除原件 $moved');
        // 曲库条目由扫描 diff 自动清除（文件已消失）
        unawaited(ref.read(libraryProvider.notifier).scanAllFolders());
        msg = tr('已移动 {n} 首', {'n': moved});
      } else {
        msg = tr('已导出 {n} 个副本', {'n': exportedCount});
      }
      if (result.skipped.isNotEmpty) {
        msg += tr('，跳过 {n} 个同名', {'n': result.skipped.length});
      }
      if (result.failed.isNotEmpty) {
        msg += tr('，失败 {n} 个', {'n': result.failed.length});
      }
      if (mounted) {
        setState(() => _selected.clear());
        showXianYuToast(context, msg, duration: const Duration(seconds: 2));
      }
    } catch (e) {
      AppLog.warn('move', '批量移动异常: $e');
      if (mounted) showXianYuToast(context, tr('操作失败：{e}', {'e': '$e'}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
