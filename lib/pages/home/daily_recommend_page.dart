import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../src/core/app_colors.dart';
import '../../src/core/settings.dart';
import '../../src/favorites/favorites_provider.dart';
import '../../src/home/daily_recommend.dart';
import '../../src/navigation/shell.dart';
import '../../src/player/player_provider.dart';
import '../../src/widgets/app_toast.dart';
import '../../src/widgets/drag_handle.dart';
import '../../src/widgets/flying_cover.dart';
import '../../src/widgets/glass_appbar.dart';
import '../../src/widgets/list_metrics.dart';
import '../../src/widgets/online_cover.dart';
import '../../src/widgets/song_actions_sheet.dart';
import '../../src/widgets/song_list_scroll_fabs.dart';
import '../../src/widgets/source_tag.dart';
import '../../src/widgets/song_list_view.dart';
import '../../src/widgets/stagger_in.dart';
import '../../src/i18n/i18n.dart';

class DailyRecommendPage extends ConsumerStatefulWidget {
  const DailyRecommendPage({super.key, this.embedded = false});

  final bool embedded;

  @override
  ConsumerState<DailyRecommendPage> createState() =>
      _DailyRecommendPageState();
}

class _DailyRecommendPageState extends ConsumerState<DailyRecommendPage>
    with HidesShellChrome {
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final async = ref.watch(dailyRecommendProvider);
    final portraitFloating = !widget.embedded &&
        MediaQuery.of(context).orientation != Orientation.landscape &&
        (ref.watch(settingsProvider
                .select((s) => s.valueOrNull?.floatingSearchBar ?? false)) ==
            true);

    return Scaffold(
      backgroundColor: appScaffoldBackground(context, ref),
      body: Stack(
        children: [
          _floatHost(
            portraitFloating,
            async.when(
              loading: () =>   Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(strokeWidth: 2),
                    SizedBox(height: 14),
                    Text(tr('正在为你生成今日推荐…'),
                        style: TextStyle(fontSize: 13, color: Colors.grey)),
                  ],
                ),
              ),
              error: (e, _) => _CenterAction(
                icon: Icons.error_outline,
                message: tr('推荐生成失败：{e}', {'e': e}),
                action: tr('重试'),
                onTap: () => ref.invalidate(dailyRecommendProvider),
              ),
              data: (state) {
                if (!state.loggedIn) {
                  return _CenterAction(
                    icon: Icons.person_outline,
                    message: tr('登录后解锁每日推荐\n基于你的听歌记录，每天为你量身定制'),
                    action: tr('去登录'),
                    onTap: () => context.push('/account'),
                  );
                }
                if (state.items.isEmpty) {
                  return _CenterAction(
                    icon: Icons.music_off_outlined,
                    message: tr('今天还没有推荐\n请先在「插件管理」中安装音源插件'),
                    action: tr('去安装插件'),
                    onTap: () => context.push('/plugin'),
                  );
                }
                return Column(
                  children: [
                    _Header(state: state),
                    Divider(
                        height: 1,
                        color: scheme.onSurface.withValues(alpha: 0.06)),
                    Expanded(child: _RecommendList(state: state)),
                  ],
                );
              },
            ),
          ),
          if (!widget.embedded)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: GlassTopBar(
                leading: const BackButton(),
                title:   Text(tr('每日推荐')),
              ),
            ),
          ],
        ),
    );
  }
  Widget _floatHost(bool floating, Widget child) {
    if (floating) {
      return SizedBox.expand(
        child: RepaintBoundary(
          child: Padding(
            padding: EdgeInsets.only(top: GlassTopBar.height(context) + 6),
            child: child,
          ),
        ),
      );
    }
    return Padding(
      padding: EdgeInsets.only(
          top: widget.embedded ? 0 : GlassTopBar.height(context)),
      child: child,
    );
  }
}

class _Header extends ConsumerWidget {
  const _Header({required this.state});

  final DailyRecommendState state;

