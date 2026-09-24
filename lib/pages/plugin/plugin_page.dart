import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../src/widgets/flat_top_bar.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/core/app_colors.dart';
import '../../src/core/settings.dart';
import '../../src/plugin/plugin_engine.dart';
import '../../src/plugin/plugin_models.dart';
import '../../src/plugin/plugin_preferences.dart';
import '../../src/plugin/plugin_provider.dart';
import '../../src/plugin/plugin_subscriptions.dart';
import '../../src/plugin/plugin_updates.dart';
import '../../src/plugin/plugin_user_vars.dart';
import '../../src/widgets/app_toast.dart';
import '../../src/widgets/glass_appbar.dart';
import '../../src/widgets/sheet_dialog.dart';
import '../../src/i18n/i18n.dart';
import 'plugin_delete.dart';

class PluginPage extends ConsumerStatefulWidget {
  const PluginPage({super.key, this.embedded = false});

  final bool embedded;

  @override
  ConsumerState<PluginPage> createState() => _PluginPageState();
}

class _PluginPageState extends ConsumerState<PluginPage> {
  bool _installing = false;
  bool _checkingUpdates = false;
  bool _togglingAll = false;
  bool _savingAutoUpdate = false;

  final _searchCtrl = TextEditingController();
  String _query = '';

  final Map<String, bool> _hasVars = {};
  bool _collectingVars = false;

  // 已检测出的插件更新结果缓存：点更新直接安装，免重复检测与弹窗（对齐桌面端）
  final Map<String, PluginUpdateCheckResult> _updateCheckResults = {};
  final Set<String> _updatingIds = {};

