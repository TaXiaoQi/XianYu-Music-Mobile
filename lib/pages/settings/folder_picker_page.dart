import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/library/library_provider.dart';
import '../../src/library/saf_channel.dart';
import '../../src/library/scan_settings_provider.dart';
import '../../src/navigation/shell.dart';
import '../../src/core/app_colors.dart';
import '../../src/widgets/app_toast.dart';
import '../../src/widgets/glass_appbar.dart';
import '../../src/i18n/i18n.dart';

/// 目录树节点（由 MediaStore 音频路径聚合构建）。
class _PathNode {
  final String path;
  final String name;
  final int directCount;
  final List<_PathNode> children = [];
  int subtreeCount = 0;
  _PathNode(this.path, this.name, this.directCount);
}

/// 应用内音乐目录选择页（Android）。
///
/// 数据来自 MediaStore 聚合的真实目录：音乐权限授予一次后，添加目录在
/// 应用内勾选即可，不再每次弹系统 SAF 授权框；真实路径直接交给 Rust
/// 路径式扫描（SAF 系统选择器仅作 DSD / USB 等特殊目录的兜底入口）。
class FolderPickerPage extends ConsumerStatefulWidget {
  const FolderPickerPage({super.key});

  @override
  ConsumerState<FolderPickerPage> createState() => _FolderPickerPageState();
}

