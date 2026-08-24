import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../src/core/app_colors.dart';
import '../../src/library/library_provider.dart';
import '../../src/library/saf_channel.dart';
import '../../src/library/scan_settings_provider.dart';
import '../../src/navigation/shell.dart';
import 'folder_picker_page.dart';

/// 扫描目录管理页：添加/删除本地音乐扫描目录。
class ScanFoldersPage extends ConsumerStatefulWidget {
  const ScanFoldersPage({super.key});

  @override
  ConsumerState<ScanFoldersPage> createState() => _ScanFoldersPageState();
}

class _ScanFoldersPageState extends ConsumerState<ScanFoldersPage>
    with HidesShellChrome {
  bool _adding = false;

  /// tree URI → 用户可读目录名缓存（避免列表滚动时反复跨 channel 查询）。
  static final Map<String, String> _nameCache = {};

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  Future<String> _nameOf(String path) async {
    final hit = _nameCache[path];
    if (hit != null) return hit;
    if (!SafChannel.isSafTree(path)) return path;
    final name = await SafChannel.friendlyTreeName(path);
    _nameCache[path] = name;
    return name;
  }

  /// 申请存储权限（按 Android 版本细分，仅申请音乐读取）：
  /// - Android 13+：READ_MEDIA_AUDIO（媒体音频权限）
  /// - Android 12 及以下：READ_EXTERNAL_STORAGE（传统存储权限）
  /// 不再申请「所有文件访问」（MANAGE_EXTERNAL_STORAGE）。
  Future<bool> _ensureStoragePermission() async {
    if (!Platform.isAndroid) return true;
    if (await Permission.audio.isGranted) return true;
    if (await Permission.storage.isGranted) return true;
    // Android 13+ 弹媒体音频权限；低版本该权限不存在，自动跳过。
    final audio = await Permission.audio.request();
    if (audio.isGranted) return true;
    // Android 12 及以下弹传统存储权限；13+ 已由 maxSdkVersion 移除，自动拒绝。
    final storage = await Permission.storage.request();
    if (storage.isGranted) return true;
    // 双双被永久拒绝时引导用户去系统设置手动开启。
    if (audio.isPermanentlyDenied && storage.isPermanentlyDenied) {
      await openAppSettings();
    }
    return false;
  }

  Future<void> _addFolder() async {
    setState(() => _adding = true);
    try {
      if (Platform.isAndroid) {
        // 音乐权限授予一次后即全局生效：添加目录走应用内选择页
        // （MediaStore 枚举 + 真实路径扫描），不再每次弹系统授权框。
        final granted = await _ensureStoragePermission();
        if (!mounted) return;
        if (granted) {
          final count = await Navigator.of(context, rootNavigator: true)
              .push<int>(MaterialPageRoute(
                  builder: (_) => const FolderPickerPage()));
          if (count != null && mounted) {
            _toast(count > 0 ? '已添加扫描目录，扫描到 $count 首' : '已添加扫描目录');
          }
          return;
        }
        // 音乐权限被拒：回退系统 SAF 选择器（按目录单独授权，无需音乐权限）。
        await _addFolderViaSaf();
        return;
      }
      final granted = await _ensureStoragePermission();
      if (!granted) {
        _toast('未授予存储权限，无法扫描本地文件夹');
        return;
      }
      final dir = await FilePicker.getDirectoryPath();
      if (dir == null) return; // 用户取消
      // SAF 返回的 content:// URI 无法用于文件系统扫描（桌面几乎不会出现）。
      if (dir.startsWith('content://')) {
        _toast('该位置无法直接访问，请选择本地存储（如音乐、Download）下的文件夹');
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

  /// 经系统 SAF 选择器添加目录（DSD / USB 等特殊目录的兜底入口）。
  Future<void> _addFolderViaSaf() async {
    setState(() => _adding = true);
    try {
      final treeUri = await SafChannel.chooseFolderTree();
      if (treeUri == null) return; // 用户取消
      await SafChannel.persistPermission(treeUri);
      await ref.read(scanFoldersProvider.notifier).addFolder(treeUri);
      // 添加后立即扫描，避免还需到音乐库「文件夹」页下拉刷新才能读到音乐。
      String msg;
      try {
        final count =
            await ref.read(libraryProvider.notifier).scanAllFolders();
        msg = '已添加扫描目录，扫描到 $count 首';
      } catch (e) {
        msg = '已添加扫描目录，但扫描失败：$e';
      }
      if (mounted) _toast(msg);
    } catch (e) {
      if (mounted) _toast('添加失败：$e');
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  /// 重新授权失效目录。
  ///
  /// 选回同一目录时返回的 tree URI 不变，旧曲库数据直接复活；
  /// 选了不同目录则替换条目并全量重扫。
  Future<void> _reauthorize(String treeUri) async {
    setState(() => _adding = true);
    try {
      final newUri = await SafChannel.chooseFolderTree();
      if (newUri == null) return; // 用户取消
      await SafChannel.persistPermission(newUri);
      if (newUri != treeUri) {
        await SafChannel.releasePermission(treeUri);
        await ref.read(scanFoldersProvider.notifier).removeFolder(treeUri);
        await ref.read(scanFoldersProvider.notifier).addFolder(newUri);
      }
      String msg;
      try {
        final count =
            await ref.read(libraryProvider.notifier).scanAllFolders();
        msg = '重新授权成功，扫描到 $count 首';
      } catch (e) {
        msg = '重新授权完成，但扫描失败：$e';
      }
      if (mounted) _toast(msg);
    } catch (e) {
      if (mounted) _toast('重新授权失败：$e');
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _removeFolder(String path) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('移除扫描目录'),
        content: Text('确定移除该目录吗？\n${_nameCache[path] ?? path}'),
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
      // 同步释放持久化授权，避免耗尽系统名额（Android 11 前仅 128 个）。
      if (SafChannel.isSafTree(path)) {
        await SafChannel.releasePermission(path);
      }
      _toast('已移除');
    } catch (e) {
      _toast('移除失败：$e');
    }
  }

  @override
  void initState() {
    super.initState();
    // 进入本页即刷新各 SAF 目录的授权状态（失效目录显示红标与重新授权按钮）。
    Future.microtask(() {
      if (mounted) {
        ref.read(libraryProvider.notifier).checkSafFolderAuthorization();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final foldersAsync = ref.watch(scanFoldersProvider);
    final lost =
        ref.watch(libraryProvider.select((s) => s.unauthorizedFolders));
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: appSurfaceBg(context),
      appBar: AppBar(
        title: const Text('扫描文件夹'),
        actions: [
          // SAF 兜底入口：MediaStore 看不到的目录（DSD / USB 等）经系统选择器授权。
          if (Platform.isAndroid)
            IconButton(
              tooltip: '系统选择器（DSD / USB 等特殊目录）',
              icon: const Icon(Icons.folder_open),
              onPressed: _adding ? null : _addFolderViaSaf,
            ),
        ],
      ),
      floatingActionButton: Padding(
        // 上移避让二级页面下沉的迷你播放条（高 58 + 距底 18 + 间隙 12）。
        padding: const EdgeInsets.only(bottom: 88),
        child: FloatingActionButton.extended(
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
                      '点击右下角「添加目录」，勾选包含音乐的文件夹即可扫描\n（仅首次需要授予音乐读取权限，之后添加不再弹授权框）',
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
              final isLost = lost.contains(f.path);
              return ListTile(
                leading: Icon(
                  isLost ? Icons.folder_off : Icons.folder,
                  color: isLost ? scheme.error : scheme.primary,
                ),
                title: FutureBuilder<String>(
                  future: _nameOf(f.path),
                  builder: (context, snap) => Text(
                    snap.data ?? f.path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                subtitle: Text(
                  isLost ? '授权已失效，点击右侧按钮重新授权' : '${f.songCount} 首',
                  style: TextStyle(
                    fontSize: 12,
                    color: isLost ? scheme.error : scheme.onSurfaceVariant,
                  ),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isLost)
                      IconButton(
                        tooltip: '重新授权',
                        icon: Icon(Icons.key, color: scheme.error),
                        onPressed: _adding ? null : () => _reauthorize(f.path),
                      ),
                    IconButton(
                      icon: Icon(Icons.delete_outline, color: scheme.error),
                      onPressed: () => _removeFolder(f.path),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}
