import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../src/auth/account_api.dart';
import '../../src/auth/auth_provider.dart';
import '../../src/core/app_colors.dart';
import '../../src/core/settings.dart';
import '../../src/navigation/routes.dart' show coverPageRoute;
import '../../src/widgets/custom_background.dart';
import '../../src/widgets/glass_appbar.dart';
import '../../src/widgets/glass_settings.dart';
import '../../src/widgets/blur_budget.dart';
import '../../src/widgets/sheet_dialog.dart';
import '../../src/widgets/app_toast.dart';
import '../../src/i18n/i18n.dart';

/// 下载记录修订号：保存新壁纸后自增，通知「我的下载」列表立即刷新。
/// 「我的下载」Tab 用 keepAlive 常驻，不监听则保存后切过去仍是旧数据（找不到）。
final ValueNotifier<int> _downloadsRevision = ValueNotifier<int>(0);

/// 壁纸中心：壁纸广场 / 我的上传 / 我的下载（对齐桌面端 WallpaperGallery 三 tab）。
class WallpaperCenterPage extends ConsumerStatefulWidget {
  const WallpaperCenterPage({super.key});

  @override
  ConsumerState<WallpaperCenterPage> createState() =>
      _WallpaperCenterPageState();
}

class _WallpaperCenterPageState extends ConsumerState<WallpaperCenterPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab = TabController(length: 4, vsync: this);

  PreferredSizeWidget get _tabBar => TabBar(
        controller: _tab,
        isScrollable: true,
        tabAlignment: TabAlignment.start,
        tabs: [
          Tab(text: tr('壁纸广场')),
          Tab(text: tr('我的上传')),
          Tab(text: tr('我的下载')),
          Tab(text: tr('自定义壁纸')),
        ],
      );

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 竖屏悬浮顶栏：TabBarView 铺满全屏、避让量注入各 tab 滚动体 padding，
    // 内容从顶栏胶囊与 Tab 气泡下方穿过（穿透观感）。
    final portraitFloating =
        MediaQuery.of(context).orientation != Orientation.landscape &&
            (ref.watch(settingsProvider.select(
                    (s) => s.valueOrNull?.floatingSearchBar ?? false)) ==
                true);
    // 悬浮模式内容避让量：顶栏实际总高（状态栏 + 8 顶距 + 48 标题行 + 10 间距
    // + Tab 气泡原高）+ 6 呼吸；固定模式 0（沿用原 Padding 避让结构）。
    final topInset = portraitFloating
        ? MediaQuery.paddingOf(context).top +
            66 +
            _tabBar.preferredSize.height +
            6
        : 0.0;
    return Scaffold(
      backgroundColor: appScaffoldBackground(context, ref),
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          _tabHost(
            portraitFloating,
            topInset,
            RepaintBoundary(
              child: TabBarView(
                controller: _tab,
                children: [
                  _WallpaperBrowseTab(topInset: topInset),
                  _MyUploadsTab(topInset: topInset),
                  _MyDownloadsTab(topInset: topInset),
                  // 编辑器 tab 自带整页预览（StackFit.expand），悬浮模式下
                  // 预览直接顶到屏幕顶，无需避让。
                  const CustomWallpaperEditor(),
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
              title: Text(tr('壁纸中心')),
              bottom: _tabBar,
            ),
          ),
        ],
      ),
    );
  }
  /// 内容容器：悬浮模式铺满全屏（[Positioned.fill]，内容穿透顶栏与 Tab 气泡），
  /// 固定模式沿用 Padding 避让（避让量注入各 tab 滚动体 padding）。
  Widget _tabHost(bool floating, double topInset, Widget child) {
    if (floating) return Positioned.fill(child: child);
    return Padding(
      padding: EdgeInsets.only(
        top: GlassTopBar.height(context, bottom: _tabBar),
      ),
      child: child,
    );
  }

}

// ───────────────────────────────────────────────────────────
// 壁纸广场
// ───────────────────────────────────────────────────────────

class _WallpaperBrowseTab extends ConsumerStatefulWidget {
  const _WallpaperBrowseTab({this.topInset = 0});

  /// 悬浮模式避让量：注入网格滚动 padding.top，内容穿透顶栏；0=固定模式。
  final double topInset;

  @override
  ConsumerState<_WallpaperBrowseTab> createState() =>
      _WallpaperBrowseTabState();
}

