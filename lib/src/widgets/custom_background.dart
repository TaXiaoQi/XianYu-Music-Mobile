import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../core/app_colors.dart';
import '../core/settings.dart';
import 'glass_settings.dart';

class CustomBackgroundLayer extends ConsumerStatefulWidget {
  const CustomBackgroundLayer({super.key, this.background});

  final CustomBackground? background;

  @override
  ConsumerState<CustomBackgroundLayer> createState() =>
      _CustomBackgroundLayerState();
}

class _CustomBackgroundLayerState extends ConsumerState<CustomBackgroundLayer>
    with WidgetsBindingObserver {
  VideoPlayerController? _videoController;
  bool _videoReady = false;
  String? _videoKey;

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
    final isVideo = cb != null &&
        cb.mediaType == WallpaperMediaType.video &&
        cb.active;
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
    });
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
      final perf = next.valueOrNull?.performanceMode == PerformanceMode.performance;
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
    final isVideo = cb.mediaType == WallpaperMediaType.video ||
        file.path.toLowerCase().endsWith('.mp4');
    final video = _videoController;
    final videoReady = isVideo && _videoReady && video != null;
    final blurSig = cb.blur * 0.6;
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        final dx = cb.translateX / 100 * w;
        final dy = cb.translateY / 100 * h;
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
                              scale: cb.scale / 100,
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
                        : !videoReady
                            ? const ColoredBox(color: Colors.black)
                            : Transform.scale(
                                scale: 2.0,
                                alignment: Alignment.center,
                                child: Transform.translate(
                                  offset: Offset(dx / 2, dy / 2),
                                  child: Transform.scale(
                                    scale: cb.scale / 100 * 0.5,
                                    alignment: Alignment.center,
                                    child: ImageFiltered(
                                      imageFilter: cheapBackdropBlur(
                                        blurSig / 2,
                                        downscale: 2,
                                      ),
                                      child: Opacity(
                                        opacity: cb.opacity / 100,
                                        child: VideoPlayer(video),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                  ),
                if (cb.maskAlpha > 0)
                  Container(
                    color: Colors.black
                        .withValues(alpha: (cb.maskAlpha / 100).clamp(0.0, 1.0)),
                  ),
              ],
            ),
          ),
        );
      },
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
    final cb = ref.watch(
      settingsProvider.select((s) => s.valueOrNull?.customBackground),
    );
    if (cb?.active != true) return child;
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(
          color: appSurfaceBg(context),
          child: CustomBackgroundLayer(background: cb),
        ),
        child,
      ],
    );
  }
}