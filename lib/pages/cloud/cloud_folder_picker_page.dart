import 'dart:async';

import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../src/cloud/cloud_credentials_store.dart';
import '../../src/cloud/cloud_folder_selection_store.dart';
import '../../src/cloud/cloud_provider.dart';
import '../../src/cloud/cloud_registry.dart';
import '../../src/cloud/cloud_types.dart';
import '../../src/core/app_colors.dart';
import '../../src/core/application_logger.dart';
import '../../src/i18n/i18n.dart';
import '../../src/navigation/shell.dart';
import '../../src/widgets/app_toast.dart';
import '../../src/widgets/glass_appbar.dart';
import '../../src/widgets/glass_settings.dart';

/// 网盘文件夹选择页：浏览当前账号网盘目录，勾选一个或多个文件夹路径。
///
/// 路径语义与 [CloudBrowserPage] 一致：path 型盘存条目绝对路径，
/// id 型盘回退存目录 id。勾选跨目录累积，保存时整体覆盖写入
/// [CloudFolderSelectionStore]。
class CloudFolderPickerPage extends ConsumerStatefulWidget {
  const CloudFolderPickerPage({
    super.key,
    required this.providerId,
    required this.accountId,
    this.embedded = false,
  });

  final String providerId;
  final String accountId;

  /// 横屏设置面板嵌入：不画自身 Scaffold/顶栏，保存后回网盘面板
  final bool embedded;

  @override
  ConsumerState<CloudFolderPickerPage> createState() =>
      _CloudFolderPickerPageState();
}

class _Crumb {
  const _Crumb(this.path, this.name);
  final String path;
  final String name;
}

class _CloudFolderPickerPageState extends ConsumerState<CloudFolderPickerPage> {
  late final CloudProvider _provider;
  late String _accountId;

  final List<_Crumb> _stack = [];
  List<CloudFile> _dirs = const [];
  List<CloudFile> _files = const [];
  String? _cursor;
  bool _loading = true;
  bool _appending = false;
  bool _saving = false;

  final Set<String> _selected = {};

  /// 已选目录名称缓存（纯展示）：id 型盘的存储键是 id 串，键不在面包屑
  /// 栈/当前列表时 chip 显示可读名全靠它；勾选与浏览命中时回写落盘
  Map<String, String> _names = const {};

  @override
  void initState() {
    super.initState();
    _provider = cloudProviderById(widget.providerId)!;
    _init();
  }

  Future<void> _init() async {
    final accounts = await CloudCredentialsStore.instance.accountsFor(
      _provider.id,
    );
    if (!mounted) return;
    final valid = accounts.any((a) => a.accountId == widget.accountId)
        ? widget.accountId
        : (accounts.isNotEmpty ? accounts.first.accountId : null);
    if (valid == null) {
      setState(() => _loading = false);
      return;
    }
    _accountId = valid;
    final saved = await CloudFolderSelectionStore.instance.pathsFor(
      _provider.id,
      valid,
    );
    final names = await CloudFolderNameCache.instance.namesFor(
      _provider.id,
      valid,
    );
    if (!mounted) return;
    setState(() {
      _selected.addAll(saved);
      _names = names;
      _stack
        ..clear()
        ..add(_Crumb(_provider.rootPath, tr('全部文件')));
    });
    _load();
  }

  Future<Map<String, String>> _cred() async {
    final cred = await CloudCredentialsStore.instance.credFor(
      _provider.id,
      _accountId,
    );
    if (cred != null) return cred;
    final sole = await CloudCredentialsStore.instance.soleCredFor(_provider.id);
    return sole ?? const {};
  }

  /// 进入子目录：与浏览页同款语义（path 优先，回退 id）。
  void _enter(String name, String? entryPath, String entryId) {
    final cur = _stack.last.path;
    final next = (entryPath != null && entryPath.isNotEmpty && entryPath != cur)
        ? entryPath
        : entryId;
    setState(() => _stack.add(_Crumb(next, name)));
    _load();
  }

  void _jumpTo(int index) {
    if (index == _stack.length - 1) return;
    setState(() => _stack.removeRange(index + 1, _stack.length));
    _load();
  }