class _WallpaperBrowseTabState extends ConsumerState<_WallpaperBrowseTab>
    with AutomaticKeepAliveClientMixin {
  List<Map<String, dynamic>> _wallpapers = [];
  bool _loading = true;
  String? _error;

  @override
  bool get wantKeepAlive => true;

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
      final list = await ref.read(accountApiProvider).fetchWallpapers();
      if (!mounted) return;
      setState(() {
        _wallpapers = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst(RegExp(r'^AuthException: '), '');
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: TextStyle(color: scheme.error)),
            const SizedBox(height: 12),
            FilledButton.tonal(
              onPressed: _load,
              child:   Text(tr('重试')),
            ),
          ],
        ),
      );
    }
    if (_wallpapers.isEmpty) {
      return Center(
        child: Text(tr('暂无壁纸'), style: TextStyle(color: scheme.onSurfaceVariant)),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: GridView.builder(
        padding: EdgeInsets.fromLTRB(12, 12 + widget.topInset, 12, 12),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 0.62,
        ),
        itemCount: _wallpapers.length,
        itemBuilder: (context, i) {
          final w = _wallpapers[i];
          return _WallpaperCard(wallpaper: w);
        },
      ),
    );
  }
}

class _WallpaperCard extends ConsumerWidget {
  const _WallpaperCard({required this.wallpaper, this.statusBadge});

  final Map<String, dynamic> wallpaper;
  final String? statusBadge;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final thumb = (wallpaper['thumbnailUrl'] as String?) ?? '';
    final title = (wallpaper['title'] as String?) ?? '';
    final uploader = (wallpaper['uploaderNickname'] as String?) ?? '';
    return Material(
      clipBehavior: Clip.antiAlias,
      color: appCardColor(context),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
      ),
      child: InkWell(
        onTap: () => _openPreview(context),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (thumb.isNotEmpty)
              CachedNetworkImage(
                imageUrl: thumb,
                fit: BoxFit.cover,
                placeholder: (_, _) => Center(
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: scheme.primary.withValues(alpha: 0.5),
                    ),
                  ),
                ),
                errorWidget: (_, _, _) => Icon(
                  Icons.image_not_supported_outlined,
                  color: scheme.onSurfaceVariant,
                ),
              )
            else
              Center(
                child: Icon(Icons.image_outlined,
                    color: scheme.onSurfaceVariant),
              ),
            if (statusBadge != null)
              Positioned(
                top: 6,
                right: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    statusBadge!,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 11),
                  ),
                ),
              ),
            // 描述直接叠加在壁纸内底部：白字 + 底部渐变保证可读，
            // 不再单独做图片下方的描述框（壁纸模式下也天然清晰）。
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.fromLTRB(10, 28, 10, 10),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.6),
                    ],
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Colors.white)),
                    if (uploader.isNotEmpty)
                      Text(uploader,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 11, color: Colors.white70)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openPreview(BuildContext context) {
    Navigator.of(context).push(coverPageRoute<void>(
      context,
      (_) => _WallpaperPreviewPage(wallpaper: wallpaper),
    ));
  }
}

// ───────────────────────────────────────────────────────────
// 壁纸全屏预览 + 保存
// ───────────────────────────────────────────────────────────

class _WallpaperPreviewPage extends ConsumerStatefulWidget {
  const _WallpaperPreviewPage({required this.wallpaper});

  final Map<String, dynamic> wallpaper;

  @override
  ConsumerState<_WallpaperPreviewPage> createState() =>
      _WallpaperPreviewPageState();
}

class _WallpaperPreviewPageState extends ConsumerState<_WallpaperPreviewPage> {
  /// 已落盘的本地路径（从「我的下载」进入时预填；本页保存后回填）。
  String? _localPath;
  bool _busy = false;
  String? _result;

  bool get _hasLocal => _localPath != null && File(_localPath!).existsSync();

  @override
  void initState() {
    super.initState();
    final lp = (widget.wallpaper['localPath'] as String?) ?? '';
    if (lp.isNotEmpty && File(lp).existsSync()) {
      _localPath = lp;
    }
  }

