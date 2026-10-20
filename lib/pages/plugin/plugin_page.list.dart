part of 'plugin_page.dart';
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

extension _PluginPageList on _PluginPageState {
  Widget _listHost(bool floating, Widget child) {
    if (floating) return Positioned.fill(child: RepaintBoundary(child: child));
    return Padding(
      padding: EdgeInsets.only(top: GlassTopBar.height(context)),
      child: child,
    );
  }

  /// 混合行重排：插件行写回 sortOrder，网盘行写回排序位（前方插件数）。
  void _onReorder(int oldIndex, int newIndex) {
    if (_query.trim().isNotEmpty) return;
    final rows = List<_PageRow>.from(_rows);
    if (newIndex > oldIndex) newIndex -= 1; // ReorderableListView 语义修正
    if (oldIndex < 0 ||
        oldIndex >= rows.length ||
        newIndex < 0 ||
        newIndex >= rows.length ||
        oldIndex == newIndex) {
      return;
    }
    final moved = rows.removeAt(oldIndex);
    rows.insert(newIndex, moved);

    final pluginIds = <String>[];
    for (final row in rows) {
      final p = row.plugin;
      if (p != null) pluginIds.add(p.id);
    }
    final cloudIndexes = <String, int>{};
    var pluginCount = 0;
    for (final row in rows) {
      if (row.plugin != null) {
        pluginCount++;
      } else {
        cloudIndexes[row.cloudProviderId!] = pluginCount;
      }
    }
    unawaited(ref.read(pluginManagerProvider.notifier).reorder(pluginIds));
    for (final e in cloudIndexes.entries) {
      unawaited(PluginPreferences.setCloudSourcePref(e.key, sortIndex: e.value));
    }
    setState(() {
      for (final e in cloudIndexes.entries) {
        _cloudPrefs[e.key] = CloudSourcePref(
          enabled: _cloudPrefs[e.key]?.enabled ?? true,
          sortIndex: e.value,
        );
      }
    });
  }
}
