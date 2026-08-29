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
    required this.edgeAmount,
    this.saturation = 1.0,
    required this.child,
  });

  /// 玻璃圆角（逻辑像素），裁剪成胶囊/圆角矩形。
  final double radius;

  /// 折射强度：滚动波浪位移幅度（0=无波浪）。
  final double refract;

  /// 色差强度：RGB 通道分离幅度。
  final double chroma;

  /// 主体模糊 sigma（逻辑像素）：由 compose 的 inner 真高斯（GPU 高斯，无
  /// 重影上限）承担，shader 内仅 σ1.5 微模糊平滑。
  final double blurSigma;

  /// 预乘混合底色（铺在波浪扭曲后的背景上，保证可读性）。
  final Color backgroundColor;

  /// 表面流动高光强度（滚动时在玻璃上扫过的反光带，纯色背景上提供动感）。
  final double specular;

  /// 边缘透镜折射幅度（逻辑像素）：内容靠近玻璃边界时沿外向法线被拉向外侧
  /// 的「弯折量」（meniscus），静止也可见，是 BiliPai 贴边观感的关键。
  final double edgeAmount;

  /// 饱和度增益（BiliPai balanced 档 1.5，水晶透亮感来源），1.0=不变。
  final double saturation;

  final Widget child;

  @override
  State<BiliPaiGlass> createState() => _BiliPaiGlassState();
}

class _BiliPaiGlassState extends State<BiliPaiGlass> {
  ui.FragmentShader? _shader;

  /// 进程内共享的已加载 program：BiliPaiGlass 会在容器/顶栏切换时频繁重新
  /// 挂载（如横屏各容器覆盖层顶栏都是独立实例），若每次都异步重载 shader，
  /// 新实例首帧走纯色回退 → 顶栏「掉玻璃闪纯色一帧」。缓存后新实例在
  /// initState 同步创建 shader，首帧即为玻璃。
  static ui.FragmentProgram? _cachedProgram;
  static Future<ui.FragmentProgram>? _programFuture;

  @override
  void initState() {
    super.initState();
    final cached = _cachedProgram;
    if (cached != null) {
      _shader = cached.fragmentShader();
      return;
    }
    _load();
  }

  Future<void> _load() async {
    try {
      _programFuture ??= ui.FragmentProgram.fromAsset(
          'assets/shaders/bilipai_liquid.frag');
      final program = await _programFuture!;
      _cachedProgram = program;
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
      edgeAmount: widget.edgeAmount,
      saturation: widget.saturation,
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
    required this.edgeAmount,
    required this.saturation,
    required super.child,
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
      edgeAmount: edgeAmount,
      saturation: saturation,
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
      ..edgeAmount = edgeAmount
      ..saturation = saturation
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
///   槽 0-1  uSize            —— 背景纹理（全屏）物理尺寸
///   槽 2    uScrollOffset    —— 全局滚动偏移
///   槽 3    uRefract         —— 折射强度
///   槽 4    uChroma          —— 色差强度
///   槽 5    uBlurSigma       —— shader 内微模糊 sigma（固定 1.5×dpr；主体
///                              模糊由 compose 的 inner 真高斯承担）
///   槽 6-9  uBackgroundColor —— 预乘底色
///   槽 10   uSpecular        —— 表面流动高光强度
///   槽 11   uRadius          —— 胶囊圆角半径（物理像素）
///   槽 12-13 uGlassOrigin    —— 玻璃表面左上角（屏幕物理像素）
///   槽 14-15 uGlassSize      —— 玻璃表面尺寸（物理像素）
///   槽 16   uEdgeAmount      —— 边缘透镜折射幅度（物理像素）
///   槽 17   uSaturation      —— 饱和度增益
///   采样器0 uImage           —— 引擎绑定的实时背景
class RenderBiliPaiGlass extends RenderProxyBox {
  RenderBiliPaiGlass({
    required ui.FragmentShader shader,
    required double radius,
    required double refract,
    required double chroma,
    required double blurSigma,
    required Color backgroundColor,
    required double specular,
    required double edgeAmount,
    required double saturation,
    required double dpr,
  })  : _shader = shader,
        _radius = radius,
        _refract = refract,
        _chroma = chroma,
        _blurSigma = blurSigma,
        _backgroundColor = backgroundColor,
        _specular = specular,
        _edgeAmount = edgeAmount,
        _saturation = saturation,
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

  /// compose(shader, blur) filter 缓存，按 sigma 失效，避免每帧重建。
  ui.ImageFilter? _cachedFilter;
  double _cachedFilterSigma = -1;

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

    // 玻璃表面在屏幕空间的物理像素位置/尺寸：SDF 以玻璃局部坐标计算，才能
    // 让「贴近边」的透镜折射/边缘光精确贴合胶囊边缘（而非全屏边缘）。
    final globalPos = localToGlobal(Offset.zero);
    final glassOrigin = Offset(globalPos.dx * dpr, globalPos.dy * dpr);
    final glassSize = Size(size.width * dpr, size.height * dpr);

    // 更新着色器 uniform：滚动偏移 / 折射 / 色差 / 微模糊 / 预乘底色 / 几何。
    // 模糊分工：shader 作为 compose 的 inner 先跑——直接在「原始清晰背景」上
    // 做边缘涟漪/透镜折射（弯折清晰可见），之后引擎的 outer 真高斯（σ=blurSigma）
    // 整体糊上去；模糊不撤销位移，边缘拉弯的内容糊后仍可见，中心则是纯净高斯。
    // 注意方向不能反：compose(outer: shader, inner: blur) 在 Impeller 上
    // shader 采到未初始化纹理，整块渲染成雪花噪声（实测）。
    // shader 内不承担模糊（uBlurSigma=0，单点采样），tap 大模糊必出重影。
    final bg = _backgroundColor;
    final a = bg.a;
    _shader
      ..setFloat(0, screen.width * dpr)
      ..setFloat(1, screen.height * dpr)
      ..setFloat(2, globalScrollOffset.value)
      ..setFloat(3, _refract)
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
      ..setFloat(16, _edgeAmount * dpr)
      ..setFloat(17, _saturation);

    // compose filter 按 sigma 缓存，滚动每帧重建太贵（对齐包内做法）。
    final targetSigma = _blurSigma * dpr;
    if (_cachedFilter == null || _cachedFilterSigma != targetSigma) {
      _cachedFilter = ui.ImageFilter.compose(
        outer: ui.ImageFilter.blur(sigmaX: targetSigma, sigmaY: targetSigma),
        inner: ui.ImageFilter.shader(_shader),
      );
      _cachedFilterSigma = targetSigma;
    }

    final backdrop = _backdropHandle.layer ??= BackdropFilterLayer();
    backdrop.filter = _cachedFilter!;

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
    _cachedFilter = null;
    super.dispose();
  }
}