  /// 确保壁纸已保存到本地（未保存则下载落盘并写入「我的下载」记录），返回本地路径。
  Future<String> _ensureLocal() async {
    if (_hasLocal) return _localPath!;
    final url = (widget.wallpaper['imageUrl'] as String?) ?? '';
    if (url.isEmpty) throw Exception(tr('壁纸地址无效'));
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    final req = await client.getUrl(Uri.parse(url));
    final res = await req.close();
    if (res.statusCode != 200) {
      throw Exception(tr('下载失败（HTTP {status}）', {'status': res.statusCode}));
    }
    final bytes = await consolidateBytes(res);
    // 保存目录：应用文档目录 Wallpapers/（缓存目录会被系统清理，不可持久化）。
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'XianYuWallpapers'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final id = widget.wallpaper['id'];
    final title = (widget.wallpaper['title'] as String?) ?? 'wallpaper';
    final safeName = title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final file = File(p.join(dir.path, 'wallpaper_${id}_$safeName.jpg'));
    await file.writeAsBytes(bytes);
    await _recordDownload(widget.wallpaper, file.path);
    _downloadsRevision.value++; // 通知「我的下载」列表刷新
    _localPath = file.path;
    return _localPath!;
  }

  /// 仅保存到本地。
  Future<void> _saveOnly() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _result = null;
    });
    try {
      final path = await _ensureLocal();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _result = tr('已保存：{path}', {'path': path});
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _result = tr('保存失败：{e}', {'e': e});
      });
    }
  }

  /// 保存到本地，并打开自定义壁纸编辑器（预加载该图，由用户调参后保存应用）。
  Future<void> _saveAndApply() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _result = null;
    });
    try {
      final path = await _ensureLocal();
      if (!mounted) return;
      setState(() => _busy = false);
      await _openCustomEditor(path);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _result = tr('保存失败：{e}', {'e': e});
      });
    }
  }

  /// 打开自定义壁纸编辑器并预加载本地壁纸（「应用壁纸」UI 入口）。
  Future<void> _apply() async {
    if (_busy) return;
    final target = _localPath;
    if (target == null || !File(target).existsSync()) {
      if (mounted) showXianYuToast(context, tr('请先保存壁纸'));
      return;
    }
    await _openCustomEditor(target);
  }

  /// 跳转到自定义壁纸编辑器，预加载 [path] 让用户调整后应用（不做任何即时整屏应用）。
  Future<void> _openCustomEditor(String path) async {
    if (!mounted) return;
    final applied = await Navigator.of(context).push<bool?>(
      coverPageRoute<bool>(
        context,
        (_) => WallpaperCustomApplyPage(imagePath: path),
      ),
    );
    if (!mounted) return;
    if (applied == true) {
      // 已在自定义界面「保存并使用」→ 把预览页一起关掉，直接回到壁纸中心，
      // 免去「应用后还要原路返回」。
      Navigator.of(context).pop(true);
      return;
    }
    showXianYuToast(context, tr('请在自定义界面点击「保存并使用」完成应用'));
  }

  Future<Uint8List> consolidateBytes(HttpClientResponse res) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in res) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  Future<void> _recordDownload(
      Map<String, dynamic> wallpaper, String localPath) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('xianyu_downloaded_wallpapers_v1');
      final list = raw == null
          ? <Map<String, dynamic>>[]
          : (jsonDecode(raw) as List)
              .whereType<Map>()
              .map((m) => Map<String, dynamic>.from(m.cast<String, dynamic>()))
              .toList();
      list.removeWhere((m) => m['id'] == wallpaper['id']);
      list.insert(0, {
        ...wallpaper,
        'localPath': localPath,
        'downloadedAt': DateTime.now().toIso8601String(),
      });
      await prefs.setString(
          'xianyu_downloaded_wallpapers_v1', jsonEncode(list));
    } catch (_) {}
  }

  /// 忙碌态小菊花。
  Widget _spinner({double size = 16}) => SizedBox(
        width: size,
        height: size,
        child: CircularProgressIndicator(
            strokeWidth: 2, color: Colors.white),
      );

  @override
  Widget build(BuildContext context) {
    final url = (widget.wallpaper['imageUrl'] as String?) ?? '';
    final hasLocal = _hasLocal;
    final title = (widget.wallpaper['title'] as String?) ?? '';
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        backgroundColor: Colors.black.withValues(alpha: 0.4),
      ),
      body: Column(
        children: [
          Expanded(
            child: InteractiveViewer(
              maxScale: 4,
              child: Center(
                child: hasLocal
                    ? Image.file(File(_localPath!), fit: BoxFit.contain)
                    : url.isEmpty
                        ? const Icon(Icons.image_not_supported_outlined,
                            color: Colors.white54, size: 64)
                        : CachedNetworkImage(
                            imageUrl: url,
                            fit: BoxFit.contain,
                            errorWidget: (_, _, _) => const Icon(
                                Icons.broken_image_outlined,
                                color: Colors.white54,
                                size: 64),
                          ),
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_result != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Text(
                        _result!,
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 12),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  if (!hasLocal) ...[
                    // 主操作：保存到本地并应用；次操作：仅保存。
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _busy ? null : _saveAndApply,
                        icon: _busy ? _spinner() : const Icon(Icons.check),
                        label: Text(_busy ? tr('保存并应用中…') : tr('保存并应用')),
                      ),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _busy ? null : _saveOnly,
                        icon: const Icon(Icons.download_outlined),
                        label: Text(tr('仅保存到本地')),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: const BorderSide(color: Colors.white54),
                        ),
                      ),
                    ),
                  ] else ...[
                    // 已保存：打开自定义壁纸编辑器，可调参后应用。
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _busy ? null : _apply,
                        icon: const Icon(Icons.tune),
                        label: Text(tr('应用壁纸')),
                      ),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.tonalIcon(
                        onPressed: null,
                        icon: const Icon(Icons.cloud_done_outlined),
                        label: Text(tr('已保存到本地')),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────────────────────────────────────────
// 我的上传
// ───────────────────────────────────────────────────────────

class _MyUploadsTab extends ConsumerStatefulWidget {
  const _MyUploadsTab({this.topInset = 0});

  /// 悬浮模式避让量：注入网格滚动 padding.top，内容穿透顶栏；0=固定模式。
  final double topInset;

  @override
  ConsumerState<_MyUploadsTab> createState() => _MyUploadsTabState();
}

class _MyUploadsTabState extends ConsumerState<_MyUploadsTab>
    with AutomaticKeepAliveClientMixin {
  List<Map<String, dynamic>> _mine = [];
  bool _loading = false;
  String? _error;

  @override
  bool get wantKeepAlive => true;

  String? get _ciyuanxiId =>
      ref.read(authProvider).user?.ciyuanxiId?.isNotEmpty == true
          ? ref.read(authProvider).user!.ciyuanxiId
          : null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeLoad());
  }

  Future<void> _maybeLoad() async {
    if (_ciyuanxiId != null && _mine.isEmpty && !_loading) {
      await _load();
    }
  }

  Future<void> _load() async {
    if (_ciyuanxiId == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await ref.read(accountApiProvider).fetchMyWallpapers();
      if (!mounted) return;
      setState(() {
        _mine = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst(RegExp(r'^AuthException: '), '');
        _loading = false;
      });
    }
  }

  Future<void> _openUpload() async {
    if (_ciyuanxiId == null) {
      showXianYuToast(context, tr('请先登录账号后再上传壁纸'));
      return;
    }
    final ok = await showSheetDialog<bool>(
      context,
      (_) => const _WallpaperUploadSheet(),
    );
    if (ok == true && mounted) {
      _tabRefresh();
    }
  }

  void _tabRefresh() {
    setState(() => _mine = []);
    _load();
  }

  String _statusBadge(String status) {
    switch (status) {
      case 'normal':
        return tr('已上架');
      case 'pending':
        return tr('待审核');
      case 'rejected':
        return tr('未通过');
      case 'disabled':
        return tr('已下架');
      default:
        return status;
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final scheme = Theme.of(context).colorScheme;
    if (_ciyuanxiId == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            tr('登录后可上传壁纸并在多端同步展示'),
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        ),
      );
    }
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    return Stack(
      children: [
        if (_error != null)
          Center(child: Text(_error!, style: TextStyle(color: scheme.error)))
        else if (_mine.isEmpty)
          Center(
            child: Text(tr('还没有上传过壁纸'),
                style: TextStyle(color: scheme.onSurfaceVariant)),
          )
        else
          RefreshIndicator(
            onRefresh: _load,
            child: GridView.builder(
              padding: EdgeInsets.fromLTRB(12, 12 + widget.topInset, 12, 12),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 0.62,
              ),
              itemCount: _mine.length,
              itemBuilder: (context, i) => _WallpaperCard(
                wallpaper: _mine[i],
                statusBadge: _statusBadge((_mine[i]['status'] as String?) ?? ''),
              ),
            ),
          ),
        Positioned(
          right: 16,
          bottom: 24,
          child: FloatingActionButton.extended(
            onPressed: _openUpload,
            icon: const Icon(Icons.upload_outlined),
            label:   Text(tr('上传壁纸')),
          ),
        ),
      ],
    );
  }
}

