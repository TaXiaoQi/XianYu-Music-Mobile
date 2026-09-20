import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import 'blur_budget.dart';
import 'glass_settings.dart';
import 'liquid_wave.dart';

typedef BackingOverlayCallback =
    void Function(PaintingContext context, Offset offset);

class BiliPaiGlass extends StatefulWidget {
  const BiliPaiGlass({
    super.key,
    required this.radius,
    required this.refract,
    required this.chroma,
    required this.blurSigma,
    required this.backgroundColor,
    required this.specular,
    required this.edgeAmount,
    this.saturation = 1.0,
    this.depthEffect = 0.0,
    this.alwaysLive = false,
    this.freshBackdrop = false,
    required this.child,
  });

  final double radius;

  final double refract;

  final double chroma;

  final double blurSigma;

  final Color backgroundColor;

  final double specular;

  final double edgeAmount;

  final double saturation;

  final double depthEffect;

  final bool alwaysLive;

  final bool freshBackdrop;

  final Widget child;

  @override
  State<BiliPaiGlass> createState() => _BiliPaiGlassState();
}

class _BiliPaiGlassState extends State<BiliPaiGlass>
    with TickerProviderStateMixin {
  ui.FragmentShader? _shader;

  static ui.FragmentProgram? _cachedProgram;
  static Future<ui.FragmentProgram>? _programFuture;

  final GlobalKey _backingKey = GlobalKey();

  ui.Image? _frozen;

  bool _idle = false;

  bool _capturing = false;
  Timer? _idleDebounce;

  late final AnimationController _fade;

  late final AnimationController _ripple;

  @override
  void initState() {
    super.initState();
    final cached = _cachedProgram;
    if (cached != null) {
      _shader = cached.fragmentShader();
    } else {
      _load();
    }
    _fade = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
      value: 0,
    );
    _fade.addListener(_onFadeTicked);
    _ripple = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
      value: 3.0,
    )..repeat();
    _ripple.addListener(_onRippleTick);
    globalIsScrolling.addListener(_onGlobalState);
    globalIsTransitioning.addListener(_onGlobalState);
    globalIsDragging.addListener(_onGlobalState);
  }

  void _onFadeTicked() {
    if (!mounted) return;
    final ro = _backingKey.currentContext?.findRenderObject();
    if (ro is RenderLiquidBacking) ro.fadeBlend = _fade.value;
  }

  void _onRippleTick() {
    if (!mounted) return;
    final ro = _backingKey.currentContext?.findRenderObject();
    if (ro is RenderLiquidBacking) {
      ro.uiTime = _ripple.value * 8.0;
      ro.markNeedsPaint();
    }
  }

  Future<void> _load() async {
    try {
      _programFuture ??= ui.FragmentProgram.fromAsset(
          'assets/shaders/bilipai_liquid.frag');
      final program = await _programFuture!;
      _cachedProgram = program;
      if (!mounted) return;
      setState(() {
        _shader = program.fragmentShader();
      });
    } catch (_) {
    }
  }

  @override
  void dispose() {
    globalIsScrolling.removeListener(_onGlobalState);
    globalIsTransitioning.removeListener(_onGlobalState);
    globalIsDragging.removeListener(_onGlobalState);
    _idleDebounce?.cancel();
    _fade.dispose();
    _ripple.dispose();
    _frozen?.dispose();
    _shader?.dispose();
    super.dispose();
  }

  void _onGlobalState() {
    if (!mounted) return;
    if (widget.alwaysLive) return;
    final idle = !globalIsScrolling.value &&
        !globalIsTransitioning.value &&
        !globalIsDragging.value;
    if (idle == _idle) return;
    _idle = idle;
    if (idle) {
      _ripple.stop();
      if (_frozen != null) {
        _startFadeIn();
      } else {
        _scheduleCapture();
      }
    } else {
      _idleDebounce?.cancel();
      if (!_ripple.isAnimating) _ripple.repeat();
      _startFadeOut();
    }
  }

  void _startFadeIn() {
    if (_fade.value >= 0.999) return;
    _fade.animateTo(
      1,
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeOut,
    );
  }

  void _startFadeOut() {
    if (_frozen == null && _fade.value <= 0.001) return;
    _fade.animateTo(
      0,
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
    ).whenComplete(() {
      if (!mounted || _idle) return;
      if (_frozen != null && _fade.value <= 0.001) {
        final old = _frozen!;
        _frozen = null;
        setState(() => old.dispose());
      }
    });
  }

  void _scheduleCapture() {
    _idleDebounce?.cancel();
    _idleDebounce = Timer(const Duration(milliseconds: 160), () {
      if (mounted) _capture();
    });
  }

  Future<void> _capture() async {
    if (_capturing || !mounted || _frozen != null) return;
    final ro = _backingKey.currentContext?.findRenderObject();
    if (ro is! RenderRepaintBoundary) return;
    if (ro.debugNeedsPaint) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _frozen == null) _capture();
      });
      return;
    }
    _capturing = true;
    try {
      final dpr = MediaQuery.devicePixelRatioOf(context);
      final ui.Image image;
      try {
        image = await ro.toImage(pixelRatio: dpr);
      } catch (_) {
        return;
      }
      if (!mounted ||
          !_idle ||
          globalIsScrolling.value ||
          globalIsTransitioning.value ||
          globalIsDragging.value) {
        image.dispose();
        return;
      }
      setState(() {
        _frozen?.dispose();
        _frozen = image;
        _fade.value = 0;
        _onFadeTicked();
      });
      _startFadeIn();
    } finally {
      _capturing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final shader = _shader;
    if (!ui.ImageFilter.isShaderFilterSupported || shader == null) {
      final isDark = Theme.of(context).brightness == Brightness.dark;
      return Container(
        decoration: BoxDecoration(
          color: isDark ? const Color(0xE62A2A2E) : const Color(0xF0FFFFFF),
          borderRadius: BorderRadius.circular(widget.radius),
        ),
        child: widget.child,
      );
    }

    return Stack(
      children: [
        Positioned.fill(
          child: RepaintBoundary(
            key: _backingKey,
            child: _LiquidBacking(
              shader: shader,
              radius: widget.radius,
              refract: widget.refract,
              chroma: widget.chroma,
              blurSigma: widget.blurSigma,
              backgroundColor: widget.backgroundColor,
              specular: widget.specular,
              edgeAmount: widget.edgeAmount,
              saturation: widget.saturation,
              depthEffect: widget.depthEffect,
              frozen: _frozen,
              fadeBlend: _fade.value,
              freshBackdrop: widget.freshBackdrop,
            ),
          ),
        ),
        ClipRRect(
          borderRadius: BorderRadius.circular(widget.radius),
          child: widget.child,
        ),
      ],
    );
  }
}

