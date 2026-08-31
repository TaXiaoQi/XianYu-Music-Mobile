import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../src/core/app_colors.dart';
import '../../src/core/settings.dart';
import '../../src/library/library_provider.dart';
import '../../src/library/saf_channel.dart';
import '../../src/library/scan_settings_provider.dart';
import '../../src/navigation/shell.dart';
import '../../src/widgets/app_toast.dart';
import '../../src/player/player_provider.dart';
import '../../src/widgets/glass_appbar.dart';
import '../../src/widgets/mini_player_bar.dart';
import '../../src/widgets/sheet_dialog.dart';
import '../../src/widgets/predictive_dialog_route.dart';
import '../settings/folder_picker_page.dart';
import 'song_list_page.dart';
import '../../src/i18n/i18n.dart';

/// 文件夹页：扫描歌曲一体化界面（参考魅族音乐「扫描歌曲」）。
///
/// 由本地库「文件夹」Tab 独立而来的二级页面（本地页顶部搜索框右侧「+」进入）：
/// 顶部扫描引导（图标 + 开始扫描）→ 过滤设置（按时长过滤）→ 扫描目录管理
/// （添加 / 移除 / 重新授权）→ 已扫描文件夹树（浏览 / 播放 / 导入歌单）。
class LibraryFolderPage extends ConsumerStatefulWidget {
  const LibraryFolderPage({super.key});

  @override
  ConsumerState<LibraryFolderPage> createState() => _LibraryFolderPageState();
}

class _LibraryFolderPageState extends ConsumerState<LibraryFolderPage> {
  final Set<String> _expanded = {};
  bool _scanning = false;
  bool _adding = false;

  /// 关闭「按时长过滤」时记住上次的阈值，重新开启时恢复。
  int _lastDuration = 60;

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

  void _toast(String msg) {
    if (!mounted) return;
    showXianYuToast(context, msg, duration: const Duration(seconds: 2));
  }

  /// 申请存储权限（按 Android 版本细分，仅申请音乐读取）。
  ///
  /// Android 13+ 申请 READ_MEDIA_AUDIO（Permission.audio）；13 以下该权限
  /// 不存在，申请不会弹窗直接返回拒绝，必须走 READ_EXTERNAL_STORAGE
  /// （Permission.storage）。
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

