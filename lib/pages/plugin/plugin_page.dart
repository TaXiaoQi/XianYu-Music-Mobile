import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/core/app_colors.dart';
import '../../src/plugin/plugin_engine.dart';
import '../../src/plugin/plugin_models.dart';
import '../../src/plugin/plugin_preferences.dart';
import '../../src/plugin/plugin_provider.dart';
import '../../src/plugin/plugin_subscriptions.dart';
import '../../src/plugin/plugin_updates.dart';
import '../../src/plugin/plugin_user_vars.dart';
import '../../src/widgets/sheet_dialog.dart';

/// 插件管理页：列表、安装（URL/脚本）、启用禁用、卸载、更新。
class PluginPage extends ConsumerStatefulWidget {
  const PluginPage({super.key});

  @override
  ConsumerState<PluginPage> createState() => _PluginPageState();
}

class _PluginPageState extends ConsumerState<PluginPage> {
  bool _installing = false;
  bool _checkingUpdates = false;
  bool _savingAutoUpdate = false;

  @override
  void initState() {
    super.initState();
    _loadAutoUpdatePref();
  }

  Future<void> _loadAutoUpdatePref() async {
    final enabled = await PluginPreferences.getAutoUpdateOnStartup();
    if (mounted) setState(() => _autoUpdateOnStartup = enabled);
  }

  bool _autoUpdateOnStartup = false;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(pluginManagerProvider);
    final subscriptions = ref.watch(pluginSubscriptionsProvider);

    return Scaffold(
      backgroundColor: appSurfaceBg(context),
      appBar: AppBar(
        title: const Text('音源'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: '插件设置',
            onPressed: _showPluginSettingsSheet,
          ),
          IconButton(
            icon: const Icon(Icons.system_update_alt_outlined),
            tooltip: '检查全部更新',
            onPressed: _checkingUpdates ? null : _checkAllUpdates,
          ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '安装插件',
            onPressed: _installing ? null : _showInstallSheet,
          ),
        ],
      ),
      body: state.loading
          ? const Center(child: CircularProgressIndicator())
          : state.sources.isEmpty && subscriptions.isEmpty
              ? _EmptyState(onInstall: _showInstallSheet)
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 150),
                  children: [
                    if (subscriptions.isNotEmpty) ...[
                      _SubscriptionSection(
                        subscriptions: subscriptions,
                        onReinstall: _installUrl,
                      ),
                      const SizedBox(height: 16),
                    ],
                    for (final source in state.sources) ...[
                      _PluginCard(source: source),
                      const SizedBox(height: 8),
                    ],
                  ],
                ),
    );
  }

  void _showInstallSheet() {
    showSheetDialog<void>(
      context,
      (ctx) => _InstallSheet(
        onInstall: (script, name) => _install(script, name),
        onInstallUrl: (url) => _installUrl(url),
      ),
    );
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
              const Text('插件设置',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(
                '管理插件的自动化行为',
                style: TextStyle(fontSize: 12, color: Theme.of(ctx).colorScheme.outline),
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('启动时自动更新',
                    style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w500)),
                subtitle: const Text('应用启动后静默检查并安装所有已启用插件的最新版本；被标记"跳过版本检查"的插件除外'),
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
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  FilledButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('完成'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _installUrl(String url) async {
    if (url.trim().isEmpty) return;
    setState(() => _installing = true);
    try {
      final result =
          await ref.read(pluginManagerProvider.notifier).installFromUrl(url);
      if (!mounted) return;
      if (result.success) {
        final summary = result.failCount > 0
            ? '成功 ${result.names.length} 个，失败 ${result.failCount} 个'
            : '成功 ${result.names.length} 个：${result.names.join('、')}';
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('插件安装完成，$summary')));
      } else {
        final detail = result.errors.isNotEmpty ? '（${result.errors.first}）' : '';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('所有插件安装失败$detail')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      final msg = e is PluginEngineException ? e.message : e.toString();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('安装失败：$msg')),
      );
    } finally {
      if (mounted) setState(() => _installing = false);
    }
  }

  Future<void> _install(String script, String name) async {
    if (script.trim().isEmpty) return;
    setState(() => _installing = true);
    try {
      final source = await ref
          .read(pluginManagerProvider.notifier)
          .installFromScript(script, fileName: name);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('插件「${source.name}」安装成功')),
      );
    } catch (e) {
      if (!mounted) return;
      final msg = e is PluginEngineException ? e.message : e.toString();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('安装失败：$msg')),
      );
    } finally {
      if (mounted) setState(() => _installing = false);
    }
  }

  Future<PluginUpdateService> _updateService() async {
    final engine = await ref.read(pluginEngineProvider.future);
    return PluginUpdateService(engine, ref.read(pluginManagerProvider.notifier));
  }

  Future<void> _checkAllUpdates() async {
    setState(() => _checkingUpdates = true);
    try {
      final service = await _updateService();
      final results = await service.checkAll();
      if (!mounted) return;
      final updateCount =
          results.values.where((r) => r.hasUpdate).length;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(updateCount > 0
              ? '发现 $updateCount 个插件可更新'
              : '所有插件均为最新版本'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('检查更新失败：$e')),
      );
    } finally {
      if (mounted) setState(() => _checkingUpdates = false);
    }
  }
}