class _LiquidBacking extends SingleChildRenderObjectWidget {
  const _LiquidBacking({
    required this.shader,
    required this.radius,
    required this.refract,
    required this.chroma,
    required this.blurSigma,
    required this.backgroundColor,
    required this.specular,
    required this.edgeAmount,
    required this.saturation,
    required this.depthEffect,
    this.frozen,
    this.fadeBlend = 1.0,
    this.freshBackdrop = false,
  });

  final ui.FragmentShader shader;
  final double radius;
  final double refract;
  final double chroma;
  final double blurSigma;
  final Color backgroundColor;
  final double specular;
  final double edgeAmount;
  final double saturation;
  final double depthEffect;

  final ui.Image? frozen;

  final double fadeBlend;

  final bool freshBackdrop;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return RenderLiquidBacking(
      shader: shader,
      radius: radius,
      refract: refract,
      chroma: chroma,
      blurSigma: blurSigma,
      backgroundColor: backgroundColor,
      specular: specular,
      edgeAmount: edgeAmount,
      saturation: saturation,
      depthEffect: depthEffect,
      frozen: frozen,
      fadeBlend: fadeBlend,
      freshBackdrop: freshBackdrop,
      dpr: MediaQuery.devicePixelRatioOf(context),
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    RenderLiquidBacking renderObject,
  ) {
    renderObject
      ..shader = shader
      ..radius = radius
      ..refract = refract
      ..chroma = chroma
      ..blurSigma = blurSigma
      ..backgroundColor = backgroundColor
      ..specular = specular
      ..edgeAmount = edgeAmount
      ..saturation = saturation
      ..depthEffect = depthEffect
      ..frozen = frozen
      ..freshBackdrop = freshBackdrop
      ..devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
  }
}

