import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../src/widgets/flat_top_bar.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/core/app_colors.dart';
import '../../src/core/application_logger.dart';
import '../../src/auth/account_api.dart';
import '../../src/cloud/cloud_credentials_store.dart';
import '../../src/cloud/cloud_registry.dart';
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
import '../../src/widgets/glass_settings.dart';
import '../../src/widgets/page_search_bar.dart';
import '../../src/widgets/press_scale.dart';
import '../../src/widgets/predictive_dialog_route.dart';
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
  const PluginPage({
    super.key,
    this.embedded = false,
    this.asShellBranch = false,
    this.showBack = true,
  });

  final bool embedded;

  /// 作为导航栏分支页嵌入（embedded: true 时生效）：标题与右上角动作
  /// 上交壳层顶栏（shellTopBarOverrideProvider），页面自身纯内容；
  /// 竖屏由壳顶栏避让，横屏壳顶栏隐藏时页面自带无返回 FlatTopBar
  final bool asShellBranch;

  /// 自带顶栏是否显示返回键；cover 页（/plugin-manage）用，分支页不经过
  final bool showBack;

  @override
  ConsumerState<PluginPage> createState() => _PluginPageState();
}

class _PageRow {
  const _PageRow.plugin(this.plugin) : cloudProviderId = null;
  const _PageRow.cloud(this.cloudProviderId) : plugin = null;

  final PluginSource? plugin;
  final String? cloudProviderId;

  String get key => plugin?.id ?? 'cloud:$cloudProviderId';
}

class _PluginPageState extends ConsumerState<PluginPage> with HidesShellChrome {
  // 分支模式复用壳顶栏/底栏（公共容器），不隐藏壳 chrome
  @override
  bool get hidesChrome => !(widget.embedded && widget.asShellBranch);

  // dispose 时清除顶栏注册：缓存 StateController（原因同 HidesShellChrome，
  // 嵌套壁纸 ProviderScope 销毁后 container.read 不安全）
  StateController<ShellTopBarOverride?>? _topBarOverrideController;

  bool _installing = false;
  bool _checkingUpdates = false;
  bool _togglingAll = false;
  bool _savingAutoUpdate = false;