/// 订阅链接区块：展示已记录的订阅，点击重新导入，可删除。
class _SubscriptionSection extends ConsumerWidget {
  const _SubscriptionSection({
    required this.subscriptions,
    required this.onReinstall,
  });

  final List<PluginSubscription> subscriptions;
  final Future<void> Function(String url) onReinstall;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.rss_feed, size: 16, color: scheme.primary),
            const SizedBox(width: 6),
            Text(
              '订阅链接 · ${subscriptions.length}',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '随插件同步到云端，点击可重新导入最新版本',
          style: TextStyle(fontSize: 11, color: scheme.outline),
        ),
        const SizedBox(height: 8),
        for (final sub in subscriptions)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Material(
              color: appCardColor(context),
              borderRadius: BorderRadius.circular(14),
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () => onReinstall(sub.url),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
                  child: Row(
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: scheme.primary.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: Icon(Icons.link,
                            size: 18, color: scheme.primary),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              sub.name,
                              style: const TextStyle(
                                  fontSize: 14, fontWeight: FontWeight.w600),
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              sub.url,
                              style: TextStyle(
                                  fontSize: 11, color: scheme.outline),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: Icon(Icons.delete_outline,
                            size: 20, color: scheme.outline),
                        tooltip: '移除订阅',
                        onPressed: () => ref
                            .read(pluginSubscriptionsProvider.notifier)
                            .remove(sub.id),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onInstall});
  final VoidCallback onInstall;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.extension_outlined, size: 56, color: scheme.outline),
          const SizedBox(height: 12),
          Text('还没有安装音源插件',
              style: TextStyle(color: scheme.onSurfaceVariant)),
          const SizedBox(height: 4),
          Text(
            '支持 LX / MusicFree 格式音源插件，在线搜索与播放需要音源支持',
            style: TextStyle(fontSize: 12, color: scheme.outline),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: onInstall,
            icon: const Icon(Icons.add),
            label: const Text('安装音源'),
          ),
        ],
      ),
    );
  }
}

class _PluginCard extends ConsumerWidget {
  const _PluginCard({required this.source});
  final PluginSource source;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final manager = ref.read(pluginManagerProvider.notifier);

