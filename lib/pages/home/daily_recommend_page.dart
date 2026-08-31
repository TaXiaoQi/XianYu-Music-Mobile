import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../src/core/app_colors.dart';
import '../../src/core/settings.dart';
import '../../src/home/daily_recommend.dart';
import '../../src/navigation/shell.dart';
import '../../src/player/player_provider.dart';
import '../../src/widgets/flying_cover.dart';
import '../../src/widgets/glass_appbar.dart';
import '../../src/widgets/mini_player_bar.dart';
import '../../src/widgets/online_cover.dart';
import '../../src/widgets/song_actions_sheet.dart';
import '../../src/widgets/song_list_view.dart';
import '../../src/i18n/i18n.dart';

/// 每日推荐页：日期徽章 + 播放全部/换一批 + 推荐歌曲列表。
/// [embedded]=true 时作为横屏右侧「内容」容器内嵌（无自绘顶栏、无自带迷你
/// 条，顶部让位为 0——容器外层 FlatTopBar 已承接返回与标题）。
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
    // 只依赖推荐数据；播放状态由 _BottomPlayBar 单独订阅，避免翻转时整页重建
    final async = ref.watch(dailyRecommendProvider);

    return Scaffold(
      backgroundColor: appScaffoldBackground(context, ref),
      body: Stack(
        children: [
          Padding(
            padding: EdgeInsets.only(
                top: widget.embedded ? 0 : GlassTopBar.height(context)),
            child: async.when(
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
                    onTap: () => context.go('/account'),
                  );
                }
                if (state.items.isEmpty) {
                  return _CenterAction(
                    icon: Icons.music_off_outlined,
                    message: tr('今天还没有推荐\n请先在「插件管理」中安装音源插件'),
                    action: tr('去安装插件'),
                    onTap: () => context.go('/plugin'),
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
          // 播放条显隐收敛为独立组件，播放状态变化不影响上方整页重建；
          // 内嵌形态由外壳迷你条承载，不再自带。
          if (!widget.embedded) const _BottomPlayBar(),
        ],
      ),
    );
  }
}

/// 底部播放条：仅当有歌曲时占位显示。独立订阅播放状态，
/// 避免播放状态翻转时触发整页（Header/列表）重建。
class _BottomPlayBar extends ConsumerWidget {
  const _BottomPlayBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasSong = ref.watch(playerProvider.select((s) => s.current != null));
    if (!hasSong) return const SizedBox.shrink();
    return const MiniPlayerBar();
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

class _RecommendList extends ConsumerWidget {
  const _RecommendList({required this.state});

  final DailyRecommendState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final hasSong = ref.watch(playerProvider.select((s) => s.current != null));
    return ListView.separated(
      padding: EdgeInsets.only(
        top: 6,
        bottom: (hasSong ? 92.0 : 24.0) +
            MediaQuery.of(context).padding.bottom,
      ),
      itemCount: state.items.length,
      separatorBuilder: (_, _) => SizedBox(height: 4),
      itemBuilder: (context, i) {
        final item = state.items[i];
        return Builder(
          builder: (rowContext) {
            // 捕获封面自身 context：飞封面直接取封面 RenderBox 的全局矩形，与列表封面像素级一致。
            BuildContext? coverCtx;
            final g = songRowPlay(
              ref,
              onPlay: () async {
                // 等封面落地后再播放：播放条封面随落地同步更新。
                final ok = await launchFlyCover(
                  rowContext,
                  coverContext: coverCtx,
                  coverSize: 46,
                  centerVertically: true,
                  networkUrl: item.coverUrl,
                  radius: 6,
                );
                if (ok) ref.read(dailyRecommendProvider.notifier).play(i);
              },
            );
            // 长按与「更多」图标共用同一操作菜单。
            void openActions() {
              final quality = ref
                      .read(settingsProvider)
                      .valueOrNull
                      ?.onlineDefaultQuality ??
                  '320k';
              showSongActionsSheet(
                rowContext,
                ref: ref,
                item: item.toQueueItem(quality),
                onPlay: () =>
                    ref.read(dailyRecommendProvider.notifier).play(i),
              );
            }

            return g.wrap(
              ListTile(
                dense: true,
                leading: Builder(
                  builder: (c) {
                    coverCtx = c;
                    return OnlineCover(url: item.coverUrl, size: 46);
                  },
                ),
                onTap: g.onTap,
                onLongPress: openActions,
                title: Text(
                  item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 14.5, fontWeight: FontWeight.w600),
                ),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 1),
                    Text(
                      item.artist.isEmpty
                          ? item.album
                          : '${item.artist} · ${item.album}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12, color: scheme.onSurfaceVariant),
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
                    if (item.durationMs > 0)
                      Text(
                        '${item.durationMs ~/ 60000}:${((item.durationMs ~/ 1000) % 60).toString().padLeft(2, '0')}',
                        style: TextStyle(
                            fontSize: 12, color: scheme.onSurfaceVariant),
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
        );
      },
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
