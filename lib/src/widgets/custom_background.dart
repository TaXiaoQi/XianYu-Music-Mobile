import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../core/app_colors.dart';
import '../core/settings.dart';
import '../theme/page_wallpaper.dart';
import 'glass_settings.dart';

/// 视频壁纸帧平均色（含遮罩/模糊后的实际观感）：
/// 由 CustomBackgroundLayer 低频采样，供转场底色（RoutePageBackdrop）
/// 取代固定 appSurfaceBg，消除切页时底色与视频壁纸的跳变
final videoWallpaperColorProvider = StateProvider<Color?>((ref) => null);

class WallpaperMediaAspect {
  WallpaperMediaAspect._();

  static final Map<String, Size> _cache = <String, Size>{};
  static final Set<String> _failed = <String>{};
  static final Map<String, Set<VoidCallback>> _pending =
      <String, Set<VoidCallback>>{};

  static Size? of(String path) => _cache[path];

  static void probe(String path, VoidCallback onChanged) {
    if (path.isEmpty || path.toLowerCase().endsWith('.mp4')) return;
    if (_cache.containsKey(path)) {
      onChanged();
      return;
    }
    if (_failed.contains(path)) return;
    final pending = _pending.putIfAbsent(path, () => <VoidCallback>{});
    pending.add(onChanged);
    if (pending.length > 1) return;
    _startProbe(path);
  }

  static void _startProbe(String path) {
    final file = File(path);
    if (!file.existsSync()) {
      _failed.add(path);
      _finishProbe(path);
      return;
    }
    final stream = ResizeImage(
      FileImage(file),
      width: 96,
    ).resolve(const ImageConfiguration());
    late ImageStreamListener listener;
    var done = false;
    listener = ImageStreamListener(
      (info, _) {
        if (done) return;
        done = true;
        stream.removeListener(listener);
        final w = info.image.width.toDouble();
        final h = info.image.height.toDouble();
        if (w > 0 && h > 0) {
          if (_cache.length > 16) _cache.clear();
          _cache[path] = Size(w, h);
        } else {
          _failed.add(path);
        }
        _finishProbe(path);
      },
      onError: (_, _) {
        if (done) return;
        done = true;
        _failed.add(path);
        _finishProbe(path);
      },
    );
    stream.addListener(listener);
  }

  static void _finishProbe(String path) {
    final cbs = _pending.remove(path);
    if (cbs == null) return;
    for (final cb in cbs) {
      cb();
    }
  }
}

Size wallpaperCoverBox(double w, double h, Size? src) {
  final vw = src?.width ?? 0;
  final vh = src?.height ?? 0;
  if (vw <= 0 || vh <= 0 || w <= 0 || h <= 0) return Size(w, h);
  final containerRatio = w / h;
  final srcRatio = vw / vh;
  if (srcRatio > containerRatio) {
    return Size(h * srcRatio, h);
  }
  return Size(w, w / srcRatio);
}

Offset wallpaperMaxTranslate(double w, double h, Size box, double s) {
  final maxDx = ((box.width * s - w) / 2).clamp(0.0, double.infinity);
  final maxDy = ((box.height * s - h) / 2).clamp(0.0, double.infinity);
  return Offset(maxDx.toDouble(), maxDy.toDouble());
}

class WallpaperMediaLayer extends StatelessWidget {
  const WallpaperMediaLayer({
    super.key,
    required this.box,
    required this.scale,
    required this.offset,
    required this.blurSigma,
    required this.opacity,
    required this.child,
  });

  final Size box;

