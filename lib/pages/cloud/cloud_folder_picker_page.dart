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
import '../../src/widgets/app_toast.dart';
import '../../src/widgets/glass_appbar.dart';

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
  });

  final String providerId;
  final String accountId;

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

  @override
  void initState() {
    super.initState();
    _provider = cloudProviderById(widget.providerId)!;
    _init();
  }

  Future<void> _init() async {
    final accounts =
        await CloudCredentialsStore.instance.accountsFor(_provider.id);
    if (!mounted) return;
    final valid = accounts.any((a) => a.accountId == widget.accountId)
        ? widget.accountId
        : (accounts.isNotEmpty ? accounts.first.accountId : null);
    if (valid == null) {
      setState(() => _loading = false);
      return;
    }
    _accountId = valid;
    final saved =
        await CloudFolderSelectionStore.instance.pathsFor(_provider.id, valid);
    if (!mounted) return;
    setState(() {
      _selected.addAll(saved);
      _stack
        ..clear()
        ..add(_Crumb(_provider.rootPath, tr('全部文件')));
    });
    _load();
  }

  Future<Map<String, String>> _cred() async {
    final cred =
        await CloudCredentialsStore.instance.credFor(_provider.id, _accountId);
    if (cred != null) return cred;
    final sole = await CloudCredentialsStore.instance.soleCredFor(_provider.id);
    return sole ?? const {};
  }

  /// 进入子目录：与浏览页同款语义（path 优先，回退 id）。
  void _enter(String name, String? entryPath, String entryId) {
    final cur = _stack.last.path;
    final next =
        (entryPath != null && entryPath.isNotEmpty && entryPath != cur)
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
      final r = await _provider.listDir(cred, path, cursor: more ? _cursor : null);
      if (!mounted || _stack.isEmpty || _stack.last.path != path) return;
      setState(() {
        _dirs = r.files.where((f) => f.isDir).toList();
        _files = r.files.where((f) => !f.isDir).toList();
        _cursor = r.nextCursor;
        _loading = false;
        _appending = false;
      });
    } catch (e) {
      if (!mounted || _stack.isEmpty || _stack.last.path != path) return;
      AppLog.warn('cloud', '选择器列目录失败 path=$path: $e');
      setState(() {
        _loading = false;
        _appending = false;
      });
      showXianYuToast(
        context,
        e is CloudException ? e.message : tr('目录加载失败'),
      );
    }
  }

  /// 当前目录的存储键（path 型盘为绝对路径，id 型盘为 id 串）。
  void _toggleCurrent() {
    if (_stack.isEmpty) return;
    final path = _stack.last.path;
    setState(() {
      if (!_selected.remove(path)) _selected.add(path);
    });
  }

  void _toggleEntry(String name, String? entryPath, String entryId) {
    final cur = _stack.last.path;
    final key =
        (entryPath != null && entryPath.isNotEmpty && entryPath != cur)
            ? entryPath
            : entryId;
    setState(() {
      if (!_selected.remove(key)) _selected.add(key);
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
    context.pop();
  }

  String _dirNameOf(String path) {
    for (final c in _stack) {
      if (c.path == path) return c.name;
    }
    final idx = path.lastIndexOf('/');
    return idx >= 0 && idx < path.length - 1
        ? path.substring(idx + 1)
        : path;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final currentSelected = _stack.isNotEmpty && _selected.contains(_stack.last.path);
    return Scaffold(
      backgroundColor: appScaffoldBackground(context, ref),
      body: Stack(
        children: [
          Column(
            children: [
              SizedBox(height: GlassTopBar.height(context)),
              if (_selected.isNotEmpty) _selectedChips(context, scheme),
              if (_stack.isNotEmpty) _breadcrumb(context, scheme),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: _selectCurrentTile(context, scheme, currentSelected),
              ),
              Divider(
                height: 1,
                thickness: 0.5,
                color: scheme.onSurface.withValues(alpha: 0.08),
              ),
              Expanded(child: _list(context, scheme)),
              _bottomBar(context, scheme),
            ],
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: GlassTopBar(
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

  Widget _selectCurrentTile(
    BuildContext context,
    ColorScheme scheme,
    bool checked,
  ) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: _toggleCurrent,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        child: Row(
          children: [
            Icon(
              Icons.folder_special_rounded,
              size: 20,
              color: checked ? scheme.primary : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                tr('选择当前文件夹'),
                style: const TextStyle(fontSize: 13),
              ),
            ),
            Checkbox(
              value: checked,
              onChanged: (_) => _toggleCurrent(),
            ),
          ],
        ),
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
              for (var i = 0; i < _stack.length; i++)
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
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 12),
      itemCount:
          _dirs.length + _files.length + (_cursor != null ? 1 : 0),
      itemBuilder: (context, i) {
        if (i >= _dirs.length + _files.length) {
          return Padding(
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
          );
        }
        if (i >= _dirs.length) {
          return _fileRow(_files[i - _dirs.length], scheme);
        }
        final d = _dirs[i];
        final cur = _stack.last.path;
        final key = (d.path != null &&
                d.path!.isNotEmpty &&
                d.path != cur)
            ? d.path!
            : d.id;
        final checked = _selected.contains(key);
        return InkWell(
          onTap: () => _enter(d.name, d.path, d.id),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
            child: Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Icon(
                        Icons.folder_rounded,
                        size: 20,
                        color: scheme.primary,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          d.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 14),
                        ),
                      ),
                    ],
                  ),
                ),
                Checkbox(
                  value: checked,
                  onChanged: (_) => _toggleEntry(d.name, d.path, d.id),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 当前目录下的文件展示行（与文件夹行同样式，仅无勾选框、不可进入）。
  Widget _fileRow(CloudFile f, ColorScheme scheme) {
    const audioExts = {
      '.mp3', '.flac', '.m4a', '.aac', '.wav', '.ogg', '.ape', '.wma',
      '.opus', '.dsf', '.dff', '.mka',
    };
    final name = f.name.toLowerCase();
    final isAudio =
        audioExts.any((e) => name.endsWith(e));
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                Icon(
                  isAudio
                      ? Icons.music_note_rounded
                      : Icons.insert_drive_file_rounded,
                  size: 20,
                  color: scheme.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    f.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14),
                  ),
                ),
              ],
            ),
          ),
          // 与文件夹行行尾 Checkbox 同尺寸的隐形占位，保证两种行高一致
          const SizedBox(width: 40, height: 48),
        ],
      ),
    );
  }

  Widget _bottomBar(BuildContext context, ColorScheme scheme) {
    return Container(
      padding: EdgeInsets.fromLTRB(
        16,
        8,
        16,
        12 + MediaQuery.of(context).padding.bottom,
      ),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.96),
        border: Border(
          top: BorderSide(
            color: scheme.onSurface.withValues(alpha: 0.08),
          ),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              tr('已选 {n} 个文件夹', {'n': '${_selected.length}'}),
              style: TextStyle(
                fontSize: 13,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.85),
              ),
            ),
          ),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(tr('保存')),
          ),
        ],
      ),
    );
  }
}