    return Material(
      color: appCardColor(context),
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
        child: Row(
          children: [
            // 图标
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                source.format == PluginFormat.lx
                    ? Icons.music_note
                    : Icons.extension,
                color: scheme.primary,
                size: 22,
              ),
            ),
            const SizedBox(width: 12),
            // 名称 + 版本 + 音源
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          source.name,
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w600),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (source.version.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Text(
                          'v${source.version}',
                          style: TextStyle(
                              fontSize: 12, color: scheme.outline),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    source.author.isEmpty
                        ? (source.format == PluginFormat.lx ? 'LX 插件' : 'MusicFree 插件')
                        : source.author,
                    style: TextStyle(
                        fontSize: 12, color: scheme.onSurfaceVariant),
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (source.sources.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      '音源：${source.sources.join(' / ')}',
                      style:
                          TextStyle(fontSize: 11, color: scheme.outline),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            // 用户变量（仅 MusicFree 插件）
            if (source.format == PluginFormat.musicfree)
              IconButton(
                icon: Icon(Icons.tune_outlined,
                    size: 20, color: scheme.outline),
                tooltip: '用户变量',
                onPressed: () => _openUserVars(context, ref),
              ),
            // 更新
            IconButton(
              icon: Icon(Icons.system_update_alt_outlined,
                  size: 20, color: scheme.outline),
              tooltip: '检查更新',
              onPressed: () => _checkUpdate(context, ref),
            ),
            // 更多：脚本编辑 / 跳过检查 / 重新加载
            PopupMenuButton<String>(
              icon: Icon(Icons.more_vert, size: 20, color: scheme.outline),
              tooltip: '更多',
              onSelected: (action) {
                switch (action) {
                  case 'skip':
                    _toggleSkipUpdate(context, ref);
                    break;
                  case 'script':
                    _openScriptEditor(context, ref);
                    break;
                  case 'reload':
                    _confirmReload(context, ref);
                    break;
                }
              },
              itemBuilder: (ctx) => [
                const PopupMenuItem(
                  value: 'skip',
                  child: Text('跳过版本检查'),
                ),
                const PopupMenuItem(
                  value: 'script',
                  child: Text('编辑脚本'),
                ),
                const PopupMenuItem(
                  value: 'reload',
                  child: Text('重新加载'),
                ),
              ],
            ),
            // 卸载
            IconButton(
              icon: Icon(Icons.delete_outline, size: 20, color: scheme.outline),
              tooltip: '卸载',
              onPressed: () => _confirmRemove(context, manager),
            ),
            // 启用开关
            Switch(
              value: source.enabled,
              onChanged: (_) => manager.toggleEnabled(source.id),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openUserVars(BuildContext context, WidgetRef ref) async {
    await showSheetDialog<void>(
      context,
      (ctx) => _UserVarsSheet(source: source),
    );
  }

  Future<void> _checkUpdate(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final engine = await ref.read(pluginEngineProvider.future);
    final service =
        PluginUpdateService(engine, ref.read(pluginManagerProvider.notifier));
    final result = await service.checkPluginUpdate(source);
    if (!context.mounted) return;
    if (result == null) {
      messenger.showSnackBar(
          const SnackBar(content: Text('无可用更新源')));
      return;
    }
    if (!result.hasUpdate) {
      messenger.showSnackBar(
          SnackBar(content: Text('「${source.name}」已是最新版本')));
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      useRootNavigator: true,
      builder: (ctx) => AlertDialog(
        title: const Text('发现新版本'),
        content: Text(
            '「${source.name}」\n当前版本：v${result.currentVersion}\n'
            '新版本：v${result.newVersion}\n\n是否立即更新？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('更新'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final outcome = await service.performPluginUpdate(source, result);
    if (!context.mounted) return;
    messenger.showSnackBar(
      SnackBar(content: Text(outcome.message)),
    );
  }

  Future<void> _openScriptEditor(BuildContext context, WidgetRef ref) async {
    await showSheetDialog<void>(
      context,
      (ctx) => _ScriptEditorSheet(source: source),
    );
  }

  Future<void> _toggleSkipUpdate(BuildContext context, WidgetRef ref) async {
    final current = await PluginPreferences.getSkipUpdateCheck(source.id);
    await PluginPreferences.setSkipUpdateCheck(source.id, !current);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(!current ? '「${source.name}」将跳过版本检查' : '「${source.name}」已恢复版本检查')),
    );
  }

  Future<void> _confirmReload(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await ref.read(pluginManagerProvider.notifier).reload(source.id);
    messenger.showSnackBar(SnackBar(
        content: Text(ok ? '「${source.name}」已重新加载' : '「${source.name}」加载失败')));
  }

  void _confirmRemove(BuildContext context, PluginManager manager) {
    showDialog<void>(
      context: context,
      useRootNavigator: true,
      builder: (ctx) => AlertDialog(
        title: const Text('卸载插件'),
        content: Text('确定要卸载「${source.name}」吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              manager.remove(source.id);
            },
            child: const Text('卸载'),
          ),
        ],
      ),
    );
  }
}

/// 插件脚本编辑器：查看/修改插件 JS 脚本，保存后重新加载生效。
class _ScriptEditorSheet extends ConsumerStatefulWidget {
  const _ScriptEditorSheet({required this.source});
  final PluginSource source;

  @override
  ConsumerState<_ScriptEditorSheet> createState() => _ScriptEditorSheetState();
}

class _ScriptEditorSheetState extends ConsumerState<_ScriptEditorSheet> {
  final _ctrl = TextEditingController();
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final engine = await ref.read(pluginEngineProvider.future);
      final script = await engine.store.readScript(widget.source.id);
      if (!mounted) return;
      _ctrl.text = script ?? '';
      setState(() => _loading = false);
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    if (_saving || _loading) return;
    setState(() => _saving = true);
    try {
      await ref
          .read(pluginManagerProvider.notifier)
          .updateScript(widget.source.id, _ctrl.text);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('脚本已保存并重新加载')),
      );
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败：$e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.72,
            maxWidth: 420,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('编辑脚本 · ${widget.source.name}',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(
                '保存后将校验并重新加载插件；脚本语法错误会阻止保存',
                style: TextStyle(fontSize: 12, color: scheme.outline),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: Container(
                  decoration: BoxDecoration(
                    color: appCardColor(context),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: scheme.outlineVariant),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: TextField(
                    controller: _ctrl,
                    maxLines: null,
                    expands: true,
                    enabled: !_loading,
                    keyboardType: TextInputType.multiline,
                    style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 12.5, height: 1.5),
                    decoration: const InputDecoration(
                      hintText: '// 插件 JS 脚本',
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.all(12),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _saving ? null : () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: (_loading || _saving) ? null : _save,
                    child: _saving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('保存'),
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

/// 安装方式选择：URL（单个脚本或插件集批量）或脚本粘贴。
class _InstallSheet extends StatefulWidget {
  const _InstallSheet({
    required this.onInstall,
    required this.onInstallUrl,
  });
  final void Function(String script, String name) onInstall;
  final Future<void> Function(String url) onInstallUrl;

  @override
  State<_InstallSheet> createState() => _InstallSheetState();
}

class _InstallSheetState extends State<_InstallSheet> {
  final _urlCtrl = TextEditingController();
  final _scriptCtrl = TextEditingController();
  bool _loading = false;

  @override
  void dispose() {
    _urlCtrl.dispose();
    _scriptCtrl.dispose();
    super.dispose();
  }

  Future<void> _installFromUrl() async {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty) return;
    setState(() => _loading = true);
    try {
      await widget.onInstallUrl(url);
      if (mounted) Navigator.pop(context);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('安装插件',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(
              '支持 LX（落雪）与 MusicFree 格式，链接可为单个插件或插件集（JSON）',
              style: TextStyle(fontSize: 12, color: scheme.outline),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _urlCtrl,
              decoration: const InputDecoration(
                labelText: '插件 URL',
                hintText: 'https://example.com/plugin.js',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                FilledButton.icon(
                  onPressed: _loading ? null : _installFromUrl,
                  icon: _loading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.download, size: 18),
                  label: const Text('从 URL 安装'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Divider(color: scheme.outlineVariant),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text('或粘贴脚本内容',
                      style: TextStyle(fontSize: 12, color: scheme.outline)),
                ),
                Expanded(child: Divider(color: scheme.outlineVariant)),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _scriptCtrl,
              maxLines: 6,
              decoration: const InputDecoration(
                hintText: '粘贴插件 JS 脚本…',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () {
                    widget.onInstall(_scriptCtrl.text, '粘贴脚本');
                    Navigator.pop(context);
                  },
                  child: const Text('安装'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 插件用户变量编辑弹层：加载定义 → 表单编辑 → 保存并重载插件。
class _UserVarsSheet extends ConsumerStatefulWidget {
  const _UserVarsSheet({required this.source});
  final PluginSource source;

  @override
  ConsumerState<_UserVarsSheet> createState() => _UserVarsSheetState();
}

class _UserVarsSheetState extends ConsumerState<_UserVarsSheet> {
  List<PluginUserVar> _vars = [];
  final Map<String, TextEditingController> _controllers = {};
  final Map<String, String> _selectValues = {};
  final Set<String> _visiblePasswords = {};
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final manager = ref.read(pluginManagerProvider.notifier);
      final vars = await manager.getUserVars(widget.source.id);
      if (!mounted) return;
      if (vars.isEmpty) {
        setState(() => _loading = false);
        return;
      }
      final values = await PluginUserVarStore().getValues(widget.source.id);
      for (final v in vars) {
        final existing = values[v.name] ?? '';
        if (v.isSelect) {
          _selectValues[v.name] = existing.isNotEmpty
              ? existing
              : (v.defaultValue ?? (v.options.isNotEmpty ? v.options.first : ''));
        } else {
          _controllers[v.name] =
              TextEditingController(text: existing.isNotEmpty ? existing : (v.defaultValue ?? ''));
        }
      }
      setState(() {
        _vars = vars;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    // 必填校验
    for (final v in _vars) {
      if (!v.required) continue;
      final value = v.isSelect
          ? (_selectValues[v.name] ?? '')
          : (_controllers[v.name]?.text.trim() ?? '');
      if (value.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('「${v.title ?? v.name}」为必填项')),
        );
        return;
      }
    }

    setState(() => _saving = true);
    final values = <String, String>{};
    for (final v in _vars) {
      if (v.isSelect) {
        values[v.name] = _selectValues[v.name] ?? '';
      } else {
        values[v.name] = _controllers[v.name]?.text.trim() ?? '';
      }
    }
    try {
      await ref
          .read(pluginManagerProvider.notifier)
          .saveUserVars(widget.source.id, values);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已保存用户变量，开始生效')),
      );
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败：$e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.7,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('用户变量 · ${widget.source.name}',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(
                '保存后插件将重新加载并应用新的变量值',
                style: TextStyle(fontSize: 12, color: scheme.outline),
              ),
              const SizedBox(height: 16),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 32),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_vars.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 32),
                  child: Column(
                    children: [
                      Icon(Icons.tune_outlined, size: 40, color: scheme.outline),
                      const SizedBox(height: 12),
                      Text('该插件未声明用户变量',
                          style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
                    ],
                  ),
                )
              else
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: _vars.length,
                    itemBuilder: (ctx, i) => _buildField(ctx, _vars[i]),
                  ),
                ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: (_loading || _saving) ? null : _save,
                    child: _saving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('保存'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildField(BuildContext context, PluginUserVar v) {
    final scheme = Theme.of(context).colorScheme;
    final label = v.title ?? v.name;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(label,
                  style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
              if (v.required)
                const Text(' *', style: TextStyle(color: Color(0xFFEC4141), fontSize: 13.5)),
              const Spacer(),
              Text(v.name,
                  style: TextStyle(fontSize: 11, color: scheme.outline)),
            ],
          ),
          if (v.description != null && v.description!.isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(v.description!,
                style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
          ],
          const SizedBox(height: 7),
          if (v.isSelect)
            DropdownButtonFormField<String>(
              initialValue: _selectValues[v.name],
              decoration: InputDecoration(
                isDense: true,
                border: const OutlineInputBorder(),
                hintText: v.placeholder,
              ),
              items: [
                for (final opt in v.options)
                  DropdownMenuItem(value: opt, child: Text(opt, style: const TextStyle(fontSize: 14))),
              ],
              onChanged: (val) {
                if (val != null) setState(() => _selectValues[v.name] = val);
              },
            )
          else
            TextField(
              controller: _controllers[v.name],
              obscureText: v.isPassword && !_visiblePasswords.contains(v.name),
              decoration: InputDecoration(
                isDense: true,
                border: const OutlineInputBorder(),
                hintText: v.placeholder,
                suffixIcon: v.isPassword
                    ? IconButton(
                        icon: Icon(
                          _visiblePasswords.contains(v.name)
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                          size: 20,
                        ),
                        onPressed: () => setState(() {
                          _visiblePasswords.contains(v.name)
                              ? _visiblePasswords.remove(v.name)
                              : _visiblePasswords.add(v.name);
                        }),
                      )
                    : null,
              ),
              style: const TextStyle(fontSize: 14),
            ),
        ],
      ),
    );
  }
}
