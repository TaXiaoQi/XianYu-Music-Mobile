import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;

import 'blur_budget.dart';

final ValueNotifier<double> globalScrollOffset = ValueNotifier<double>(0);

class ScrollOffsetCapture extends StatelessWidget {
  const ScrollOffsetCapture({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (notification) {
        final metrics = notification.metrics;
        markScrollActivity();
        if (metrics.axis == Axis.vertical) {
          globalScrollOffset.value = metrics.pixels;
        }
        return false;
      },
      child: child,
    );
  }
}

class LiquidWave extends StatefulWidget {
  const LiquidWave({
    super.key,
    required this.child,
    required this.rects,
    this.enabled = true,
    this.refract = 0.02,
    this.chroma = 0.3,
  });

  final Widget child;

  final List<Rect> rects;

  final bool enabled;

  final double refract;

  final double chroma;

  @override
  State<LiquidWave> createState() => _LiquidWaveState();
}

class _LiquidWaveState extends State<LiquidWave> {
  ui.FragmentShader? _shader;
  ui.Image? _bg;
  bool _capturing = false;

  static final _repaintKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _loadShader();
    globalScrollOffset.addListener(_onGlobalScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _capture());
  }

  @override
  void dispose() {
    globalScrollOffset.removeListener(_onGlobalScroll);
    _bg?.dispose();
    super.dispose();
  }

  Future<void> _loadShader() async {
    try {
      final program =
          await ui.FragmentProgram.fromAsset('assets/shaders/liquid_wave.frag');
      if (!mounted) return;
      setState(() => _shader = program.fragmentShader());
      WidgetsBinding.instance.addPostFrameCallback((_) => _capture());
    } catch (_) {
    }
  }

  void _onGlobalScroll() {
    if (!widget.enabled) return;
    _capture();
  }

  Future<void> _capture() async {
    if (_capturing || !mounted) return;
    final renderObject = _repaintKey.currentContext?.findRenderObject();
    if (renderObject is! RenderRepaintBoundary) return;
    _capturing = true;
    try {
      final dpr = MediaQuery.of(context).devicePixelRatio;
      final image = await renderObject.toImage(pixelRatio: dpr);
      if (!mounted) return;
      setState(() {
        _bg?.dispose();
        _bg = image;
      });
    } finally {
      _capturing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled || _shader == null) return widget.child;
    return Stack(
      fit: StackFit.expand,
      children: [
        RepaintBoundary(key: _repaintKey, child: widget.child),
        IgnorePointer(
          child: CustomPaint(
            painter: _WavePainter(
              shader: _shader!,
              bg: _bg,
              rects: widget.rects,
              refract: widget.refract,
              chroma: widget.chroma,
              dpr: MediaQuery.of(context).devicePixelRatio,
              scrollOffset: globalScrollOffset.value,
            ),
          ),
        ),
      ],
    );
  }
}

class _WavePainter extends CustomPainter {
  _WavePainter({
    required this.shader,
    required this.bg,
    required this.rects,
    required this.refract,
    required this.chroma,
    required this.dpr,
    required this.scrollOffset,
  });

  final ui.FragmentShader shader;
  final ui.Image? bg;
  final List<Rect> rects;
  final double refract;
  final double chroma;
  final double dpr;
  final double scrollOffset;

  @override
  void paint(Canvas canvas, Size size) {
    final image = bg;
    if (image == null || size.width <= 0 || size.height <= 0) return;

    double rx(int i) => i >= rects.length ? 0 : rects[i].left * dpr;
    double ry(int i) => i >= rects.length ? 0 : rects[i].top * dpr;
    double rz(int i) => i >= rects.length ? 0 : rects[i].right * dpr;
    double rw(int i) => i >= rects.length ? 0 : rects[i].bottom * dpr;

    shader
      ..setImageSampler(0, image)
      ..setFloat(0, size.width)
      ..setFloat(1, size.height)
      ..setFloat(2, size.width * dpr)
      ..setFloat(3, size.height * dpr)
      ..setFloat(4, scrollOffset)
      ..setFloat(5, rx(0))
      ..setFloat(6, ry(0))
      ..setFloat(7, rz(0))
      ..setFloat(8, rw(0))
      ..setFloat(9, rx(1))
      ..setFloat(10, ry(1))
      ..setFloat(11, rz(1))
      ..setFloat(12, rw(1))
      ..setFloat(13, rx(2))
      ..setFloat(14, ry(2))
      ..setFloat(15, rz(2))
      ..setFloat(16, rw(2))
      ..setFloat(17, refract)
      ..setFloat(18, chroma);

    canvas.save();
    canvas.scale(dpr, dpr);
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_WavePainter oldDelegate) =>
      oldDelegate.bg != bg ||
      oldDelegate.rects != rects ||
      oldDelegate.refract != refract ||
      oldDelegate.chroma != chroma ||
      oldDelegate.dpr != dpr ||
      oldDelegate.scrollOffset != scrollOffset;
}