  String get _dateLabel {
    final now = DateTime.now();
    final week = [tr('一'), tr('二'), tr('三'), tr('四'), tr('五'), tr('六'), tr('日')][now.weekday - 1];
    return tr('{m}月{d}日 · 周{w}', {'m': now.month, 'd': now.day, 'w': week});
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final reason = state.algorithm?.topArtistNames.isNotEmpty == true
        ? tr('根据你常听的 {artists} 生成', {'artists': state.algorithm!.topArtistNames.join('、')})
        : tr('根据你的听歌记录生成');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 3),
                      decoration: BoxDecoration(
                        color: scheme.primary.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        _dateLabel,
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.primary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  reason,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          FilledButton.icon(
            onPressed: () => ref.read(dailyRecommendProvider.notifier).play(0),
            icon: const Icon(Icons.play_arrow, size: 18),
            label:   Text(tr('播放全部'), style: TextStyle(fontSize: 13)),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              minimumSize: const Size(0, 36),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: () =>
                ref.read(dailyRecommendProvider.notifier).refresh(),
            icon: const Icon(Icons.refresh, size: 16),
            label:   Text(tr('换一批'), style: TextStyle(fontSize: 13)),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              minimumSize: const Size(0, 36),
            ),
          ),
        ],
      ),
    );
  }
}

class _RecommendList extends ConsumerStatefulWidget {
  const _RecommendList({required this.state});

  final DailyRecommendState state;

  @override
  ConsumerState<_RecommendList> createState() => _RecommendListState();
}

class _RecommendListState extends ConsumerState<_RecommendList> {
  final ScrollController _scroll = ScrollController();
  late final StaggerWindow _stagger = StaggerWindow(onClosed: () {
    if (mounted) setState(() {});
  });

  @override
  void initState() {
    super.initState();
    _stagger.start();
  }

  @override
  void didUpdateWidget(covariant _RecommendList oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 换一批/重新生成后整批内容变化，重播入场动画；
    // 封面回填等同一批 items 的更新（同一 List 实例）不重播
    if (!identical(oldWidget.state.items, widget.state.items)) {
      _stagger.start();
    }
  }

