part of 'wallpaper_center_page.dart';

class _MyUploadsTab extends ConsumerStatefulWidget {
  const _MyUploadsTab({this.topInset = 0});

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
          Center(
            child: Text(_error!, style: TextStyle(color: scheme.error)),
          )
        else if (_mine.isEmpty)
          Center(
            child: Text(
              tr('还没有上传过壁纸'),
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
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
                statusBadge: _statusBadge(
                  (_mine[i]['status'] as String?) ?? '',
                ),
              ),
            ),
          ),
        Positioned(
          right: 16,
          bottom: 24,
          child: FloatingActionButton.extended(
            onPressed: _openUpload,
            icon: const Icon(Icons.upload_outlined),
            label: Text(tr('上传壁纸')),
          ),
        ),
      ],
    );
  }
}

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
  final _upPosterKey = GlobalKey();
  XFile? _picked;
  String? _videoPath;
  int _videoDuration = 0;
  VideoPlayerController? _upVideo;
  bool _posterFromStill = false;
  WallpaperMediaType _displayMode = WallpaperMediaType.video;
  bool _uploading = false;
  String? _error;

  @override
  void dispose() {
    _titleCtrl.dispose();
    _descCtrl.dispose();
    _categoryCtrl.dispose();
    _upVideo?.dispose();
    super.dispose();
  }

  Future<void> _disposeUploadVideo() async {
    final old = _upVideo;
    if (old == null) return;
    _upVideo = null;
    if (mounted) setState(() {});
    try {
      await old.dispose();
    } catch (e) { AppLog.debug('wallpaper', '释放视频控制器失败: $e'); }
  }

  Future<void> _setupUploadVideo(String path, {XFile? still}) async {
    setState(() {
      _videoPath = path;
      _picked = still;
      _posterFromStill = still != null;
      _error = null;
    });
    await _disposeUploadVideo();
    final c = VideoPlayerController.file(File(path));
    try {
      await c.initialize();
    } catch (_) {
      if (mounted) {
        setState(() {
          _videoPath = null;
          _error = tr('视频无法解析，请换一个文件');
        });
      }
      try {
        await c.dispose();
      } catch (e) { AppLog.debug('wallpaper', '释放视频控制器失败: $e'); }
      return;
    }
    if (!mounted) {
      try {
        await c.dispose();
      } catch (e) { AppLog.debug('wallpaper', '释放视频控制器失败: $e'); }
      return;
    }
    setState(() {
      _upVideo = c;
      _videoDuration = c.value.duration.inSeconds;
    });
    // 与自定义编辑器一致：自动循环静音播放，可直接预览动态效果
    c..setLooping(true)..setVolume(0);
    unawaited(c.play());
  }

  Future<void> _pickImage() async {
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        imageQuality: 100,
      );
      if (picked == null || !mounted) return;
      // 实况照片：提取内嵌视频后按视频壁纸走
      final tmp = await getTemporaryDirectory();
      final dir = Directory(p.join(tmp.path, 'upload_wallpapers'));
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final videoTarget = p.join(
        dir.path,
        'upload_${DateTime.now().millisecondsSinceEpoch}.mp4',
      );
      final extracted = await extractMotionPhotoVideo(
        File(picked.path),
        videoTarget,
      );
      if (extracted != null && mounted) {
        await _setupUploadVideo(extracted, still: picked);
        return;
      }
      await _disposeUploadVideo();
      if (!mounted) return;
      setState(() {
        _picked = picked;
        _videoPath = null;
        _error = null;
      });
    } catch (e) { AppLog.warn('wallpaper', '选择图片失败: $e'); }
  }

  Future<void> _pickVideo() async {
    try {
      final picked = await ImagePicker().pickVideo(source: ImageSource.gallery);
      if (picked == null || !mounted) return;
      await _setupUploadVideo(picked.path);
    } catch (e) { AppLog.warn('wallpaper', '选择视频失败: $e'); }
  }

  /// 从预览 RepaintBoundary 抓当前视频帧作为封面
  Future<String?> _capturePosterDataUrl() async {
    final ctx = _upPosterKey.currentContext;
    final ro = ctx?.findRenderObject();
    if (ro is! RenderRepaintBoundary || !ro.attached) return null;
    try {
      final c = _upVideo;
      if (c != null && c.value.isInitialized) {
        await c.pause();
        await c.seekTo(Duration.zero);
        await Future.delayed(const Duration(milliseconds: 150));
      }
      final size = ro.size;
      if (size.width < 8 || size.height < 8) return null;
      final pixelRatio = (720.0 / size.width).clamp(0.5, 3.0);
      final captured = await ro.toImage(pixelRatio: pixelRatio);
      final byteData = await captured.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      final w = captured.width;
      final h = captured.height;
      captured.dispose();
      if (byteData == null) return null;
      final frame = img.Image.fromBytes(
        width: w,
        height: h,
        bytes: byteData.buffer,
        order: img.ChannelOrder.rgba,
      );
      final jpeg = img.encodeJpg(frame, quality: 85);
      return 'data:image/jpeg;base64,${base64Encode(jpeg)}';
    } catch (_) {
      return null;
    }
  }

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
    if (_videoPath == null && _picked == null) {
      setState(() => _error = tr('请选择壁纸图片或视频'));
      return;
    }
    setState(() {
      _uploading = true;
      _error = null;
    });
    try {
      if (_videoPath != null) {
        final poster = _posterFromStill && _picked != null
            ? await _compressToDataUrl(_picked!)
            : await _capturePosterDataUrl();
        if (poster == null || poster.isEmpty) {
          throw Exception(tr('视频封面生成失败，请重试'));
        }
        final bytes = await File(_videoPath!).readAsBytes();
        await ref
            .read(accountApiProvider)
            .uploadWallpaper(
              title: title,
              description: _descCtrl.text.trim(),
              category: _categoryCtrl.text.trim(),
              imageData: poster,
              videoData: 'data:video/mp4;base64,${base64Encode(bytes)}',
              videoDuration: _videoDuration,
              mediaType: _displayMode == WallpaperMediaType.video
                  ? 'video'
                  : 'image',
            );
      } else {
        final imageData = await _compressToDataUrl(_picked!);
        await ref
            .read(accountApiProvider)
            .uploadWallpaper(
              title: title,
              description: _descCtrl.text.trim(),
              category: _categoryCtrl.text.trim(),
              imageData: imageData,
            );
      }
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

  /// 上传预览：视频画面 cover 铺满（与自定义编辑器一致）；
  /// 「展示图片」模式且拿得到静帧（实况照片）时显示静帧原图
  Widget _buildUploadPreview() {
    final scheme = Theme.of(context).colorScheme;
    final videoReady =
        _videoPath != null && _upVideo != null && _upVideo!.value.isInitialized;
    final showStill =
        _displayMode == WallpaperMediaType.image && _picked != null;
    if (videoReady && !showStill) {
      final raw = _upVideo!.value.size;
      final rot = _upVideo!.value.rotationCorrection;
      final display =
          (rot == 90 || rot == 270) ? Size(raw.height, raw.width) : raw;
      final ar = display.width <= 0 || display.height <= 0
          ? 16 / 9
          : display.width / display.height;
      return SizedBox(
        height: 200,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: RepaintBoundary(
            key: _upPosterKey,
            child: Stack(
              fit: StackFit.expand,
              children: [
                const ColoredBox(color: Colors.black),
                LayoutBuilder(
                  builder: (context, cons) {
                    final w = cons.maxWidth;
                    final h = cons.maxHeight;
                    final vw = (h * ar) >= w ? h * ar : w;
                    final vh = (h * ar) >= w ? h : w / ar;
                    return ClipRect(
                      child: Center(
                        child: SizedBox(
                          width: vw,
                          height: vh,
                          child: VideoPlayer(_upVideo!),
                        ),
                      ),
                    );
                  },
                ),
                Positioned(
                  top: 8,
                  right: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.videocam,
                          color: Colors.white,
                          size: 12,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          tr('视频壁纸'),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return GestureDetector(
      onTap: _uploading ? null : _pickImage,
      child: Container(
        height: videoReady ? 200 : 160,
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
                    Icon(
                      Icons.add_photo_alternate_outlined,
                      size: 40,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      tr('点击选择图片或视频\n(JPG / PNG / WEBP / MP4)'),
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
                child: Image.file(
                  File(_picked!.path),
                  fit: BoxFit.cover,
                  width: double.infinity,
                ),
              ),
      ),
    );
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
          Text(
            tr('上传壁纸'),
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 14),
          _buildUploadPreview(),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _uploading ? null : _pickImage,
                  icon: const Icon(Icons.photo_outlined, size: 18),
                  label: Text(tr('选图片')),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _uploading ? null : _pickVideo,
                  icon: const Icon(Icons.movie_outlined, size: 18),
                  label: Text(tr('选视频')),
                ),
              ),
            ],
          ),
          if (_videoPath != null) ...[
            const SizedBox(height: 10),
            SegmentedButton<WallpaperMediaType>(
              segments: [
                ButtonSegment(
                  value: WallpaperMediaType.video,
                  label: Text(tr('展示视频')),
                ),
                ButtonSegment(
                  value: WallpaperMediaType.image,
                  label: Text(tr('展示图片')),
                ),
              ],
              selected: {_displayMode},
              showSelectedIcon: false,
              onSelectionChanged: _uploading
                  ? null
                  : (selection) =>
                        setState(() => _displayMode = selection.first),
            ),
          ],
          const SizedBox(height: 12),
          TextField(
            controller: _titleCtrl,
            enabled: !_uploading,
            decoration: InputDecoration(
              labelText: tr('标题'),
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _descCtrl,
            enabled: !_uploading,
            maxLines: 2,
            decoration: InputDecoration(
              labelText: tr('描述（可选）'),
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _categoryCtrl,
            enabled: !_uploading,
            decoration: InputDecoration(
              labelText: tr('分类（可选，默认「用户上传」）'),
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                _error!,
                style: TextStyle(color: scheme.error, fontSize: 12),
              ),
            ),
          const SizedBox(height: 14),
          FilledButton(
            onPressed: _uploading ? null : _submit,
            child: _uploading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Text(tr('提交审核')),
          ),
        ],
      ),
    );
  }
}
