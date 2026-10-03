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
import '../../src/navigation/shell.dart';
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
import '../../src/widgets/source_tag.dart';
import '../../src/i18n/i18n.dart';
import 'plugin_delete.dart';
part 'plugin_page.list.dart';
part 'plugin_page.install.dart';
part 'plugin_page.updates.dart';
part 'plugin_page.settings.dart';
part 'plugin_page.cards.dart';
part 'plugin_page.detail_sheet.dart';
part 'plugin_page.install_sheets.dart';

class PluginPage extends ConsumerStatefulWidget {
  const PluginPage({super.key, this.embedded = false});

  final bool embedded;

  @override
  ConsumerState<PluginPage> createState() => _PluginPageState();
}

class _PluginPageState extends ConsumerState<PluginPage>
    with HidesShellChrome {
  bool _installing = false;
  bool _checkingUpdates = false;
  bool _togglingAll = false;
  bool _savingAutoUpdate = false;

  // 在线链接安装的取消状态与进度小黑条句柄（弹窗返回/取消键触发终止）
  bool _urlInstallCancelled = false;
  XianYuProgressToastHandle? _urlInstallProgress;

  final _searchCtrl = TextEditingController();
  String _query = '';

  final Map<String, bool> _hasVars = {};
  bool _collectingVars = false;

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

}
