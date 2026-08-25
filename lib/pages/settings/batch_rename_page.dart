import 'package:xianyu_music_mobile/src/widgets/predictive_dialog_route.dart';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/core/app_colors.dart';
import '../../src/core/db_path.dart';
import '../../src/library/library_provider.dart';
import '../../src/rust/api.dart';

/// 批量重命名页面：按标签模板重命名本地音乐文件（对齐桌面端工具箱重命名）。
class BatchRenamePage extends ConsumerStatefulWidget {
  const BatchRenamePage({super.key});

  @override
  ConsumerState<BatchRenamePage> createState() => _BatchRenamePageState();
}

class _BatchRenamePageState extends ConsumerState<BatchRenamePage> {
  final _templateCtrl = TextEditingController(text: '{title} - {artist}');
  String? _folder;
  bool _removeTrackPrefix = false;
  bool _removeSourcePrefix = false;

  List<Map<String, dynamic>> _previews = [];
  bool _scanning = false;
  bool _applying = false;
  bool _hasScanned = false;
  String? _error;

  static const _presets = [
    ('歌名 - 歌手', '{title} - {artist}'),
    ('歌手 - 歌名', '{artist} - {title}'),
    ('轨道. 歌名', '{track}. {title}'),
  ];

  static const _variables = [
    ('{title}', '标题'),
    ('{artist}', '歌手'),
    ('{album}', '专辑'),
    ('{year}', '年份'),
    ('{track}', '轨道号'),
  ];

  @override
  void dispose() {
    _templateCtrl.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> get _validItems => _previews
      .where((p) => p['status'] == 'tags' && p['error'] == null)
      .toList();

  Future<void> _scan() async {
    final folder = _folder;
    if (folder == null) {
      setState(() => _error = '请先选择目标文件夹');
      return;
    }
    setState(() {
      _scanning = true;
      _error = null;
      _hasScanned = false;
    });
    try {
      final config = jsonEncode({
        'mode': 'tags',
        'template': _templateCtrl.text,
        'remove_track_prefix': _removeTrackPrefix,
        'remove_source_prefix': _removeSourcePrefix,
      });
      final json = await previewRename(rootPath: folder, configJson: config);
      final list = (jsonDecode(json) as List)
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m.cast<String, dynamic>()))
          .toList();
      if (!mounted) return;
      setState(() {
        _previews = list;
        _scanning = false;
        _hasScanned = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _apply() async {
    final valid = _validItems;
    if (valid.isEmpty || _applying) return;
    // 二次确认：文件重命名不可撤销
    final ok = await showPredictiveDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认重命名'),
        content: Text('将重命名 ${valid.length} 个文件，此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('重命名'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    setState(() {
      _applying = true;
      _error = null;
    });
    try {
      final ops = valid
          .map((p) => {
                'original_path': p['original_path'],
                'new_name': p['new_name'],
              })
          .toList();
      final count = await applyRename(operationsJson: jsonEncode(ops));
      // 重命名后刷新该文件夹歌曲（数据库路径同步）
      final dbPath = await ref.read(dbPathProvider.future);
      await refreshFolderSongs(dbPath: dbPath, folderPath: _folder!);
      await ref.read(libraryProvider.notifier).load();
      if (!mounted) return;
      setState(() {
        _applying = false;
        _hasScanned = false;
        _previews = [];
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('成功重命名 $count 个文件')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _applying = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final folders = ref.watch(libraryProvider).folders;

    return Scaffold(
      backgroundColor: appSurfaceBg(context),
      appBar: AppBar(title: const Text('批量重命名')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 文件夹选择
          Text('目标文件夹',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurfaceVariant)),
          const SizedBox(height: 8),
          if (folders.isEmpty)
            Text('本地还没有文件夹，请先在「本地 → 文件夹」页添加扫描目录',
                style: TextStyle(fontSize: 12, color: scheme.outline))
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final f in folders)
                  ChoiceChip(
                    label: Text(_folderName(f),
                        style: const TextStyle(fontSize: 12)),
                    selected: _folder == f,
                    onSelected: (_) => setState(() {
                      _folder = f;
                      _hasScanned = false;
                      _previews = [];
                    }),
                  ),
              ],
            ),
          const SizedBox(height: 16),

          // 模板
          Text('命名模板',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurfaceVariant)),
          const SizedBox(height: 8),
          TextField(
            controller: _templateCtrl,
            enabled: !_applying,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              isDense: true,
              hintText: '{title} - {artist}',
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (label, value) in _presets)
                ActionChip(
                  label: Text(label, style: const TextStyle(fontSize: 12)),
                  onPressed: () {
                    _templateCtrl.text = value;
                    setState(() => _hasScanned = false);
                  },
                ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (code, name) in _variables)
                ActionChip(
                  label: Text('$name $code',
                      style: const TextStyle(fontSize: 11)),
                  onPressed: () {
                    _templateCtrl.text += code;
                    setState(() => _hasScanned = false);
                  },
                ),
            ],
          ),
          const SizedBox(height: 12),

          // 附加选项
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('移除轨道号前缀', style: TextStyle(fontSize: 13)),
            value: _removeTrackPrefix,
            onChanged: (v) => setState(() {
              _removeTrackPrefix = v;
              _hasScanned = false;
            }),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('移除来源前缀', style: TextStyle(fontSize: 13)),
            value: _removeSourcePrefix,
            onChanged: (v) => setState(() {
              _removeSourcePrefix = v;
              _hasScanned = false;
            }),
          ),
          const SizedBox(height: 8),

          // 操作按钮
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _scanning || _applying ? null : _scan,
                  icon: _scanning
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.search, size: 18),
                  label: Text(_scanning ? '扫描中…' : '扫描预览'),
                ),
              ),
              if (_validItems.isNotEmpty && _hasScanned) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _applying ? null : _apply,
                    icon: _applying
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child:
                                CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.drive_file_rename_outline,
                            size: 18),
                    label: Text(_applying
                        ? '重命名中…'
                        : '应用 (${_validItems.length})'),
                  ),
                ),
              ],
            ],
          ),

          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(_error!,
                  style: TextStyle(color: scheme.error, fontSize: 12)),
            ),

          // 预览列表
          if (_hasScanned) ...[
            const SizedBox(height: 16),
            Text(
              '预览（${_validItems.length} 个可重命名，'
              '${_previews.length - _validItems.length} 个跳过）',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            if (_previews.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 20),
                child: Center(
                  child: Text('没有需要重命名的文件',
                      style:
                          TextStyle(fontSize: 13, color: scheme.outline)),
                ),
              )
            else
              for (final p in _previews.take(200))
                _previewTile(p, scheme),
          ],
        ],
      ),
    );
  }

  Widget _previewTile(Map<String, dynamic> p, ColorScheme scheme) {
    final ok = p['status'] == 'tags' && p['error'] == null;
    final original = p['original_name'] as String? ?? '';
    final newName = p['new_name'] as String? ?? '';
    final error = p['error'] as String?;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            ok ? Icons.check_circle_outline : Icons.skip_next,
            size: 16,
            color: ok ? scheme.primary : scheme.outline,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  original,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 12.5,
                      decoration: ok ? TextDecoration.lineThrough : null,
                      color: scheme.onSurfaceVariant),
                ),
                if (ok)
                  Text(
                    newName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 12.5, fontWeight: FontWeight.w600),
                  ),
                if (error != null)
                  Text(error,
                      style:
                          TextStyle(fontSize: 11, color: scheme.error)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _folderName(String path) {
    final parts = path.replaceAll('\\', '/').split('/');
    return parts.isEmpty ? path : parts.last;
  }
}
