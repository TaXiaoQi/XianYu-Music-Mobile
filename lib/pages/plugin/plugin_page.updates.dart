part of 'plugin_page.dart';
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

extension _PluginPageUpdates on _PluginPageState {
  Future<PluginUpdateService> _updateService() async {
    final engine = await ref.read(pluginEngineProvider.future);
    return PluginUpdateService(
      engine,
      ref.read(pluginManagerProvider.notifier),
      subscriptionsReader: () => ref.read(pluginSubscriptionsProvider),
    );
  }

  Future<void> _checkAllUpdates() async {
    setState(() => _checkingUpdates = true);
    try {
      final service = await _updateService();
      final manager = ref.read(pluginManagerProvider.notifier);
      final sources = ref.read(pluginManagerProvider).sources;
      final results = await service.checkAll();
      if (!mounted) return;
      _updateCheckResults
        ..clear()
        ..addAll(results);
      for (final s in sources) {
        final r = results[s.id];
        await manager.setUpdateAvailable(s.id, r?.hasUpdate ?? false);
      }
      final updateCount = results.values.where((r) => r.hasUpdate).length;
      if (!mounted) return;
      showXianYuToast(
        context,
        updateCount > 0
            ? tr('发现 {n} 个插件可更新', {'n': updateCount})
            : tr('所有插件均为最新版本'),
      );
    } catch (e) {
      if (!mounted) return;
      showXianYuToast(context, tr('检查更新失败：{e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _checkingUpdates = false);
    }
  }

  Future<void> _updatePlugin(BuildContext context, PluginSource source) async {
    if (_updatingIds.contains(source.id)) return;
    _updatingIds.add(source.id);
    final manager = ref.read(pluginManagerProvider.notifier);
    try {
      final cached = _updateCheckResults[source.id];
      if (cached != null && cached.hasUpdate && cached.newScript != null) {
        final service = await _updateService();
        final outcome = await service.performPluginUpdate(source, cached);
        if (!context.mounted) return;
        showXianYuToast(context, outcome.message);
        if (outcome.success) {
          _updateCheckResults.remove(source.id);
          await manager.setUpdateAvailable(source.id, false);
        }
        return;
      }
      final service = await _updateService();
      final result = await service.checkPluginUpdate(source);
      await manager.setUpdateAvailable(source.id, result?.hasUpdate ?? false);
      if (!context.mounted) return;
      if (result == null) {
        showXianYuToast(context, tr('无可用更新源'));
      } else if (result.hasUpdate) {
        _updateCheckResults[source.id] = result;
        showXianYuToast(context, tr('「{name}」发现新版本 v{ver}，再次点击更新',
            {'name': source.name, 'ver': result.newVersion}));
      } else {
        showXianYuToast(context, tr('「{name}」已是最新版本', {'name': source.name}));
      }
    } catch (e) {
      if (context.mounted) showXianYuToast(context, tr('检查更新失败：{e}', {'e': e}));
    } finally {
      _updatingIds.remove(source.id);
    }
  }

  Future<void> _toggleAllPlugins(bool targetEnabled) async {
    setState(() => _togglingAll = true);
    try {
      await ref.read(pluginManagerProvider.notifier).toggleAll(targetEnabled);
      if (!mounted) return;
      final count = ref.read(pluginManagerProvider).sources.length;
      showXianYuToast(
        context,
        tr(
          targetEnabled ? '已启用 {n} 个插件' : '已禁用 {n} 个插件',
          {'n': count},
        ),
      );
    } catch (e) {
      if (!mounted) return;
      showXianYuToast(context, tr('操作失败：{e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _togglingAll = false);
    }
  }
}
