import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'blur_budget.dart';
import 'liquid_wave.dart';

/// BiliPai 液态玻璃表面（迷你播放条/悬浮底栏专用）。
///
/// 用自定义片元着色器 [assets/shaders/bilipai_liquid.frag] 对实时背景做
/// 「滚动波浪扭曲 + RGB 色差 + 轻量模糊 + 半透明底色」，替代
/// liquid_glass_widgets 的 `AdaptiveGlass`：
/// - 着色器经 `BackdropFilterLayer` + `ImageFilter.shader` 绑定背景采样
///   （第一个 sampler 由引擎绑定到玻璃下方的实时内容），无需像旧 LiquidWave
///   那样整页离屏捕获，成本更低；
/// - 滚动时按 [globalScrollOffset] 驱动波浪相位（shader 只在滚动时重绘，
///   静止冻结采样），对应「纯滑动不更新、交互才激活」的性能原则；
/// - 中/高档真液态档位生效；低档（伪液态毛玻璃）走 [pseudoLiquidSurface]。
///
/// 不支持 Impeller / shader 加载失败时回退为高不透明度纯色圆角胶囊。
class BiliPaiGlass extends StatefulWidget {
  const BiliPaiGlass({
    super.key,
    required this.radius,
    required this.refract,
    required this.chroma,
    required this.blurSigma,
    required this.backgroundColor,
    required this.specular,
    required this.child,
  });

  /// 玻璃圆角（逻辑像素），裁剪成胶囊/圆角矩形。
  final double radius;

  /// 折射强度：滚动波浪位移幅度（0=无波浪）。
  final double refract;

  /// 色差强度：RGB 通道分离幅度。
  final double chroma;

  /// 轻量模糊 sigma（逻辑像素），0=不模糊。
  final double blurSigma;

  /// 预乘混合底色（铺在波浪扭曲后的背景上，保证可读性）。
  final Color backgroundColor;

  /// 表面流动高光强度（滚动时在玻璃上扫过的反光带，纯色背景上提供动感）。
  final double specular;

  final Widget child;

  @override
  State<BiliPaiGlass> createState() => _BiliPaiGlassState();
}

class _BiliPaiGlassState extends State<BiliPaiGlass> {
  ui.FragmentShader? _shader;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final program =
          await ui.FragmentProgram.fromAsset('assets/shaders/bilipai_liquid.frag');
      if (!mounted) return;
      setState(() => _shader = program.fragmentShader());
    } catch (_) {
      // 加载失败保持 null，build 走纯色回退。
    }
  }

  @override
  void dispose() {
    _shader?.dispose();
    super.dispose();
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
    return _BiliPaiGlassRender(
      shader: shader,
      radius: widget.radius,
      refract: widget.refract,
      chroma: widget.chroma,
      blurSigma: widget.blurSigma,
      backgroundColor: widget.backgroundColor,
      specular: widget.specular,
      child: widget.child,
    );
  }
}

class _BiliPaiGlassRender extends SingleChildRenderObjectWidget {
  const _BiliPaiGlassRender({
    required this.shader,
    required this.radius,
    required this.refract,
    required this.chroma,
    required this.blurSigma,
    required this.backgroundColor,
    required this.specular,
    required super.child,
  });

  final ui.FragmentShader shader;
  final double radius;
  final double refract;
  final double chroma;
  final double blurSigma;
  final Color backgroundColor;
  final double specular;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return RenderBiliPaiGlass(
      shader: shader,
      radius: radius,
      refract: refract,
      chroma: chroma,
      blurSigma: blurSigma,
      backgroundColor: backgroundColor,
      specular: specular,
      dpr: MediaQuery.devicePixelRatioOf(context),
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    RenderBiliPaiGlass renderObject,
  ) {
    renderObject
      ..shader = shader
      ..radius = radius
      ..refract = refract
      ..chroma = chroma
      ..blurSigma = blurSigma
      ..backgroundColor = backgroundColor
      ..specular = specular
      ..devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
  }
}