/// 上传壁纸底部弹层：选图 + 标题/描述/分类 → 压缩 → 上传。
class _WallpaperUploadSheet extends ConsumerStatefulWidget {
  const _WallpaperUploadSheet();

  @override
  ConsumerState<_WallpaperUploadSheet> createState() =>
      _WallpaperUploadSheetState();
}

class _WallpaperUploadSheetState extends ConsumerState<_WallpaperUploadSheet> {
  final _titleCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _categoryCtrl = TextEditingController();
  XFile? _picked;
  bool _uploading = false;
  String? _error;

  @override
  void dispose() {
    _titleCtrl.dispose();
    _descCtrl.dispose();
    _categoryCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    try {
      final picked = await ImagePicker().pickImage(
          source: ImageSource.gallery, imageQuality: 100);
      if (picked != null && mounted) {
        setState(() {
          _picked = picked;
          _error = null;
        });
      }
    } catch (_) {}
  }

  /// 压缩为最大宽 1920 的 JPEG data URL（与桌面端 compressImageToDataUrl 对齐）。
  Future<String> _compressToDataUrl(XFile file) async {
    final bytes = await file.readAsBytes();
    final image = img.decodeImage(bytes);
    if (image == null) throw Exception(tr('图片解析失败'));
    var out = image;
    if (image.width > 1920) {
      final h = (image.height * 1920 / image.width).round();
      out = img.copyResize(image, width: 1920, height: h);
    }
    final jpeg = img.encodeJpg(out, quality: 80);
    return 'data:image/jpeg;base64,${base64Encode(jpeg)}';
  }

