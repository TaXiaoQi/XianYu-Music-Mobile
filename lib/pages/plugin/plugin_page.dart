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
              : ReorderableListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 150),
                  buildDefaultDragHandles: false,
                  itemCount: sources.isNotEmpty && filtered.isEmpty
                      ? 0
                      : filtered.length,
                  onReorderItem: _onReorder,
                  header: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
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
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10),
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
                            label: Text(_checkingUpdates
                                ? '检查中...'
                                : '检查全部更新'),
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
                        ),
                    ],
                  ),
                  // 拖动代理样式与正常卡片保持一致（去掉默认拖拽阴影）
                  proxyDecorator: (child, index, animation) => child,
                  itemBuilder: (context, i) {
                    final source = filtered[i];
                    // 点击最前方拖动图标即可拖拽；搜索过滤时禁用
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _PluginCard(
                        source: source,
                        index: i,
                        dragEnabled: _query.isEmpty,
                      ),
                    );
                  },
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

class _PluginCard extends ConsumerStatefulWidget {
  const _PluginCard({
    required this.source,
    required this.index,
    required this.dragEnabled,
  });
  final PluginSource source;
  final int index;
  final bool dragEnabled;

  @override
  ConsumerState<_PluginCard> createState() => _PluginCardState();
}

class _PluginCardState extends ConsumerState<_PluginCard> {
  bool _hasVars = false;

  PluginSource get source => widget.source;