  @override
  void dispose() {
    _stagger.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Widget _buildSourceTag(DailyRecommendItem item) {
    final q = item.toQueueItem('320k');
    return SourceTag(
      path: q.path,
      isOnline: true,
      source: q.source,
      onlineSongJson: q.onlineSongJson,
      pluginId: item.pluginId,
    );
  }

  void _toggleFavorite(DailyRecommendItem item, QueueItem q, bool wasFav) {
    ref.read(favoritesProvider.notifier).toggle(q);
    showXianYuToast(
        context,
        wasFav
            ? tr('已取消收藏：{t}', {'t': item.title})
            : tr('已收藏：{t}', {'t': item.title}));
  }

  /// 行首槽位：序号/播放标识（与其他在线歌曲列表同款），不可拖拽
  Widget _rowShell(int i, String songPath, Widget row) => Stack(
        children: [
          Padding(padding: const EdgeInsets.only(left: 44), child: row),
          Positioned(
            left: 8,
            top: 0,
            bottom: 0,
            width: 36,
            child: Center(
              child: SongRowLeading(index: i, songPath: songPath),
            ),
          ),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final state = widget.state;
    final favorites = ref.watch(favoritesProvider);
    final hasSong = ref.watch(playerProvider.select((s) => s.current != null));
    final m = ListMetrics.ofRef(ref);
    final quality =
        ref.read(settingsProvider).valueOrNull?.onlineDefaultQuality ?? '320k';
    final bottomPad =
        (hasSong ? 92.0 : 24.0) + MediaQuery.of(context).padding.bottom;
    // 行顶坐标前缀和（带 reason 的行加高一行），供悬浮定位按钮估算
    final rowTops = <double>[6];
    for (final it in state.items) {
      rowTops.add(rowTops.last +
          m.songCover +
          2 * m.vPad +
          (it.reason.isNotEmpty ? 18.0 : 0.0) +
          4);
    }
    return Stack(
      children: [
        ListView.separated(
          controller: _scroll,
          padding: EdgeInsets.only(top: 6, bottom: bottomPad),
          itemCount: state.items.length,
          separatorBuilder: (_, _) => SizedBox(height: 4),
          itemBuilder: (context, i) {
            final item = state.items[i];
            final q = item.toQueueItem(quality);
            final isFav = favorites.contains(q.path);
            return _stagger.wrap(
              i,
              _rowShell(
                i,
                q.path,
                Builder(
                  builder: (rowContext) {
                    BuildContext? coverCtx;
                    final g = songRowPlay(
                      ref,
                      onPlay: () async {
                        final ok = await launchFlyCover(
                          rowContext,
                          coverContext: coverCtx,
                          coverSize: m.songCover,
                          vPad: m.vPad,
                          networkUrl: item.coverUrl,
                          radius: m.songRadius,
                        );
                        if (ok) {
                          ref.read(dailyRecommendProvider.notifier).play(i);
                        }
                      },
                    );
                    void openActions() {
                      showSongActionsSheet(
                        rowContext,
                        ref: ref,
                        item: q,
                        onPlay: () =>
                            ref.read(dailyRecommendProvider.notifier).play(i),
                      );
                    }

                    return g.wrap(
                      CoverRow(
                        cover: Builder(
                          builder: (c) {
                            coverCtx = c;
                            return OnlineCover(
                              url: item.coverUrl,
                              size: m.songCover,
                              radius: m.songRadius,
                            );
                          },
                        ),
                        onTap: g.onTap,
                        onLongPress: openActions,
                        verticalPadding: m.vPad,
                        title: Text(
                          item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: m.titleSize,
                              fontWeight: FontWeight.w600),
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    item.artist.isEmpty
                                        ? item.album
                                        : '${item.artist} · ${item.album}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        fontSize: m.subtitleSize,
                                        color: scheme.onSurfaceVariant),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                _buildSourceTag(item),
                              ],
                            ),
                            if (item.reason.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 3),
                                child: Text(
                                  item.reason,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 10.5, color: scheme.primary),
                                ),
                              ),
                          ],
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: Icon(
                                isFav ? Icons.favorite : Icons.favorite_border,
                                size: 20,
                                color: isFav
                                    ? scheme.primary
                                    : scheme.onSurfaceVariant,
                              ),
                              tooltip: tr('收藏'),
                              onPressed: () => _toggleFavorite(item, q, isFav),
                            ),
                            if (item.durationMs > 0)
                              Text(
                                '${item.durationMs ~/ 60000}:${((item.durationMs ~/ 1000) % 60).toString().padLeft(2, '0')}',
                                style: TextStyle(
                                    fontSize: m.subtitleSize,
                                    color: scheme.onSurfaceVariant),
                              ),
                            IconButton(
                              icon: const Icon(Icons.more_horiz, size: 22),
                              color: scheme.onSurfaceVariant,
                              tooltip: tr('更多'),
                              onPressed: openActions,
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            );
          },
        ),
        SongListScrollFabs(
          controller: _scroll,
          paths: [
            for (final it in state.items) it.toQueueItem(quality).path,
          ],
          rowTopOf: (i) => i < rowTops.length ? rowTops[i] : rowTops.last,
          itemExtent: m.songCover + 2 * m.vPad,
          bottom: bottomPad + 8,
          right: 12,
        ),
      ],
    );
  }
}

class _CenterAction extends StatelessWidget {
  const _CenterAction({
    required this.icon,
    required this.message,
    required this.action,
    required this.onTap,
  });

  final IconData icon;
  final String message;
  final String action;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 56, color: scheme.onSurfaceVariant.withValues(alpha: 0.4)),
          const SizedBox(height: 14),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              height: 1.6,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 14),
          FilledButton(
            onPressed: onTap,
            child: Text(action, style: const TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
  }
}