  // 网盘伪音源行：每个已绑定网盘一条（开关/排序/删除=解绑），配置存 PluginPreferences
  Map<String, int> _cloudAccountCounts = {};
  Map<String, CloudSourcePref> _cloudPrefs = {};
  List<_PageRow> _rows = const [];
  late final void Function() _cloudListenerReg = _onCloudStoreChanged;

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
    if (widget.embedded && widget.asShellBranch) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _topBarOverrideController = ProviderScope.containerOf(
          context,
          listen: false,
        ).read(shellTopBarOverrideProvider.notifier);
        _syncTopBarOverride();
      });
    }
    _loadAutoUpdatePref();
    CloudCredentialsStore.instance.addListener(_cloudListenerReg);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _ensureVarsLoaded();
        _loadCloudState();
      }
    });
  }

  /// 标题与右上角动作上交壳层顶栏：竖屏与首页/我的同款公共容器；
  /// 横屏 chrome 为覆盖式，上交的动作会悬在弹窗之上（还能交互），
  /// 且与页内头部行重复——横屏不上交，改由头部行自带入口
  bool? _overrideSentLandscape;
  void _syncTopBarOverride() {
    final controller = _topBarOverrideController;
    if (controller == null || !widget.embedded || !widget.asShellBranch) {
      return;
    }
    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    if (_overrideSentLandscape == landscape) return;
    _overrideSentLandscape = landscape;
    controller.state = landscape
        ? null
        : ShellTopBarOverride(
            title: '插件管理',
            actions: [
              ShellTopBarAction(
                icon: Icons.settings_outlined,
                tooltip: '插件设置',
                onPressed: _showPluginSettingsSheet,
              ),
              ShellTopBarAction(
                icon: Icons.add,
                tooltip: '安装插件',
                onPressed: _showInstallSheet,
              ),
            ],
          );
  }

  @override
  void dispose() {
    final overrideController = _topBarOverrideController;
    _topBarOverrideController = null;
    if (overrideController != null && overrideController.state != null) {
      overrideController.state = null;
    }
    _searchCtrl.dispose();
    CloudCredentialsStore.instance.removeListener(_cloudListenerReg);
    super.dispose();
  }

  void _onCloudStoreChanged() {
    if (mounted) _loadCloudState();
  }

  Future<void> _loadCloudState() async {
    final counts = <String, int>{};
    for (final p in cloudProviders) {
      try {
        counts[p.id] = (await CloudCredentialsStore.instance.accountsFor(
          p.id,
        )).length;
      } catch (_) {
        counts[p.id] = 0; // 单盘查询失败不影响其余
      }
    }
    final prefs = await PluginPreferences.getCloudSources();
    if (!mounted) return;
    setState(() {
      _cloudAccountCounts = counts;
      _cloudPrefs = prefs;
    });
  }

  /// 每个已绑定网盘独立开关：关闭后搜索来源不含该盘、不再拉取
  Future<void> _toggleCloudSource(String providerId) async {
    final cur = _cloudPrefs[providerId]?.enabled ?? true;
    await PluginPreferences.setCloudSourcePref(providerId, enabled: !cur);
    if (!mounted) return;
    setState(() {
      _cloudPrefs[providerId] = CloudSourcePref(
        enabled: !cur,
        sortIndex: _cloudPrefs[providerId]?.sortIndex,
      );
    });
  }

  /// 展示行 = 插件行 + 已绑定网盘行（未绑定不显示；搜索过滤时只留插件行）。
  /// 网盘行按 sortIndex（前方插件数）插入第一个 sortOrder >= idx 的插件之前。
  List<_PageRow> _buildRows(List<PluginSource> filteredPlugins) {
    final rows = [for (final s in filteredPlugins) _PageRow.plugin(s)];
    if (_query.trim().isNotEmpty) return rows;
    final cloudRows = <_PageRow>[
      for (final p in cloudProviders)
        if ((_cloudAccountCounts[p.id] ?? 0) > 0) _PageRow.cloud(p.id),
    ];
    cloudRows.sort((a, b) {
      final ia = _cloudPrefs[a.cloudProviderId]?.sortIndex ?? 1 << 30;
      final ib = _cloudPrefs[b.cloudProviderId]?.sortIndex ?? 1 << 30;
      return ia - ib;
    });
    final merged = <_PageRow>[];
    var ci = 0;
    for (final row in rows) {
      final pIdx = row.plugin?.sortOrder ?? 0;
      while (ci < cloudRows.length) {
        final cIdx = _cloudPrefs[cloudRows[ci].cloudProviderId]?.sortIndex;
        if (cIdx == null || cIdx > pIdx) break;
        merged.add(cloudRows[ci++]);
      }
      merged.add(row);
    }
    while (ci < cloudRows.length) {
      merged.add(cloudRows[ci++]);
    }
    return merged;
  }

  /// 删除网盘音源：确认后解绑该盘全部账号
  Future<void> _confirmRemoveCloudSource(String providerId) async {
    final name = cloudProviders
        .where((p) => p.id == providerId)
        .map((p) => p.displayName)
        .firstOrNull;
    final count = _cloudAccountCounts[providerId] ?? 0;
    final ok = await showPredictiveDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('删除网盘音源「{name}」', {'name': name ?? providerId})),
        content: Text(tr('将同时解绑其下 {n} 个已绑定的网盘账号，绑定信息将无法恢复。', {'n': count})),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('取消')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('删除')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final accounts = await CloudCredentialsStore.instance.accountsFor(
        providerId,
      );
      for (final account in accounts) {
        await CloudCredentialsStore.instance.removeAccount(
          providerId,
          account.accountId,
        );
      }
      if (!mounted) return;
      showXianYuToast(
        context,
        tr('已删除「{name}」音源并解绑 {n} 个账号', {
          'name': name ?? providerId,
          'n': accounts.length,
        }),
      );
      await _loadCloudState();
    } catch (e) {
      AppLog.warn('plugin', '解绑网盘账号失败: $e');
      if (mounted) showXianYuToast(context, tr('删除失败，请重试'));
    }
  }

  bool _autoUpdateOnStartup = false;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(pluginManagerProvider);
    final subscriptions = ref.watch(pluginSubscriptionsProvider);
    final scheme = Theme.of(context).colorScheme;

    final portraitFloating =
        !widget.embedded &&
        MediaQuery.of(context).orientation != Orientation.landscape &&
        (ref.watch(
              settingsProvider.select(
                (s) => s.valueOrNull?.floatingSearchBar ?? false,
              ),
            ) ==
            true);
    final contentTop = portraitFloating
        ? GlassTopBar.height(context) + 6
        : null;
    final branchMode = widget.embedded && widget.asShellBranch;
    final landscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    // 分支模式竖屏：壳顶栏（GlassTopBar+搜索条）避让，与首页/我的同款；
    // 横屏：壳顶栏隐藏（守卫仅 0/1），页面自带无返回 FlatTopBar 避让
    // 横屏面板：宿主顶栏改覆盖式（悬浮/固定同构），列表全屏铺、自带
    // 标题带换 GlassTopBar，内容从带下穿过被实时模糊
    final embeddedPanel = widget.embedded && !widget.asShellBranch;
    final topInset = branchMode
        ? (landscape
              ? (portraitFloating
                  // 悬浮态：shell 悬浮 chrome 贴顶，页面垫 chrome 高 + 呼吸间距
                  ? FlatTopBar.height(context) + 18
                  // 固定态：shell 固定带（topInset 8）盖住顶部，垫带高+呼吸
                  : GlassTopBar.height(context, topInset: 8) + 12)
              : GlassTopBar.height(
                  context,
                  bottom: PageSearchBarBottom(onTap: () {}),
                ))
        : (contentTop ??
              (embeddedPanel ? landscapePanelBand(context, ref) + 8 : 8));

    final sources = state.sources;
    // 横竖屏切换时同步壳顶栏动作的上交/撤回（横屏撤回见 _syncTopBarOverride）
    if (branchMode) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _syncTopBarOverride();
      });
    }
    final q = _query.trim().toLowerCase();
    final filtered = q.isEmpty
        ? sources
        : sources
              .where(
                (s) =>
                    s.name.toLowerCase().contains(q) ||
                    s.author.toLowerCase().contains(q) ||
                    s.sources.join(',').toLowerCase().contains(q),
              )
              .toList();
    final rows = _buildRows(filtered);
    _rows = rows;
    final searchingNoMatch = q.isNotEmpty && filtered.isEmpty;

    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: Stack(
        clipBehavior: Clip.none,
        children: [
          _listHost(
            // 分支模式/横屏面板页面自管避让（topInset 已含顶栏），
            // floating 路径 = Positioned.fill 不再垫 padding，否则与
            // _listHost 内层的 GlassTopBar.height 双倍叠加出空白
            portraitFloating || branchMode || embeddedPanel,
            NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                if (notification is ScrollEndNotification) {
                  _ensureVarsLoaded();
                }
                return false;
              },
              child: state.loading
                  ? const Center(child: CircularProgressIndicator())
                  : sources.isEmpty && subscriptions.isEmpty && rows.isEmpty
                  ? _EmptyState(onInstall: _showInstallSheet)
                  : ReorderableListView.builder(
                      padding: EdgeInsets.fromLTRB(16, topInset, 16, 150),
                      buildDefaultDragHandles: false,
                      itemCount: searchingNoMatch ? 0 : rows.length,
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
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(width: 8),
                              // Expanded 吃满剩余：按钮组恒贴行尾（横屏宽屏
                              // 不会因 Flexible+Spacer 平分余量而悬在中间）
                              Expanded(
                                child: Text(
                                  tr('已启用 {enabled} / 共 {total}', {
                                    'enabled': sources
                                        .where((s) => s.enabled)
                                        .length,
                                    'total': sources.length,
                                  }),
                                  style: TextStyle(
                                    fontSize: 12,
                                    // onSurfaceVariant 在壁纸文字「跟随主题」
                                    // 模式下不翻转，铺壁纸上发灰；用统一次要前景
                                    color: appSecondaryFg(scheme),
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: 4),
                              // 横屏分支：设置/安装不上交壳顶栏（覆盖式
                              // chrome 会把动作悬在弹窗上），改由头部行自带
                              if (branchMode && landscape) ...[
                                IconButton(
                                  visualDensity: VisualDensity.compact,
                                  color: appSecondaryFg(scheme),
                                  tooltip: tr('插件设置'),
                                  onPressed: _showPluginSettingsSheet,
                                  icon: const Icon(
                                    Icons.settings_outlined,
                                    size: 20,
                                  ),
                                ),
                                IconButton(
                                  visualDensity: VisualDensity.compact,
                                  color: appSecondaryFg(scheme),
                                  tooltip: tr('安装插件'),
                                  onPressed: _installing
                                      ? null
                                      : _showInstallSheet,
                                  icon: const Icon(Icons.add, size: 22),
                                ),
                                const SizedBox(width: 4),
                              ],
                              FilledButton.tonalIcon(
                                style: FilledButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                  ),
                                  textStyle: const TextStyle(fontSize: 12.5),
                                ),
                                onPressed: (_togglingAll || sources.isEmpty)
                                    ? null
                                    : () => _toggleAllPlugins(
                                        !sources.every((s) => s.enabled),
                                      ),
                                icon: _togglingAll
                                    ? const SizedBox(
                                        width: 14,
                                        height: 14,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : Icon(
                                        sources.every((s) => s.enabled)
                                            ? Icons.toggle_off_outlined
                                            : Icons.toggle_on_outlined,
                                        size: 16,
                                      ),
                                label: Text(
                                  _togglingAll
                                      ? tr('处理中...')
                                      : tr(
                                          sources.every((s) => s.enabled)
                                              ? '全部禁用'
                                              : '全部启用',
                                        ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              FilledButton.tonalIcon(
                                style: FilledButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                  ),
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
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(
                                        Icons.system_update_alt_outlined,
                                        size: 16,
                                      ),
                                label: Text(
                                  _checkingUpdates
                                      ? tr('检查中...')
                                      : tr('检查全部更新'),
                                ),
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
                                    fontSize: 13,
                                    color: appSecondaryFg(scheme),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                      // 对齐导航栏管理的拖起浮层：elevation 随拖拽进度升起
                      proxyDecorator: (child, index, animation) =>
                          AnimatedBuilder(
                            animation: animation,
                            builder: (context, child) {
                              final t = Curves.easeInOut.transform(
                                animation.value,
                              );
                              return Material(
                                color: Colors.transparent,
                                elevation: t * 6,
                                shadowColor: Theme.of(context)
                                    .colorScheme
                                    .shadow
                                    .withValues(alpha: t * 0.25),
                                child: child,
                              );
                            },
                            child: child,
                          ),
                      itemBuilder: (context, i) {
                        final row = _rows[i];
                        final plugin = row.plugin;
                        return RepaintBoundary(
                          key: ValueKey(row.key),
                          child: Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: plugin != null
                                ? _PluginCard(
                                    source: plugin,
                                    index: i,
                                    dragEnabled: _query.isEmpty,
                                    hasVars: _hasVars[plugin.id] == true,
                                    onUpdate: (ctx) =>
                                        _updatePlugin(ctx, plugin),
                                  )
                                : _CloudCard(
                                    providerId: row.cloudProviderId!,
                                    index: i,
                                    dragEnabled: _query.isEmpty,
                                    accountCount:
                                        _cloudAccountCounts[row
                                            .cloudProviderId!] ??
                                        0,
                                    enabled:
                                        _cloudPrefs[row.cloudProviderId!]
                                            ?.enabled ??
                                        true,
                                    onToggle: () => _toggleCloudSource(
                                      row.cloudProviderId!,
                                    ),
                                    onRemove: () => _confirmRemoveCloudSource(
                                      row.cloudProviderId!,
                                    ),
                                  ),
                          ),
                        );
                      },
                    ),
            ),
          ),
          Positioned(
            top: 0,
            // 嵌入面板：统一带（页面级）只铺到分割条右缘，此头从面板左
            // 缘原位起排与其相接；其余分支原位
            left: 0,
            right: 0,
            // 分支模式：标题/动作不页面自绘（竖屏上交壳顶栏、横屏由
            // 头部行自带），只交给列表 topInset 避让
            child: branchMode
                ? const SizedBox.shrink()
                : widget.embedded
                ? GlassTopBar(
                    // 独立回读：统一带先画，同组会复用其制备纹理
                    sharedNavGroup: false,
                    titleSpacing: 18,
                    title: Text(
                      tr('插件'),
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
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
                  )
                : FlatTopBar(
                    leading: widget.showBack ? const BackButton() : null,
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
