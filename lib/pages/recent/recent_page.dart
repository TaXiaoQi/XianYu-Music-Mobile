import 'package:xianyu_music_mobile/src/widgets/predictive_dialog_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/navigation/shell.dart';
import '../../src/core/app_colors.dart';
import '../../src/core/settings.dart';
import '../../src/player/player_provider.dart';
import '../../src/recent/recent_provider.dart';
import '../../src/widgets/bottom_play_bar_slot.dart';
import '../../src/widgets/cover_image.dart';
import '../../src/widgets/flying_cover.dart';
import '../../src/widgets/glass_appbar.dart';
import '../../src/widgets/list_metrics.dart';
import '../../src/widgets/song_list_view.dart';
import '../../src/widgets/song_list_scroll_fabs.dart';
import '../../src/i18n/i18n.dart';

/// 最近播放页：展示播放历史，支持点播/移除/清空。
class RecentPage extends ConsumerWidget {
  const RecentPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recent = ref.watch(recentProvider);
    // 面板模式下隐藏本页顶部 GlassTopBar（由外层横屏胶囊顶栏占位）。
    final inMusicPane = ref.watch(landscapeLibraryProvider) != null;
    final notifier = ref.read(recentProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    // 横屏音乐库面板模式下统一继承壳层全局顶栏：页内只保留一个『清空』内容头，
    // 位于全局顶栏下方（悬浮模式按顶栏高度下移）。
    final floating = ref.watch(
        settingsProvider.select((s) => s.valueOrNull?.floatingSearchBar ?? false));
    final statusBar = MediaQuery.paddingOf(context).top;
    final paneTop = (floating && inMusicPane) ? statusBar + 66 : 0.0;
    // 有记录时渲染「清空」内容头，否则直接以全局顶栏为头。
    final hasHeader = inMusicPane && recent.entries.isNotEmpty;

    return HideShellChrome(
      child: Scaffold(
        backgroundColor: appScaffoldBackground(context, ref),
        body: Stack(
          children: [
            Padding(
              padding: EdgeInsets.only(
                // 面板模式下内容头在全局顶栏下方，内容按内容头避让；非面板模式
                // 沿用完整 GlassTopBar 高度避让。
                top: inMusicPane
                    ? paneTop + (hasHeader ? 48 : 8)
                    : GlassTopBar.height(context),
              ),
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
                                tr('暂无播放记录'),
                                style: TextStyle(
                                    fontSize: 14,
                                    color: scheme.onSurfaceVariant),
                              ),
                            ],
                          ),
                        )
                      : _RecentList(
                          recent: recent,
                          notifier: notifier,
                        ),
            ),
            // 内容头：面板模式仅保留右侧「清空」；非面板模式完整 GlassTopBar。
            if (inMusicPane)
              Positioned(
                top: paneTop,
                left: (inMusicPane && floating) ? 12 : 0,
                right: (inMusicPane && floating) ? 12 : 0,
                child: hasHeader
                    ? Align(
                        alignment: Alignment.centerRight,
                        child: IconButton(
                          icon: const Icon(Icons.delete_sweep_outlined),
                          tooltip: tr('清空'),
                          onPressed: () => _confirmClear(context, notifier),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            if (!inMusicPane)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: GlassTopBar(
                  leading: const BackButton(),
                  title:   Text(tr('最近播放')),
                  actions: [
                    if (recent.entries.isNotEmpty)
                      IconButton(
                        icon: const Icon(Icons.delete_sweep_outlined),
                        tooltip: tr('清空'),
                        onPressed: () => _confirmClear(context, notifier),
                      ),
                  ],
                ),
              ),
            // 统一播放条由外壳承载：横屏面板模式下不渲染页内嵌条。
            if (!inMusicPane) const BottomPlayBarSlot(),
          ],
        ),
      ),
    );
  }

  void _confirmClear(BuildContext context, RecentManager notifier) {
    showPredictiveDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title:   Text(tr('清空最近播放')),
        content:   Text(tr('确定要清空全部播放记录吗？')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child:   Text(tr('取消')),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              notifier.clear();
            },
            child:   Text(tr('清空')),
          ),
        ],
      ),
    );
  }
}

