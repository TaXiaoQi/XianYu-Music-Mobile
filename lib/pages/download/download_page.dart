import 'package:xianyu_music_mobile/src/widgets/predictive_dialog_route.dart';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/download/download_provider.dart';
import '../../src/core/app_colors.dart';
import '../../src/navigation/shell.dart';
import '../../src/player/player_provider.dart';
import '../../src/widgets/app_toast.dart';
import '../../src/widgets/bottom_play_bar_slot.dart';
import '../../src/widgets/cover_image.dart';
import '../../src/widgets/flying_cover.dart';
import '../../src/widgets/glass_appbar.dart';
import '../../src/widgets/list_metrics.dart';
import '../../src/widgets/song_list_view.dart';
import '../../src/i18n/i18n.dart';

/// 下载管理页：进行中的下载任务 + 下载历史。
///
/// [embedded] 用于横屏右侧容器内嵌（壳层 [_DownloadPane]），不开二级路由：
/// 顶栏由全局横屏顶栏承接（搜索框左侧回退按钮负责闭合容器）。
class DownloadPage extends ConsumerWidget {
  const DownloadPage({super.key, this.embedded = false});

  final bool embedded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(downloadProvider);
    final notifier = ref.read(downloadProvider.notifier);
    final scheme = Theme.of(context).colorScheme;

