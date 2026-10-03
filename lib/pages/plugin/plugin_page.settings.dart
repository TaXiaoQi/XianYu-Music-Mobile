part of 'plugin_page.dart';
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

extension _PluginPageSettings on _PluginPageState {
  Future<void> _loadAutoUpdatePref() async {
    final enabled = await PluginPreferences.getAutoUpdateOnStartup();
    if (mounted) setState(() => _autoUpdateOnStartup = enabled);
  }

  Future<void> _ensureVarsLoaded() async {
    if (_collectingVars) return;
    _collectingVars = true;
    try {
      final sources = ref.read(pluginManagerProvider).sources;
      var needRefresh = false;
      for (final s in sources) {
        if (_hasVars.containsKey(s.id)) continue;
        var hasVars = false;
        try {
          final vars = await ref
              .read(pluginManagerProvider.notifier)
              .getUserVars(s.id);
          hasVars = vars.isNotEmpty;
        } catch (_) {
        }
        _hasVars[s.id] = hasVars;
        needRefresh = needRefresh || hasVars;
      }
      if (needRefresh && mounted) setState(() {});
    } finally {
      _collectingVars = false;
    }
  }

  Future<void> _showPluginSettingsSheet() async {
    await showSheetDialog<void>(
      context,
      (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
                Text(tr('插件设置'),
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(
                tr('管理插件的自动化行为'),
                style: TextStyle(fontSize: 12, color: Theme.of(ctx).colorScheme.outline),
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title:   Text(tr('启动时自动更新'),
                    style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w500)),
                subtitle:   Text(tr('应用启动后静默检查并安装所有已启用插件的最新版本；被标记"跳过版本检查"的插件除外')),
                value: _autoUpdateOnStartup,
                onChanged: _savingAutoUpdate
                    ? null
                    : (val) async {
                        setSheetState(() => _savingAutoUpdate = true);
                        await PluginPreferences.setAutoUpdateOnStartup(val);
                        if (mounted) {
                          setState(() => _autoUpdateOnStartup = val);
                        }
                        setSheetState(() => _savingAutoUpdate = false);
                      },
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(tr('显示真实音源名'),
                    style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w500)),
                subtitle: Text(tr('把插件用「小X」规避审查的别名还原为平台真名（网易云/酷狗/QQ 等）')),
                value: ref.watch(settingsProvider.select((s) => s.valueOrNull?.showRealSourceName ?? false)),
                onChanged: (val) => ref.read(settingsProvider.notifier).setShowRealSourceName(val),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  FilledButton(
                    onPressed: () => Navigator.pop(ctx),
                    child:   Text(tr('完成')),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