  @override
  void initState() {
    super.initState();
    // 首帧后再读取，避免插件列表初次渲染被变量加载拖慢
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadHasVars());
  }

  Future<void> _loadHasVars() async {
    try {
      final vars =
          await ref.read(pluginManagerProvider.notifier).getUserVars(source.id);
      if (!mounted || vars.isEmpty) return;
      setState(() => _hasVars = true);
    } catch (_) {
      // 读取失败时不显示变量图标
    }
  }

  @override
  Widget build(BuildContext context) {
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

    // 第二行文案：v{version} · 作者 · 描述（缺省时省略，与桌面端一致）
    final subText = [
      if (source.version.isNotEmpty) 'v${source.version}',
      if (source.author.isNotEmpty) source.author,
      if (source.description.isNotEmpty) source.description,
    ].join(' · ');

    // 格式标签（落雪 / MusicFree / BakaMusic / 未知），与图标配色同源判定
    final tagLabel = source.format == PluginFormat.lx
        ? '落雪'
        : source.format == PluginFormat.musicfree
            ? (source.author.toLowerCase().contains('toskysun')
                ? 'BakaMusic'
                : 'MusicFree')
            : '未知';

    return Material(
      color: appCardColor(context),
      borderRadius: BorderRadius.circular(14),
      child: Stack(
        children: [
          // 内容：左侧预留拖动图标让位
          Padding(
            padding: const EdgeInsets.fromLTRB(56, 8, 8, 6),
            child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 上面行：图标 + [名称(带格式标签) / 版本·作者] + 开关
            Row(
              children: [
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
                // 名称 + 格式标签（第 1 行）/ 版本·作者（第 2 行）
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
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: iconBg,
                              borderRadius: BorderRadius.circular(5),
                            ),
                            child: Text(
                              tagLabel,
                              style: TextStyle(
                                  fontSize: 10,
                                  color: iconColor,
                                  fontWeight: FontWeight.w600),
                            ),
                          ),
                          // 有用户变量时，在标签后显示变量入口图标
                          if (_hasVars) ...[
                            const SizedBox(width: 6),
                            Icon(Icons.tune_outlined,
                                size: 15, color: scheme.primary),
                          ],
                        ],
                      ),
                      if (subText.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          subText,
                          style: TextStyle(
                              fontSize: 12, color: scheme.outline),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                // 开关（仍在上面行右侧）
                Switch(
                  value: source.enabled,
                  activeThumbColor: iconColor,
                  onChanged: (_) => manager.toggleEnabled(source.id),
                ),
              ],
            ),
            const SizedBox(height: 4),
            // 下面一行：详情 / 更新 / 删除，与上方插件图标同一左缘对齐
            Row(
              children: [
                _action(
                  context,
                  Icons.info_outline,
                  '详情',
                  () => _openDetail(context, ref),
                ),
                const SizedBox(width: 4),
                _action(
                  context,
                  Icons.system_update_alt_outlined,
                  '更新',
                  () => _checkUpdate(context, ref),
                ),
                const SizedBox(width: 4),
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
        // 拖动 UI：最前方，整条垂直居中；点击立即触发拖拽
        Positioned(
          left: 4,
          top: 0,
          bottom: 0,
          width: 40,
          child: Center(
            child: widget.dragEnabled
                ? ReorderableDragStartListener(
                    index: widget.index,
                    child: Icon(Icons.drag_indicator,
                        size: 38, color: scheme.outline),
                  )
                : Icon(Icons.drag_indicator,
                    size: 38, color: scheme.outline),
          ),
        ),
      ],
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
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
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

/// 插件详情弹窗：展示插件信息、链接与用户变量（对齐桌面端；无变量则不显示变量区）。
class _PluginDetailSheet extends ConsumerStatefulWidget {
  const _PluginDetailSheet({required this.source});
  final PluginSource source;

  @override
  ConsumerState<_PluginDetailSheet> createState() => _PluginDetailSheetState();
}

class _PluginDetailSheetState extends ConsumerState<_PluginDetailSheet> {
  List<PluginUserVar> _vars = [];
  final Map<String, TextEditingController> _controllers = {};
  final Map<String, String> _selectValues = {};
  final Set<String> _visiblePasswords = {};
  bool _loading = true;
  bool _saving = false;

  PluginSource get source => widget.source;

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
      final vars = await manager.getUserVars(source.id);
      if (!mounted) return;
      if (vars.isEmpty) {
        setState(() {
          _vars = const [];
          _loading = false;
        });
        return;
      }
      final values = await PluginUserVarStore().getValues(source.id);
      for (final v in vars) {
        final existing = values[v.name] ?? '';
        if (v.isSelect) {
          _selectValues[v.name] = existing.isNotEmpty
              ? existing
              : (v.defaultValue ??
                  (v.options.isNotEmpty ? v.options.first : ''));
        } else {
          _controllers[v.name] = TextEditingController(
              text: existing.isNotEmpty ? existing : (v.defaultValue ?? ''));
        }
      }
      if (!mounted) return;
      setState(() {
        _vars = vars;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _vars = const [];
        _loading = false;
      });
    }
  }

  Future<void> _save() async {
    if (_saving) return;
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
      values[v.name] = v.isSelect
          ? (_selectValues[v.name] ?? '')
          : (_controllers[v.name]?.text.trim() ?? '');
    }
    try {
      await ref
          .read(pluginManagerProvider.notifier)
          .saveUserVars(source.id, values);
      if (!mounted) return;
      showXianYuToast(context, '已保存用户变量，开始生效');
    } catch (e) {
      if (!mounted) return;
      showXianYuToast(context, '保存失败：$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
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
        padding: EdgeInsets.only(
          left: 18,
          right: 18,
          top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 10,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.72,
          ),
          child: ListView(
            shrinkWrap: true,
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
              // 音源（插件链接）chips
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 64,
                      child: Text('链接',
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
              // 用户变量（内联展示，对齐桌面端；无变量则不显示）
              if (!_loading && _vars.isNotEmpty) ...[
                const Divider(height: 8),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(Icons.tune_outlined,
                        size: 18, color: scheme.primary),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text('用户变量',
                          style: TextStyle(
                              fontSize: 14.5, fontWeight: FontWeight.w600)),
                    ),
                    if (_saving)
                      const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                    else
                      FilledButton(
                        style: FilledButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding:
                              const EdgeInsets.symmetric(horizontal: 14),
                          textStyle: const TextStyle(fontSize: 13),
                        ),
                        onPressed: _save,
                        child: const Text('保存'),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text('保存后插件将重新加载并应用新的变量值',
                    style: TextStyle(fontSize: 12, color: scheme.outline)),
                const SizedBox(height: 12),
                for (final v in _vars) _buildField(context, v),
              ],
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
                  DropdownMenuItem(
                      value: opt,
                      child: Text(opt, style: const TextStyle(fontSize: 14))),
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