/// 最近播放列表：独立订阅播放状态以调整底部留白，播放状态翻转不波及页头。
/// 右下角叠加「回到顶部 / 定位当前播放歌曲」悬浮按钮。
class _RecentList extends ConsumerStatefulWidget {
  const _RecentList({required this.recent, required this.notifier});

  final RecentState recent;
  final RecentManager notifier;

  @override
  ConsumerState<_RecentList> createState() => _RecentListState();
}

class _RecentListState extends ConsumerState<_RecentList> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasSong = ref.watch(playerProvider.select((s) => s.current != null));
    final m = ListMetrics.ofRef(ref);
    // 行高固定（封面 + 上下内边距），itemExtent 让 Sliver 按偏移量直接定位，
    // 跳过逐行布局测量，大列表快速滑动更省 CPU（对齐统一 SongsListView）。
    final rowExtent = m.songCover + 2 * m.vPad;
    final bottomPad =
        (hasSong ? 92.0 : 24.0) + MediaQuery.of(context).padding.bottom;

    return Stack(
      children: [
        ListView.builder(
          controller: _controller,
          padding: EdgeInsets.only(bottom: bottomPad),
          itemExtent: rowExtent,
          // 提前半屏预缓存，避免新行进场时突然解码封面掉帧（对齐 SongsListView）。
          scrollCacheExtent: ScrollCacheExtent.pixels(500),
          // 行不保留状态（封面/标题均无状态构建），离屏即弃，省内存与重建。
          addAutomaticKeepAlives: false,
          itemCount: widget.recent.entries.length,
          itemBuilder: (context, i) {
            final entry = widget.recent.entries[i];
            return _RecentTile(
              entry: entry,
              onPlay: () => widget.notifier.play(i),
              onRemove: () => widget.notifier.remove(entry.songPath),
            );
          },
        ),
        SongListScrollFabs(
          controller: _controller,
          paths: widget.recent.entries.map((e) => e.songPath).toList(),
          rowTopOf: (i) => i * rowExtent,
          itemExtent: rowExtent,
          bottom: bottomPad + 8,
          right: 12,
        ),
      ],
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

    // 捕获封面自身 context：飞封面直接取封面 RenderBox 的全局矩形，与列表封面像素级一致。
    BuildContext? coverCtx;
    final g = songRowPlay(ref, onPlay: () async {
      // 等封面落地后再播放：播放条封面随落地同步更新。
      final ok = await launchFlyCover(
        context,
        coverContext: coverCtx,
        coverSize: m.songCover,
        vPad: m.vPad,
        songPath: entry.songPath,
        networkUrl: item?.coverUrl,
        radius: m.songRadius,
      );
      if (ok) onPlay();
    });
    return g.wrap(
      CoverRow(
        horizontalPadding: 16,
        verticalPadding: m.vPad,
        onTap: g.onTap,
        onLongPress: () => onRemove(),
        cover: Builder(
          builder: (c) {
            coverCtx = c;
            return CoverImage(
              songPath: entry.songPath,
              networkUrl: item?.coverUrl,
              width: m.songCover,
              height: m.songCover,
              radius: m.songRadius,
              icon: Icons.music_note,
            );
          },
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
          tooltip: tr('移除'),
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
    if (diff == 0) return tr('今天 {hm}', {'hm': hm});
    if (diff == 1) return tr('昨天 {hm}', {'hm': hm});
    if (diff < 7) return tr('{m}月{d}日 {hm}', {'m': dt.month, 'd': dt.day, 'hm': hm});
    return tr('{y}年{m}月{d}日', {'y': dt.year, 'm': dt.month, 'd': dt.day});
  }
}
