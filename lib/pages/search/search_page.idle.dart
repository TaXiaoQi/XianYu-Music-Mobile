part of 'search_page.dart';

// ==================== 输入关键词联想视图 ====================

class _SuggestionView extends StatelessWidget {
  const _SuggestionView({
    required this.query,
    required this.keywords,
    required this.topPadding,
    required this.onSubmit,
  });

  final String query;
  final List<String> keywords;
  final double topPadding;
  final void Function(String) onSubmit;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bottomInset = MediaQuery.of(context).padding.bottom + 24;

    return ListView(
      padding: EdgeInsets.fromLTRB(16, topPadding, 16, bottomInset),
      children: [
        Row(
          children: [
            Icon(Icons.search, size: 18, color: scheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Text(
              tr('搜索联想'),
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        for (final w in keywords)
          InkWell(
            onTap: () => onSubmit(w),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                children: [
                  const SizedBox(width: 4),
                  Icon(Icons.search,
                      size: 16, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 12),
                  Expanded(
                    child: highlightedText(
                      w,
                      query,
                      scheme.primary,
                      maxLines: 1,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w500),
                    ),
                  ),
                  Icon(Icons.north_west,
                      size: 14, color: scheme.onSurfaceVariant),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

// ==================== 默认页 ====================

// autoDispose：每次进搜索空闲页重新拉取，避免未登录/未配服务器时的失败结果被永久缓存
final _hotSearchProvider =
    FutureProvider.autoDispose<List<HotSearchItem>>((ref) {
  return ref.read(accountApiProvider).fetchHotSearch(limit: 10);
});

class SearchIdleView extends ConsumerWidget {
  const SearchIdleView({
    super.key,
    required this.onSearch,
    this.topPadding = 4,
  });

  final void Function(String keyword) onSearch;

  final double topPadding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final history = ref.watch(searchHistoryProvider);
    final hotAsync = ref.watch(_hotSearchProvider);
    final bottomInset = MediaQuery.of(context).padding.bottom + 24;

    return ListView(
      padding: EdgeInsets.fromLTRB(16, topPadding, 16, bottomInset),
      children: [
        _IdleCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.history, size: 18, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Text(
                    tr('搜索历史'),
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  if (history.isNotEmpty)
                    InkWell(
                      onTap: () =>
                          ref.read(searchHistoryProvider.notifier).clear(),
                      borderRadius: BorderRadius.circular(6),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        child: Text(
                          tr('清空'),
                          style: TextStyle(
                              fontSize: 12, color: scheme.onSurfaceVariant),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              if (history.isEmpty)
                Text(
                  tr('暂无搜索历史'),
                  style: TextStyle(fontSize: 13, color: scheme.outline),
                )
              else
                // 一条一个胶囊：比"每条占一整行"省下大半屏，删除按钮也就在词条旁边
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final kw in history)
                      _HistoryTile(keyword: kw, onTap: onSearch),
                  ],
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        Row(
          children: [
            Icon(Icons.local_fire_department_outlined,
                size: 18, color: scheme.primary),
            const SizedBox(width: 8),
            Text(
              tr('大家都在搜'),
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        hotAsync.when(
          loading: () => const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.4),
              ),
            ),
          ),
          error: (_, _) => _EmptyHotHint(scheme),
          data: (list) => list.isEmpty
              ? _EmptyHotHint(scheme)
              : Column(
                  children: [
                    // 桌面端热搜同款逐条揭示：140ms 起始、每条 50ms、自上方 4px 淡入
                    for (var i = 0; i < list.length; i++)
                      StaggerIn(
                        delay: Duration(milliseconds: 140 + i * 50),
                        duration: const Duration(milliseconds: 200),
                        offsetY: -4,
                        scaleFrom: 1,
                        child: _HotTile(
                          index: i,
                          item: list[i],
                          onTap: onSearch,
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

/// 搜索页空闲态的分组卡片：两段内容（历史/热搜）用同一套圆角容器，
/// 与个人中心统计卡观感一致。
class _IdleCard extends ConsumerWidget {
  const _IdleCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: themeTint(ref, 'search.panel',
            scheme.surfaceContainerHighest.withValues(alpha: 0.45)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: child,
    );
  }
}

class _HistoryTile extends ConsumerWidget {
  const _HistoryTile({required this.keyword, required this.onTap});

  final String keyword;
  final void Function(String keyword) onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    // 胶囊标签：词条与删除按钮挨着，整行高度也从 ~40px 降到 ~32px
    return InkWell(
      onTap: () => onTap(keyword),
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 148),
              child: Text(
                keyword,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: scheme.onSurface),
              ),
            ),
            const SizedBox(width: 2),
            InkWell(
              onTap: () => ref
                  .read(searchHistoryProvider.notifier)
                  .remove(keyword),
              borderRadius: BorderRadius.circular(999),
              child: Padding(
                padding: const EdgeInsets.all(3),
                child: Icon(Icons.close, size: 14, color: scheme.outline),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HotTile extends ConsumerWidget {
  const _HotTile({
    required this.index,
    required this.item,
    required this.onTap,
  });

  final int index;
  final HotSearchItem item;
  final void Function(String keyword) onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final hot = index < 3;
    final color = hot ? scheme.primary : scheme.onSurfaceVariant;
    final size = index == 0
        ? 15.5
        : index == 1
            ? 15.0
            : 14.5;
    final itemTint = themeTintOrNull(ref, 'search.item');
    return Container(
      decoration: itemTint == null
          ? null
          : BoxDecoration(
              color: itemTint,
              borderRadius: BorderRadius.circular(8),
            ),
      child: InkWell(
        onTap: () => onTap(item.keyword),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            children: [
              SizedBox(
                width: 26,
                child: Text(
                  '${index + 1}',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: color,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  item.keyword,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: size,
                    fontWeight: hot ? FontWeight.w600 : FontWeight.w400,
                    color: scheme.onSurface,
                  ),
                ),
              ),
              Text(
                tr('{n}人搜', {'n': item.count}),
                style: TextStyle(fontSize: 11, color: scheme.outline),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyHotHint extends StatelessWidget {
  const _EmptyHotHint(this.scheme);
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(
        tr('暂无热搜'),
        style: TextStyle(fontSize: 13, color: scheme.outline),
      ),
    );
  }
}

