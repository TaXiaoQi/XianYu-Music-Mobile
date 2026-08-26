import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:xianyu_music_mobile/src/widgets/predictive_dialog_route.dart';

import '../../src/core/app_colors.dart';
import '../../src/plugin/plugin_engine.dart';
import '../../src/plugin/plugin_models.dart';
import '../../src/plugin/plugin_preferences.dart';
import '../../src/plugin/plugin_provider.dart';
import '../../src/plugin/plugin_subscriptions.dart';
import '../../src/plugin/plugin_updates.dart';
import '../../src/plugin/plugin_user_vars.dart';
import '../../src/widgets/app_toast.dart';
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

  final _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _loadAutoUpdatePref();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
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
    final scheme = Theme.of(context).colorScheme;

    final sources = state.sources;
    final q = _query.trim().toLowerCase();
    final filtered = q.isEmpty
        ? sources
        : sources
            .where((s) =>
                s.name.toLowerCase().contains(q) ||
                s.author.toLowerCase().contains(q) ||
                s.sources.join(',').toLowerCase().contains(q))
            .toList();

    return Scaffold(
      backgroundColor: appSurfaceBg(context),
      // 键盘弹/收时不让 Scaffold 按 viewInsets 逐帧缩放 body：插件列表不再
      // 每帧重排重绘，彻底消除输入法动画掉帧（键盘弹出后面板由弹窗自行上移）。
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        title: const Text('音源'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: '插件设置',
            onPressed: _showPluginSettingsSheet,
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
          : sources.isEmpty && subscriptions.isEmpty
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
                    // 已安装插件标题（对标桌面端「已安装插件」区块）
                    Row(
                      children: [
                        Container(
                          width: 3,
                          height: 16,
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.primary,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        const SizedBox(width: 7),
                        const Text(
                          '已安装插件',
                          style: TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '已启用 ${sources.where((s) => s.enabled).length} / 共 ${sources.length}',
                          style: TextStyle(
                              fontSize: 12, color: scheme.outline),
                        ),
                        const Spacer(),
                        FilledButton.tonalIcon(
                          style: FilledButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding:
                                const EdgeInsets.symmetric(horizontal: 10),
                            textStyle: const TextStyle(fontSize: 12.5),
                          ),
                          onPressed: (_checkingUpdates || sources.isEmpty)
                              ? null
                              : _checkAllUpdates,
                          icon: _checkingUpdates
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2),
                                )
                              : const Icon(Icons.system_update_alt_outlined,
                                  size: 16),
                          label: Text(
                              _checkingUpdates ? '检查中...' : '检查全部更新'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    // 搜索框
                    TextField(
                      controller: _searchCtrl,
                      onChanged: (v) => setState(() => _query = v),
                      decoration: InputDecoration(
                        hintText: '搜索插件名称、平台或作者',
                        prefixIcon: const Icon(Icons.search, size: 20),
                        suffixIcon: _query.isEmpty
                            ? null
                            : IconButton(
                                icon: const Icon(Icons.close, size: 18),
                                onPressed: () {
                                  _searchCtrl.clear();
                                  setState(() => _query = '');
                                },
                              ),
                        isDense: true,
                        filled: true,
                        fillColor: appCardColor(context),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    if (sources.isNotEmpty && filtered.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 32),
                        child: Center(
                          child: Text(
                            '未找到匹配的插件',
                            style: TextStyle(
                                fontSize: 13, color: scheme.onSurfaceVariant),
                          ),
                        ),
                      )
                    else
                      ReorderableListView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        buildDefaultDragHandles: false,
                        padding: EdgeInsets.zero,
                        itemCount: filtered.length,
                        onReorderItem: _onReorder,
                        itemBuilder: (context, i) {
                          final source = filtered[i];
                          return Padding(
                            key: ValueKey(source.id),
                            padding: const EdgeInsets.only(bottom: 8),
                            child: _PluginCard(
                              source: source,
                              // 搜索过滤时不参与排序，隐藏拖拽把手
                              handle: _query.isEmpty
                                  ? ReorderableDragStartListener(
                                      index: i,
                                      child: Icon(Icons.drag_indicator,
                                          size: 20, color: scheme.outline),
                                    )
                                  : null,
                            ),
                          );
                        },
                      ),
                  ],
                ),
    );
  }

  /// 拖拽排序结束：把调整后的完整插件顺序持久化到 sortOrder。
  /// 此时 [newIndex] 已由框架处理移除后的下标修正（无需再 -1）。
  /// 仅在未搜索过滤时生效（把手已隐藏）。
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

  /// 安装插件：先选择安装方式（本地文件 / 在线链接）。
  void _showInstallSheet() {
    showSheetDialog<void>(
      context,
      (ctx) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('安装插件',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(
              '支持 LX（落雪）与 MusicFree 格式音源插件',
              style: TextStyle(
                  fontSize: 12, color: Theme.of(ctx).colorScheme.outline),
            ),
            const SizedBox(height: 14),
            _InstallOption(
              icon: Icons.folder_open_outlined,
              title: '本地文件',
              subtitle: '选择本地的插件脚本（.js / .txt）',
              onTap: () {
                Navigator.pop(ctx);
                _pickLocalPlugin();
              },
            ),
            const SizedBox(height: 10),
            _InstallOption(
              icon: Icons.cloud_download_outlined,
              title: '在线链接',
              subtitle: '输入 URL 安装，支持单个插件或插件集（JSON）批量',
              onTap: () {
                Navigator.pop(ctx);
                _showUrlInstallSheet();
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 本地文件安装：选择插件脚本并逐个安装。
  Future<void> _pickLocalPlugin() async {
    if (_installing) return;
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['js', 'txt'],
    );
    if (files.isEmpty) return;
    for (final f in files) {
      if (!mounted) return;
      try {
        final bytes = await f.readAsBytes();
        if (!mounted) return;
        if (bytes.isEmpty) {
          showXianYuToast(context, '读取「${f.name}」失败或文件为空');
          continue;
        }
        final script = utf8.decode(bytes, allowMalformed: true);
        await _install(script, f.name.isNotEmpty ? f.name : '本地插件');
      } catch (e) {
        if (!mounted) return;
        showXianYuToast(context, '读取「${f.name}」失败：$e');
      }
    }
  }

  /// 在线链接安装：弹出 URL 输入弹窗。
  Future<void> _showUrlInstallSheet() async {
    await showSheetDialog<void>(
      context,
      (ctx) => _UrlInstallSheet(onInstallUrl: (url) => _installUrl(url)),
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
        showXianYuToast(context, '插件安装完成，$summary');
      } else {
        final detail = result.errors.isNotEmpty ? '（${result.errors.first}）' : '';
        showXianYuToast(context, '所有插件安装失败$detail');
      }
    } catch (e) {
      if (!mounted) return;
      final msg = e is PluginEngineException ? e.message : e.toString();
      showXianYuToast(context, '安装失败：$msg');
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
      showXianYuToast(context, '插件「${source.name}」安装成功');
    } catch (e) {
      if (!mounted) return;
      final msg = e is PluginEngineException ? e.message : e.toString();
      showXianYuToast(context, '安装失败：$msg');
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
      showXianYuToast(
        context,
        updateCount > 0
            ? '发现 $updateCount 个插件可更新'
            : '所有插件均为最新版本',
      );
    } catch (e) {
      if (!mounted) return;
      showXianYuToast(context, '检查更新失败：$e');
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
  const _PluginCard({required this.source, this.handle});
  final PluginSource source;
  /// 排列在卡片最前面的拖拽排序把手（null 时不展示）。
  final Widget? handle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final manager = ref.read(pluginManagerProvider.notifier);

    // 图标/开关按插件格式分类配色（对齐桌面端，不随主题色变化）。
    // 落雪=绿、MusicFree=橙、BakaMusic(Toskysun)=蓝、其它=红。
    Color iconBg;
    Color iconColor;
    if (source.format == PluginFormat.lx) {
      iconBg = const Color(0x1A22C55E);
      iconColor = const Color(0xFF22C55E);
    } else if (source.format == PluginFormat.musicfree &&
        source.author.toLowerCase().contains('toskysun')) {
      iconBg = const Color(0x1A3B82F6);
      iconColor = const Color(0xFF3B82F6);
    } else if (source.format == PluginFormat.musicfree) {
      iconBg = const Color(0x1AF97316);
      iconColor = const Color(0xFFF97316);
    } else {
      iconBg = const Color(0x1AEC4141);
      iconColor = const Color(0xFFEC4141);
    }

    return Material(
      color: appCardColor(context),
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 8, 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 第一行：拖拽把手 + 图标 + 插件名称/版本 + 开关
            Row(
              children: [
                // 拖拽排序把手（排在最前面）
                if (handle != null) ...[
                  handle!,
                  const SizedBox(width: 2),
                ],
                // 图标
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: iconBg,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    source.format == PluginFormat.lx
                        ? Icons.music_note
                        : Icons.extension,
                    color: iconColor,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                // 名称 + 版本（第一行纯展示名称与版本）
                Expanded(
                  child: Row(
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
                ),
                // 开关（仍在第一行右侧）
                Switch(
                  value: source.enabled,
                  activeThumbColor: iconColor,
                  onChanged: (_) => manager.toggleEnabled(source.id),
                ),
              ],
            ),
            const SizedBox(height: 4),
            // 第二行：详情 / 更新 / 删除 均分布放，图标后带名字
            Row(
              children: [
                _action(
                  context,
                  Icons.info_outline,
                  '详情',
                  () => _openDetail(context, ref),
                ),
                _action(
                  context,
                  Icons.system_update_alt_outlined,
                  '更新',
                  () => _checkUpdate(context, ref),
                ),
                _action(
                  context,
                  Icons.delete_outline,
                  '删除',
                  () => _confirmRemove(context, manager),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 等宽分布的操作按钮：图标 + 文字（详情/更新/删除）。
  Widget _action(
    BuildContext context,
    IconData icon,
    String label,
    VoidCallback onTap,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 17, color: scheme.outline),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(fontSize: 13, color: scheme.outline),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openDetail(BuildContext context, WidgetRef ref) async {
    await showSheetDialog<void>(
      context,
      (ctx) => _PluginDetailSheet(source: source),
    );
  }

  Future<void> _checkUpdate(BuildContext context, WidgetRef ref) async {
    final engine = await ref.read(pluginEngineProvider.future);
    final service =
        PluginUpdateService(engine, ref.read(pluginManagerProvider.notifier));
    final result = await service.checkPluginUpdate(source);
    if (!context.mounted) return;
    if (result == null) {
      showXianYuToast(context, '无可用更新源');
      return;
    }
    if (!result.hasUpdate) {
      showXianYuToast(context, '「${source.name}」已是最新版本');
      return;
    }
    final confirmed = await showPredictiveDialog<bool>(
      context: context,
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
    showXianYuToast(context, outcome.message);
  }

  void _confirmRemove(BuildContext context, PluginManager manager) {
    showPredictiveDialog<void>(
      context: context,
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

/// 插件详情弹窗：展示插件信息；MusicFree 插件提供「用户变量」配置入口。
class _PluginDetailSheet extends ConsumerWidget {
  const _PluginDetailSheet({required this.source});
  final PluginSource source;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final formatLabel =
        source.format == PluginFormat.lx ? '落雪格式' : 'MusicFree 格式';

    Widget row(String label, String value) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 64,
                child: Text(label,
                    style: TextStyle(
                        fontSize: 13, color: scheme.onSurfaceVariant)),
              ),
              Expanded(child: Text(value, style: const TextStyle(fontSize: 13))),
            ],
          ),
        );

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 头部
            Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(11),
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
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(source.name,
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w700),
                          overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 2),
                      Text(formatLabel,
                          style: TextStyle(
                              fontSize: 12, color: scheme.onSurfaceVariant)),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const Divider(height: 24),
            row('版本', source.version.isEmpty ? '—' : 'v${source.version}'),
            row('作者', source.author.isEmpty ? '—' : source.author),
            if (source.description.isNotEmpty) row('描述', source.description),
            // 音源 chips
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 64,
                    child: Text('音源',
                        style: TextStyle(
                            fontSize: 13, color: scheme.onSurfaceVariant)),
                  ),
                  Expanded(
                    child: source.sources.isEmpty
                        ? const Text('—')
                        : Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              for (final s in source.sources)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: scheme.primary
                                        .withValues(alpha: 0.10),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(s,
                                      style: TextStyle(
                                          fontSize: 11.5,
                                          color: scheme.primary)),
                                ),
                            ],
                          ),
                  ),
                ],
              ),
            ),
            // MusicFree 插件：用户变量入口（对齐桌面端详情内的用户变量区）
            if (source.format == PluginFormat.musicfree) ...[
              const Divider(height: 4),
              const SizedBox(height: 6),
              Material(
                color: appCardColor(context),
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => showSheetDialog<void>(
                    context,
                    (ctx) => _UserVarsSheet(source: source),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Icon(Icons.tune_outlined,
                            size: 18, color: scheme.primary),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('用户变量',
                                  style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600)),
                              Text('插件运行所需的自定义参数',
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: scheme.onSurfaceVariant)),
                            ],
                          ),
                        ),
                        Icon(Icons.chevron_right,
                            size: 20, color: scheme.outline),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 在线链接安装弹窗：输入 URL 安装（单个插件或插件集批量）。
