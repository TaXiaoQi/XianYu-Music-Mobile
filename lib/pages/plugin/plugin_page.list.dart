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

  void _onReorder(int oldIndex, int newIndex) {
    if (_query.trim().isNotEmpty) return;
    final full =
        List<PluginSource>.from(ref.read(pluginManagerProvider).sources);
    if (newIndex < 0 || newIndex >= full.length || newIndex == oldIndex) {
      return;
    }
    final moved = full.removeAt(oldIndex);
    full.insert(newIndex, moved);
    ref
        .read(pluginManagerProvider.notifier)
        .reorder(full.map((e) => e.id).toList());
  }
}
