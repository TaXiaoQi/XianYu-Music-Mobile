import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../src/core/app_colors.dart';
import '../../src/home/daily_recommend.dart';
import '../../src/navigation/shell.dart';
import '../../src/player/player_provider.dart';
import '../../src/widgets/flying_cover.dart';
import '../../src/widgets/mini_player_bar.dart';
import '../../src/widgets/online_cover.dart';
import '../../src/widgets/song_list_view.dart';

/// 每日推荐页：日期徽章 + 播放全部/换一批 + 推荐歌曲列表。
class DailyRecommendPage extends ConsumerStatefulWidget {
  const DailyRecommendPage({super.key});

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
    final hasSong = ref.watch(playerProvider.select((s) => s.current != null));

    return Scaffold(
      backgroundColor: appSurfaceBg(context),
      appBar: AppBar(
        title: const Text('每日推荐'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
      ),
      body: Stack(
        children: [
          async.when(
            loading: () => const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(strokeWidth: 2),
                  SizedBox(height: 14),
                  Text('正在为你生成今日推荐…',
                      style: TextStyle(fontSize: 13, color: Colors.grey)),
                ],
              ),
            ),
            error: (e, _) => _CenterAction(
              icon: Icons.error_outline,
              message: '推荐生成失败：$e',
              action: '重试',
              onTap: () => ref.invalidate(dailyRecommendProvider),
            ),
            data: (state) {
              if (!state.loggedIn) {
                return _CenterAction(
                  icon: Icons.person_outline,
                  message: '登录后解锁每日推荐\n基于你的听歌记录，每天为你量身定制',
                  action: '去登录',
                  onTap: () => context.go('/account'),
                );
              }
              if (state.items.isEmpty) {
                return _CenterAction(
                  icon: Icons.music_off_outlined,
                  message: '今天还没有推荐\n请先在「插件管理」中安装音源插件',
                  action: '去安装插件',
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
          if (hasSong)
            const MiniPlayerBar(),
        ],
      ),
    );
  }
}

class _Header extends ConsumerWidget {
  const _Header({required this.state});

  final DailyRecommendState state;

  String get _dateLabel {
    final now = DateTime.now();
    final week = ['一', '二', '三', '四', '五', '六', '日'][now.weekday - 1];
    return '${now.month}月${now.day}日 · 周$week';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final reason = state.algorithm?.topArtistNames.isNotEmpty == true
        ? '根据你常听的 ${state.algorithm!.topArtistNames.join('、')} 生成'
        : '根据你的听歌记录生成';
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
            label: const Text('播放全部', style: TextStyle(fontSize: 13)),
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
            label: const Text('换一批', style: TextStyle(fontSize: 13)),
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
    return ListView.separated(
      padding: EdgeInsets.only(
        top: 6,
        bottom: MediaQuery.of(context).padding.bottom + 24,
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
              onPlay: () {
                launchFlyCover(
                  rowContext,
                  coverContext: coverCtx,
                  coverSize: 46,
                  centerVertically: true,
                  networkUrl: item.coverUrl,
                  radius: 6,
                );
                ref.read(dailyRecommendProvider.notifier).play(i);
              },
            );
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
                trailing: item.durationMs > 0
                    ? Text(
                        '${item.durationMs ~/ 60000}:${((item.durationMs ~/ 1000) % 60).toString().padLeft(2, '0')}',
                        style: TextStyle(
                            fontSize: 12, color: scheme.onSurfaceVariant),
                      )
                    : null,
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
