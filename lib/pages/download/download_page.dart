import 'package:xianyu_music_mobile/src/widgets/predictive_dialog_route.dart';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/core/app_colors.dart';
import '../../src/download/download_provider.dart';
import '../../src/navigation/shell.dart';
import '../../src/player/player_provider.dart';
import '../../src/widgets/app_toast.dart';
import '../../src/widgets/cover_image.dart';
import '../../src/widgets/glass_appbar.dart';
import '../../src/widgets/list_metrics.dart';
import '../../src/widgets/mini_player_bar.dart';
import '../../src/widgets/song_list_view.dart';

/// 下载管理页：进行中的下载任务 + 下载历史。
class DownloadPage extends ConsumerWidget {
  const DownloadPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(downloadProvider);
    final notifier = ref.read(downloadProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    final hasSong = ref.watch(playerProvider).current != null;

    final active = state.tasks
        .where((t) =>
            t.status == DownloadStatus.waiting ||
            t.status == DownloadStatus.downloading)
        .toList();
    final finished = state.tasks
        .where((t) =>
            t.status == DownloadStatus.done ||
            t.status == DownloadStatus.failed)
        .toList();

    return HideShellChrome(
      child: Scaffold(
        backgroundColor: appSurfaceBg(context),
        body: Stack(
          children: [
            Padding(
              padding: EdgeInsets.only(top: GlassTopBar.height(context)),
              child: state.loading
                  ? const Center(child: CircularProgressIndicator())
                  : ListView(
                      padding: EdgeInsets.only(
                        bottom: (hasSong ? 92.0 : 24.0) +
                            MediaQuery.of(context).padding.bottom,
                      ),
                      children: [
                        if (active.isNotEmpty) ...[
                          _sectionHeader(context, '下载中'),
                          for (final t in active)
                            _ActiveTaskTile(task: t),
                          if (finished.isNotEmpty) const Divider(height: 24),
                        ],
                        if (finished.isNotEmpty) ...[
                          _sectionHeader(context, '最近完成'),
                          for (final t in finished)
                            _FinishedTaskTile(
                              task: t,
                              onDismiss: () => notifier.clearFinishedTasks(),
                            ),
                          const Divider(height: 24),
                        ],
                        _sectionHeader(context, '下载记录'),
                        if (state.history.isEmpty)
                          _empty(context, scheme)
                        else
                          for (final e in state.history)
                            _HistoryTile(
                              entry: e,
                              onPlay: () => _play(context, ref, e),
                              onRemove: () => notifier.removeHistory(e.songPath),
                            ),
                      ],
                    ),
            ),
            if (hasSong)
              Positioned(
                left: 14,
                right: 14,
                bottom: MediaQuery.of(context).padding.bottom + 12,
                child: const MiniPlayerBar(),
              ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: GlassTopBar(
                leading: const BackButton(),
                title: const Text('下载管理'),
                actions: [
                  if (state.history.isNotEmpty)
                    IconButton(
                      icon: const Icon(Icons.delete_sweep_outlined),
                      tooltip: '清空记录',
                      onPressed: () => _confirmClear(context, notifier),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _play(BuildContext context, WidgetRef ref, DownloadHistoryEntry e) {
    final file = File(e.filePath);
    if (!file.existsSync()) {
      showXianYuToast(context, '文件不存在：${e.fileName}');
      return;
    }
    ref.read(playerProvider.notifier).playQueue([e.toQueueItem()], startIndex: 0);
  }

  void _confirmClear(BuildContext context, DownloadManager notifier) {
    showPredictiveDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空下载记录'),
        content: const Text('确定要清空全部下载记录吗？（不会删除已下载的文件）'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              notifier.clearHistory();
            },
            child: const Text('清空'),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(BuildContext context, String title) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(
          title,
          style: TextStyle(
            fontSize: 13,
            color: Theme.of(context).colorScheme.primary,
            fontWeight: FontWeight.w600,
          ),
        ),
      );

  Widget _empty(BuildContext context, ColorScheme scheme) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 48),
        child: Column(
          children: [
            Icon(Icons.download_outlined,
                size: 48, color: scheme.onSurface.withValues(alpha: 0.25)),
            const SizedBox(height: 12),
            Text(
              '暂无下载记录\n在搜索结果或播放页点击下载按钮即可下载',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      );
}

/// 进行中的下载任务。
class _ActiveTaskTile extends StatelessWidget {
  const _ActiveTaskTile({required this.task});
  final DownloadTask task;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      dense: true,
      leading: SizedBox(
        width: 36,
        height: 36,
        child: Stack(
          alignment: Alignment.center,
          children: [
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            Icon(Icons.download, size: 16, color: scheme.primary),
          ],
        ),
      ),
      title: Text(task.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        task.status == DownloadStatus.waiting
            ? '排队中 · ${task.quality}'
            : '${task.artist} · ${task.quality}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
      ),
    );
  }
}

/// 已结束的下载任务（成功/失败）。
class _FinishedTaskTile extends StatelessWidget {
  const _FinishedTaskTile({required this.task, required this.onDismiss});
  final DownloadTask task;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ok = task.status == DownloadStatus.done;
    return ListTile(
      dense: true,
      leading: Icon(
        ok ? Icons.check_circle : Icons.error_outline,
        size: 22,
        color: ok ? const Color(0xFF4CAF50) : scheme.error,
      ),
      title: Text(task.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        ok ? '下载完成' : (task.error ?? '下载失败'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
            fontSize: 12,
            color: ok ? scheme.onSurfaceVariant : scheme.error),
      ),
      trailing: IconButton(
        icon: Icon(Icons.close, size: 18, color: scheme.outline),
        tooltip: '移除',
        onPressed: onDismiss,
      ),
    );
  }
}

/// 下载记录条目。
class _HistoryTile extends ConsumerWidget {
  const _HistoryTile({
    required this.entry,
    required this.onPlay,
    required this.onRemove,
  });

  final DownloadHistoryEntry entry;
  final VoidCallback onPlay;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final m = ListMetrics.ofRef(ref);
    final exists = File(entry.filePath).existsSync();
    return CoverRow(
      horizontalPadding: 16,
      verticalPadding: m.vPad,
      onTap: exists ? onPlay : null,
      cover: CoverImage(
        songPath: entry.filePath,
        width: m.songCover,
        height: m.songCover,
        radius: m.songRadius,
        icon: Icons.music_note,
      ),
      title: Text(entry.title ?? entry.fileName,
          maxLines: 1, overflow: TextOverflow.ellipsis,
          style: TextStyle(
              fontSize: m.titleSize, fontWeight: FontWeight.w600)),
      subtitle: Text(
        '${entry.artist ?? ''}${entry.artist?.isNotEmpty == true ? ' · ' : ''}${entry.quality}${exists ? '' : ' · 文件缺失'}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: m.subtitleSize,
          color: exists ? scheme.onSurfaceVariant : scheme.error,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: Icon(Icons.play_arrow, size: 20, color: scheme.primary),
            tooltip: '播放',
            onPressed: exists ? onPlay : null,
          ),
          IconButton(
            icon: Icon(Icons.close, size: 18, color: scheme.outline),
            tooltip: '移除记录',
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}