  Future<void> _load({bool more = false}) async {
    if (more && (_cursor == null || _appending)) return;
    if (_stack.isEmpty) return;
    final path = _stack.last.path;
    if (!mounted) return;
    setState(() {
      if (more) {
        _appending = true;
      } else {
        _loading = true;
        _dirs = const [];
        _files = const [];
        _cursor = null;
      }
    });
    try {
      final cred = await _cred();
      final r = await _provider.listDir(
        cred,
        path,
        cursor: more ? _cursor : null,
      );
      if (!mounted || _stack.isEmpty || _stack.last.path != path) return;
      // 名称 heal：当前列表命中的已选键回填缓存——跨设备同步来的选择
      //（本地无名称记录）首次浏览到其父目录即可显示可读名；setState
      // 内合并，chip 当帧从原始 id 换成可读名
      final heal = <String, String>{};
      for (final d in _dirs) {
        final k = _entryKey(d);
        if (_selected.contains(k)) heal[k] = d.name;
      }
      setState(() {
        _dirs = r.files.where((f) => f.isDir).toList();
        _files = r.files.where((f) => !f.isDir).toList();
        _cursor = r.nextCursor;
        _loading = false;
        _appending = false;
        if (heal.isNotEmpty) _names = {..._names, ...heal};
      });
      if (heal.isNotEmpty) {
        unawaited(
          CloudFolderNameCache.instance.remember(
            _provider.id,
            _accountId,
            heal,
          ),
        );
      }
    } catch (e) {
      if (!mounted || _stack.isEmpty || _stack.last.path != path) return;
      AppLog.warn('cloud', '选择器列目录失败 path=$path: $e');
      setState(() {
        _loading = false;
        _appending = false;
      });
      showXianYuToast(context, e is CloudException ? e.message : tr('目录加载失败'));
    }
  }

  /// 当前目录的存储键（path 型盘为绝对路径，id 型盘为 id 串）。
  void _toggleCurrent() {
    if (_stack.isEmpty) return;
    final path = _stack.last.path;
    setState(() {
      if (!_selected.remove(path)) {
        _selected.add(path);
        _rememberName({path: _stack.last.name});
      }
    });
  }

  /// 名称缓存回写（只增改不删，落盘去抖在缓存内部）
  void _rememberName(Map<String, String> entries) {
    if (entries.isEmpty) return;
    _names = {..._names, ...entries};
    unawaited(
      CloudFolderNameCache.instance.remember(_provider.id, _accountId, entries),
    );
  }

  /// 列表条目的存储键（path 优先，回退 id），与勾选写入同口径
  String _entryKey(CloudFile d) {
    final cur = _stack.isNotEmpty ? _stack.last.path : null;
    return (d.path != null && d.path!.isNotEmpty && d.path != cur)
        ? d.path!
        : d.id;
  }

