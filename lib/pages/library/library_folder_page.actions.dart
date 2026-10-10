part of 'library_folder_page.dart';
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

extension _LibraryFolderPageActions on _LibraryFolderPageState {
  Future<void> _seedSandboxFolders() async {
    if (!PlatformCaps.supportsSandboxLibrary) return;
    final existing = ref.read(scanFoldersProvider).valueOrNull;
    if (existing == null || existing.isNotEmpty) return;
    try {
      final docs = await getApplicationDocumentsDirectory();
      for (final sub in const ['Downloads', 'Music']) {
        final dir = Directory(p.join(docs.path, sub));
        if (!dir.existsSync()) dir.createSync(recursive: true);
        await ref.read(scanFoldersProvider.notifier).addFolder(dir.path);
      }
    } catch (e) {
      AppLog.warn('library', '初始化沙盒音乐目录失败: $e');
    }
  }

  Future<void> _importFiles() async {
    setState(() => _adding = true);
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: _LibraryFolderPageState._audioExts,
        // ignore: deprecated_member_use
        allowMultiple: true,
      );
      if (files.isEmpty) return;
      if (!mounted) return;
      final docs = await getApplicationDocumentsDirectory();
      final destDir = Directory(p.join(docs.path, 'Music'));
      if (!destDir.existsSync()) destDir.createSync(recursive: true);
      var imported = 0;
      for (final f in files) {
        final src = f.path;
        if (src == null) continue;
        final srcFile = File(src);
        if (!srcFile.existsSync()) continue;
        await srcFile.copy(p.join(destDir.path, p.basename(src)));
        imported++;
      }
      if (!mounted) return;
      if (imported == 0) {
        _toast(tr('未选择有效音频文件'));
        return;
      }
      _toast(tr('{n} 个文件已导入，开始扫描', {'n': imported}));
      await _startScan();
    } catch (e) {
      _toast('导入失败：$e');
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    showXianYuToast(context, msg, duration: const Duration(seconds: 2));
  }

  /// 鸿蒙「导入文件夹」：系统 folder picker 临时授权 → 递归列音频 →
  /// 复制进沙盒 `Music/<folderName>/` → 加入扫描目录并扫描。授权不持久化，
  /// 重启后扫描的是沙盒副本（与 _importFiles 单文件导入同一物化模型）。
  Future<void> _importFolder() async {
    setState(() => _adding = true);
    try {
      final uri = await OhosFolderChannel.pickFolder();
      if (uri == null || !mounted) return;
      final docs = await getApplicationDocumentsDirectory();
      final segs = Uri.parse(uri).pathSegments.where((s) => s.isNotEmpty);
      final folderName = segs.isEmpty ? 'imported' : segs.last;
      final destDir = Directory(p.join(docs.path, 'Music', folderName));
      await destDir.create(recursive: true);
      final files = await OhosFolderChannel.listAudioFiles(
          uri, _LibraryFolderPageState._audioExts);
      if (!mounted) return;
      if (files.isEmpty) {
        _toast(tr('该文件夹内没有受支持的音频文件'));
        return;
      }
      final imported = await OhosFolderChannel.importFiles(
        folderUri: uri,
        rels: [for (final f in files) f.rel],
        destDir: destDir.path,
      );
      if (!mounted) return;
      if (imported == 0) {
        _toast(tr('导入失败，文件可能已被移动或删除'));
        return;
      }
      _toast(tr('{n} 个文件已导入，开始扫描', {'n': imported}));
      await ref.read(scanFoldersProvider.notifier).addFolder(destDir.path);
      await _startScan();
    } catch (e) {
      _toast('导入失败：$e');
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<bool> _ensureStoragePermission() async {
    if (!Platform.isAndroid) return true;
    final sdkInt = await SafChannel.androidSdkInt();
    if (sdkInt >= 33) {
      if (await Permission.audio.isGranted) return true;
      final audio = await Permission.audio.request();
      if (audio.isGranted) return true;
      if (audio.isPermanentlyDenied) await openAppSettings();
      return false;
    }
    if (await Permission.storage.isGranted) return true;
    final storage = await Permission.storage.request();
    if (storage.isGranted) return true;
    if (storage.isPermanentlyDenied) await openAppSettings();
    return false;
  }

  Future<void> _addFolder() async {
    if (!PlatformCaps.supportsFolderScan) {
      _toast(tr('当前平台不支持扫描本地文件夹'));
      return;
    }
    setState(() => _adding = true);
    try {
      if (Platform.isAndroid) {
        final granted = await _ensureStoragePermission();
        if (!mounted) return;
        if (granted) {
          final count = await Navigator.of(context, rootNavigator: true)
              .push<int>(coverPageRoute<int>(
                  context, (_) => const FolderPickerPage()));
          if (count != null && count > 0 && mounted) {
            _toast(count > 1 ? '已添加 $count 个扫描目录' : tr('已添加扫描目录'));
          }
          return;
        }
        await _addFolderViaSaf();
        return;
      }
      final granted = await _ensureStoragePermission();
      if (!granted) {
        _toast(tr('未授予存储权限，无法扫描本地文件夹'));
        return;
      }
      final dir = await FilePicker.getDirectoryPath();
      if (dir == null) return;
      if (dir.startsWith('content://')) {
        _toast(tr('该位置无法直接访问，请选择本地存储（如音乐、Download）下的文件夹'));
        return;
      }
      await ref.read(scanFoldersProvider.notifier).addFolder(dir);
      _toast(tr('已添加扫描目录'));
    } catch (e) {
      _toast('添加失败：$e');
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _addFolderViaSaf() async {
    setState(() => _adding = true);
    try {
      final treeUri = await SafChannel.chooseFolderTree();
      if (treeUri == null) return;
      await SafChannel.persistPermission(treeUri);
      await ref.read(scanFoldersProvider.notifier).addFolder(treeUri);
      if (mounted) _toast('已添加扫描目录');
    } catch (e) {
      if (mounted) _toast(tr('添加失败：{e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _reauthorize(String treeUri) async {
    setState(() => _adding = true);
    try {
      final newUri = await SafChannel.chooseFolderTree();
      if (newUri == null) return;
      await SafChannel.persistPermission(newUri);
      if (newUri != treeUri) {
        await SafChannel.releasePermission(treeUri);
        await ref.read(scanFoldersProvider.notifier).removeFolder(treeUri);
        await ref.read(scanFoldersProvider.notifier).addFolder(newUri);
      }
      if (mounted) _toast(tr('重新授权成功'));
    } catch (e) {
      if (mounted) _toast(tr('重新授权失败：{e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _removeFolder(String path) async {
    final name = await _friendlyFolderName(path);
    if (!mounted) return;
    final ok = await showPredictiveDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title:   Text(tr('移除扫描目录')),
        content: Text(tr('确定移除该目录吗？\n{name}', {'name': name})),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child:   Text(tr('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child:   Text(tr('移除')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(scanFoldersProvider.notifier).removeFolder(path);
      if (SafChannel.isSafTree(path)) {
        await SafChannel.releasePermission(path);
      }
      _toast(tr('已移除'));
    } catch (e) {
      _toast(tr('移除失败：{e}', {'e': e}));
    }
  }

  Future<void> _importAsPlaylist(FolderNodeData node) async {
    final count = await ref
        .read(libraryProvider.notifier)
        .importFolderAsPlaylist(node.path);
    if (!mounted) return;
    final name = node.name.isNotEmpty ? node.name : node.path.split('/').last;
    showXianYuToast(
      context,
      count > 0
          ? tr('已将 {n} 首歌曲导入到歌单「{name}」', {'n': count, 'name': name})
          : tr('「{name}」下没有可导入的歌曲', {'name': name}),
      duration: const Duration(seconds: 2),
    );
  }

  Future<void> _onRefresh() => _startScan();

  Future<void> _startScan() async {
    if (_scanning) return;
    final localFolders =
        ref.read(scanFoldersProvider).valueOrNull ?? const <ScanFolder>[];
    final remoteSources = ref.read(remoteLibraryProvider).sources;
    if (localFolders.isEmpty && remoteSources.isEmpty) {
      showXianYuToast(context, tr('请先添加本地或远程文件夹，再开始扫描'));
      return;
    }
    setState(() => _scanning = true);
    try {
      final count = await ref.read(libraryProvider.notifier).scanAllFolders();
      if (!mounted) return;
      showXianYuToast(context, tr('扫描完成，共 {n} 首', {'n': count}),
          duration: const Duration(seconds: 2));
    } catch (e) {
      if (!mounted) return;
      showXianYuToast(context, tr('扫描失败：{e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _pickMinDuration(int cur) async {
    final choice = await showSheetDialog<int>(
      context,
      (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
                Text(tr('按时长过滤'),
                  style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(
                tr('过滤掉时长小于阈值的音频文件，重新扫描后生效'),
                style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(ctx).colorScheme.outline),
              ),
              const SizedBox(height: 12),
              for (final v in const [0, 10, 30, 60])
                ListTile(
                  title: Text(switch (v) {
                    0 => tr('不排除'),
                    _ => tr('{v} 秒', {'v': v}),
                  }),
                  trailing: cur == v
                      ? Icon(Icons.check,
                          color: Theme.of(ctx).colorScheme.primary)
                      : null,
                  contentPadding: EdgeInsets.zero,
                  onTap: () => Navigator.pop(ctx, v),
                ),
            ],
          ),
        ),
      ),
    );
    if (choice == null) return;
    if (choice > 0) _lastDuration = choice;
    await ref
        .read(settingsProvider.notifier)
        .setLibraryMinDurationSeconds(choice);
  }
}
