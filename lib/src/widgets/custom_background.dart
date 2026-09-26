import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../core/app_colors.dart';
import '../core/settings.dart';
import 'glass_settings.dart';

class CustomBackgroundLayer extends ConsumerStatefulWidget {
  const CustomBackgroundLayer({
    super.key,
    this.background,
    this.forceOrientation,
  });

  final CustomBackground? background;

  /// 预览框内强制按指定方向取参（竖屏下预览横屏样式时使用）
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

  bool get _videoShouldAutoPlay {
    final s = ref.read(settingsProvider);
    return s.valueOrNull?.performanceMode != PerformanceMode.performance;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _syncVideo(widget.background);
  }

  @override
  void didUpdateWidget(covariant CustomBackgroundLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    final cb = widget.background;
    if (oldWidget.background?.imagePath != cb?.imagePath ||
        oldWidget.background?.mediaType != cb?.mediaType) {
      _syncVideo(cb);
    }
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
    final key = isVideo ? cb.imagePath : null;
    if (_videoKey == key) return;
    _videoKey = key;

    final old = _videoController;
    _videoController = null;
    _videoReady = false;
    if (mounted) setState(() {});
    await old?.dispose();

    if (!isVideo) return;

    final controller = VideoPlayerController.file(File(cb.imagePath))
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
      debugPrint(
        'customBg video init raw=$size rot=$rot display=$_videoSize',
      );
    });
    // 壁纸视频必须无声：初始化后再静音一次，规避部分实现初始化完成时重置音量的情况
    await controller.setVolume(0);
    if (_videoShouldAutoPlay &&
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      unawaited(controller.play());
    }
  }

  @override
  void dispose() {
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
    final isVideo =
        cb.mediaType == WallpaperMediaType.video ||
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
        final videoBox = videoReady ? _coverBox(w, h, _videoSize) : null;
        final logSig = videoReady ? '$videoBox|${w}x$h' : null;
        if (logSig != null && logSig != _lastVideoLogSig) {
          _lastVideoLogSig = logSig;
          debugPrint('customBg videoBox=$videoBox container=${w}x$h');
        }
        return RepaintBoundary(
          child: SizedBox.expand(
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (hasMedia)
                  ClipRect(
                    child: !isVideo
                        ? Transform.translate(
                            offset: Offset(dx, dy),
                            child: Transform.scale(
                              scale: useScale / 100,
                              alignment: Alignment.center,
                              child: ImageFiltered(
                                imageFilter: cheapBackdropBlur(blurSig),
                                child: Opacity(
                                  opacity: cb.opacity / 100,
                                  child: Image.file(
                                    key: ValueKey('wallpaper-${file.path}'),
                                    file,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, _, _) =>
                                        const SizedBox.shrink(),
                                  ),
                                ),
                              ),
                            ),
                          )
                        : videoBox == null
                        ? const ColoredBox(color: Colors.black)
                        : _buildVideoLayer(
                            video!,
                            videoBox,
                            dx,
                            dy,
                            useScale.toDouble(),
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

  Size? _coverBox(double w, double h, Size? videoSize) {
    final vw = videoSize?.width ?? 0;
    final vh = videoSize?.height ?? 0;
    if (vw <= 0 || vh <= 0 || w <= 0 || h <= 0) return null;
    final containerRatio = w / h;
    final videoRatio = vw / vh;
    if (videoRatio > containerRatio) {
      return Size(h * videoRatio, h);
    }
    return Size(w, w / videoRatio);
  }

  Widget _buildVideoLayer(
    VideoPlayerController video,
    Size box,
    double dx,
    double dy,
    double scale,
    CustomBackground cb,
  ) {
    // box 是按旋转后显示比例算出的 cover 框。但 VideoPlayer 纹理本身是原始编码比例，
    // 且视频带旋转元数据时会由内部 RotatedBox 旋转。若直接按显示比例拉伸纹理，旋转后必然变形。
    // 因此带 90/270 旋转时把纹理框的宽高交换，让纹理按原始比例拉伸，旋转后再对回 box。
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
    final cb = ref.watch(
      settingsProvider.select((s) => s.valueOrNull?.customBackground),
    );
    if (cb?.active != true) return const SizedBox.shrink();
    return CustomBackgroundLayer(background: cb);
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

/// 覆盖式转场中跟随新页滑入的页面底。页面 Scaffold 是透明的
/// （scaffoldBackgroundColor 全局 transparent，为了根部视频壁纸能透出），
/// 覆盖转场若不垫底，新页滑入区域会直接透出旧页内容造成混叠。
/// - 无壁纸：垫 appSurfaceBg，与根 Stack 的 ColoredBox 同源，视觉一致；
/// - 图片壁纸：渲一份与根部对齐的壁纸副本（Image.file 走 ImageCache，开销小），
///   转场结束后常驻也与底层壁纸无缝；
/// - 视频壁纸：转场期间垫纯色、[completion] 动画完成后变透明露出底层视频
///   （避免每个转场页各挂一路视频解码器）。
class RoutePageBackdrop extends ConsumerWidget {
  const RoutePageBackdrop({super.key, this.completion, required this.child});

  final Animation<double>? completion;

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plain =
        ColoredBox(color: appSurfaceBg(context), child: child);
    if (!ref.watch(wallpaperActiveProvider)) return plain;
    final cb = ref.watch(
      settingsProvider.select((s) => s.valueOrNull?.customBackground),
    );
    if (cb?.active != true) return plain;
    if (cb!.mediaType == WallpaperMediaType.video) {
      final anim = completion;
      if (anim == null) return plain;
      return AnimatedBuilder(
        animation: anim,
        builder: (context, child) =>
            anim.status == AnimationStatus.completed
                ? (child ?? const SizedBox.shrink())
                : ColoredBox(color: appSurfaceBg(context), child: child!),
        child: child,
      );
    }
    return ColoredBox(
      color: appSurfaceBg(context),
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