  @override
  void initState() {
    super.initState();
    _loadAutoUpdatePref();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _ensureVarsLoaded();
    });
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

  bool _autoUpdateOnStartup = false;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(pluginManagerProvider);
    final subscriptions = ref.watch(pluginSubscriptionsProvider);
    final scheme = Theme.of(context).colorScheme;

    final portraitFloating = !widget.embedded &&
        MediaQuery.of(context).orientation != Orientation.landscape &&
        (ref.watch(settingsProvider
                .select((s) => s.valueOrNull?.floatingSearchBar ?? false)) ==
            true);
    final contentTop = portraitFloating ? GlassTopBar.height(context) + 6 : null;

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
      backgroundColor: appScaffoldBackground(context, ref),
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          _listHost(
            portraitFloating,
            NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification is ScrollEndNotification) {
            _ensureVarsLoaded();
          }
          return false;
        },
        child: state.loading
            ? const Center(child: CircularProgressIndicator())
            : sources.isEmpty && subscriptions.isEmpty
                ? _EmptyState(onInstall: _showInstallSheet)
                : ReorderableListView.builder(
                  padding: EdgeInsets.fromLTRB(16, contentTop ?? 8, 16, 150),
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
                            Text(
                            tr('已安装插件'),
                            style: TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              tr('已启用 {enabled} / 共 {total}', {'enabled': sources.where((s) => s.enabled).length, 'total': sources.length}),
                              style: TextStyle(
                                  fontSize: 12, color: scheme.outline),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const Spacer(),
                          FilledButton.tonalIcon(
                            style: FilledButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10),
                              textStyle: const TextStyle(fontSize: 12.5),
                            ),
                            onPressed: (_togglingAll || sources.isEmpty)
                                ? null
                                : () => _toggleAllPlugins(!sources
                                    .every((s) => s.enabled)),
                            icon: _togglingAll
                                ? const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  )
                                : Icon(
                                    sources.every((s) => s.enabled)
                                        ? Icons.toggle_off_outlined
                                        : Icons.toggle_on_outlined,
                                    size: 16,
                                  ),
                            label: Text(_togglingAll
                                ? tr('处理中...')
                                : tr(sources.every((s) => s.enabled)
                                    ? '全部禁用'
                                    : '全部启用')),
                          ),
                          const SizedBox(width: 6),
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
                                ? tr('检查中...')
                                : tr('检查全部更新')),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _searchCtrl,
                        onChanged: (v) => setState(() => _query = v),
                        decoration: InputDecoration(
                          hintText: tr('搜索插件名称、平台或作者'),
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
                          fillColor: appCardFill(context, ref),
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
                              tr('未找到匹配的插件'),
                              style: TextStyle(
                                  fontSize: 13, color: scheme.onSurfaceVariant),
                            ),
                          ),
                        ),
                    ],
                  ),
                  proxyDecorator: (child, index, animation) =>
                      Material(type: MaterialType.transparency, child: child),
                  itemBuilder: (context, i) {
                    final source = filtered[i];
                    return RepaintBoundary(
                      key: ValueKey(source.id),
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _PluginCard(
                          source: source,
                          index: i,
                          dragEnabled: _query.isEmpty,
                          hasVars: _hasVars[source.id] == true,
                          onUpdate: (ctx) => _updatePlugin(ctx, source),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: widget.embedded
                  ? Container(
                      height: GlassTopBar.height(context),
                      alignment: Alignment.centerLeft,
                      padding: const EdgeInsets.only(left: 18, right: 6),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              tr('插件'),
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.settings_outlined),
                            tooltip: tr('插件设置'),
                            onPressed: _showPluginSettingsSheet,
                          ),
                          IconButton(
                            icon: const Icon(Icons.add),
                            tooltip: tr('安装插件'),
                            onPressed: _installing ? null : _showInstallSheet,
                          ),
                        ],
                      ),
                    )
                  : FlatTopBar(
                      leading: const BackButton(),
                      title: tr('插件'),
                      backgroundColor: appScaffoldBackground(context, ref),
                      actions: [
                        IconButton(
                          icon: const Icon(Icons.settings_outlined),
                          tooltip: tr('插件设置'),
                          onPressed: _showPluginSettingsSheet,
                        ),
                        IconButton(
                          icon: const Icon(Icons.add),
                          tooltip: tr('安装插件'),
                          onPressed: _installing ? null : _showInstallSheet,
                        ),
                      ],
                    ),
            ),
          ],
        ),
      );
  }

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

  void _showInstallSheet() {
    showSheetDialog<void>(
      context,
      (ctx) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
              Text(tr('安装插件'),
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 14),
            _InstallOption(
              icon: Icons.folder_open_outlined,
              title: tr('本地文件'),
              subtitle: tr('选择本地的插件脚本（.js / .txt）'),
              onTap: () {
                Navigator.pop(ctx);
                _pickLocalPlugin();
              },
            ),
            const SizedBox(height: 10),
            _InstallOption(
              icon: Icons.cloud_download_outlined,
              title: tr('在线链接'),
              subtitle: tr('输入 URL 安装，支持单个插件或插件集（JSON）批量'),
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
          showXianYuToast(context, tr('读取「{name}」失败或文件为空', {'name': f.name}));
          continue;
        }
        final script = utf8.decode(bytes, allowMalformed: true);
        await _install(script, f.name.isNotEmpty ? f.name : tr('本地插件'));
      } catch (e) {
        if (!mounted) return;
        showXianYuToast(context, tr('读取「{name}」失败：{e}', {'name': f.name, 'e': e}));
      }
    }
  }

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

  Future<void> _installUrl(String url) async {
    if (url.trim().isEmpty) return;
    final progress = showXianYuProgressToast(context, tr('正在导入插件...'));
    setState(() => _installing = true);
    try {
      final result = await ref
          .read(pluginManagerProvider.notifier)
          .installFromUrl(
            url,
            onProgress: (msg, p) => progress.update(msg, progress: p),
          );
      if (!mounted) return;
      if (result.success) {
        final summary = result.failCount > 0
            ? tr('成功 {ok} 个，失败 {fail} 个', {'ok': result.names.length, 'fail': result.failCount})
            : tr('成功 {ok} 个：{names}', {'ok': result.names.length, 'names': result.names.join('、')});
        progress.complete(tr('插件安装完成，{summary}', {'summary': summary}));
      } else {
        final detail = result.errors.isNotEmpty ? '（${result.errors.first}）' : '';
        progress.fail(tr('所有插件安装失败{detail}', {'detail': detail}));
      }
    } catch (e) {
      if (!mounted) return;
      final msg = e is PluginEngineException ? e.message : e.toString();
      progress.fail(tr('安装失败：{msg}', {'msg': msg}));
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
      showXianYuToast(context, tr('插件「{name}」安装成功', {'name': source.name}));
    } catch (e) {
      if (!mounted) return;
      final msg = e is PluginEngineException ? e.message : e.toString();
      showXianYuToast(context, tr('安装失败：{msg}', {'msg': msg}));
    } finally {
      if (mounted) setState(() => _installing = false);
    }
  }

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

  // 对齐桌面端：已检出更新则点击直接安装；未检出时先检测并提示再次点击，全程无确认弹窗
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
              tr('订阅链接 · {n}', {'n': subscriptions.length}),
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          tr('随插件同步到云端，点击可重新导入最新版本'),
          style: TextStyle(fontSize: 11, color: scheme.outline),
        ),
        const SizedBox(height: 8),
        for (final sub in subscriptions)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Material(
              color: appCardFill(context, ref),
              clipBehavior: Clip.antiAlias,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: BorderSide.none,
              ),
              child: InkWell(
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
                        tooltip: tr('移除订阅'),
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
          Text(tr('还没有安装插件'),
              style: TextStyle(color: scheme.onSurfaceVariant)),
          const SizedBox(height: 4),
          Text(
            tr('支持 LX / MusicFree 格式插件'),
            style: TextStyle(fontSize: 12, color: scheme.outline),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: onInstall,
            icon: const Icon(Icons.add),
            label:   Text(tr('安装插件')),
          ),
        ],
      ),
    );
  }
}

