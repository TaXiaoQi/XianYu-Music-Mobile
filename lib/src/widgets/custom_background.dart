import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../core/app_colors.dart';
import '../core/settings.dart';
import 'glass_settings.dart';

class CustomBackgroundLayer extends StatefulWidget {
  const CustomBackgroundLayer({super.key, this.background});

  final CustomBackground? background;

  @override
  State<CustomBackgroundLayer> createState() => _CustomBackgroundLayerState();
}

class _CustomBackgroundLayerState extends State<CustomBackgroundLayer> {
  VideoPlayerController? _videoController;
  bool _videoReady = false;
  String? _videoKey;

  @override
  void initState() {
    super.initState();
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
    unawaited(controller.play());
  }

  @override
  void dispose() {
    _videoController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
                    child: Transform.translate(
                      offset: Offset(dx, dy),
                      child: Transform.scale(
                        scale: cb.scale / 100,
                        alignment: Alignment.center,
                        child: ImageFiltered(
                          imageFilter: cheapBackdropBlur(blurSig),
                          child: Opacity(
                            opacity: cb.opacity / 100,
                            child: videoReady
                                ? VideoPlayer(video)
                                : Image.file(
                                    key: ValueKey('wallpaper-${file.path}'),
                                    file,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, _, _) =>
                                        const SizedBox.shrink(),
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