import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../src/home/daily_recommend.dart';
import '../../src/home/home_providers.dart';
import '../../src/home/top_lists_preview_provider.dart';
import '../../src/plugin/plugin_catalog.dart';
import '../../src/widgets/online_cover.dart';
import 'online_detail_page.dart';
import '../../src/i18n/i18n.dart';

/// 首页发现区：统计 / 每日推荐 / 音源榜单三 tab 切换（对齐桌面 HomeDiscoverTabs）。
class DiscoverSection extends ConsumerStatefulWidget {
  const DiscoverSection({super.key});

  @override
  ConsumerState<DiscoverSection> createState() => _DiscoverSectionState();
}

class _DiscoverSectionState extends ConsumerState<DiscoverSection> {
  int _index = 0;

  void _selectTab(int i) {
    // 切到「统计」tab 时主动刷新统计数据，确保每次打开都能读到最新
    // （不依赖播放落库的失效时机，本地查询很快，几乎无感）。
    if (i == 0) {
      ref.invalidate(listenStatsProvider);
      ref.invalidate(mostPlayedProvider);
    }
    setState(() => _index = i);
  }

  static get _tabs => [
    (key: 'statistics', label: tr('统计'), route: '/leaderboard'),
    (key: 'dailyRecommend', label: tr('每日推荐'), route: '/home/daily'),
    (key: 'topLists', label: tr('音源榜单'), route: '/home/toplists'),
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
                onTap: () => _selectTab(i),
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
                      tr('查看全部'),
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
        // 内容卡片：只对新卡片做纯淡入 + 轻微上移，旧卡片立即移除不参与叠加。
        // 若用默认交叉淡入，两张半透明白玻璃卡片在过渡中叠加、亮度翻倍，
        // 在无壁纸（纯色背景）下切换会闪一下；对齐桌面端瞬时切换以避免重排跳动。
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          switchInCurve: Curves.easeOutCubic,
          transitionBuilder: (child, animation) {
            return FadeTransition(
              opacity: animation,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 0.02),
                  end: Offset.zero,
                ).animate(animation),
                child: child,
              ),
            );
          },
          // 只绘制当前（新）卡片：旧卡片不残留，杜绝交叉淡入的白闪与高度跳动。
          layoutBuilder: (currentChild, previousChildren) =>
              currentChild ?? const SizedBox.shrink(),
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
      _ => const _TopListsBody(),
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
              label: tr('累计听歌'),
              value: data?.totalDurationText ?? '—',
            ),
          ),
          _divider(scheme),
          Expanded(
            child: _statCell(
              scheme,
              icon: Icons.today_outlined,
              label: tr('今日时长'),
              value: data?.todayDurationText ?? '—',
            ),
          ),
          _divider(scheme),
          Expanded(
            child: _statCell(
              scheme,
              icon: Icons.audiotrack_outlined,
              label: tr('今日首数'),
              value: data == null ? '—' : tr('{n} 首', {'n': data.todayPlayCount}),
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
                notLoggedIn ? tr('登录后解锁每日推荐') : tr('安装音源插件后生成推荐'),
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

/// 音源榜单预览：内嵌展示真实榜单数据（对齐桌面端首页内嵌榜单区块）。
class _TopListsBody extends ConsumerWidget {
  const _TopListsBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final state = ref.watch(topListsPreviewProvider);

    if (state.checking || state.loading) {
      return const _CardContainer(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Center(
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
      );
    }
    if (state.noSources) {
      return _CardContainer(
        onTap: () => context.push('/plugin'),
        child: Row(
          children: [
            Icon(Icons.extension_outlined, size: 22, color: scheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                tr('暂无支持榜单的音源插件，去安装'),
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
              ),
            ),
            Icon(Icons.chevron_right, size: 18, color: scheme.onSurfaceVariant),
          ],
        ),
      );
    }
    final boards = state.boards;
    if (boards.isEmpty) {
      return _CardContainer(
        onTap: () => context.push('/home/toplists'),
        child: Row(
          children: [
            Icon(Icons.library_music_outlined, size: 22, color: scheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                tr('「{name}」暂无榜单', {'name': state.sourceName ?? tr('当前音源')}),
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
              ),
            ),
            Icon(Icons.chevron_right, size: 18, color: scheme.onSurfaceVariant),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (state.sourceName != null)
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 6),
            child: Text(
              tr('来源：{name}', {'name': state.sourceName ?? ''}),
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
          ),
        SizedBox(
          height: 144,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: boards.length,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (context, i) => _boardTile(context, scheme, boards[i]),
          ),
        ),
      ],
    );
  }

  Widget _boardTile(BuildContext context, ColorScheme scheme, MfSheetItem b) {
    return GestureDetector(
      onTap: () => context.push(
        '/online-detail',
        extra: OnlineDetailArgs(
          type: OnlineDetailType.toplist,
          pluginId: b.pluginId,
          title: b.title,
          subtitle: b.subtitle,
          coverUrl: b.coverUrl,
          raw: b.raw,
        ),
      ),
      child: SizedBox(
        width: 92,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: OnlineCover(url: b.coverUrl, size: 92, radius: 10),
            ),
            const SizedBox(height: 5),
            Text(
              b.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                height: 1.25,
              ),
            ),
          ],
        ),
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
