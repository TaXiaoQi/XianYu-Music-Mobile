import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../src/home/daily_recommend.dart';
import '../../src/home/home_providers.dart';
import '../../src/home/top_lists_preview_provider.dart';
import '../../src/plugin/plugin_catalog.dart';
import '../../src/navigation/shell.dart';
import '../../src/widgets/glass_settings.dart';
import '../../src/widgets/online_cover.dart';
import 'online_detail_page.dart';
import '../../src/i18n/i18n.dart';

void openDiscoverEntry(BuildContext context, WidgetRef ref, String route) {
  if (ref.read(isLandscapeProvider)) {
    ref.read(landscapeContentPathProvider.notifier).state = route;
  } else {
    context.push(route);
  }
}

class DiscoverSection extends ConsumerWidget {
  const DiscoverSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const _TopListsBody();
  }
}

class DailyRecommendSection extends ConsumerWidget {
  const DailyRecommendSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const _DailyCard();
  }
}

class StatsSummaryCard extends ConsumerWidget {
  const StatsSummaryCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final stats = ref.watch(listenStatsProvider);
    final data = stats.valueOrNull;
    return _CardContainer(
      onTap: () => openDiscoverEntry(context, ref, '/leaderboard'),
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
      final hasError = async.hasError && state == null;
      return _CardContainer(
        onTap: hasError
            ? () => ref.invalidate(dailyRecommendProvider)
            : () => context.push(notLoggedIn ? '/account' : '/plugin'),
        child: Row(
          children: [
            Icon(Icons.auto_awesome_outlined,
                size: 22, color: scheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                hasError
                    ? tr('每日推荐获取失败，点击重试')
                    : notLoggedIn
                        ? tr('登录后解锁每日推荐')
                        : tr('安装音源插件后生成推荐'),
                style: TextStyle(
                    fontSize: 13, color: scheme.onSurfaceVariant),
              ),
            ),
            Icon(
              hasError ? Icons.refresh : Icons.chevron_right,
              size: hasError ? 20 : 18,
              color: scheme.onSurfaceVariant,
            ),
          ],
        ),
      );
    }
    final items = state?.items.take(3).toList() ?? const [];
    return _CardContainer(
      onTap: () => openDiscoverEntry(context, ref, '/home/daily'),
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
        onTap: () => openDiscoverEntry(context, ref, '/home/toplists'),
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

class _CardContainer extends ConsumerWidget {
  const _CardContainer({required this.child, this.onTap});

  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return frostedCardSurface(
      context: context,
      ref: ref,
      radius: 13,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(13),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(13),
          child: Container(
            padding: const EdgeInsets.all(14),
            child: child,
          ),
        ),
      ),
    );
  }
}
