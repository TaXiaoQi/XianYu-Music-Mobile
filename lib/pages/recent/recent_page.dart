import 'package:xianyu_music_mobile/src/widgets/predictive_dialog_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/core/app_colors.dart';
import '../../src/navigation/shell.dart';
import '../../src/player/player_provider.dart';
import '../../src/recent/recent_provider.dart';
import '../../src/widgets/cover_image.dart';
import '../../src/widgets/glass_appbar.dart';
import '../../src/widgets/list_metrics.dart';
import '../../src/widgets/mini_player_bar.dart';
import '../../src/widgets/song_list_view.dart';

/// 最近播放页：展示播放历史，支持点播/移除/清空。
class RecentPage extends ConsumerWidget {
  const RecentPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recent = ref.watch(recentProvider);
    final notifier = ref.read(recentProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    final hasSong = ref.watch(playerProvider).current != null;

    return HideShellChrome(
      child: Scaffold(
        backgroundColor: appSurfaceBg(context),
        body: Stack(
          children: [
            Padding(
              padding: EdgeInsets.only(top: GlassTopBar.height(context)),
              child: recent.loading
                  ? const Center(child: CircularProgressIndicator())
                  : recent.entries.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.history,
                                  size: 48,
                                  color: scheme.onSurface
                                      .withValues(alpha: 0.25)),
                              const SizedBox(height: 12),
                              Text(
                                '暂无播放记录',
                                style: TextStyle(
                                    fontSize: 14,
                                    color: scheme.onSurfaceVariant),
                              ),
                            ],
                          ),
                        )
                      : ListView.separated(
                          padding: EdgeInsets.only(
                            bottom: (hasSong ? 92.0 : 24.0) +
                                MediaQuery.of(context).padding.bottom,
                          ),
                          itemCount: recent.entries.length,
                          separatorBuilder: (_, _) =>
                              const Divider(height: 1),
                          itemBuilder: (context, i) {
                            final entry = recent.entries[i];
                            return _RecentTile(
                              entry: entry,
                              onPlay: () => notifier.play(i),
                              onRemove: () =>
                                  notifier.remove(entry.songPath),
                            );
                          },
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
                title: const Text('最近播放'),
                actions: [
                  if (recent.entries.isNotEmpty)
                    IconButton(
                      icon: const Icon(Icons.delete_sweep_outlined),
                      tooltip: '清空',
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

  void _confirmClear(BuildContext context, RecentManager notifier) {
    showPredictiveDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空最近播放'),
        content: const Text('确定要清空全部播放记录吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              notifier.clear();
            },
            child: const Text('清空'),
          ),
        ],
      ),
    );
  }
}

class _RecentTile extends ConsumerWidget {
  const _RecentTile({
    required this.entry,
    required this.onPlay,
    required this.onRemove,
  });

  final RecentEntry entry;
  final VoidCallback onPlay;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final m = ListMetrics.ofRef(ref);
    final item = entry.toQueueItem();
    final title = item?.title ?? _titleFromPath(entry.songPath);
    final artist = item?.artist ?? '';

    final g = songRowPlay(ref, onPlay: onPlay);
    return g.wrap(
      CoverRow(
        horizontalPadding: 16,
        verticalPadding: m.vPad,
        onTap: g.onTap,
        onLongPress: () => onRemove(),
        cover: CoverImage(
          songPath: entry.songPath,
          networkUrl: item?.coverUrl,
          width: m.songCover,
          height: m.songCover,
          radius: m.songRadius,
          icon: Icons.music_note,
        ),
        title: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: m.titleSize,
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: Text(
          artist.isEmpty
              ? _timeText(entry.playedAt)
              : '$artist · ${_timeText(entry.playedAt)}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: m.subtitleSize,
            color: scheme.onSurfaceVariant,
          ),
        ),
        trailing: IconButton(
          icon: Icon(Icons.close, size: 18, color: scheme.outline),
          tooltip: '移除',
          onPressed: onRemove,
        ),
      ),
    );
  }

  String _titleFromPath(String p) {
    final name = p.split(RegExp(r'[\\/]')).last;
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  String _timeText(int ms) {
    if (ms <= 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(dt.year, dt.month, dt.day);
    final diff = today.difference(day).inDays;
    final hm = '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    if (diff == 0) return '今天 $hm';
    if (diff == 1) return '昨天 $hm';
    if (diff < 7) return '${dt.month}月${dt.day}日 $hm';
    return '${dt.year}年${dt.month}月${dt.day}日';
  }
}