class _HoldDragStartListener extends StatefulWidget {
  const _HoldDragStartListener({required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  State<_HoldDragStartListener> createState() => _HoldDragStartListenerState();
}

class _DelayedDragRecognizerListener extends ReorderableDelayedDragStartListener {
  const _DelayedDragRecognizerListener({
    required super.child,
    required super.index,
  });

  @override
  MultiDragGestureRecognizer createRecognizer() {
    return DelayedMultiDragGestureRecognizer(
      delay: const Duration(milliseconds: 300),
      debugOwner: this,
    );
  }
}

class _HoldDragStartListenerState extends State<_HoldDragStartListener> {
  Timer? _haptic;

  void _onDown(PointerDownEvent _) {
    _haptic?.cancel();
    _haptic = Timer(const Duration(milliseconds: 300), () {
      if (mounted) HapticFeedback.mediumImpact();
    });
  }

  void _clear() {
    _haptic?.cancel();
    _haptic = null;
  }

  @override
  void dispose() {
    _clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _onDown,
      child: _DelayedDragRecognizerListener(
        index: widget.index,
        child: widget.child,
      ),
    );
  }
}

class _PluginCard extends ConsumerWidget {
  const _PluginCard({
    required this.source,
    required this.index,
    required this.dragEnabled,
    required this.hasVars,
    required this.onUpdate,
  });

  final PluginSource source;
  final int index;
  final bool dragEnabled;
  final bool hasVars;
  final Future<void> Function(BuildContext context) onUpdate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;

