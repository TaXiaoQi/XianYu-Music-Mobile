part of 'favorites_page.dart';

// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

extension _FavoritesPageToolbar on _FavoritesPageState {
  void _onBatchChanged() {
    if (!_batch.batchMode) {
      ref.read(batchBarLiftProvider.notifier).state = 0;
    }
  }

  Widget _batchToggle(BuildContext context, {bool floating = false}) {
    return ListenableBuilder(
      listenable: _batch,
      builder: (context, _) {
        final active = _batch.batchMode;
        final icon = active
            ? Icons.check_rounded
            : Icons.library_add_check_outlined;
        final tip = active ? tr('完成') : tr('批量');
        void onTap() => active ? _batch.exit() : _batch.enter();
        if (floating) {
          return BiliPaiIconButton(
            icon: icon,
            tooltip: tip,
            color: active ? Theme.of(context).colorScheme.primary : null,
            onTap: onTap,
          );
        }
        return IconButton(
          icon: Icon(icon, size: 22),
          tooltip: tip,
          onPressed: onTap,
        );
      },
    );
  }

  Widget _tabHost(bool floating, double dockedTop, Widget child) {
    if (floating) return SizedBox.expand(child: child);
    return Padding(
      padding: EdgeInsets.only(top: dockedTop),
      child: child,
    );
  }

  Widget _tabBarStrip(BuildContext context, Widget tabBar) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: scheme.onSurface.withValues(alpha: 0.06)),
        ),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(
          tabBarTheme: TabBarThemeData(
            dividerColor: Colors.transparent,
          ),
        ),
        child: SizedBox(height: 48, child: tabBar),
      ),
    );
  }

  Future<void> _confirmClear(
      BuildContext context, FavoritesManager notifier) async {
    final paths =
        ref.read(favoritesProvider).entries.map((e) => e.path).toList();
    if (await shouldAskFavoriteDeleteScope(ref, paths)) {
      if (!context.mounted) return;
      final scope = await resolveFavoriteDeleteScope(context, ref, paths);
      if (!context.mounted) return;
      if (scope == null) return;
      await applyFavoriteDeleteScope(context, ref, scope, paths,
          onLocalRemove: () => notifier.clear());
      return;
    }
    if (!context.mounted) return;
    showPredictiveDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title:   Text(tr('清空收藏')),
        content:   Text(tr('确定要清空全部收藏歌曲吗？收藏的歌单与专辑不受影响。')),
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
