import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../src/home/daily_recommend.dart';
import '../../src/home/home_providers.dart';
import '../../src/widgets/online_cover.dart';

/// 首页发现区：统计 / 每日推荐 / 音源榜单三 tab 切换（对齐桌面 HomeDiscoverTabs）。
class DiscoverSection extends ConsumerStatefulWidget {
  const DiscoverSection({super.key});

  @override
  ConsumerState<DiscoverSection> createState() => _DiscoverSectionState();
}

class _DiscoverSectionState extends ConsumerState<DiscoverSection> {
  int _index = 0;

  static const _tabs = [
    (key: 'statistics', label: '统计', route: '/leaderboard'),
    (key: 'dailyRecommend', label: '每日推荐', route: '/home/daily'),
    (key: 'topLists', label: '音源榜单', route: '/home/toplists'),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Tab 行（桌面同款：文字 + 红色下划线指示）。
        Row(
          children: [
            for (var i = 0; i < _tabs.length; i++)
              InkWell(
                onTap: () => setState(() => _index = i),
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _tabs[i].label,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          color: _index == i
                              ? scheme.primary
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 5),
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 240),
                        curve: Curves.easeOut,
                        width: 24,
                        height: 2,
                        decoration: BoxDecoration(
                          color: scheme.primary,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        transform: Matrix4.diagonal3Values(
                            _index == i ? 1.0 : 0.001, 1.0, 1.0),
                      ),
                    ],
                  ),
                ),
              ),
            const Spacer(),
            InkWell(
              onTap: () => context.push(_tabs[_index].route),
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                child: Row(
                  children: [
                    Text(
                      '查看全部',
                      style: TextStyle(
                        fontSize: 13,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    Icon(Icons.chevron_right,
                        size: 16, color: scheme.onSurfaceVariant),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        // 内容卡片：带入场动画的切换。
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          child: KeyedSubtree(
            key: ValueKey(_tabs[_index].key),
            child: _buildContent(scheme),
          ),
        ),
      ],
    );
  }

  Widget _buildContent(ColorScheme scheme) {
    return switch (_tabs[_index].key) {
      'statistics' => _StatsCard(),
      'dailyRecommend' => const _DailyCard(),
      _ => _TopListsCard(),
    };
  }
}

/// 统计预览：听歌时长 + 今日数据。
class _StatsCard extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final stats = ref.watch(listenStatsProvider);
    final data = stats.valueOrNull;
    return _CardContainer(
      child: Row(
        children: [
          Expanded(
            child: _statCell(
              scheme,
              icon: Icons.headphones_outlined,
              label: '累计听歌',
              value: data?.totalDurationText ?? '—',
            ),
          ),
          _divider(scheme),
          Expanded(
            child: _statCell(
              scheme,
              icon: Icons.today_outlined,
              label: '今日时长',
              value: data?.todayDurationText ?? '—',
            ),
          ),
          _divider(scheme),
          Expanded(
            child: _statCell(
              scheme,
              icon: Icons.audiotrack_outlined,
              label: '今日首数',
              value: data == null ? '—' : '${data.todayPlayCount} 首',
            ),
          ),
        ],
      ),
    );
  }

  Widget _divider(ColorScheme scheme) => Container(
        width: 1,
        height: 34,
        color: scheme.onSurface.withValues(alpha: 0.06),
      );

  Widget _statCell(
    ColorScheme scheme, {
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Column(
      children: [
        Icon(icon, size: 19, color: scheme.primary),
        const SizedBox(height: 6),
        Text(
          value,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 3),
        Text(
          label,
          style: TextStyle(
              fontSize: 11, color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// 日推预览：前 3 条推荐。
class _DailyCard extends ConsumerWidget {
  const _DailyCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final async = ref.watch(dailyRecommendProvider);
    final state = async.valueOrNull;
    if (!async.isLoading &&
        (state == null || !state.loggedIn || state.items.isEmpty)) {
      final notLoggedIn = state != null && !state.loggedIn;
      return _CardContainer(
        onTap: () => context.push(notLoggedIn ? '/account' : '/plugin'),
        child: Row(
          children: [
            Icon(Icons.auto_awesome_outlined,
                size: 22, color: scheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                notLoggedIn ? '登录后解锁每日推荐' : '安装音源插件后生成推荐',
                style: TextStyle(
                    fontSize: 13, color: scheme.onSurfaceVariant),
              ),
            ),
            Icon(Icons.chevron_right,
                size: 18, color: scheme.onSurfaceVariant),
          ],
        ),
      );
    }
    final items = state?.items.take(3).toList() ?? const [];
    return _CardContainer(
      onTap: () => context.push('/home/daily'),
      child: async.isLoading && items.isEmpty
          ? const Padding(
              padding: EdgeInsets.symmetric(vertical: 14),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          : Column(
              children: [
                for (var i = 0; i < items.length; i++) ...[
                  _dailyRow(scheme, items[i]),
                  if (i != items.length - 1) const SizedBox(height: 8),
                ],
              ],
            ),
    );
  }

  Widget _dailyRow(ColorScheme scheme, DailyRecommendItem item) {
    return Row(
      children: [
        OnlineCover(url: item.coverUrl, size: 38, radius: 8),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 1),
              Text(
                item.reason.isNotEmpty ? item.reason : item.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 11, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 音源榜单预览：入口卡片。
class _TopListsCard extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return _CardContainer(
      onTap: () => context.push('/home/toplists'),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child:
                Icon(Icons.leaderboard_outlined, size: 22, color: scheme.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '音源榜单',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  '各音源热门排行 · 飙升 / 新歌 / 热歌',
                  style: TextStyle(
                      fontSize: 12, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right, size: 18, color: scheme.onSurfaceVariant),
        ],
      ),
    );
  }
}

/// 发现区卡片容器（半透明玻璃卡片，与首页其余卡片一致）。
class _CardContainer extends StatelessWidget {
  const _CardContainer({required this.child, this.onTap});

  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(13),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(13),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(13),
            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          ),
          child: child,
        ),
      ),
    );
  }
}