class RenderLiquidBacking extends RenderBox {
  RenderLiquidBacking({
    required ui.FragmentShader shader,
    required double radius,
    required double refract,
    required double chroma,
    required double blurSigma,
    required Color backgroundColor,
    required double specular,
    required double edgeAmount,
    required double saturation,
    required double depthEffect,
    required ui.Image? frozen,
    required double fadeBlend,
    required bool freshBackdrop,
    required double dpr,
  }) : _shader = shader,
       _radius = radius,
       _refract = refract,
       _chroma = chroma,
       _blurSigma = blurSigma,
       _backgroundColor = backgroundColor,
       _specular = specular,
       _edgeAmount = edgeAmount,
       _saturation = saturation,
       _depthEffect = depthEffect,
       _frozen = frozen,
       _fadeBlend = fadeBlend,
       _freshBackdrop = freshBackdrop,
       _devicePixelRatio = dpr;

  ui.FragmentShader _shader;
  ui.FragmentShader get shader => _shader;
  set shader(ui.FragmentShader value) {
    if (_shader == value) return;
    _shader = value;
    markNeedsPaint();
  }

  double _radius;
  double get radius => _radius;
  set radius(double value) {
    if (_radius == value) return;
    _radius = value;
    markNeedsPaint();
  }

  double _refract;
  double get refract => _refract;
  set refract(double value) {
    if (_refract == value) return;
    _refract = value;
    markNeedsPaint();
  }

  double _chroma;
  double get chroma => _chroma;
  set chroma(double value) {
    if (_chroma == value) return;
    _chroma = value;
    markNeedsPaint();
  }

  double _blurSigma;
  double get blurSigma => _blurSigma;
  set blurSigma(double value) {
    if (_blurSigma == value) return;
    _blurSigma = value;
    markNeedsPaint();
  }

  Color _backgroundColor;
  Color get backgroundColor => _backgroundColor;
  set backgroundColor(Color value) {
    if (_backgroundColor == value) return;
    _backgroundColor = value;
    markNeedsPaint();
  }

  double _specular;
  double get specular => _specular;
  set specular(double value) {
    if (_specular == value) return;
    _specular = value;
    markNeedsPaint();
  }

  double _edgeAmount;
  double get edgeAmount => _edgeAmount;
  set edgeAmount(double value) {
    if (_edgeAmount == value) return;
    _edgeAmount = value;
    markNeedsPaint();
  }

  double _saturation;
  double get saturation => _saturation;
  set saturation(double value) {
    if (_saturation == value) return;
    _saturation = value;
    markNeedsPaint();
  }

  double _depthEffect;
  double get depthEffect => _depthEffect;
  set depthEffect(double value) {
    if (_depthEffect == value) return;
    _depthEffect = value;
    markNeedsPaint();
  }

  ui.Image? _frozen;
  ui.Image? get frozen => _frozen;
  set frozen(ui.Image? value) {
    if (_frozen == value) return;
    _frozen = value;
    markNeedsPaint();
  }

  double _fadeBlend;
  double get fadeBlend => _fadeBlend;
  set fadeBlend(double value) {
    final v = value.clamp(0.0, 1.0).toDouble();
    if (_fadeBlend == v) return;
    _fadeBlend = v;
    markNeedsPaint();
  }

  bool _freshBackdrop;
  bool get freshBackdrop => _freshBackdrop;
  set freshBackdrop(bool value) {
    if (_freshBackdrop == value) return;
    _freshBackdrop = value;
    markNeedsPaint();
  }

  double uiTime = 0;

  double _devicePixelRatio;
  double get devicePixelRatio => _devicePixelRatio;
  set devicePixelRatio(double value) {
    if (_devicePixelRatio == value) return;
    _devicePixelRatio = value;
    markNeedsPaint();
  }

  @override
  bool get alwaysNeedsCompositing => true;

  Size get _screenSize {
    final root = owner?.rootNode;
    if (root is RenderView) return root.size;
    return size;
  }

  final LayerHandle<BackdropFilterLayer> _blurHandle =
      LayerHandle<BackdropFilterLayer>();
  final LayerHandle<BackdropFilterLayer> _shaderHandle =
      LayerHandle<BackdropFilterLayer>();
  final LayerHandle<ClipPathLayer> _clipHandle = LayerHandle<ClipPathLayer>();