  final double scale;
  final Offset offset;
  final double blurSigma;
  final double opacity;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    Widget layer(Size b) => Transform.translate(
      offset: offset,
      child: Transform.scale(
        scale: scale,
        alignment: Alignment.center,
        child: OverflowBox(
          alignment: Alignment.center,
          minWidth: b.width,
          maxWidth: b.width,
          minHeight: b.height,
          maxHeight: b.height,
          child: ImageFiltered(
            imageFilter: cheapBackdropBlur(blurSigma),
            child: child,
          ),
        ),
      ),
    );
    if (blurSigma <= 0) {
      return Opacity(opacity: opacity, child: layer(box));
    }
    final pad = (blurSigma * 2.5).clamp(4.0, 64.0);
    return Opacity(
      opacity: opacity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          layer(Size(box.width + pad * 2, box.height + pad * 2)),
          layer(box),
        ],
      ),
    );
  }
}

class CustomBackgroundLayer extends ConsumerStatefulWidget {
  const CustomBackgroundLayer({
    super.key,
    this.background,
    this.forceOrientation,
  });

  final CustomBackground? background;

  final Orientation? forceOrientation;

  @override
  ConsumerState<CustomBackgroundLayer> createState() =>
      _CustomBackgroundLayerState();
}

class _CustomBackgroundLayerState extends ConsumerState<CustomBackgroundLayer>
    with WidgetsBindingObserver {
  VideoPlayerController? _videoController;
  bool _videoReady = false;
  String? _videoKey;
  Size? _videoSize;
  String? _lastVideoLogSig;

  final GlobalKey _captureKey = GlobalKey();
  Timer? _colorTimer;

  bool get _videoShouldAutoPlay {
    final s = ref.read(settingsProvider);
    return s.valueOrNull?.performanceMode != PerformanceMode.performance;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _syncVideo(widget.background);
    _syncAspect(widget.background);
  }

  @override
  void didUpdateWidget(covariant CustomBackgroundLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    final cb = widget.background;
    if (oldWidget.background?.imagePath != cb?.imagePath ||
        oldWidget.background?.mediaType != cb?.mediaType ||
        oldWidget.background?.motionVideoPath != cb?.motionVideoPath) {
      _syncVideo(cb);
    }
    _syncAspect(cb);
  }

  void _syncAspect(CustomBackground? cb) {
    if (cb == null ||
        cb.mediaType != WallpaperMediaType.image ||
        cb.imagePath.isEmpty) {
      return;
    }
    WallpaperMediaAspect.probe(cb.imagePath, () {
      if (mounted) setState(() {});
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final v = _videoController;
    if (v == null || !_videoReady) return;
    if (state == AppLifecycleState.resumed) {
      if (_videoShouldAutoPlay) unawaited(v.play());
    } else {
      unawaited(v.pause());
    }
  }

  Future<void> _syncVideo(CustomBackground? cb) async {
    final isVideo =
        cb != null && cb.mediaType == WallpaperMediaType.video && cb.active;
    // 动态图片：视频源取内嵌提取的 mp4（imagePath 是静帧）；
    // 普通视频壁纸：视频源即 imagePath 本身
    final videoPath =
        isVideo && cb.motionVideoPath.isNotEmpty ? cb.motionVideoPath : cb?.imagePath ?? '';
    final key = isVideo ? videoPath : null;
    if (_videoKey == key) return;
    _videoKey = key;
    _colorTimer?.cancel();
    _colorTimer = null;
    ref.read(videoWallpaperColorProvider.notifier).state = null;

    final old = _videoController;
    _videoController = null;
    _videoReady = false;
    if (mounted) setState(() {});
    await old?.dispose();

    if (!isVideo) return;

    final controller = VideoPlayerController.file(File(videoPath))
      ..setLooping(true)
      ..setVolume(0);
    try {
      await controller.initialize();
    } catch (_) {
      await controller.dispose().catchError((_) {});
      if (_videoKey == key) _videoKey = null;
      return;
    }
    if (!mounted || _videoKey != key) {
      await controller.dispose().catchError((_) {});
      return;
    }
    setState(() {
      _videoController = controller;
      _videoReady = true;
      final size = controller.value.size;
      final rot = controller.value.rotationCorrection;
      _videoSize = (rot == 90 || rot == 270)
          ? Size(size.height, size.width)
          : size;
      debugPrint('customBg video init raw=$size rot=$rot display=$_videoSize');
    });
    await controller.setVolume(0);
    if (_videoShouldAutoPlay &&
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      unawaited(controller.play());
    }
    _startColorSampling();
  }

  /// 转场底色取色：低频采样视频帧平均色写入 videoWallpaperColorProvider，
  /// 供 RoutePageBackdrop 在转场期间垫底，避免固定底色与视频壁纸跳变
  void _startColorSampling() {
    _colorTimer?.cancel();
    _colorTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      final v = _videoController;
      if (v == null || !v.value.isPlaying) return;
      unawaited(_captureColor());
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_captureColor());
    });
  }

  Future<void> _captureColor() async {
    final ctx = _captureKey.currentContext;
    if (ctx == null) return;
    final ro = ctx.findRenderObject();
    if (ro is! RenderRepaintBoundary || !ro.attached) return;
    final sz = ro.size;
    if (sz.width < 8 || sz.height < 8) return;
    try {
      final pr = (24.0 / sz.width).clamp(0.005, 1.0);
      final img = await ro.toImage(pixelRatio: pr);
      final bd = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      img.dispose();
      if (bd == null || !mounted) return;
      final px = bd.buffer.asUint8List();
      var r = 0, g = 0, b = 0, n = 0;
      for (var i = 0; i + 3 < px.length; i += 4) {
        if (px[i + 3] < 8) continue;
        r += px[i];
        g += px[i + 1];
        b += px[i + 2];
        n++;
      }
      if (n == 0) return;
      ref.read(videoWallpaperColorProvider.notifier).state =
          Color.fromARGB(255, r ~/ n, g ~/ n, b ~/ n);
    } catch (_) {
      // 边界已销毁/纹理未就绪等场景静默放弃，下一轮再采
    }
  }

  @override
  void dispose() {
    _colorTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _videoController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<AppSettings>>(settingsProvider, (_, next) {
      final v = _videoController;
      if (v == null || !_videoReady) return;
      final perf =
          next.valueOrNull?.performanceMode == PerformanceMode.performance;
      if (perf) {
        unawaited(v.pause());
      } else if (WidgetsBinding.instance.lifecycleState ==
          AppLifecycleState.resumed) {
        unawaited(v.play());
      }
    });
    final cb = widget.background;
    if (cb == null) {
      return _SettingsBound();
    }
    return _render(cb);
  }

  Widget _render(CustomBackground cb) {
    final file = File(cb.imagePath);
    final hasMedia = file.path.isNotEmpty;
    // 动态图片（motionVideoPath 非空）按 mediaType 决定展示图片还是视频；
    // 普通内容按 mediaType / 扩展名判定
    final isVideo = cb.motionVideoPath.isNotEmpty
        ? cb.mediaType == WallpaperMediaType.video
        : cb.mediaType == WallpaperMediaType.video ||
              file.path.toLowerCase().endsWith('.mp4');
    final video = _videoController;
    final videoReady = isVideo && _videoReady && video != null;
    final blurSig = cb.blur * 0.6;
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        final isLandscape =
            (widget.forceOrientation ?? MediaQuery.orientationOf(context)) ==
            Orientation.landscape;
        final useScale = isLandscape ? cb.landscapeScale : cb.scale;
        final useTx = isLandscape ? cb.landscapeTranslateX : cb.translateX;
        final useTy = isLandscape ? cb.landscapeTranslateY : cb.translateY;
        final dx = useTx / 100 * w;
        final dy = useTy / 100 * h;
        final sEff = (useScale / 100).clamp(0.8, 10.0).toDouble();
        final imgBox = wallpaperCoverBox(
          w,
          h,
          WallpaperMediaAspect.of(file.path),
        );
        final videoBox = videoReady
            ? wallpaperCoverBox(w, h, _videoSize)
            : null;
        final box = isVideo ? (videoBox ?? Size(w, h)) : imgBox;
        final maxT = wallpaperMaxTranslate(w, h, box, sEff);
        final ddx = dx.clamp(-maxT.dx, maxT.dx).toDouble();
        final ddy = dy.clamp(-maxT.dy, maxT.dy).toDouble();
        final logSig = videoReady ? '$videoBox|${w}x$h' : null;
        if (logSig != null && logSig != _lastVideoLogSig) {
          _lastVideoLogSig = logSig;
          debugPrint('customBg videoBox=$videoBox container=${w}x$h');
        }
        return RepaintBoundary(
          key: _captureKey,
          child: SizedBox.expand(
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (hasMedia)
                  ClipRect(
                    child: !isVideo
                        ? _buildImageLayer(
                            file: file,
                            box: imgBox,
                            scale: sEff,
                            dx: ddx,
                            dy: ddy,
                            cb: cb,
                            blurSig: blurSig,
                          )
                        : videoBox == null
                        ? const ColoredBox(color: Colors.black)
                        : _buildVideoLayer(
                            video!,
                            videoBox,
                            ddx,
                            ddy,
                            sEff * 100,
                            cb,
                          ),
                  ),
                if (cb.maskAlpha > 0)
                  Container(
                    color: Colors.black.withValues(
                      alpha: (cb.maskAlpha / 100).clamp(0.0, 1.0),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildImageLayer({
    required File file,
    required Size box,
    required double scale,
    required double dx,
    required double dy,
    required CustomBackground cb,
    required double blurSig,
  }) {
    return WallpaperMediaLayer(
      box: box,
      scale: scale,
      offset: Offset(dx, dy),
      blurSigma: blurSig,
      opacity: (cb.opacity / 100).clamp(0.0, 1.0),
      child: Image.file(
        key: ValueKey('wallpaper-${file.path}'),
        file,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => const SizedBox.shrink(),
      ),
    );
  }

  Widget _buildVideoLayer(
    VideoPlayerController video,
    Size box,
    double dx,
    double dy,
    double scale,
    CustomBackground cb,
  ) {
    final rot = video.value.rotationCorrection;
    final isRotated = rot == 90 || rot == 270;
    final halfW0 = box.width / 2;
    final halfH0 = box.height / 2;
    final halfW = isRotated ? halfH0 : halfW0;
    final halfH = isRotated ? halfW0 : halfH0;
    return Transform.translate(
      offset: Offset(dx, dy),
      child: Transform.scale(
        scale: scale / 100 * 2.0,
        alignment: Alignment.center,
        child: Align(
          alignment: Alignment.center,
          child: OverflowBox(
            minWidth: halfW,
            maxWidth: halfW,
            minHeight: halfH,
            maxHeight: halfH,
            alignment: Alignment.center,
            child: ImageFiltered(
              imageFilter: cheapBackdropBlur(cb.blur * 0.6 / 2, downscale: 2),
              child: Opacity(
                opacity: cb.opacity / 100,
                child: VideoPlayer(video),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SettingsBound extends ConsumerWidget {
  const _SettingsBound();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 根层无页面作用域（pageId = null）：解析结果即全局用户壁纸
    final cb = ref.watch(pageWallpaperProvider);
    if (cb == null) return const SizedBox.shrink();
    return CustomBackgroundLayer(background: cb);
  }
}

/// 页面壁纸作用域：注入 pageIdProvider（页面内脚手架底色/组件色块等按页
/// 解析），并在主题包定义了该页壁纸时于 child 之下垫壁纸层（盖过根层
/// 全局壁纸）。壳页分支/横屏面板/播放页等非覆盖路由场景使用。
class PageWallpaperScope extends ConsumerWidget {
  const PageWallpaperScope({
    super.key,
    required this.pageId,
    required this.child,
  });

  /// 页面 id；null 表示本页不参与按页壁纸（无注入、无垫层，全局语义）。
  final String? pageId;

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wp = pageId == null
        ? null
        : ref.watch(themeLibraryProvider
            .select((s) => s.active?.wallpapers[pageId!]));
    Widget inner = child;
    if (wp != null) {
      inner = Stack(
        fit: StackFit.expand,
        children: [
          CustomBackgroundLayer(
            background: pageWallpaperToCustomBackground(wp),
          ),
          Positioned.fill(child: child),
        ],
      );
    }
    if (pageId == null) return inner;
    return ProviderScope(
      overrides: [pageIdProvider.overrideWithValue(pageId)],
      child: inner,
    );
  }
}

class AppPageBackground extends ConsumerWidget {
  const AppPageBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return child;
  }
}

class RoutePageBackdrop extends ConsumerWidget {
  const RoutePageBackdrop({
    super.key,
    this.completion,
    this.location,
    required this.child,
  });

  final Animation<double>? completion;

  /// 覆盖路由的 matchedLocation：用于解析主题包的每页壁纸；
  /// 未传（未映射页面/命令式路由）时整体回落全局壁纸语义。
  final String? location;

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pageId = pageIdForLocation(
      location,
      landscape: MediaQuery.orientationOf(context) == Orientation.landscape,
    );
    final pageWp = pageId == null
        ? null
        : ref.watch(
            themeLibraryProvider.select((s) => s.active?.wallpapers[pageId]));
    Widget core = _buildCore(context, ref, pageWp);
    if (pageId == null) return core;
    // 页面内容（脚手架底色/组件色块等）按本页 id 解析壁纸状态
    return ProviderScope(
      overrides: [pageIdProvider.overrideWithValue(pageId)],
      child: core,
    );
  }

  Widget _buildCore(
      BuildContext context, WidgetRef ref, PageWallpaper? pageWp) {
    final plain = ColoredBox(color: appSurfaceBg(context), child: child);
    if (pageWp != null) {
      // 主题包页面壁纸（静图）：整页垫层，转场随页面一起进出
      return ColoredBox(
        color: Colors.transparent,
        child: Stack(
          fit: StackFit.expand,
          children: [
            CustomBackgroundLayer(
              background: pageWallpaperToCustomBackground(pageWp),
            ),
            Positioned.fill(child: child),
          ],
        ),
      );
    }
    if (!ref.watch(wallpaperActiveProvider)) return plain;
    final cb = ref.watch(
      settingsProvider.select((s) => s.valueOrNull?.customBackground),
    );
    if (cb?.active != true) return plain;
    if (cb!.mediaType == WallpaperMediaType.video) {
      final anim = completion;
      if (anim == null) return plain;
      // 转场底色优先用视频帧采样平均色：固定 appSurfaceBg 与视频壁纸
      // 观感差异大，切页进出时跳变明显
      final sampled = ref.watch(videoWallpaperColorProvider);
      final base = sampled ?? appSurfaceBg(context);
      return AnimatedBuilder(
        animation: anim,
        // 结构必须恒定：按 status 切换「裸 child ↔ ColoredBox 包裹」会让
        // child 的 element 深度变化，RouteStaticSnapshot（child=页面快照层）
        // 在每次转场开始/结束时被销毁重建——快照图丢失，转场全程失去
        // backdrop 保护（玻璃采样黑/白闪）。completed 与否只影响 base 色
        // 是否叠在页面底下；页面本身不透明（AppPageBackground），恒定
        // ColoredBox 无视觉差异
        builder: (context, child) => ColoredBox(color: base, child: child!),
        child: child,
      );
    }
    // 垫透明而非 appSurfaceBg：转场中页面整树半透明渐入/渐出，
    // 不透明 244 底会透出来盖住全局壁纸——壁纸色块组件（30% 白）
    // 读作满填充纯色块；透全局壁纸则转场前后观感一致
    return ColoredBox(
      color: Colors.transparent,
      child: Stack(
        fit: StackFit.expand,
        children: [
          CustomBackgroundLayer(background: cb),
          Positioned.fill(child: child),
        ],
      ),
    );
  }
}