class _FolderPickerPageState extends ConsumerState<FolderPickerPage>
    with HidesShellChrome {
  List<_PathNode> _roots = [];
  final Set<String> _selected = {};
  final Set<String> _expanded = {};
  bool _loading = true;
  String? _error;
  bool _adding = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final folders = await SafChannel.listMediaAudioFolders();
      if (!mounted) return;
      setState(() {
        _roots = _buildTree(folders);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  /// 由扁平目录列表构建目录树，并折叠单链前缀（/storage/emulated/0 一类）。
  List<_PathNode> _buildTree(List<MediaFolderInfo> folders) {
    final root = _PathNode('', '', 0);
    for (final f in folders) {
      final segs = f.path.split('/').where((s) => s.isNotEmpty).toList();
      if (segs.isEmpty) continue;
      var node = root;
      var cur = '';
      for (var i = 0; i < segs.length; i++) {
        cur = i == 0 ? '/${segs[i]}' : '$cur/${segs[i]}';
        final isLast = i == segs.length - 1;
        _PathNode child;
        final hit = node.children.where((c) => c.name == segs[i]).toList();
        if (hit.isEmpty) {
          child = _PathNode(cur, segs[i], isLast ? f.count : 0);
          node.children.add(child);
        } else {
          child = hit.first;
        }
        node = child;
      }
    }
    var top = root;
    while (top.children.length == 1) {
      top = top.children.single;
    }
    _computeSubtree(top);
    _sortChildren(top);
    return top.children;
  }

  int _computeSubtree(_PathNode node) {
    var sum = node.directCount;
    for (final c in node.children) {
      sum += _computeSubtree(c);
    }
    node.subtreeCount = sum;
    return sum;
  }

  void _sortChildren(_PathNode node) {
    node.children.sort((a, b) {
      final c = b.subtreeCount.compareTo(a.subtreeCount);
      return c != 0 ? c : a.name.compareTo(b.name);
    });
    for (final c in node.children) {
      _sortChildren(c);
    }
  }

  /// 已选目录中剔除被祖先覆盖的子目录（选了 Music 就无需再选 Music/子目录）。
  List<String> get _keptSelection {
    final sorted = _selected.toList()..sort();
    final kept = <String>[];
    for (final p in sorted) {
      if (!kept.any((k) => p.startsWith('$k/'))) kept.add(p);
    }
    return kept;
  }

  void _toggle(String path) {
    setState(() {
      if (!_selected.remove(path)) _selected.add(path);
    });
  }

  Future<void> _confirm() async {
    final kept = _keptSelection;
    if (kept.isEmpty || _adding) return;
    setState(() => _adding = true);
    try {
      final folders = ref.read(scanFoldersProvider.notifier);
      for (final p in kept) {
        await folders.addFolder(p);
      }
      final count = await ref.read(libraryProvider.notifier).scanAllFolders();
      if (!mounted) return;
      Navigator.of(context).pop(count);
    } catch (e) {
      if (!mounted) return;
      setState(() => _adding = false);
      showXianYuToast(context, tr('添加失败：{e}', {'e': e}));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final kept = _keptSelection;
    return Scaffold(
      backgroundColor: appScaffoldBackground(context, ref),
      body: Stack(
        children: [
          Padding(
            padding: EdgeInsets.only(top: GlassTopBar.height(context)),
            child: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(tr('读取音频目录失败：{e}', {'e': _error ?? ''}),
                          textAlign: TextAlign.center),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: _load,
                        icon: const Icon(Icons.refresh),
                        label:   Text(tr('重试')),
                      ),
                    ],
                  ),
                )
              : _roots.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.library_music,
                                size: 48, color: scheme.onSurfaceVariant),
                            const SizedBox(height: 12),
                              Text(tr('未发现包含音频的文件夹'),
                                style: TextStyle(fontWeight: FontWeight.w600)),
                            const SizedBox(height: 4),
                            Text(
                              tr('若音乐存放在 DSD / USB 等特殊目录，\n请返回上一页使用顶栏的系统选择器添加'),
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  fontSize: 13,
                                  color: scheme.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.only(bottom: 120),
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                          child: Text(
                            tr('勾选要扫描的文件夹（已授予音乐权限，无需再次授权）'),
                            style: TextStyle(
                                fontSize: 12, color: scheme.onSurfaceVariant),
                          ),
                        ),
                        for (final node in _roots) _tile(node, 0),
                      ],
                    ),
          ),
          Positioned(
            top: 0, left: 0, right: 0,
            child: GlassTopBar(
              leading: const BackButton(),
              title:   Text(tr('选择音乐文件夹')),
              actions: [
                IconButton(
                  tooltip: tr('刷新'),
                  icon: const Icon(Icons.refresh),
                  onPressed: _loading || _adding ? null : _load,
                ),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: _roots.isEmpty || _error != null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: FilledButton.icon(
                  onPressed:
                      kept.isEmpty || _adding ? null : _confirm,
                  icon: _adding
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.library_add_check),
                  label: Text(
                      _adding ? tr('正在扫描…') : '添加 ${kept.length} 个目录并扫描'),
                ),
              ),
            ),
    );
  }

  Widget _tile(_PathNode node, int depth) {
    final checked = _selected.contains(node.path);
    final hasChildren = node.children.isNotEmpty;
    final expanded = _expanded.contains(node.path);
    return Column(
      children: [
        ListTile(
          dense: true,
          contentPadding:
              EdgeInsets.only(left: 8.0 + depth * 20, right: 12),
          leading: Checkbox(
            value: checked,
            onChanged: _adding ? null : (_) => _toggle(node.path),
          ),
          title: Text(
            node.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 14.5),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                tr('{n} 首', {'n': node.subtreeCount}),
                style: TextStyle(
                    fontSize: 12, color: Theme.of(context).colorScheme.outline),
              ),
              if (hasChildren)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: AnimatedRotation(
                    turns: expanded ? 0.25 : 0,
                    duration: const Duration(milliseconds: 180),
                    child: const Icon(Icons.chevron_right),
                  ),
                  onPressed: _adding
                      ? null
                      : () => setState(() {
                            if (!_expanded.remove(node.path)) {
                              _expanded.add(node.path);
                            }
                          }),
                ),
            ],
          ),
          onTap: hasChildren && !_adding
              ? () => setState(() {
                    if (!_expanded.remove(node.path)) {
                      _expanded.add(node.path);
                    }
                  })
              : (!_adding ? () => _toggle(node.path) : null),
        ),
        if (hasChildren && expanded)
          for (final c in node.children) _tile(c, depth + 1),
      ],
    );
  }
}
