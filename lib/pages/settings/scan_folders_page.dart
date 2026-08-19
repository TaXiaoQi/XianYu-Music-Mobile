import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../src/library/scan_settings_provider.dart';

/// 扫描目录管理页：添加/删除本地音乐扫描目录。
class ScanFoldersPage extends ConsumerStatefulWidget {
  const ScanFoldersPage({super.key});

  @override
  ConsumerState<ScanFoldersPage> createState() => _ScanFoldersPageState();
}

class _ScanFoldersPageState extends ConsumerState<ScanFoldersPage> {
  bool _adding = false;

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  /// 申请存储权限：Android 11+ 优先「所有文件访问」，回退媒体/存储权限。
  Future<bool> _ensureStoragePermission() async {
    if (!Platform.isAndroid) return true;
    // 优先所有文件访问权限（扫描任意目录需要真实路径）。
    if (await Permission.manageExternalStorage.isGranted) return true;
    final manage = await Permission.manageExternalStorage.request();
    if (manage.isGranted) return true;
    // 回退：媒体音频 / 传统存储权限。
    final audio = await Permission.audio.request();
    if (audio.isGranted) return true;
    final storage = await Permission.storage.request();
    return storage.isGranted;
  }

  Future<void> _addFolder() async {
    setState(() => _adding = true);
    try {
      final granted = await _ensureStoragePermission();
      if (!granted) {
        _toast('未授予存储权限，无法扫描本地文件夹');
        return;
      }
      final dir = await FilePicker.platform.getDirectoryPath();
      if (dir == null) return; // 用户取消
      // SAF 返回的 content:// URI 无法用于文件系统扫描。
      if (dir.startsWith('content://')) {
        _toast('请授予「所有文件访问」权限后重新选择文件夹');
        return;
      }
      await ref.read(scanFoldersProvider.notifier).addFolder(dir);
      _toast('已添加扫描目录');
    } catch (e) {
      _toast('添加失败：$e');
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _removeFolder(String path) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('移除扫描目录'),
        content: Text('确定移除该目录吗？\n$path'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(scanFoldersProvider.notifier).removeFolder(path);
      _toast('已移除');
    } catch (e) {
      _toast('移除失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final foldersAsync = ref.watch(scanFoldersProvider);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('扫描文件夹')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _adding ? null : _addFolder,
        icon: _adding
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.create_new_folder),
        label: const Text('添加目录'),
      ),
      body: foldersAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载失败：$e')),
        data: (folders) {
          if (folders.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.folder_off,
                        size: 48, color: scheme.onSurfaceVariant),
                    const SizedBox(height: 12),
                    const Text('还没有扫描目录',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    Text(
                      '点击右下角「添加目录」选择本地音乐文件夹，\n然后到「音乐库 → 文件夹」下拉刷新开始扫描',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 13, color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.only(bottom: 88),
            itemCount: folders.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final f = folders[i];
              return ListTile(
                leading: Icon(Icons.folder, color: scheme.primary),
                title: Text(f.path,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text('${f.songCount} 首'),
                trailing: IconButton(
                  icon: Icon(Icons.delete_outline, color: scheme.error),
                  onPressed: () => _removeFolder(f.path),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
