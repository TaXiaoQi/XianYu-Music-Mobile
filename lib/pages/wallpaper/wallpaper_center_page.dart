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
import '../../src/widgets/sheet_dialog.dart';
import '../../src/widgets/app_toast.dart';

/// 壁纸中心：壁纸广场 / 我的上传 / 我的下载（对齐桌面端 WallpaperGallery 三 tab）。
class WallpaperCenterPage extends ConsumerStatefulWidget {
  const WallpaperCenterPage({super.key});

  @override
  ConsumerState<WallpaperCenterPage> createState() =>
      _WallpaperCenterPageState();
}

class _WallpaperCenterPageState extends ConsumerState<WallpaperCenterPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab = TabController(length: 3, vsync: this);

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        title: const Text('壁纸中心'),
        bottom: TabBar(
          controller: _tab,
          tabs: const [
            Tab(text: '壁纸广场'),
            Tab(text: '我的上传'),
            Tab(text: '我的下载'),
          ],
        ),
      ),
      body: RepaintBoundary(child: TabBarView(
        controller: _tab,
        children: const [
          _WallpaperBrowseTab(),
          _MyUploadsTab(),
          _MyDownloadsTab(),
        ],
        ),
      ),
    );
  }
}

// ───────────────────────────────────────────────────────────
// 壁纸广场
// ───────────────────────────────────────────────────────────

class _WallpaperBrowseTab extends ConsumerStatefulWidget {
  const _WallpaperBrowseTab();

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
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    if (_wallpapers.isEmpty) {
      return Center(
        child: Text('暂无壁纸', style: TextStyle(color: scheme.onSurfaceVariant)),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: GridView.builder(
        padding: const EdgeInsets.all(12),
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

class _WallpaperCard extends StatelessWidget {
  const _WallpaperCard({required this.wallpaper, this.statusBadge});

  final Map<String, dynamic> wallpaper;
  final String? statusBadge;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final thumb = (wallpaper['thumbnailUrl'] as String?) ?? '';
    final title = (wallpaper['title'] as String?) ?? '';
    final uploader = (wallpaper['uploaderNickname'] as String?) ?? '';
    return Material(
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      color: appCardColor(context),
      child: InkWell(
        onTap: () => _openPreview(context),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
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
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600)),
                  if (uploader.isNotEmpty)
                    Text(uploader,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 11, color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openPreview(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => _WallpaperPreviewPage(wallpaper: wallpaper),
    ));
  }
}

// ───────────────────────────────────────────────────────────
// 壁纸全屏预览 + 保存
// ───────────────────────────────────────────────────────────

class _WallpaperPreviewPage extends StatefulWidget {
  const _WallpaperPreviewPage({required this.wallpaper});

  final Map<String, dynamic> wallpaper;

  @override
  State<_WallpaperPreviewPage> createState() => _WallpaperPreviewPageState();
}

class _WallpaperPreviewPageState extends State<_WallpaperPreviewPage> {
  bool _saving = false;
  String? _saveResult;

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _saveResult = null;
    });
    try {
      final url = (widget.wallpaper['imageUrl'] as String?) ?? '';
      if (url.isEmpty) throw Exception('壁纸地址无效');
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
      final req = await client.getUrl(Uri.parse(url));
      final res = await req.close();
      if (res.statusCode != 200) {
        throw Exception('下载失败（HTTP ${res.statusCode}）');
      }
      final bytes = await consolidateBytes(res);
      // 保存目录：应用文档目录 Wallpapers/（缓存目录会被系统清理，不可持久化）。
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(docs.path, 'XianYuWallpapers'));
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final id = widget.wallpaper['id'];
      final title = (widget.wallpaper['title'] as String?) ?? 'wallpaper';
      final safeName = title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final file =
          File(p.join(dir.path, 'wallpaper_${id}_$safeName.jpg'));
      await file.writeAsBytes(bytes);
      await _recordDownload(widget.wallpaper, file.path);
      if (!mounted) return;
      setState(() {
        _saving = false;
        _saveResult = '已保存：${file.path}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _saveResult = '保存失败：$e';
      });
    }
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

  @override
  Widget build(BuildContext context) {
    final url = (widget.wallpaper['imageUrl'] as String?) ?? '';
    final localPath = (widget.wallpaper['localPath'] as String?) ?? '';
    final hasLocal = localPath.isNotEmpty && File(localPath).existsSync();
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
                    ? Image.file(File(localPath), fit: BoxFit.contain)
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
                  if (!hasLocal) ...[
                    if (_saveResult != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Text(
                          _saveResult!,
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 12),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _saving ? null : _save,
                        icon: _saving
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white))
                            : const Icon(Icons.download_outlined),
                        label: Text(_saving ? '保存中…' : '保存壁纸'),
                      ),
                    ),
                  ] else
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.tonalIcon(
                        onPressed: null,
                        icon: const Icon(Icons.check_circle_outline),
                        label: const Text('已保存到本地'),
                      ),
                    ),
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
  const _MyUploadsTab();

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
      showXianYuToast(context, '请先登录账号后再上传壁纸');
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
        return '已上架';
      case 'pending':
        return '待审核';
      case 'rejected':
        return '未通过';
      case 'disabled':
        return '已下架';
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
            '登录后可上传壁纸并在多端同步展示',
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
            child: Text('还没有上传过壁纸',
                style: TextStyle(color: scheme.onSurfaceVariant)),
          )
        else
          RefreshIndicator(
            onRefresh: _load,
            child: GridView.builder(
              padding: const EdgeInsets.all(12),
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
            label: const Text('上传壁纸'),
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
    if (image == null) throw Exception('图片解析失败');
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
      setState(() => _error = '请填写壁纸标题');
      return;
    }
    if (_picked == null) {
      setState(() => _error = '请选择壁纸图片');
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
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 8,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('上传壁纸',
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
                  ? Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.add_photo_alternate_outlined,
                            size: 40, color: scheme.onSurfaceVariant),
                        const SizedBox(height: 6),
                        Text('点击选择图片（JPG / PNG / WEBP，30MB 以内）',
                            style: TextStyle(
                                fontSize: 12,
                                color: scheme.onSurfaceVariant)),
                      ],
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
            decoration: const InputDecoration(
                labelText: '标题', isDense: true, border: OutlineInputBorder()),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _descCtrl,
            enabled: !_uploading,
            maxLines: 2,
            decoration: const InputDecoration(
                labelText: '描述（可选）',
                isDense: true,
                border: OutlineInputBorder()),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _categoryCtrl,
            enabled: !_uploading,
            decoration: const InputDecoration(
                labelText: '分类（可选，默认「用户上传」）',
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
                : const Text('提交审核'),
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
  const _MyDownloadsTab();

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
        child: Text('还没有下载过壁纸',
            style: TextStyle(color: scheme.onSurfaceVariant)),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(16),
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
            exists ? path : '本地文件已不存在',
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
              Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) =>
                    _WallpaperPreviewPage(wallpaper: w),
              ));
            }
          },
        );
      },
    );
  }
}