  Future<void> _submit() async {
    final title = _titleCtrl.text.trim();
    if (title.isEmpty) {
      setState(() => _error = tr('请填写壁纸标题'));
      return;
    }
    if (_picked == null) {
      setState(() => _error = tr('请选择壁纸图片'));
      return;
    }
    setState(() {
      _uploading = true;
      _error = null;
    });
    try {
      final imageData = await _compressToDataUrl(_picked!);
      await ref.read(accountApiProvider).uploadWallpaper(
            title: title,
            description: _descCtrl.text.trim(),
            category: _categoryCtrl.text.trim(),
            imageData: imageData,
          );
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _uploading = false;
        _error = e.toString().replaceFirst(RegExp(r'^AuthException: '), '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(tr('上传壁纸'),
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 14),
          GestureDetector(
            onTap: _uploading ? null : _pickImage,
            child: Container(
              height: 160,
              decoration: BoxDecoration(
                color: appCardColor(context),
                borderRadius: BorderRadius.circular(14),
              ),
              child: _picked == null
                  ? Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.add_photo_alternate_outlined,
                              size: 40, color: scheme.onSurfaceVariant),
                          const SizedBox(height: 8),
                          Text(
                            tr('点击选择图片\n(JPG / PNG / WEBP，30MB 以内)'),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.4,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    )
                  : ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: Image.file(File(_picked!.path),
                          fit: BoxFit.cover,
                          width: double.infinity),
                    ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _titleCtrl,
            enabled: !_uploading,
            decoration:   InputDecoration(
                labelText: tr('标题'), isDense: true, border: OutlineInputBorder()),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _descCtrl,
            enabled: !_uploading,
            maxLines: 2,
            decoration:   InputDecoration(
                labelText: tr('描述（可选）'),
                isDense: true,
                border: OutlineInputBorder()),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _categoryCtrl,
            enabled: !_uploading,
            decoration:   InputDecoration(
                labelText: tr('分类（可选，默认「用户上传」）'),
                isDense: true,
                border: OutlineInputBorder()),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(_error!,
                  style: TextStyle(color: scheme.error, fontSize: 12)),
            ),
          const SizedBox(height: 14),
          FilledButton(
            onPressed: _uploading ? null : _submit,
            child: _uploading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                :   Text(tr('提交审核')),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────────────────────────────────────────
// 我的下载
// ───────────────────────────────────────────────────────────

class _MyDownloadsTab extends StatefulWidget {
  const _MyDownloadsTab({this.topInset = 0});

  /// 悬浮模式避让量：注入列表滚动 padding.top，内容穿透顶栏；0=固定模式。
  final double topInset;

  @override
  State<_MyDownloadsTab> createState() => _MyDownloadsTabState();
}

class _MyDownloadsTabState extends State<_MyDownloadsTab>
    with AutomaticKeepAliveClientMixin {
  List<Map<String, dynamic>> _downloads = [];

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
    // 下载记录修订号变化（本页或其它入口新增壁纸）时刷新列表。
    _downloadsRevision.addListener(_load);
  }

  @override
  void dispose() {
    _downloadsRevision.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('xianyu_downloaded_wallpapers_v1');
      final list = raw == null
          ? <Map<String, dynamic>>[]
          : (jsonDecode(raw) as List)
              .whereType<Map>()
              .map((m) => Map<String, dynamic>.from(m.cast<String, dynamic>()))
              .toList();
      if (mounted) setState(() => _downloads = list);
    } catch (_) {}
  }

  Future<void> _remove(int index) async {
    final list = [..._downloads];
    final removed = list.removeAt(index);
    setState(() => _downloads = list);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          'xianyu_downloaded_wallpapers_v1', jsonEncode(list));
      final localPath = removed['localPath'] as String?;
      if (localPath != null && localPath.isNotEmpty) {
        final f = File(localPath);
        if (await f.exists()) await f.delete();
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final scheme = Theme.of(context).colorScheme;
    if (_downloads.isEmpty) {
      return Center(
        child: Text(tr('还没有下载过壁纸'),
            style: TextStyle(color: scheme.onSurfaceVariant)),
      );
    }
    return ListView.separated(
      padding: EdgeInsets.fromLTRB(16, 16 + widget.topInset, 16, 16),
      itemCount: _downloads.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final w = _downloads[i];
        final thumb = (w['thumbnailUrl'] as String?) ?? '';
        final title = (w['title'] as String?) ?? '';
        final path = (w['localPath'] as String?) ?? '';
        final exists = File(path).existsSync();
        return ListTile(
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: thumb.isNotEmpty
                ? CachedNetworkImage(
                    imageUrl: thumb,
                    width: 48,
                    height: 48,
                    fit: BoxFit.cover,
                    errorWidget: (_, _, _) => const SizedBox(
                        width: 48,
                        height: 48,
                        child: Icon(Icons.image_outlined)),
                  )
                : const SizedBox(
                    width: 48, height: 48, child: Icon(Icons.image_outlined)),
          ),
          title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            exists ? path : tr('本地文件已不存在'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
          trailing: IconButton(
            icon: Icon(Icons.delete_outline, color: scheme.error),
            onPressed: () => _remove(i),
          ),
          onTap: () {
            if (exists) {
              Navigator.of(context).push(coverPageRoute<void>(
                context,
                (_) => _WallpaperPreviewPage(wallpaper: w),
              ));
            }
          },
        );
      },
    );
  }
}

// ───────────────────────────────────────────────────────────
// 自定义壁纸（对齐桌面端 CustomSkinModal）
//
// 同时作为「壁纸中心-自定义壁纸」Tab 展示，以及「壁纸广场」预览页应用壁纸时
// 打开的独立编辑页（传入 initialImagePath 预加载下载壁纸，由用户调参后保存）。
// ───────────────────────────────────────────────────────────

class CustomWallpaperEditor extends ConsumerStatefulWidget {
  const CustomWallpaperEditor({super.key, this.initialImagePath});