class _UrlInstallSheet extends StatefulWidget {
  const _UrlInstallSheet({required this.onInstallUrl});
  final Future<void> Function(String url) onInstallUrl;

  @override
  State<_UrlInstallSheet> createState() => _UrlInstallSheetState();
}

class _UrlInstallSheetState extends State<_UrlInstallSheet> {
  final _urlCtrl = TextEditingController();
  bool _loading = false;
  /// 键盘所需上移量：只作用于外层位移，弹窗内容布局固定，不随键盘逐帧重建。
  final _keyboardShift = ValueNotifier<double>(0.0);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final insets = MediaQuery.viewInsetsOf(context).bottom;
    final next = insets > 0 ? insets / 2 : 0.0;
    if ((next - _keyboardShift.value).abs() > 0.5) {
      _keyboardShift.value = next;
    }
  }

  @override
  void dispose() {
    _keyboardShift.dispose();
    _urlCtrl.dispose();
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
      child: ValueListenableBuilder<double>(
        valueListenable: _keyboardShift,
        builder: (context, shift, _) => Transform.translate(
          offset: Offset(0, -shift),
          child: RepaintBoundary(
            child: Padding(
              // 内容布局固定；被键盘遮挡时仅整体上移，不随键盘逐帧重排
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('在线链接安装',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text(
                    '支持 LX（落雪）与 MusicFree 格式，链接可为单个插件或插件集（JSON）',
                    style: TextStyle(fontSize: 12, color: scheme.outline),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _urlCtrl,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: '插件 URL',
                      hintText: 'https://example.com/plugin.js',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    keyboardType: TextInputType.url,
                    onSubmitted: (_) => _installFromUrl(),
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
                      FilledButton.icon(
                        onPressed: _loading ? null : _installFromUrl,
                        icon: _loading
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.download, size: 18),
                        label: const Text('安装'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 安装方式选项卡片：图标 + 标题 + 副标题。
class _InstallOption extends StatelessWidget {
  const _InstallOption({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: appCardColor(context),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, size: 20, color: scheme.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: const TextStyle(
                            fontSize: 14.5, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(subtitle,
                        style: TextStyle(
                            fontSize: 12, color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, size: 20, color: scheme.outline),
            ],
          ),
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
        showXianYuToast(context, '「${v.title ?? v.name}」为必填项');
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
      showXianYuToast(context, '已保存用户变量，开始生效');
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      showXianYuToast(context, '保存失败：$e');
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