  /// 添加扫描目录：应用内文件夹选择页（MediaStore），无权限时回退系统 SAF。
  Future<void> _addFolder() async {
    setState(() => _adding = true);
    try {
      if (Platform.isAndroid) {
        final granted = await _ensureStoragePermission();
        if (!mounted) return;
        if (granted) {
          final count = await Navigator.of(context, rootNavigator: true)
              .push<int>(
                  MaterialPageRoute(builder: (_) => const FolderPickerPage()));
          if (count != null && mounted) {
            _toast(count > 0 ? '已添加扫描目录，扫描到 $count 首' : tr('已添加扫描目录'));
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

  /// 经系统 SAF 选择器添加目录（DSD / USB 等特殊目录的兜底入口）。
  Future<void> _addFolderViaSaf() async {
    setState(() => _adding = true);
    try {
      final treeUri = await SafChannel.chooseFolderTree();
      if (treeUri == null) return;
      await SafChannel.persistPermission(treeUri);
      await ref.read(scanFoldersProvider.notifier).addFolder(treeUri);
      String msg;
      try {
        final count = await ref.read(libraryProvider.notifier).scanAllFolders();
        msg = '已添加扫描目录，扫描到 $count 首';
      } catch (e) {
        msg = '已添加扫描目录，但扫描失败：$e';
      }
      if (mounted) _toast(msg);
    } catch (e) {
      if (mounted) _toast(tr('添加失败：{e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  /// 重新授权失效目录：选回同一目录时 tree URI 不变，旧曲库数据直接复活。
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
      String msg;
      try {
        final count = await ref.read(libraryProvider.notifier).scanAllFolders();
        msg = tr('重新授权成功，扫描到 {n} 首', {'n': count});
      } catch (e) {
        msg = tr('重新授权完成，但扫描失败：{e}', {'e': e});
      }
      if (mounted) _toast(msg);
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

  void _buildNodes(
      BuildContext context, List<FolderNodeData> nodes, List<Widget> out) {
    for (final n in nodes) {
      final hasChildren = n.children.isNotEmpty || n.childCount > 0;
      final isExpanded = _expanded.contains(n.path);
      out.add(_FolderTile(
        node: n,
        hasChildren: hasChildren,
        isExpanded: isExpanded,
        onToggle: () {
          setState(() {
            if (isExpanded) {
              _expanded.remove(n.path);
            } else {
              _expanded.add(n.path);
            }
          });
        },
        onOpen: () {
          if (n.songCount > 0) {
            Navigator.of(context, rootNavigator: true).push(
              MaterialPageRoute(
                builder: (_) => SongListPage(
                  title: n.name,
                  loader: () =>
                      ref.read(libraryProvider.notifier).songsByFolder(n.path),
                ),
              ),
            );
          }
        },
        onImport: () => _importAsPlaylist(n),
      ));
      if (isExpanded && n.children.isNotEmpty) {
        _buildNodes(context, n.children, out);
      }
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

  /// 一键扫描全部目录（也作为下拉刷新动作）。
  Future<void> _onRefresh() => _startScan();

  Future<void> _startScan() async {
    if (_scanning) return;
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

  /// 按时长过滤阈值选择（不排除 / 10 / 30 / 60 秒）。
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

  @override
  Widget build(BuildContext context) {
    final lib = ref.watch(libraryProvider);
    final root = ref.watch(libraryProvider.select((s) => s.folderRoot));
    final lost =
        ref.watch(libraryProvider.select((s) => s.unauthorizedFolders));
    final foldersAsync = ref.watch(scanFoldersProvider);
    final minDuration = ref
            .watch(settingsProvider)
            .valueOrNull
            ?.libraryMinDurationSeconds ??
        0;
    final scheme = Theme.of(context).colorScheme;

    final tiles = <Widget>[];
    _buildNodes(context, root, tiles);

    return HideShellChrome(
      child: Scaffold(
        backgroundColor: appScaffoldBackground(context, ref),
        resizeToAvoidBottomInset: false,
        body: RepaintBoundary(
          child: Stack(
            children: [
              Padding(
                padding: EdgeInsets.only(top: GlassTopBar.height(context)),
                child: RefreshIndicator(
                  onRefresh: _onRefresh,
                  child: ListView(
                    padding: EdgeInsets.only(
                      left: 16,
                      right: 16,
                      top: 8,
                      bottom: (ref.watch(playerProvider
                                  .select((s) => s.current != null))
                              ? 92.0
                              : 16.0) +
                          MediaQuery.of(context).padding.bottom,
                    ),
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      // —— 扫描引导（魅族风格：渐变圆标 + 一键扫描）——
                      _ScanHero(
                        scanning: _scanning,
                        onScan: _startScan,
                        onSafFallback:
                            Platform.isAndroid && !_adding
                                ? _addFolderViaSaf
                                : null,
                      ),
                      if (lost.isNotEmpty) _UnauthorizedBanner(lost: lost),
                      const SizedBox(height: 16),
                      // —— 过滤设置 ——
                      _FilterCard(
                        minDuration: minDuration,
                        onToggle: (v) {
                          final next = v ? _lastDuration : 0;
                          ref
                              .read(settingsProvider.notifier)
                              .setLibraryMinDurationSeconds(next);
                        },
                        onPick: () => _pickMinDuration(minDuration),
                      ),
                      const SizedBox(height: 16),
                      // —— 扫描目录管理 ——
                      foldersAsync.when(
                        loading: () => const Padding(
                          padding: EdgeInsets.symmetric(vertical: 24),
                          child: Center(child: CircularProgressIndicator()),
                        ),
                        error: (e, _) => Text(tr('扫描目录加载失败：{e}', {'e': e}),
                            style: TextStyle(
                                fontSize: 13, color: scheme.error)),
                        data: (folders) => _ScanFoldersCard(
                          folders: folders,
                          lost: lost,
                          adding: _adding,
                          onAdd: _adding ? null : _addFolder,
                          onRemove: _removeFolder,
                          onReauthorize: _reauthorize,
                        ),
                      ),
                      const SizedBox(height: 16),
                      // —— 远程音乐库（WebDAV）入口 ——
                      const _RemoteLibraryCard(),
                      // —— 已扫描文件夹树 ——
                      if (root.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                          child: Text(
                            tr('已扫描文件夹'),
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: scheme.primary,
                            ),
                          ),
                        ),
                        Material(
                          color: appCardColor(context),
                          clipBehavior: Clip.antiAlias,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                            side: BorderSide.none,
                          ),
                          child: Column(children: tiles),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: GlassTopBar(
                  leading: const BackButton(),
                  title: Text(tr('文件夹')),
                ),
              ),
              // 统一播放条由外壳承载的逻辑与其他本地页一致：页内自渲染迷你条。
              if (lib.songs.isNotEmpty) const MiniPlayerBar(),
            ],
          ),
        ),
      ),
    );
  }
}

/// 扫描引导头图：径向渐变圆标 + 主标题 + 「开始扫描」胶囊按钮 + SAF 兜底入口。
class _ScanHero extends StatelessWidget {
  const _ScanHero({
    required this.scanning,
    required this.onScan,
    this.onSafFallback,
  });

  final bool scanning;
  final VoidCallback onScan;
  final VoidCallback? onSafFallback;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final light = Color.lerp(scheme.primary, Colors.white, 0.35)!;
    return Column(
      children: [
        const SizedBox(height: 20),
        Container(
          width: 84,
          height: 84,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              center: const Alignment(-0.3, -0.4),
              colors: [light, scheme.primary],
            ),
            boxShadow: [
              BoxShadow(
                color: scheme.primary.withValues(alpha: 0.35),
                blurRadius: 22,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: const Icon(Icons.library_music_rounded,
              color: Colors.white, size: 40),
        ),
        const SizedBox(height: 14),
          Text(
          tr('一键扫描手机内的歌曲文件'),
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 14),
        SizedBox(
          width: 220,
          height: 46,
          child: FilledButton(
            onPressed: scanning ? null : onScan,
            style: FilledButton.styleFrom(
              backgroundColor: scheme.primary,
              foregroundColor: scheme.onPrimary,
              shape: const StadiumBorder(),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (scanning)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  const Icon(Icons.play_arrow_rounded, size: 22),
                const SizedBox(width: 6),
                Text(
                  scanning ? tr('正在扫描…') : tr('开始扫描'),
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ),
        if (onSafFallback != null) ...[
          const SizedBox(height: 4),
          TextButton(
            onPressed: onSafFallback,
            style: TextButton.styleFrom(
              foregroundColor: scheme.primary,
              textStyle: const TextStyle(fontSize: 12),
            ),
            child:   Text(tr('看不到部分歌曲？试试系统选择器添加目录')),
          ),
        ],
      ],
    );
  }
}

/// 过滤设置卡：按时长过滤开关 + 阈值选择。
class _FilterCard extends ConsumerWidget {
  const _FilterCard({
    required this.minDuration,
    required this.onToggle,
    required this.onPick,
  });

  final int minDuration;
  final ValueChanged<bool> onToggle;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;

    return Material(
      color: appCardColor(context),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide.none,
      ),
      child: ListTile(
        leading: Icon(Icons.timer_outlined, color: scheme.primary),
        title:   Text(tr('按时长过滤')),
        subtitle: Text(
          minDuration > 0
              ? tr('已过滤时长小于 {n} 秒的音频文件', {'n': minDuration})
              : tr('可过滤掉时长过短的音频文件（点按调整阈值）'),
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
        trailing: Switch(
          value: minDuration > 0,
          onChanged: onToggle,
        ),
        onTap: onPick,
      ),
    );
  }
}

/// 扫描目录管理卡：目录列表 + 添加 / 重新授权 / 移除。
class _ScanFoldersCard extends ConsumerWidget {
  const _ScanFoldersCard({
    required this.folders,
    required this.lost,
    required this.adding,
    required this.onAdd,
    required this.onRemove,
    required this.onReauthorize,
  });

  final List<ScanFolder> folders;
  final List<String> lost;
  final bool adding;
  final VoidCallback? onAdd;
  final void Function(String path) onRemove;
  final void Function(String path) onReauthorize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;

    return Material(
      color: appCardColor(context),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide.none,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
            child: Row(
              children: [
                Icon(Icons.folder_copy_outlined,
                    size: 20, color: scheme.primary),
                const SizedBox(width: 8),
                Text(
                  folders.isEmpty ? tr('扫描目录') : '扫描目录 · ${folders.length}',
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                IconButton(
                  tooltip: tr('添加目录'),
                  onPressed: onAdd,
                  icon: adding
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.add),
                ),
              ],
            ),
          ),
          if (folders.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
              child: Text(
                tr('还没有扫描目录，点击右上角「+」选择包含音乐的文件夹\n（仅首次需要授予音乐读取权限）'),
                style: TextStyle(
                    fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            )
          else
            for (var i = 0; i < folders.length; i++)
              Builder(builder: (context) {
                final f = folders[i];
                final isLost = lost.contains(f.path);
                return ListTile(
                  dense: true,
                  leading: Icon(
                    isLost ? Icons.folder_off : Icons.folder,
                    color: isLost ? scheme.error : scheme.primary,
                  ),
                  title: FutureBuilder<String>(
                    future: _friendlyFolderName(f.path),
                    builder: (context, snap) => Text(
                      snap.data ?? f.path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  subtitle: Text(
                    isLost ? tr('授权已失效，点击钥匙重新授权') : '${f.songCount} 首',
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
                          tooltip: tr('重新授权'),
                          icon: Icon(Icons.key,
                              color: scheme.error, size: 20),
                          onPressed: () => onReauthorize(f.path),
                        ),
                      IconButton(
                        tooltip: tr('移除'),
                        icon: Icon(Icons.delete_outline,
                            color: scheme.error, size: 20),
                        onPressed: () => onRemove(f.path),
                      ),
                    ],
                  ),
                );
              }),
        ],
      ),
    );
  }
}

/// tree URI → 用户可读目录名（静态缓存，避免列表滚动时反复跨 channel 查询）。
Future<String> _friendlyFolderName(String path) async {
  final hit = _folderNameCache[path];
  if (hit != null) return hit;
  if (!SafChannel.isSafTree(path)) return path;
  final name = await SafChannel.friendlyTreeName(path);
  _folderNameCache[path] = name;
  return name;
}

final Map<String, String> _folderNameCache = {};

/// 授权失效目录的警示横幅（重新授权入口在下方「扫描目录」卡片内）。
///
/// 重新授权选回同一目录时 tree URI 不变，旧曲库数据直接复活，无需重扫。
class _UnauthorizedBanner extends StatelessWidget {
  final List<String> lost;
  const _UnauthorizedBanner({required this.lost});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Material(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              Icon(Icons.folder_off, size: 20, color: scheme.onErrorContainer),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  tr('{n} 个目录授权已失效，可在下方重新授权', {'n': lost.length}),
                  style: TextStyle(
                      fontSize: 13,
                      color: scheme.onErrorContainer,
                      fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FolderTile extends StatelessWidget {
  final FolderNodeData node;
  final bool hasChildren;
  final bool isExpanded;
  final VoidCallback onToggle;
  final VoidCallback onOpen;
  final VoidCallback onImport;
  const _FolderTile({
    required this.node,
    required this.hasChildren,
    required this.isExpanded,
    required this.onToggle,
    required this.onOpen,
    required this.onImport,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.folder),
      title: Text(
        node.name.isNotEmpty ? node.name : node.path.split('/').last,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w500),
      ),
      subtitle: Text(
        tr('{n} 首', {'n': node.songCount}),
        style: const TextStyle(fontSize: 12),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hasChildren)
            IconButton(
              icon: AnimatedRotation(
                turns: isExpanded ? 0.5 : 0,
                duration: const Duration(milliseconds: 200),
                child: const Icon(Icons.expand_more),
              ),
              onPressed: onToggle,
            ),
          if (node.songCount > 0)
            IconButton(icon: const Icon(Icons.play_arrow), onPressed: onOpen),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, size: 20),
            tooltip: tr('更多'),
            onSelected: (action) {
              if (action == 'import') onImport();
            },
            itemBuilder: (ctx) => [
              PopupMenuItem(
                value: 'import',
                enabled: node.songCount > 0,
                child:   Text(tr('导入为歌单')),
              ),
            ],
          ),
        ],
      ),
      onTap: hasChildren ? onToggle : onOpen,
    );
  }
}

/// 远程音乐库 WebDAV 管理入口（从设置页「本地」迁至本文件夹页）。
class _RemoteLibraryCard extends ConsumerWidget {
  const _RemoteLibraryCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;

    return Material(
      color: appCardColor(context),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide.none,
      ),
      child: ListTile(
        leading: Icon(Icons.cloud_outlined, color: scheme.primary),
        title:   Text(tr('远程音乐库 (WebDAV)')),
        subtitle: Text(
          tr('访问 WebDAV 服务器上的音乐资源'),
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
        trailing: Icon(Icons.chevron_right, color: scheme.outline),
        onTap: () => context.push('/remote-library'),
      ),
    );
  }
}