  /// 预加载图片路径；为 null 时读取当前已保存的自定义背景。
  final String? initialImagePath;

  @override
  ConsumerState<CustomWallpaperEditor> createState() =>
      _CustomWallpaperEditorState();
}

/// 「应用壁纸」独立编辑页：带返回栏，预加载下载壁纸。
class WallpaperCustomApplyPage extends StatelessWidget {
  const WallpaperCustomApplyPage({super.key, required this.imagePath});

  final String imagePath;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('自定义壁纸'))),
      body: CustomWallpaperEditor(initialImagePath: imagePath),
    );
  }
}

class _CustomWallpaperEditorState
    extends ConsumerState<CustomWallpaperEditor> {
  late CustomBackground _draft;

  @override
  void initState() {
    super.initState();
    final ip = widget.initialImagePath;
    if (ip != null && ip.isNotEmpty && File(ip).existsSync()) {
      // 已下载壁纸预加载：用「清晰档」起步（不整屏模糊），用户可再调。
      _draft = CustomBackground(
        imagePath: ip,
        enabled: true,
        blur: 0,
        maskAlpha: 18,
      );
    } else {
      _draft = ref.read(settingsProvider).valueOrNull?.customBackground ??
          CustomBackground.none;
    }
  }

  Future<void> _pickImage() async {
    final picked =
        await ImagePicker().pickImage(source: ImageSource.gallery);
    if (picked == null) return;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(docs.path, 'custom_background'));
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final ext = p.extension(picked.path).toLowerCase();
      // 统一文件名，旧文件直接覆盖，避免每次选图都堆积一份。
      final target = p.join(dir.path, 'wallpaper$ext');
      await File(picked.path).copy(target);
      if (!mounted) return;
      setState(() => _draft = _draft.copyWith(imagePath: target));
    } catch (_) {
      if (mounted) showXianYuToast(context, tr('请先选择图片'));
    }
  }

  Future<void> _apply() async {
    if (_draft.imagePath.isEmpty) {
      showXianYuToast(context, tr('请先选择图片'));
      return;
    }
    final overlay = Overlay.of(context, rootOverlay: true);
    await ref
        .read(settingsProvider.notifier)
        .setCustomBackground(_draft.copyWith(enabled: true));
    // 应用成功后直接关闭本编辑页（并把结果透传给预览页，让其一起关掉，
    // 免去「应用后还要原路返回」）。
    showXianYuToastByOverlay(overlay, tr('已应用自定义壁纸'));
    if (mounted) Navigator.of(context).pop(true);
  }

  Future<void> _restore() async {
    final overlay = Overlay.of(context, rootOverlay: true);
    await ref
        .read(settingsProvider.notifier)
        .setCustomBackground(CustomBackground.none);
    if (mounted) setState(() => _draft = CustomBackground.none);
    showXianYuToastByOverlay(overlay, tr('已恢复默认背景'));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final hasImage =
        _draft.imagePath.isNotEmpty && File(_draft.imagePath).existsSync();
    // 整页预览：草稿作为整个 tab 的背景透出，控件聚合到底部圆角控制面板。
    // 面板用略实的半透明底保证控件可读，顶部留白展示整页壁纸效果。
    final panelBg = isDark
        ? const Color(0xDE262626)
        : const Color(0xEFFFFFFF);
    // 已选图片（面板叠在壁纸草图上）：改为透明 + 高斯模糊毛玻璃，透出壁纸
    // 又保证控件可读，避免壁纸状态下实色底板太「压」背景难看清。
    final glassPanel = hasImage;
    final panelColor = glassPanel
        ? Colors.white.withValues(alpha: isDark ? 0.38 : 0.58)
        : panelBg;

    return Stack(
      fit: StackFit.expand,
      children: [
        CustomBackgroundLayer(background: _draft),
        if (!hasImage)
          Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.wallpaper,
                      size: 48, color: Colors.white70),
                  const SizedBox(height: 12),
                  Text(
                    tr('从相册选择一张图片作为应用背景'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70),
                  ),
                ],
              ),
            ),
          ),
        Align(
          alignment: Alignment.bottomCenter,
          child: _FrostedSheet(
            enabled: glassPanel,
            radius: 28,
            child: Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: panelColor,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(28),
                topRight: Radius.circular(28),
              ),
              border: Border(
                top: BorderSide(
                  color: scheme.onSurface.withValues(alpha: 0.08),
                ),
              ),
            ),
            child: SafeArea(
              top: false,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.7,
                ),
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            tr('自定义壁纸'),
                            style: const TextStyle(
                                fontSize: 17, fontWeight: FontWeight.w700),
                          ),
                        ),
                        if (hasImage)
                          TextButton(
                            onPressed: _draft.active ? _restore : null,
                            child: Text(tr('恢复默认')),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _pickImage,
                        icon: const Icon(Icons.photo_library_outlined,
                            size: 18),
                        label: Text(
                            hasImage ? tr('更换图片') : tr('选择本地图片')),
                      ),
                    ),
                    if (hasImage) ...[
                      const SizedBox(height: 12),
                      _ParamSlider(
                        icon: Icons.blur_on,
                        label: tr('模糊'),
                        value: _draft.blur,
                        min: 0,
                        max: 40,
                        divisions: 40,
                        onChanged: (v) =>
                            setState(() => _draft = _draft.copyWith(blur: v)),
                      ),
                      _ParamSlider(
                        icon: Icons.opacity,
                        label: tr('不透明度'),
                        value: _draft.opacity,
                        min: 10,
                        max: 100,
                        divisions: 90,
                        onChanged: (v) =>
                            setState(() => _draft = _draft.copyWith(opacity: v)),
                      ),
                      _ParamSlider(
                        icon: Icons.dark_mode_outlined,
                        label: tr('遮罩'),
                        value: _draft.maskAlpha,
                        min: 0,
                        max: 60,
                        divisions: 60,
                        suffix: tr('压暗'),
                        onChanged: (v) => setState(
                            () => _draft = _draft.copyWith(maskAlpha: v)),
                      ),
                      _ParamSlider(
                        icon: Icons.zoom_out_map,
                        label: tr('缩放'),
                        value: _draft.scale,
                        min: 80,
                        max: 160,
                        divisions: 80,
                        onChanged: (v) => setState(
                            () => _draft = _draft.copyWith(scale: v)),
                      ),
                      // 组件底色块不透明度：壁纸下原本透明的卡片/控件改为
                      // 反色色块（亮字→深色块、暗字→浅色块），可调 0~90%，
                      // 0 = 完全透明。
                      _ParamSlider(
                        icon: Icons.invert_colors,
                        label: tr('组件底色'),
                        value: _draft.widgetAlpha,
                        min: 0,
                        max: 90,
                        divisions: 90,
                        suffix: '%',
                        onChanged: (v) => setState(
                            () => _draft = _draft.copyWith(widgetAlpha: v)),
                      ),
                      const SizedBox(height: 4),
                      // 全局字体颜色档位：保存并使用后随壁纸一起生效/持久化。
                      SegmentedButton<WallpaperTextColor>(
                        segments: [
                          ButtonSegment(
                            value: WallpaperTextColor.follow,
                            label: Text(tr('默认')),
                          ),
                          ButtonSegment(
                            value: WallpaperTextColor.light,
                            label: Text(tr('亮色字体')),
                          ),
                          ButtonSegment(
                            value: WallpaperTextColor.dark,
                            label: Text(tr('暗色字体')),
                          ),
                        ],
                        selected: {_draft.textMode},
                        showSelectedIcon: false,
                        onSelectionChanged: (selection) => setState(
                            () => _draft =
                                _draft.copyWith(textMode: selection.first)),
                      ),
                      const SizedBox(height: 20),
                      FilledButton.icon(
                        onPressed: _apply,
                        icon: const Icon(Icons.check, size: 18),
                        label: Text(tr('保存并使用')),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(46),
                          textStyle: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          ),
        ),
      ],
    );
  }
}