  ui.ImageFilter? _cachedBlurFilter;
  double _cachedBlurSigma = -1;

  @override
  void performLayout() {
    size = constraints.biggest;
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    globalScrollOffset.addListener(_onScrollChanged);
    globalScrollTick.addListener(_onScrollTick);
  }

  @override
  void detach() {
    globalScrollOffset.removeListener(_onScrollChanged);
    globalScrollTick.removeListener(_onScrollTick);
    super.detach();
  }

  void _onScrollChanged() {
    if (_frozen == null) markNeedsPaint();
  }

  void _onScrollTick() {
    // 横向滚动（来源气泡等 transform 平移）不改变竖向 globalScrollOffset，
    // 也不会触发 markScrollActivity 变更 _frozen；须强制回归 live 重绘，
    // 否则折射采样位置停留在玻璃平移前的屏幕坐标。
    if (_frozen != null) {
      final old = _frozen;
      _frozen = null;
      _fadeBlend = 0;
      // 该 image 可能仍被本帧 scene 引用，且回调在通知合成阶段同步触发，
      // 直接 dispose 会触发 dart:ui Image.dispose 断言——延迟到本帧渲染后。
      SchedulerBinding.instance.addPostFrameCallback((_) => old?.dispose());
    }
    markNeedsPaint();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (size.isEmpty) return;
    final frozen = _frozen;
    final fade = _fadeBlend;
    if (frozen != null && fade > 0.001) {
      if (fade >= 0.999) {
        _paintFrozen(context, offset, frozen);
      } else {
        _paintCrossfade(context, offset, frozen, fade);
      }
    } else {
      _paintLive(context, offset);
    }
  }

  void _paintFrozen(
    PaintingContext context,
    Offset offset,
    ui.Image image,
  ) {
    final rect = offset & size;
    final canvas = context.canvas;
    canvas.save();
    canvas.clipPath(Path()
      ..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(_radius))));
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(
        0,
        0,
        image.width.toDouble(),
        image.height.toDouble(),
      ),
      rect,
      Paint()..filterQuality = FilterQuality.high,
    );
    canvas.restore();
  }

  void _paintCrossfade(
    PaintingContext context,
    Offset offset,
    ui.Image image,
    double fade,
  ) {
    _paintLive(context, offset, overlay: (context, offset) {
      final rect = offset & size;
      context.canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        rect,
        Paint()
          ..filterQuality = FilterQuality.high
          ..color = Colors.white.withValues(alpha: fade),
      );
    });
  }

  void _paintLive(
    PaintingContext context,
    Offset offset, {
    BackingOverlayCallback? overlay,
  }) {
    if (!attached) return;
    final dpr = _devicePixelRatio;
    final screen = _screenSize;

    final globalPos = localToGlobal(Offset.zero);
    final glassOrigin = Offset(globalPos.dx * dpr, globalPos.dy * dpr);
    final glassSize = Size(size.width * dpr, size.height * dpr);

    final bg = _backgroundColor;

    final forceFresh = _freshBackdrop || globalIsDragging.value;
    final targetSigma = _blurSigma;
    _cachedBlurFilter = forceFresh
        ? cheapBackdropBlurFresh(targetSigma)
        : (_cachedBlurFilter != null && _cachedBlurSigma == targetSigma
            ? _cachedBlurFilter!
            : cheapBackdropBlur(targetSigma));
    _cachedBlurSigma = targetSigma;
    final liveBlurFilter = _cachedBlurFilter!;
    final blurLayer = _blurHandle.layer = BackdropFilterLayer();
    blurLayer.filter = liveBlurFilter;

    final clipPath = Path()
      ..addRRect(RRect.fromRectAndRadius(
        Offset.zero & size,
        Radius.circular(_radius),
      ));

    final a = bg.a;
    final refractPx =
        math.min(_refract, math.min(size.width, size.height) * 0.375) * dpr;
    _shader
      ..setFloat(0, screen.width * dpr)
      ..setFloat(1, screen.height * dpr)
      ..setFloat(2, globalScrollOffset.value)
      ..setFloat(3, refractPx)
      ..setFloat(4, _chroma)
      ..setFloat(5, 0.0)
      ..setFloat(6, bg.r * a)
      ..setFloat(7, bg.g * a)
      ..setFloat(8, bg.b * a)
      ..setFloat(9, a)
      ..setFloat(10, _specular)
      ..setFloat(11, _radius * dpr)
      ..setFloat(12, glassOrigin.dx)
      ..setFloat(13, glassOrigin.dy)
      ..setFloat(14, glassSize.width)
      ..setFloat(15, glassSize.height)
      ..setFloat(
        16,
        math.min(_edgeAmount, math.min(size.width, size.height) * 0.42) * dpr,
      )
      ..setFloat(17, _saturation)
      ..setFloat(18, _depthEffect)
      ..setFloat(19, uiTime);

    final shaderLayer = _shaderHandle.layer = BackdropFilterLayer();
    shaderLayer.filter = ui.ImageFilter.shader(_shader);

    _clipHandle.layer = context.pushClipPath(
      needsCompositing,
      offset,
      Offset.zero & size,
      clipPath,
      (context, offset) {
        if (forceFresh) {
          final parity = (uiTime * 1000).toInt().isEven;
          context.canvas.drawRect(
            offset.translate(size.width / 2, size.height / 2) &
                const Size(1, 1),
            Paint()
              ..color = (parity ? Colors.black : Colors.white)
                  .withValues(alpha: 1 / 255),
          );
        }
        context.pushLayer(blurLayer, (context, offset) {}, offset);
        context.pushLayer(shaderLayer, (context, offset) {}, offset);
        overlay?.call(context, offset);
      },
    );
  }

  @override
  void dispose() {
    _blurHandle.layer?.filter = ui.ImageFilter.blur(sigmaX: 0, sigmaY: 0);
    _shaderHandle.layer?.filter = ui.ImageFilter.blur(sigmaX: 0, sigmaY: 0);
    _blurHandle.layer = null;
    _shaderHandle.layer = null;
    _clipHandle.layer = null;
    _cachedBlurFilter = null;
    super.dispose();
  }
}

