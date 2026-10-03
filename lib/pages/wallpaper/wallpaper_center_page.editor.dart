part of 'wallpaper_center_page.dart';

class CustomWallpaperEditor extends ConsumerStatefulWidget {
  const CustomWallpaperEditor({
    super.key,
    this.initialImagePath,
    this.initialIsVideo = false,
    this.topInset = 0,
  });

  final String? initialImagePath;
  final bool initialIsVideo;
  final double topInset;

  @override
  ConsumerState<CustomWallpaperEditor> createState() =>
      _CustomWallpaperEditorState();
}

class WallpaperCustomApplyPage extends StatelessWidget {
  const WallpaperCustomApplyPage({
    super.key,
    required this.imagePath,
    this.mediaType = false,
  });

  final String imagePath;
  final bool mediaType;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('自定义壁纸'))),
      body: CustomWallpaperEditor(
        initialImagePath: imagePath,
        initialIsVideo: mediaType,
      ),
    );
  }
}

class _CustomWallpaperEditorState extends ConsumerState<CustomWallpaperEditor> {
  late CustomBackground _draft;
  bool _landscape = false;
  double? _gestureBaseScale;
  double? _gestureBaseTx;
  double? _gestureBaseTy;

  @override
  void initState() {
    super.initState();
    final ip = widget.initialImagePath;
    if (ip != null && ip.isNotEmpty && File(ip).existsSync()) {
      _draft = CustomBackground(
        imagePath: ip,
        mediaType: widget.initialIsVideo
            ? WallpaperMediaType.video
            : WallpaperMediaType.image,
        enabled: true,
        blur: 0,
        maskAlpha: 18,
      );
    } else {
      _draft =
          ref.read(settingsProvider).valueOrNull?.customBackground ??
          CustomBackground.none;
    }
  }

