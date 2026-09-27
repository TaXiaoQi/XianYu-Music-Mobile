import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';
import '../core/application_logger.dart';

class RouteStaticSnapshot extends ConsumerStatefulWidget {
  const RouteStaticSnapshot({
    super.key,
    required this.animation,
    required this.child,
  });

  final Animation<double> animation;

  final Widget child;

  @override
  ConsumerState<RouteStaticSnapshot> createState() =>
      _RouteStaticSnapshotState();
}

class _RouteStaticSnapshotState extends ConsumerState<RouteStaticSnapshot> {
  static const int _downscale = 2;

  final GlobalKey _boundaryKey = GlobalKey();
  ui.Image? _image;
  Size? _size;
  bool _enabled = true;
  bool _capturing = false;
  int _token = 0;

  bool get _moving {
    final s = widget.animation.status;
    return s == AnimationStatus.forward || s == AnimationStatus.reverse;
  }

  @override
  void initState() {
    super.initState();
    final s = ref.read(settingsProvider).valueOrNull;
    _enabled = (s?.frostedGlass ?? false) || (s?.liquidGlass ?? false);
    widget.animation.addStatusListener(_onStatus);
    WidgetsBinding.instance.addPostFrameCallback((_) => _capture());
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.forward || status == AnimationStatus.reverse) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _moving) _capture();
      });
      return;
    }
    final wasMoving = _moving;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !wasMoving) setState(() {});
    });
  }

  @override
  void dispose() {
    _token++;
    widget.animation.removeStatusListener(_onStatus);
    _image?.dispose();
    _image = null;
    _size = null;
    super.dispose();
  }

  Future<void> _capture({int attempt = 0}) async {
    if (!_enabled || _capturing) return;
    _capturing = true;
    final token = ++_token;
    final ctx = _boundaryKey.currentContext;
    final box = ctx?.findRenderObject();
    if (!mounted || ctx == null || box is! RenderRepaintBoundary) {
      _capturing = false;
      return;
    }
    if (box.size.isEmpty || !box.attached) {
      _capturing = false;
      return;
    }
    final dpr = MediaQuery.devicePixelRatioOf(ctx);
    final size = box.size;
    ui.Image? img;
    try {
      img = await box.toImage(
        pixelRatio: dpr / _downscale,
      );
    } catch (e) {
      img = null;
      if (e.toString().contains('debugNeedsPaint') && attempt < 2 && mounted) {
        _capturing = false;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _capture(attempt: attempt + 1);
        });
        return;
      }
      AppLog.warn('route-snapshot', 'capture toImage failed: $e');
    }
    _capturing = false;
    if (!mounted || token != _token) {
      img?.dispose();
      return;
    }
    setState(() {
      _image?.dispose();
      _image = img;
      _size = size;
    });
  }

  @override
  Widget build(BuildContext context) {
    final img = _image;
    final size = _size;
    final moving = _enabled && _moving;
    final showImg = moving && img != null && size != null;
    return RepaintBoundary(
      key: _boundaryKey,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Offstage(offstage: showImg, child: widget.child),
          if (img != null && size != null && moving)
            Positioned.fill(
              child: RawImage(
                image: img,
                width: size.width,
                height: size.height,
                fit: BoxFit.fill,
                filterQuality: FilterQuality.medium,
              ),
            ),
        ],
      ),
    );
  }
}