Widget liquidGlassShell(
  BuildContext context, {
  required Widget child,
  double radius = 999,
  Color? lightBorder,
  Color? darkBorder,
  double borderWidth = 0.8,
}) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return CustomPaint(
    foregroundPainter: _LiquidGlassRimPainter(
      isDark: isDark,
      radius: radius,
      strokeWidth: borderWidth,
      lightBorder: lightBorder,
      darkBorder: darkBorder,
    ),
    child: child,
  );
}

class _LiquidGlassRimPainter extends CustomPainter {
  _LiquidGlassRimPainter({
    required this.isDark,
    required this.radius,
    required this.strokeWidth,
    this.lightBorder,
    this.darkBorder,
  });

  final bool isDark;
  final double radius;
  final double strokeWidth;
  final Color? lightBorder;
  final Color? darkBorder;

  @override
  void paint(Canvas canvas, Size size) {
    final outer = Offset.zero & size;
    final shortest = outer.shortestSide;
    if (shortest <= 0) return;
    final rr = RRect.fromRectAndRadius(
      outer.deflate(strokeWidth / 2),
      Radius.circular(radius.clamp(0.0, shortest / 2)),
    );
    final base = isDark
        ? (darkBorder ?? Colors.white)
        : (lightBorder ?? Colors.black);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..maskFilter =
          MaskFilter.blur(BlurStyle.normal, isDark ? 0.5 : 2.2);
    paint.shader = isDark
        ? RadialGradient(
            center: const Alignment(0, -1.4),
            radius: 1.6,
            colors: [
              base.withValues(alpha: 0.55),
              base.withValues(alpha: 0.12),
              base.withValues(alpha: 0.03),
            ],
          ).createShader(outer)
        : LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              base.withValues(alpha: 0.05),
              base.withValues(alpha: 0.13),
              base.withValues(alpha: 0.17),
            ],
          ).createShader(outer);
    canvas.drawRRect(rr, paint);
  }

  @override
  bool shouldRepaint(_LiquidGlassRimPainter old) =>
      old.isDark != isDark ||
      old.radius != radius ||
      old.strokeWidth != strokeWidth ||
      old.lightBorder != lightBorder ||
      old.darkBorder != darkBorder;
}