  void _toggleEntry(String name, String? entryPath, String entryId) {
    final cur = _stack.last.path;
    final key = (entryPath != null && entryPath.isNotEmpty && entryPath != cur)
        ? entryPath
        : entryId;
    setState(() {
      if (!_selected.remove(key)) {
        _selected.add(key);
        _rememberName({key: name});
      }
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    await CloudFolderSelectionStore.instance.setPaths(
      _provider.id,
      _accountId,
      _selected.toList(),
    );
    if (!mounted) return;
    showXianYuToast(context, tr('已保存 {n} 个文件夹', {'n': '${_selected.length}'}));
    // 嵌入面板模式切回网盘面板（宿主重建本页刷新已选数）；独立页出栈。
    // 详情面板语境（设置面板未开）收起详情回宿主面板
    if (widget.embedded) {
      if (ref.read(landscapeSettingsCategoryProvider) != null) {
        ref.read(landscapeSettingsCategoryProvider.notifier).state = '/cloud';
      } else {
        ref.read(landscapeDetailProvider.notifier).state = null;
      }
    } else {
      context.pop();
    }
  }

  String _dirNameOf(String path) {
    for (final c in _stack) {
      if (c.path == path) return c.name;
    }
    for (final d in _dirs) {
      if (_entryKey(d) == path) return d.name;
    }
    final cached = _names[path];
    if (cached != null && cached.isNotEmpty) return cached;
    final idx = path.lastIndexOf('/');
    return idx >= 0 && idx < path.length - 1 ? path.substring(idx + 1) : path;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final currentSelected =
        _stack.isNotEmpty && _selected.contains(_stack.last.path);
    final landscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    if (widget.embedded) {
      // 与 CloudBindPage.embedded 同款：裸内容列，标题由面板宿主统一带
      // head 位绘制；顶距自垫栏高，面包屑/工具行/列表/底条结构不变
      final panelBand = landscapePanelBand(context, ref);
      return RepaintBoundary(
        child: Column(
          children: [
            SizedBox(height: panelBand),
            Expanded(
              child: Column(
                children: [
                  if (_selected.isNotEmpty) _selectedChips(context, scheme),
                  if (_stack.isNotEmpty) _breadcrumb(context, scheme),
                  if (_stack.isNotEmpty)
                    _toolbar(context, scheme, currentSelected),
                  Expanded(child: _list(context, scheme)),
                  _bottomBar(context, scheme),
                ],
              ),
            ),
          ],
        ),
      );
    }
    return Scaffold(
      backgroundColor: appScaffoldBackground(context, ref),
      body: Stack(
        children: [
          Column(
            children: [
              SizedBox(height: GlassTopBar.height(context)),
              Expanded(
                // 横屏内容收窄居中（选择器口径），竖屏照旧全幅
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: landscape ? 560 : double.infinity,
                    ),
                    child: Column(
                      children: [
                        if (_selected.isNotEmpty)
                          _selectedChips(context, scheme),
                        if (_stack.isNotEmpty) _breadcrumb(context, scheme),
                        if (_stack.isNotEmpty)
                          _toolbar(context, scheme, currentSelected),
                        Expanded(child: _list(context, scheme)),
                        _bottomBar(context, scheme),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: GlassTopBar(
              // 横屏时挖孔在左缘，返回钮内推避让（与设置统一带同口径）
              leadingIndent: MediaQuery.paddingOf(context).left,
              leading: const BackButton(),
              title: Text(tr('选择文件夹')),
            ),
          ),
        ],
      ),
    );
  }

  Widget _selectedChips(BuildContext context, ColorScheme scheme) {
    final keys = _selected.toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final k in keys)
              Chip(
                label: Text(
                  _dirNameOf(k),
                  style: TextStyle(
                    fontSize: 12,
                    // 壁纸模式下 Chip 默认底色是不透明白块，改卡片感知填充
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                backgroundColor: appCardFill(context, ref),
                side: BorderSide(
                  color: scheme.outlineVariant.withValues(alpha: 0.6),
                ),
                visualDensity: VisualDensity.compact,
                onDeleted: () => setState(() => _selected.remove(k)),
              ),
          ],
        ),
      ),
    );
  }

  /// 行首图标容器：软色调圆角方块，与个人中心/网盘页的图标语言一致
  Widget _iconBox(
    BuildContext context,
    ColorScheme scheme,
    IconData icon, {
    bool active = true,
  }) {
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: active
            ? scheme.primary.withValues(alpha: 0.10)
            : scheme.onSurfaceVariant.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(
        icon,
        size: 20,
        color: active ? scheme.primary : scheme.onSurfaceVariant,
      ),
    );
  }

  Widget _breadcrumb(BuildContext context, ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          reverse: true,
          child: Row(
            children: [
              for (var i = 0; i < _stack.length; i++) ...[
                if (i > 0)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: Text(
                      '›',
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
                      ),
                    ),
                  ),
                InkWell(
                  onTap: () => _jumpTo(i),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: Text(
                      _stack[i].name,
                      style: TextStyle(
                        fontSize: 12,
                        color: i == _stack.length - 1
                            ? scheme.onSurface
                            : scheme.primary,
                        fontWeight: i == _stack.length - 1
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _list(BuildContext context, ColorScheme scheme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_dirs.isEmpty && _files.isEmpty) {
      return Center(
        child: Text(
          tr('此文件夹为空'),
          style: TextStyle(
            fontSize: 13,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
          ),
        ),
      );
    }
    // 单卡包裹全部条目：卡高随内容收缩（内容少时不撑满整屏），
    // 内容多时整体滚动
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: frostedCardSurface(
        context: context,
        ref: ref,
        radius: 16,
        child: Column(
          children: [
            for (var i = 0; i < _dirs.length; i++) ...[
              if (i > 0) _rowDivider(scheme),
              _dirRow(_dirs[i], _entryKey(_dirs[i]), scheme),
            ],
            if (_dirs.isNotEmpty && _files.isNotEmpty) _rowDivider(scheme),
            for (var j = 0; j < _files.length; j++) ...[
              if (j > 0) _rowDivider(scheme),
              _fileRow(_files[j], scheme),
            ],
            if (_cursor != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Center(
                  child: _appending
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : TextButton(
                          onPressed: () => _load(more: true),
                          child: Text(tr('加载更多')),
                        ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 卡片内行间细分隔线（缩进避让行首图标）
  Widget _rowDivider(ColorScheme scheme) {
    return Divider(
      height: 1,
      indent: 54,
      endIndent: 14,
      thickness: 0.5,
      color: scheme.onSurface.withValues(alpha: 0.08),
    );
  }

  /// 文件夹行：点行进入目录，点行尾圆勾仅切换勾选
  Widget _dirRow(CloudFile d, String key, ColorScheme scheme) {
    final checked = _selected.contains(key);
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: () => _enter(d.name, d.path, d.id),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 7, 6, 7),
          child: Row(
            children: [
              _iconBox(context, scheme, Icons.folder_rounded),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  d.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14),
                ),
              ),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _toggleEntry(d.name, d.path, d.id),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: _RoundCheck(checked: checked),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 当前目录下的文件展示行（与文件夹行同样式，仅无勾选框、不可进入）。
  Widget _fileRow(CloudFile f, ColorScheme scheme) {
    const audioExts = {
      '.mp3',
      '.flac',
      '.m4a',
      '.aac',
      '.wav',
      '.ogg',
      '.ape',
      '.wma',
      '.opus',
      '.dsf',
      '.dff',
      '.mka',
    };
    final name = f.name.toLowerCase();
    final isAudio = audioExts.any((e) => name.endsWith(e));
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 7, 14, 7),
      child: Row(
        children: [
          _iconBox(
            context,
            scheme,
            isAudio
                ? Icons.music_note_rounded
                : Icons.insert_drive_file_rounded,
            active: isAudio,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              f.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                color: isAudio
                    ? scheme.onSurface
                    : scheme.onSurfaceVariant.withValues(alpha: 0.7),
              ),
            ),
          ),
          // 与文件夹行行尾勾选区同宽的占位，保证两种行高一致
          const SizedBox(width: 38),
        ],
      ),
    );
  }

  /// 列表上方操作行：返回上一级 + 选择当前目录（独立于底栏保存区）
  Widget _toolbar(
    BuildContext context,
    ColorScheme scheme,
    bool currentSelected,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Row(
        // 三个操作按钮作为整组视觉居中
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          OutlinedButton(
            // 根目录（面包屑只剩"全部文件"）时不可再返回
            onPressed: _stack.length > 1
                ? () => _jumpTo(_stack.length - 2)
                : null,
            child: Text(tr('返回上一级')),
          ),
          const SizedBox(width: 8),
          // 选择当前目录：选中态用 tonal 填充 + 对勾，与保存的主按钮区分层级
          if (currentSelected)
            FilledButton.tonal(
              onPressed: _toggleCurrent,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.check_rounded, size: 18, color: scheme.primary),
                  const SizedBox(width: 4),
                  Text(tr('选择当前')),
                ],
              ),
            )
          else
            OutlinedButton(
              onPressed: _toggleCurrent,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.folder_special_rounded,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Text(tr('选择当前')),
                ],
              ),
            ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(tr('确认保存')),
          ),
        ],
      ),
    );
  }

