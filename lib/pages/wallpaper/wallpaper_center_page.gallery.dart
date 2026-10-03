part of 'wallpaper_center_page.dart';

class _WallpaperBrowseTab extends ConsumerStatefulWidget {
  const _WallpaperBrowseTab({this.topInset = 0});

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
            FilledButton.tonal(onPressed: _load, child: Text(tr('重试'))),
          ],
        ),
      );
    }
    if (_wallpapers.isEmpty) {
      return Center(
        child: Text(
          tr('暂无壁纸'),
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
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

  bool get _isVideo {
    final mt = (wallpaper['mediaType'] as String?) ?? '';
    return mt == 'video';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final thumb = (wallpaper['thumbnailUrl'] as String?) ?? '';
    final title = (wallpaper['title'] as String?) ?? '';
    final uploader = (wallpaper['uploaderNickname'] as String?) ?? '';
    return Material(
      clipBehavior: Clip.antiAlias,
      color: appCardColor(context),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
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
                child: Icon(
                  Icons.image_outlined,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            if (statusBadge != null)
              Positioned(
                top: 6,
                right: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    statusBadge!,
                    style: const TextStyle(color: Colors.white, fontSize: 11),
                  ),
                ),
              ),
            if (_isVideo)
              Positioned(
                top: 6,
                left: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.play_circle_outline,
                        size: 13,
                        color: Colors.white,
                      ),
                      SizedBox(width: 2),
                      Text(
                        '视频',
                        style: TextStyle(color: Colors.white, fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ),
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
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                    if (uploader.isNotEmpty)
                      Text(
                        uploader,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.white70,
                        ),
                      ),
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
    Navigator.of(context).push(
      coverPageRoute<void>(
        context,
        (_) => _WallpaperPreviewPage(wallpaper: wallpaper),
      ),
    );
  }
}

class _WallpaperPreviewPage extends ConsumerStatefulWidget {
  const _WallpaperPreviewPage({required this.wallpaper});

  final Map<String, dynamic> wallpaper;

  @override
  ConsumerState<_WallpaperPreviewPage> createState() =>
      _WallpaperPreviewPageState();
}

class _WallpaperPreviewPageState extends ConsumerState<_WallpaperPreviewPage> {
  String? _localPath;
  bool _busy = false;
  String? _result;
  VideoPlayerController? _previewVideo;
  bool _previewVideoReady = false;

  bool get _isVideo {
    final mt = (widget.wallpaper['mediaType'] as String?) ?? '';
    return mt == 'video';
  }

  bool get _hasLocal => _localPath != null && File(_localPath!).existsSync();

  Future<void> _initPreviewVideo() async {
    final lp = _localPath;
    if (lp == null || !File(lp).existsSync()) return;
    await _disposePreviewVideo();
    final controller = VideoPlayerController.file(File(lp))
      ..setLooping(true)
      ..setVolume(0);
    _previewVideo = controller;
    try {
      await controller.initialize();
    } catch (_) {
      if (identical(_previewVideo, controller)) _previewVideo = null;
      _previewVideoReady = false;
      if (mounted) setState(() {});
      await controller.dispose().catchError((_) {});
      return;
    }
    if (!mounted || !identical(_previewVideo, controller)) {
      await controller.dispose().catchError((_) {});
      return;
    }
    setState(() {
      _previewVideoReady = true;
    });
    await controller.setVolume(0);
    unawaited(controller.play());
  }

  Future<void> _disposePreviewVideo() async {
    final old = _previewVideo;
    _previewVideo = null;
    _previewVideoReady = false;
    await old?.dispose().catchError((_) {});
  }

  @override
  void initState() {
    super.initState();
    final lp = (widget.wallpaper['localPath'] as String?) ?? '';
    if (lp.isNotEmpty && File(lp).existsSync()) {
      _localPath = lp;
    }
    if (_isVideo && _hasLocal) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _initPreviewVideo());
    }
  }

  @override
  void dispose() {
    final v = _previewVideo;
    _previewVideo = null;
    _previewVideoReady = false;
    v?.dispose().catchError((_) {});
    super.dispose();
  }

  Future<String> _ensureLocal() async {
    if (_hasLocal) return _localPath!;
    final isVideo = _isVideo;
    final url = isVideo
        ? ((widget.wallpaper['videoUrl'] as String?) ?? '')
        : ((widget.wallpaper['imageUrl'] as String?) ?? '');
    if (url.isEmpty) throw Exception(tr('壁纸地址无效'));
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'XianYuWallpapers'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final id = widget.wallpaper['id'];
    final sha = (widget.wallpaper['videoSha256'] as String?) ?? '';
    final ext = isVideo ? 'mp4' : 'jpg';
    final cacheKey = isVideo && sha.isNotEmpty ? sha.substring(0, 8) : '';
    final file = File(
      p.join(
        dir.path,
        'wallpaper_$id${cacheKey.isEmpty ? '' : '_$cacheKey'}_${_safeName(widget.wallpaper)}.$ext',
      ),
    );
    if (file.existsSync() &&
        file.lengthSync() > 0 &&
        (isVideo ? cacheKey.isNotEmpty : true)) {
      await _recordDownload(widget.wallpaper, file.path);
      _downloadsRevision.value++;
      setState(() => _localPath = file.path);
      if (_isVideo) await _initPreviewVideo();
      return _localPath!;
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    final req = await client.getUrl(Uri.parse(url));
    final res = await req.close();
    if (res.statusCode != 200) {
      throw Exception(tr('下载失败（HTTP {status}）', {'status': res.statusCode}));
    }
    final bytes = await consolidateBytes(res);
    if (isVideo && sha.isNotEmpty) {
      final actual = sha256.convert(bytes).toString();
      if (actual != sha.toLowerCase()) {
        throw Exception(tr('壁纸文件校验失败，请稍后重试'));
      }
    }
    await file.writeAsBytes(bytes);
    await _recordDownload(widget.wallpaper, file.path);
    await _evictWallpaperCache(dir);
    _downloadsRevision.value++;
    setState(() => _localPath = file.path);
    if (_isVideo) {
      await _initPreviewVideo();
    }
    return _localPath!;
  }

  String _safeName(Map<String, dynamic> w) {
    final t = (w['title'] as String?) ?? 'wallpaper';
    return t.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  }

  static const _cacheLimitBytes = 300 * 1024 * 1024;

  Future<void> _evictWallpaperCache(Directory dir) async {
    try {
      final files = dir.listSync().whereType<File>().toList();
      var total = files.fold<int>(0, (s, f) => s + _fileSize(f));
      if (total <= _cacheLimitBytes) return;
      final active = _localPath;
      files.sort(
        (a, b) => a.statSync().modified.compareTo(b.statSync().modified),
      );
      for (final f in files) {
        if (f.path == active) continue;
        final s = _fileSize(f);
        try {
          await f.delete();
        } catch (e) { AppLog.debug('wallpaper', '删除缓存文件失败: $e'); }
        total -= s;
        if (total <= _cacheLimitBytes) break;
      }
    } catch (e) { AppLog.debug('wallpaper', '清理壁纸缓存失败: $e'); }
  }

  static int _fileSize(File f) {
    try {
      return f.lengthSync();
    } catch (_) {
      return 0;
    }
  }

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

  Future<void> _apply() async {
    if (_busy) return;
    final target = _localPath;
    if (target == null || !File(target).existsSync()) {
      if (mounted) showXianYuToast(context, tr('请先保存壁纸'));
      return;
    }
    await _openCustomEditor(target);
  }

  Future<void> _openCustomEditor(String path) async {
    if (!mounted) return;
    final applied = await Navigator.of(context).push<bool?>(
      coverPageRoute<bool>(
        context,
        (_) => WallpaperCustomApplyPage(imagePath: path, mediaType: _isVideo),
      ),
    );
    if (!mounted) return;
    if (applied == true) {
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
    Map<String, dynamic> wallpaper,
    String localPath,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('xianyu_downloaded_wallpapers_v1');
      final list = raw == null
          ? <Map<String, dynamic>>[]
          : (jsonDecode(raw) as List)
                .whereType<Map>()
                .map(
                  (m) => Map<String, dynamic>.from(m.cast<String, dynamic>()),
                )
                .toList();
      list.removeWhere((m) => m['id'] == wallpaper['id']);
      list.insert(0, {
        ...wallpaper,
        'localPath': localPath,
        'downloadedAt': DateTime.now().toIso8601String(),
      });
      await prefs.setString(
        'xianyu_downloaded_wallpapers_v1',
        jsonEncode(list),
      );
    } catch (e) { AppLog.warn('wallpaper', '记录下载壁纸失败: $e'); }
  }

  Widget _spinner({double size = 16}) => SizedBox(
    width: size,
    height: size,
    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
  );

  @override
  Widget build(BuildContext context) {
    final url = (widget.wallpaper['imageUrl'] as String?) ?? '';
    final hasLocal = _hasLocal;
    final title = (widget.wallpaper['title'] as String?) ?? '';
    final video = _previewVideoReady ? _previewVideo : null;
    Widget previewContent;
    if (video != null && video.value.isInitialized) {
      final raw = video.value.size;
      final rot = video.value.rotationCorrection;
      final display = (rot == 90 || rot == 270)
          ? Size(raw.height, raw.width)
          : raw;
      previewContent = AspectRatio(
        aspectRatio: display.width / display.height,
        child: VideoPlayer(video),
      );
    } else if (_isVideo && url.isNotEmpty) {
      previewContent = CachedNetworkImage(
        imageUrl: url,
        fit: BoxFit.contain,
        errorWidget: (_, _, _) => const Icon(
          Icons.broken_image_outlined,
          color: Colors.white54,
          size: 64,
        ),
      );
    } else if (hasLocal) {
      previewContent = Image.file(File(_localPath!), fit: BoxFit.contain);
    } else if (url.isNotEmpty) {
      previewContent = CachedNetworkImage(
        imageUrl: url,
        fit: BoxFit.contain,
        errorWidget: (_, _, _) => const Icon(
          Icons.broken_image_outlined,
          color: Colors.white54,
          size: 64,
        ),
      );
    } else {
      previewContent = const Icon(
        Icons.image_not_supported_outlined,
        color: Colors.white54,
        size: 64,
      );
    }
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
              child: Center(child: previewContent),
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
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  if (!hasLocal) ...[
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