/// 底部圆角面板的伪毛玻璃包装：开启时叠一层透明 + 高斯模糊（透出壁纸草图），
/// 关闭时原样返回子组件（保持不透明实底）。圆角与面板顶部两角对齐。
/// 接入全局 blur 预算：滚动/转场时面板玻璃降级（drawerOrSheet 档）。
class _FrostedSheet extends ConsumerWidget {
  const _FrostedSheet({
    required this.enabled,
    required this.radius,
    required this.child,
  });

  final bool enabled;
  final double radius;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!enabled) return child;
    final budget = ref.watch(blurBudgetProvider(BlurSurfaceType.drawerOrSheet));
    final sigma = surfaceBlurSigma(
      base: 12,
      budget: budget,
      type: BlurSurfaceType.drawerOrSheet,
    );
    // 降采样模糊（cheapBackdropBlur）：模糊工作量降为 1/16，
    // 运动期保持玻璃恒定（RwaS 口径），sigma 按预算档位缩放。
    return ClipRRect(
      borderRadius: BorderRadius.only(
        topLeft: Radius.circular(radius),
        topRight: Radius.circular(radius),
      ),
      child: BackdropFilter(
        filter: cheapBackdropBlur(sigma),
        child: child,
      ),
    );
  }
}

/// 单条参数滑块：图标 + 名称 + 实时值，便于边调边看预览。
class _ParamSlider extends StatelessWidget {
  const _ParamSlider({
    required this.icon,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
    this.suffix,
  });

  final IconData icon;
  final String label;
  final int value;
  final int min;
  final int max;
  final int divisions;
  final String? suffix;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: scheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Text(label,
                  style: const TextStyle(fontSize: 14)),
              const Spacer(),
              Text(
                '$value${suffix ?? ''}',
                style: TextStyle(
                  fontSize: 13,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          Slider(
            value: value.toDouble(),
            min: min.toDouble(),
            max: max.toDouble(),
            divisions: divisions,
            onChanged: (v) => onChanged(v.round()),
          ),
        ],
      ),
    );
  }
}