  Future<String?> _prepareImageForWallpaper(File src, String target) async {
    try {
      final raf = src.openSync();
      var isGif = false;
      try {
        final head = raf.readSync(6);
        isGif = head.length >= 4 &&
            head[0] == 0x47 &&
            head[1] == 0x49 &&
            head[2] == 0x46 &&
            head[3] == 0x38;
      } finally {
        raf.closeSync();
      }
      if (isGif) {
        await src.copy(target);
        AppLog.warn('wallpaper', 'prepare gif copy=$target');
        return target;
      }
    } catch (_) {}
    try {
      final bytes = await src.readAsBytes();
      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: 64,
        targetHeight: 64,
      );
      final frame = await codec.getNextFrame();
      frame.image.dispose();
      codec.dispose();
      await src.copy(target);
      return target;
    } catch (_) {
    }
    final converted = await FlutterImageCompress.compressAndGetFile(
      src.path,
      target,
      quality: 90,
      format: CompressFormat.jpeg,
    );
    final convertedPath = converted?.path;
    if (convertedPath != null &&
        File(convertedPath).existsSync() &&
        File(convertedPath).lengthSync() > 0) {
      return convertedPath;
    }
    return null;
  }

  Future<void> _pickImage() async {
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (picked == null) {
      AppLog.warn('wallpaper', 'pickImage cancelled');
      return;
    }
    AppLog.warn('wallpaper', 'pickImage picked path=${picked.path}');
    try {
      final pickedLen = File(picked.path).lengthSync();
      final raf = File(picked.path).openSync();
      var isJpeg = false;
      try {
        final head = raf.readSync(2);
        isJpeg = head.length >= 2 && head[0] == 0xff && head[1] == 0xd8;
      } finally {
        raf.closeSync();
      }
      AppLog.warn('wallpaper', 'pickImage picked len=$pickedLen jpeg=$isJpeg');
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(docs.path, 'custom_background'));
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final ts = DateTime.now().millisecondsSinceEpoch;
      final videoTarget = p.join(dir.path, 'wallpaper_$ts.mp4');
      final extracted = await extractMotionPhotoVideo(
        File(picked.path),
        videoTarget,
      );
      AppLog.warn('wallpaper', 'pickImage motionExtract=$extracted');
      if (extracted != null) {
        // 动态图片：静帧与内嵌视频都保留，可在编辑器切换展示形态
        final stillTarget = p.join(dir.path, 'wallpaper_$ts.jpg');
        final still = await _prepareImageForWallpaper(
          File(picked.path),
          stillTarget,
        );
        if (!mounted) return;
        if (still != null) {
          _cleanupOldBackgroundFiles(dir, keep: extracted, alsoKeep: still);
          setState(
            () => _draft = _draft.copyWith(
              imagePath: still,
              motionVideoPath: extracted,
              mediaType: WallpaperMediaType.video,
            ),
          );
        } else {
          // 静帧处理失败：退回纯视频模式（与旧行为一致）
          _cleanupOldBackgroundFiles(dir, keep: extracted);
          setState(
            () => _draft = _draft.copyWith(
              imagePath: extracted,
              motionVideoPath: '',
              mediaType: WallpaperMediaType.video,
            ),
          );
        }
        return;
      }
      final ext = p.extension(picked.path).toLowerCase();
      final target = p.join(dir.path, 'wallpaper_$ts${ext.isEmpty ? '.jpg' : ext}');
      final ready = await _prepareImageForWallpaper(
        File(picked.path),
        target,
      );
      AppLog.warn('wallpaper', 'pickImage ready=$ready');
      if (ready != null) {
        _cleanupOldBackgroundFiles(dir, keep: ready);
        if (!mounted) return;
        setState(
          () => _draft = _draft.copyWith(
            imagePath: ready,
            motionVideoPath: '',
            mediaType: WallpaperMediaType.image,
          ),
        );
        return;
      }
      if (!mounted) return;
      showXianYuToast(context, tr('当前图片格式不受支持，请在相册中另存为 JPEG'));
    } catch (e) {
      AppLog.warn('wallpaper', 'pickImage failed: $e');
      if (mounted) showXianYuToast(context, tr('请先选择图片'));
    }
  }

  Future<void> _pickVideo() async {
    final picked = await ImagePicker().pickVideo(source: ImageSource.gallery);
    if (picked == null) return;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(docs.path, 'custom_background'));
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final ts = DateTime.now().millisecondsSinceEpoch;
      var ext = p.extension(picked.path).toLowerCase();
      if (ext.isEmpty) ext = '.mp4';
      final target = p.join(dir.path, 'wallpaper_$ts$ext');
      await picked.saveTo(target);
      _cleanupOldBackgroundFiles(dir, keep: target);
      if (!mounted) return;
      setState(
        () => _draft = _draft.copyWith(
          imagePath: target,
          motionVideoPath: '',
          mediaType: WallpaperMediaType.video,
        ),
      );
    } catch (e) {
      debugPrint('custom wallpaper pickVideo failed: $e');
      if (mounted) showXianYuToast(context, tr('请先选择视频'));
    }
  }

  void _cleanupOldBackgroundFiles(
    Directory dir, {
    required String keep,
    String? alsoKeep,
  }) {
    try {
      final applied =
          ref.read(settingsProvider).valueOrNull?.customBackground;
      final appliedPath = applied?.imagePath ?? '';
      final appliedMotion = applied?.motionVideoPath ?? '';
      for (final e in dir.listSync()) {
        if (e is! File) continue;
        final path = e.path;
        if (path == keep ||
            path == appliedPath ||
            path == appliedMotion ||
            path == alsoKeep) {
          continue;
        }
        if (p.basename(path).startsWith('wallpaper_')) {
          e.deleteSync();
        }
      }
    } catch (_) {}
  }

  Future<void> _apply() async {
    if (_draft.imagePath.isEmpty) {
      showXianYuToast(context, tr('请先选择图片或视频'));
      return;
    }
    final overlay = Overlay.of(context, rootOverlay: true);
    await ref
        .read(settingsProvider.notifier)
        .setCustomBackground(_draft.copyWith(enabled: true));
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

  void _onPreviewScaleStart(ScaleStartDetails d) {
    if (_draft.imagePath.isEmpty) return;
    _gestureBaseScale =
        (_landscape ? _draft.landscapeScale : _draft.scale).toDouble();
    _gestureBaseTx =
        (_landscape ? _draft.landscapeTranslateX : _draft.translateX)
            .toDouble();
    _gestureBaseTy =
        (_landscape ? _draft.landscapeTranslateY : _draft.translateY)
            .toDouble();
  }

  void _onPreviewScaleUpdate(ScaleUpdateDetails d, double bw, double bh) {
    final baseScale = _gestureBaseScale;
    final baseTx = _gestureBaseTx;
    final baseTy = _gestureBaseTy;
    if (baseScale == null || baseTx == null || baseTy == null) return;
    if (bw <= 0 || bh <= 0) return;

    double scale = (_landscape ? _draft.landscapeScale : _draft.scale)
        .toDouble();
    if (d.pointerCount >= 2) {
      scale = (baseScale * d.scale).clamp(80.0, 240.0);
    }

    final sEff = (scale / 100).clamp(1.0, 10.0).toDouble();
    final maxTx = ((sEff - 1) / 2 * 100).clamp(0.0, 100.0).toDouble();
    final maxTy = maxTx;
    final tx = (baseTx + d.focalPointDelta.dx / bw * 100)
        .clamp(-maxTx, maxTx)
        .toDouble();
    final ty = (baseTy + d.focalPointDelta.dy / bh * 100)
        .clamp(-maxTy, maxTy)
        .toDouble();

    setState(() {
      if (_landscape) {
        _draft = _draft.copyWith(
          landscapeScale: scale.round(),
          landscapeTranslateX: tx.round(),
          landscapeTranslateY: ty.round(),
        );
      } else {
        _draft = _draft.copyWith(
          scale: scale.round(),
          translateX: tx.round(),
          translateY: ty.round(),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final hasImage =
        _draft.imagePath.isNotEmpty && File(_draft.imagePath).existsSync();

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(16, 16 + widget.topInset, 16, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildPreviewCard(context, hasImage, isDark),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _pickImage,
                    icon: const Icon(Icons.photo_library_outlined, size: 18),
                    label: Text(
                      hasImage && _draft.mediaType == WallpaperMediaType.image
                          ? tr('更换图片')
                          : tr('选择图片'),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _pickVideo,
                    icon: const Icon(Icons.video_library_outlined, size: 18),
                    label: Text(
                      hasImage && _draft.mediaType == WallpaperMediaType.video
                          ? tr('更换视频')
                          : tr('选择视频'),
                    ),
                  ),
                ),
              ],
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
                onChanged: (v) =>
                    setState(() => _draft = _draft.copyWith(maskAlpha: v)),
              ),
              const SizedBox(height: 4),
              if (_draft.motionVideoPath.isNotEmpty) ...[
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
                  selected: {_draft.mediaType},
                  showSelectedIcon: false,
                  onSelectionChanged: (selection) => setState(
                    () => _draft = _draft.copyWith(mediaType: selection.first),
                  ),
                ),
                const SizedBox(height: 8),
              ],
              SegmentedButton<bool>(
                segments: [
                  ButtonSegment(value: false, label: Text(tr('竖屏'))),
                  ButtonSegment(value: true, label: Text(tr('横屏'))),
                ],
                selected: {_landscape},
                showSelectedIcon: false,
                onSelectionChanged: (selection) =>
                    setState(() => _landscape = selection.first),
              ),
              _ParamSlider(
                icon: Icons.zoom_out_map,
                label: tr('缩放'),
                value: _landscape ? _draft.landscapeScale : _draft.scale,
                min: 80,
                max: 240,
                divisions: 160,
                onChanged: (v) => setState(
                  () => _draft = _landscape
                      ? _draft.copyWith(landscapeScale: v)
                      : _draft.copyWith(scale: v),
                ),
              ),
              _ParamSlider(
                icon: Icons.swap_horiz,
                label: tr('水平位移'),
                value: _landscape
                    ? _draft.landscapeTranslateX
                    : _draft.translateX,
                min: -100,
                max: 100,
                divisions: 200,
                onChanged: (v) => setState(
                  () => _draft = _landscape
                      ? _draft.copyWith(landscapeTranslateX: v)
                      : _draft.copyWith(translateX: v),
                ),
              ),
              _ParamSlider(
                icon: Icons.swap_vert,
                label: tr('垂直位移'),
                value: _landscape
                    ? _draft.landscapeTranslateY
                    : _draft.translateY,
                min: -100,
                max: 100,
                divisions: 200,
                onChanged: (v) => setState(
                  () => _draft = _landscape
                      ? _draft.copyWith(landscapeTranslateY: v)
                      : _draft.copyWith(translateY: v),
                ),
              ),
              _ParamSlider(
                icon: Icons.invert_colors,
                label: tr('组件底色'),
                value: _draft.widgetAlpha,
                min: 0,
                max: 90,
                divisions: 90,
                suffix: '%',
                onChanged: (v) =>
                    setState(() => _draft = _draft.copyWith(widgetAlpha: v)),
              ),
              const SizedBox(height: 4),
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
                  () => _draft = _draft.copyWith(textMode: selection.first),
                ),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: _apply,
                icon: const Icon(Icons.check, size: 18),
                label: Text(tr('保存并使用')),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(46),
                  textStyle: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (_draft.active) ...[
                const SizedBox(height: 8),
                Center(
                  child: TextButton(
                    onPressed: _restore,
                    child: Text(tr('恢复默认')),
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildPreviewCard(BuildContext context, bool hasImage, bool isDark) {
    final scheme = Theme.of(context).colorScheme;
    final win = MediaQuery.sizeOf(context);
    final long = win.width > win.height ? win.width : win.height;
    final short = long > 0
        ? (win.width > win.height ? win.height : win.width)
        : 0.0;
    final portraitRatio = short > 0 ? short / long : 9 / 19.5;
    final landscapeRatio = 1 / portraitRatio;
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxW = constraints.maxWidth;
        double bw;
        double bh;
        if (_landscape) {
          bh = maxW / landscapeRatio;
          if (bh > 240) bh = 240;
          bw = bh * landscapeRatio;
          if (bw > maxW) {
            bw = maxW;
            bh = bw / landscapeRatio;
          }
        } else {
          bh = 240;
          bw = bh * portraitRatio;
          if (bw > maxW) {
            bw = maxW;
            bh = bw / portraitRatio;
          }
        }
        Widget content;
        if (!hasImage) {
          content = ColoredBox(
            color: isDark ? const Color(0xFF262626) : const Color(0xFFE8E8E8),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.image_outlined,
                    size: 44,
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.45),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _draft.mediaType == WallpaperMediaType.video
                        ? tr('未选择视频')
                        : tr('未选择图片'),
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          );
        } else {
          final textColor = switch (_draft.textMode) {
            WallpaperTextColor.light => Colors.white,
            WallpaperTextColor.dark => const Color(0xFF111111),
            WallpaperTextColor.follow => scheme.onSurface,
          };
          final shadow = Shadow(
            color: textColor.computeLuminance() > 0.5
                ? Colors.black.withValues(alpha: 0.55)
                : Colors.white.withValues(alpha: 0.5),
            blurRadius: 6,
          );
          final modeLabel = switch (_draft.textMode) {
            WallpaperTextColor.light => tr('亮色字体'),
            WallpaperTextColor.dark => tr('暗色字体'),
            WallpaperTextColor.follow => tr('默认'),
          };
          content = Stack(
            fit: StackFit.expand,
            children: [
              const ColoredBox(color: Colors.black),
              CustomBackgroundLayer(
                background: _draft.copyWith(enabled: true),
                forceOrientation: _landscape
                    ? Orientation.landscape
                    : Orientation.portrait,
              ),
              Positioned(
                left: 12,
                right: 12,
                bottom: 10,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            tr('字体预览'),
                            style: TextStyle(
                              fontSize: 9,
                              letterSpacing: 2,
                              color: textColor.withValues(alpha: 0.6),
                              shadows: [shadow],
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '夜航星',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: textColor,
                              shadows: [shadow],
                            ),
                          ),
                          Text(
                            tr('浅色和深色字体会直接预览在这里'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: textColor.withValues(alpha: 0.72),
                              shadows: [shadow],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      modeLabel,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: textColor.withValues(alpha: 0.85),
                        shadows: [shadow],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        }
        return Center(
          child: Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onScaleStart: _onPreviewScaleStart,
                  onScaleUpdate: (d) => _onPreviewScaleUpdate(d, bw, bh),
                  child: SizedBox(width: bw, height: bh, child: content),
                ),
              ),
              Positioned.fill(
                child: CustomPaint(
                  painter: _DashedRectPainter(
                    color: hasImage
                        ? Colors.white.withValues(alpha: 0.45)
                        : scheme.onSurfaceVariant.withValues(alpha: 0.35),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _DashedRectPainter extends CustomPainter {
  _DashedRectPainter({required this.color});

  final Color color;
  static const double radius = 14;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(
      rect.deflate(0.75),
      Radius.circular(radius),
    );
    final path = Path()..addRRect(rrect);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = color;
    const dashLen = 5.0;
    const gapLen = 4.0;
    for (final metric in path.computeMetrics()) {
      double dist = 0;
      while (dist < metric.length) {
        final end = (dist + dashLen).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(dist, end), paint);
        dist = end + gapLen;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedRectPainter oldDelegate) =>
      oldDelegate.color != color;
}

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
              Text(label, style: const TextStyle(fontSize: 14)),
              const Spacer(),
              Text(
                '$value${suffix ?? ''}',
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
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