    return HideShellChrome(
      child: Scaffold(
        backgroundColor: appScaffoldBackground(context, ref),
        body: Stack(
          children: [
            Padding(
              padding: EdgeInsets.only(top: GlassTopBar.height(context)),
              child: state.loading
                  ? const Center(child: CircularProgressIndicator())
                  : _DownloadList(
                      state: state,
                      notifier: notifier,
                      scheme: scheme,
                    ),
            ),
            // 内嵌模式由全局顶栏承接（搜索框左侧带回退），本页不渲染自身顶栏。
            if (!embedded)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: GlassTopBar(
                  leading: const BackButton(),
                  title:   Text(tr('下载管理')),
                  actions: [
                    if (state.history.isNotEmpty)
                      IconButton(
                        icon: const Icon(Icons.delete_sweep_outlined),
                        tooltip: tr('清空记录'),
                        onPressed: () => _confirmClear(context, notifier),
                      ),
                  ],
                ),
              ),
            if (!embedded) const BottomPlayBarSlot(),
          ],
        ),
      ),
    );
  }

  void _confirmClear(BuildContext context, DownloadManager notifier) {
    bool deleteFiles = false;
    showPredictiveDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setState) {
          return AlertDialog(
            title: Text(tr('清空下载记录')),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tr('确定要清空全部下载记录吗？')),
                const SizedBox(height: 12),
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () {
                    setState(() {
                      deleteFiles = !deleteFiles;
                    });
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 24,
                          height: 24,
                          child: Checkbox(
                            value: deleteFiles,
                            onChanged: (v) {
                              setState(() {
                                deleteFiles = v ?? false;
                              });
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          tr('同时删除本地文件'),
                          style: TextStyle(
                            fontSize: 14,
                            color: Theme.of(ctx).colorScheme.onSurface,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(tr('取消')),
              ),
              FilledButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  notifier.clearHistory(deleteFiles: deleteFiles);
                  showXianYuToast(
                    context,
                    deleteFiles
                        ? tr('已清空记录并删除本地文件')
                        : tr('已清空下载记录'),
                  );
                },
                child: Text(tr('清空')),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ==================== 下载列表（独立订阅播放状态调底部留白） ====================

/// 下载管理列表：独立订阅播放状态以调整底部留白，避免播放状态翻转波及页头。
class _DownloadList extends ConsumerWidget {
  const _DownloadList({
    required this.state,
    required this.notifier,
    required this.scheme,
  });

  final DownloadState state;
  final DownloadManager notifier;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasSong = ref.watch(playerProvider.select((s) => s.current != null));
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

    return ListView(
      padding: EdgeInsets.only(
        bottom: (hasSong ? 92.0 : 24.0) +
            MediaQuery.of(context).padding.bottom,
      ),
      children: [
        if (active.isNotEmpty) ...[
          _dlSectionHeader(context, tr('下载中')),
          for (final t in active)
            _ActiveTaskTile(task: t),
          if (finished.isNotEmpty) const Divider(height: 24),
        ],
        if (finished.isNotEmpty) ...[
          _dlSectionHeader(context, tr('最近完成')),
          for (final t in finished)
            _FinishedTaskTile(
              task: t,
              onDismiss: () => notifier.clearFinishedTasks(),
            ),
          const Divider(height: 24),
        ],
        _dlSectionHeader(context, tr('下载记录')),
        if (state.history.isEmpty)
          _dlEmpty(context, scheme)
        else
          for (final e in state.history)
            _HistoryTile(
              entry: e,
              onPlay: () => _dlPlay(context, ref, e),
              onRemove: () => notifier.removeHistory(e.songPath),
            ),
      ],
    );
  }
}

void _dlPlay(BuildContext context, WidgetRef ref, DownloadHistoryEntry e) {
  final file = File(e.filePath);
  if (!file.existsSync()) {
    showXianYuToast(context, tr('文件不存在：{name}', {'name': e.fileName}));
    return;
  }
  ref.read(playerProvider.notifier).playQueue([e.toQueueItem()], startIndex: 0);
}

Widget _dlSectionHeader(BuildContext context, String title) => Padding(
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

Widget _dlEmpty(BuildContext context, ColorScheme scheme) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(
        children: [
          Icon(Icons.download_outlined,
              size: 48, color: scheme.onSurface.withValues(alpha: 0.25)),
          const SizedBox(height: 12),
          Text(
            tr('暂无下载记录\n在搜索结果或播放页点击下载按钮即可下载'),
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );

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
            ? tr('排队中 · {quality}', {'quality': task.quality})
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
        ok ? tr('下载完成') : (task.error ?? tr('下载失败')),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
            fontSize: 12,
            color: ok ? scheme.onSurfaceVariant : scheme.error),
      ),
      trailing: IconButton(
        icon: Icon(Icons.close, size: 18, color: scheme.outline),
        tooltip: tr('移除'),
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
    // 捕获封面自身 context：飞封面直接取封面 RenderBox 的全局矩形，与列表封面像素级一致。
    BuildContext? coverCtx;
    final play = exists
        ? () async {
            // 等封面落地后再播放：播放条封面随落地同步更新。
            final ok = await launchFlyCover(
              context,
              coverContext: coverCtx,
              coverSize: m.songCover,
              vPad: m.vPad,
              songPath: entry.filePath,
              radius: m.songRadius,
            );
            if (ok) onPlay();
          }
        : null;
    return CoverRow(
      horizontalPadding: 16,
      verticalPadding: m.vPad,
      onTap: play,
      cover: Builder(
        builder: (c) {
          coverCtx = c;
          return CoverImage(
            songPath: entry.filePath,
            width: m.songCover,
            height: m.songCover,
            radius: m.songRadius,
            icon: Icons.music_note,
          );
        },
      ),
      title: Text(entry.title ?? entry.fileName,
          maxLines: 1, overflow: TextOverflow.ellipsis,
          style: TextStyle(
              fontSize: m.titleSize, fontWeight: FontWeight.w600)),
      subtitle: Text(
        '${entry.artist ?? ''}${entry.artist?.isNotEmpty == true ? ' · ' : ''}${entry.quality}${exists ? '' : ' · ${tr('文件缺失')}'}',
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
            tooltip: tr('播放'),
            onPressed: play,
          ),
          IconButton(
            icon: Icon(Icons.close, size: 18, color: scheme.outline),
            tooltip: tr('移除记录'),
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}