  /// 底部状态条：仅展示已选计数，材质与顶栏/固定底栏同源
  /// （fixedNavBarSurfaceFill 填充 + 导航面档位 sigma + 回读组）
  Widget _bottomBar(BuildContext context, ColorScheme scheme) {
    final (glassFill, solid) = fixedNavBarSurfaceFill(context, ref);
    final content = Container(
      color: glassFill,
      padding: EdgeInsets.fromLTRB(
        16,
        10,
        16,
        12 + MediaQuery.of(context).padding.bottom,
      ),
      child: Text(
        tr('已选 {n} 个文件夹', {'n': '${_selected.length}'}),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12,
          color: scheme.onSurfaceVariant.withValues(alpha: 0.85),
        ),
      ),
    );
    if (solid) return content;
    // 二级页玻璃按路由实例分组（与 GlassTopBar 同口径），不进 navGlassKey
    // 全局组：避免与被盖住的 shell 底栏/mini 条跨路由混组
    final sigma = navSurfaceBlurSigma(ref);
    return RepaintBoundary(
      child: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
          backdropGroupKey: navGroupFor(context),
          child: content,
        ),
      ),
    );
  }
}

/// 圆形勾选标记：替代默认方形 Checkbox，与应用内圆润卡片语言一致
class _RoundCheck extends StatelessWidget {
  const _RoundCheck({required this.checked});

  final bool checked;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      width: 22,
      height: 22,
      decoration: ShapeDecoration(
        color: checked ? scheme.primary : Colors.transparent,
        shape: CircleBorder(
          side: BorderSide(
            width: checked ? 0 : 1.5,
            color: checked
                ? scheme.primary
                : scheme.onSurfaceVariant.withValues(alpha: 0.4),
          ),
        ),
      ),
      child: checked
          ? Icon(Icons.check_rounded, size: 15, color: scheme.onPrimary)
          : null,
    );
  }
}
