import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'dart:async';

import '../leaderboard/leaderboard_prefetch.dart';

import '../../src/home/daily_recommend.dart';
import '../../src/home/home_providers.dart';
import '../../src/home/top_lists_preview_provider.dart';
import '../../src/home/recommend_sheets_preview_provider.dart';
import '../../src/plugin/plugin_catalog.dart';
import '../../src/navigation/shell.dart';
import '../../src/responsive/landscape.dart';
import '../../src/theme/theme_icon.dart';
import '../../src/widgets/glass_settings.dart';
import '../../src/widgets/online_cover.dart';
import '../../src/widgets/press_scale.dart';
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
      themeSlot: 'mine.stats',
      onTap: () {
        // 先把榜单数据拉起来：页面打开即命中缓存，转场那几百毫秒里
        // 就不会只剩一屏空骨架（"点进去先闪一下"的成因）
        unawaited(prefetchLeaderboard(ref));
        openDiscoverEntry(context, ref, '/leaderboard');
      },
      child: Row(
        children: [
          Expanded(
            child: _statCell(
              scheme,
              ref,
              icon: Icons.headphones_outlined,
              themeSlot: 'mine.stat_listen',
              label: tr('累计时长'),
              value: data?.totalDurationText ?? '—',
            ),
          ),
          _divider(scheme),
          Expanded(
            child: _statCell(
              scheme,
              ref,
              icon: Icons.today_outlined,
              themeSlot: 'mine.stat_today',
              label: tr('今日时长'),
              value: data?.todayDurationText ?? '—',
            ),
          ),
          _divider(scheme),
          Expanded(
            child: _statCell(
              scheme,
              ref,
              icon: Icons.audiotrack_outlined,
              themeSlot: 'mine.stat_count',
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
    ColorScheme scheme,
    WidgetRef ref, {
    required IconData icon,
    required String label,
    required String value,
    String? themeSlot,
  }) {
    return Column(
      children: [
        themeSlotIcon(ref, themeSlot,
            fallback: icon, size: 19, color: scheme.primary),
        const SizedBox(height: 6),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 3),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
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
            : () => context.push(notLoggedIn ? '/account' : '/plugin-manage'),
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
                        : tr('添加本地音乐或安装音源插件后再试'),
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
    final landscape = useLandscape(ref);
    // 横屏 3 列 × 4 行 = 12 首塞满卡片（列数仍按卡宽自适应）；竖屏单列 5 首
    final items = state?.items.take(landscape ? 12 : 5).toList() ?? const [];
    return _CardContainer(
      // 该区块在竖屏首页与横屏发现页共用（_discoverBlocks 两处渲染），
      // 而槽位是横屏专属，必须按方向判定，不能写死 ls- 槽。
      themeSlot: landscape ? 'ls-home.daily' : null,
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
          : LayoutBuilder(
              builder: (context, cons) =>
                  _dailyRows(scheme, items, landscape, cons.maxWidth),
            ),
    );
  }

  Widget _dailyRows(ColorScheme scheme, List<DailyRecommendItem> items,
      bool landscape, double maxWidth) {
    // 列宽自适应（约 200 逻辑像素一列，1~3 列封顶），按列填充各列高度均衡
    final columns =
        landscape ? (maxWidth / 200).floor().clamp(1, 3).toInt() : 1;
    if (columns <= 1) {
      return Column(
        children: [
          for (var i = 0; i < items.length; i++) ...[
            _dailyRow(scheme, items[i]),
            if (i != items.length - 1) const SizedBox(height: 8),
          ],
        ],
      );
    }
    final per = (items.length / columns).ceil();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var c = 0; c < columns; c++) ...[
          if (c > 0) const SizedBox(width: 18),
          Expanded(
            child: Column(
              children: [
                for (var i = c * per;
                    i < (c + 1) * per && i < items.length;
                    i++)
                  Padding(
                    padding: EdgeInsets.only(
                      bottom: i == items.length - 1 ? 0 : 8,
                    ),
                    child: _dailyRow(scheme, items[i]),
                  ),
              ],
            ),
          ),
        ],
      ],
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
        onTap: () => context.push('/plugin-manage'),
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
    final tile = GestureDetector(
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
    return PressableScale(child: tile);
  }
}

class RecommendSheetsSection extends ConsumerWidget {
  const RecommendSheetsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const _RecommendSheetsBody();
  }
}

class _RecommendSheetsBody extends ConsumerWidget {
  const _RecommendSheetsBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final state = ref.watch(recommendSheetsPreviewProvider);
    // 无数据时整块隐藏（home_page 同步按 hasData 隐藏标题，避免孤标题）
    final sheets = state.sheets;
    if (!state.hasData || sheets.isEmpty) return const SizedBox.shrink();
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
            itemCount: sheets.length,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (context, i) => _sheetTile(context, sheets[i]),
          ),
        ),
      ],
    );
  }

  Widget _sheetTile(BuildContext context, MfSheetItem s) {
    final tile = GestureDetector(
      onTap: () => context.push(
        '/online-detail',
        extra: OnlineDetailArgs(
          type: OnlineDetailType.playlist,
          pluginId: s.pluginId,
          title: s.title,
          subtitle: s.subtitle,
          coverUrl: s.coverUrl,
          raw: s.raw,
        ),
      ),
      child: SizedBox(
        width: 92,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: OnlineCover(url: s.coverUrl, size: 92, radius: 10),
            ),
            const SizedBox(height: 5),
            Text(
              s.title,
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
    return PressableScale(child: tile);
  }
}

class _CardContainer extends ConsumerWidget {
  const _CardContainer({required this.child, this.onTap, this.themeSlot});

  final Widget child;
  final VoidCallback? onTap;

  /// 主题色块槽位 id；为空则不加叠色（多数调用点不需要）。
  final String? themeSlot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final card = frostedCardSurface(
      context: context,
      ref: ref,
      themeSlot: themeSlot,
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
    // loading 骨架不可点，不挂按压反馈
    return onTap == null ? card : PressableScale(child: card);
  }
}