/// BiliPai 液态玻璃自绘渲染对象。
///
/// 布局上包裹子组件；绘制时把子树（连同其上的实时背景）裁剪成圆角胶囊，
/// 用 `BackdropFilterLayer` + `ImageFilter.shader` 对背景施加 BiliPai 波浪
/// 扭曲，再在顶部绘制子组件内容。
///
/// uniform 布局（按声明顺序，sampler 不计入 float 索引）：
///   槽 0-1  uSize             —— 背景纹理（全屏）物理尺寸
///   槽 2    uScrollOffset     —— 全局滚动偏移
///   槽 3    uRefract          —— 折射强度
///   槽 4    uChroma           —— 色差强度
///   槽 5    uBlurSigma        —— 模糊 sigma（物理像素）
///   槽 6-9  uBackgroundColor  —— 预乘底色
///   槽 10   uSpecular         —— 表面流动高光强度
///   采样器0 uImage            —— 引擎绑定的实时背景
class RenderBiliPaiGlass extends RenderProxyBox {
  RenderBiliPaiGlass({
    required ui.FragmentShader shader,
    required double radius,
    required double refract,
    required double chroma,
    required double blurSigma,
    required Color backgroundColor,
    required double specular,
    required double dpr,
  })  : _shader = shader,
        _radius = radius,
        _refract = refract,
        _chroma = chroma,
        _blurSigma = blurSigma,
        _backgroundColor = backgroundColor,
        _specular = specular,
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

  double _devicePixelRatio;
  double get devicePixelRatio => _devicePixelRatio;
  set devicePixelRatio(double value) {
    if (_devicePixelRatio == value) return;
    _devicePixelRatio = value;
    markNeedsPaint();
  }

  /// 需合成：BackdropFilterLayer 依赖合成，必须置 true 否则裁剪与滤镜次序错乱。
  @override
  bool get alwaysNeedsCompositing => true;

  /// 背景纹理尺寸 = 全屏物理像素（BackdropFilter 模式 uSize 约定）。
  Size get _screenSize {
    final root = owner?.rootNode;
    if (root is RenderView) return root.size;
    return size;
  }

  final LayerHandle<BackdropFilterLayer> _backdropHandle =
      LayerHandle<BackdropFilterLayer>();
  final LayerHandle<ClipPathLayer> _clipHandle = LayerHandle<ClipPathLayer>();

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    globalScrollOffset.addListener(_onScrollChanged);
    globalIsScrolling.addListener(_onScrollChanged);
  }

  @override
  void detach() {
    globalScrollOffset.removeListener(_onScrollChanged);
    globalIsScrolling.removeListener(_onScrollChanged);
    super.detach();
  }

  void _onScrollChanged() => markNeedsPaint();

  @override
  void paint(PaintingContext context, Offset offset) {
    if (!attached || size.isEmpty) return;
    final dpr = _devicePixelRatio;
    final screen = _screenSize;

    // 更新着色器 uniform：滚动偏移 / 折射 / 色差 / 模糊 / 预乘底色。
    final bg = _backgroundColor;
    final a = bg.a;
    _shader
      ..setFloat(0, screen.width * dpr)
      ..setFloat(1, screen.height * dpr)
      ..setFloat(2, globalScrollOffset.value)
      ..setFloat(3, _refract)
      ..setFloat(4, _chroma)
      ..setFloat(5, _blurSigma * dpr)
      ..setFloat(6, bg.r * a)
      ..setFloat(7, bg.g * a)
      ..setFloat(8, bg.b * a)
      ..setFloat(9, a)
      ..setFloat(10, _specular);

    final backdrop = _backdropHandle.layer ??= BackdropFilterLayer();
    backdrop.filter = ui.ImageFilter.shader(_shader);

    final clipPath = Path()
      ..addRRect(RRect.fromRectAndRadius(
        Offset.zero & size,
        Radius.circular(_radius),
      ));
    _clipHandle.layer = context.pushClipPath(
      needsCompositing,
      offset,
      Offset.zero & size,
      clipPath,
      (context, offset) {
        context.pushLayer(backdrop, super.paint, offset);
      },
      oldLayer: _clipHandle.layer,
    );
  }

  @override
  void dispose() {
    // 提前清掉 layer 上的 filter 引用，避免 GPU 关闭时资源滞留（对齐包内做法）。
    _backdropHandle.layer?.filter = ui.ImageFilter.blur(sigmaX: 0, sigmaY: 0);
    _backdropHandle.layer = null;
    _clipHandle.layer = null;
    super.dispose();
  }
}