    Color iconBg;
    Color iconColor;
    if (source.format == PluginFormat.lx) {
      iconBg = const Color(0x1A22C55E);
      iconColor = const Color(0xFF22C55E);
    } else if (source.format == PluginFormat.anime) {
      iconBg = const Color(0x1AA855F7);
      iconColor = const Color(0xFFA855F7);
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

    final subText = [
      if (source.version.isNotEmpty) 'v${source.version}',
      if (source.author.isNotEmpty) source.author,
      if (source.description.isNotEmpty) source.description,
    ].join(' · ');

    final tagLabel = source.format == PluginFormat.lx
        ? tr('落雪')
        : source.format == PluginFormat.anime
            ? 'anime'
            : source.format == PluginFormat.musicfree
                ? (source.author.toLowerCase().contains('toskysun')
                    ? 'BakaMusic'
                    : 'MusicFree')
                : tr('未知');

    return Material(
      color: appCardFill(context, ref),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide.none,
      ),
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(50, 8, 8, 6),
            child: _buildBody(context, ref, scheme, iconBg, iconColor,
                subText, tagLabel),
          ),
        Positioned(
          left: 4,
          top: 0,
          bottom: 0,
          width: 36,
          child: Center(
            child: dragEnabled
                ? _HoldDragStartListener(
                    index: index,
                    child: Icon(Icons.drag_indicator,
                        size: 34, color: scheme.outline),
                  )
                : Icon(Icons.drag_indicator,
                    size: 34, color: scheme.outline),
          ),
        ),
      ],
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    WidgetRef ref,
    ColorScheme scheme,
    Color iconBg,
    Color iconColor,
    String subText,
    String tagLabel,
  ) {
    final manager = ref.read(pluginManagerProvider.notifier);

    final icon = Container(
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
    );

    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                pluginDisplayName(source),
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w600),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 6),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
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
            if (source.updateAvailable) ...[
              const SizedBox(width: 6),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: scheme.error.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(
                  tr('可更新'),
                  style: TextStyle(
                      fontSize: 10,
                      color: scheme.error,
                      fontWeight: FontWeight.w600),
                ),
              ),
            ],
            if (hasVars) ...[
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
            style: TextStyle(fontSize: 12, color: scheme.outline),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ],
    );

    final toggle = Switch(
      value: source.enabled,
      activeThumbColor: iconColor,
      onChanged: (_) => manager.toggleEnabled(source.id),
    );

    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _action(
          context,
          Icons.info_outline,
          tr('详情'),
          () => _openDetail(context, ref),
        ),
        const SizedBox(width: 4),
        _action(
          context,
          Icons.system_update_alt_outlined,
          tr('更新'),
          () => onUpdate(context),
          color: source.updateAvailable ? scheme.error : null,
        ),
        const SizedBox(width: 4),
        _action(
          context,
          Icons.delete_outline,
          tr('删除'),
          () => _confirmRemove(context, ref, manager),
        ),
      ],
    );

    final isWide =
        MediaQuery.orientationOf(context) == Orientation.landscape;

    if (isWide) {
      return Row(
        children: [
          icon,
          const SizedBox(width: 12),
          Expanded(child: info),
          const SizedBox(width: 8),
          actions,
          const SizedBox(width: 4),
          toggle,
        ],
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            icon,
            const SizedBox(width: 12),
            Expanded(child: info),
            const SizedBox(width: 6),
            toggle,
          ],
        ),
        const SizedBox(height: 4),
        actions,
      ],
    );
  }

  Widget _action(
    BuildContext context,
    IconData icon,
    String label,
    VoidCallback onTap, {
    Color? color,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final c = color ?? scheme.outline;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 17, color: c),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(fontSize: 13, color: c),
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

  void _confirmRemove(BuildContext context, WidgetRef ref, PluginManager manager) {
    unawaited(confirmRemovePlugin(context, ref, source));
  }
}

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
        showXianYuToast(context, tr('「{name}」为必填项', {'name': v.title ?? v.name}));
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
      showXianYuToast(context, tr('已保存用户变量，开始生效'));
    } catch (e) {
      if (!mounted) return;
      showXianYuToast(context, tr('保存失败：{e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final formatLabel = switch (source.format) {
      PluginFormat.lx => tr('落雪格式'),
      PluginFormat.anime => 'anime 格式',
      _ => tr('MusicFree 格式'),
    };

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
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.72,
          ),
          child: ListView(
            shrinkWrap: true,
            children: [
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
                        Text(pluginDisplayName(source),
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
              row(tr('版本'), source.version.isEmpty ? '—' : 'v${source.version}'),
              row(tr('作者'), source.author.isEmpty ? '—' : source.author),
              if (source.description.isNotEmpty) row(tr('描述'), source.description),
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 64,
                      child: Text(tr('链接'),
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
              if (!_loading && _vars.isNotEmpty) ...[
                const Divider(height: 8),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(Icons.tune_outlined,
                        size: 18, color: scheme.primary),
                    const SizedBox(width: 8),
                      Expanded(
                      child: Text(tr('用户变量'),
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
                        child:   Text(tr('保存')),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(tr('保存后插件将重新加载并应用新的变量值'),
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

class _UrlInstallSheet extends StatefulWidget {
  const _UrlInstallSheet({required this.onInstallUrl});
  final Future<void> Function(String url) onInstallUrl;

  @override
  State<_UrlInstallSheet> createState() => _UrlInstallSheetState();
}

class _UrlInstallSheetState extends State<_UrlInstallSheet> {
  final _urlCtrl = TextEditingController();
  bool _loading = false;

  @override
  void dispose() {
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
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
              Text(tr('在线链接安装'),
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(
              tr('支持 LX（落雪）与 MusicFree 格式，链接可为单个插件或插件集（JSON）'),
              style: TextStyle(fontSize: 12, color: scheme.outline),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _urlCtrl,
              autofocus: true,
              decoration:   InputDecoration(
                labelText: tr('插件 URL'),
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
                  child:   Text(tr('取消')),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _loading ? null : _installFromUrl,
                  icon: _loading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.download, size: 18),
                  label:   Text(tr('安装')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _InstallOption extends ConsumerWidget {
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
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: appCardFill(context, ref),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide.none,
      ),
      child: InkWell(
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

