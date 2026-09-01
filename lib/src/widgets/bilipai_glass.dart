import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'blur_budget.dart';
import 'liquid_wave.dart';

/// 实时背板绘制完成后的叠加绘制回调（十字淡变时在之上叠冻结图）。
typedef BackingOverlayCallback =
    void Function(PaintingContext context, Offset offset);

/// BiliPai 液态玻璃表面（迷你播放条/悬浮底栏专用）。
///
/// 用自定义片元着色器 [assets/shaders/bilipai_liquid.frag] 对实时背景做
/// 「滚动波浪扭曲 + RGB 色差 + 轻量模糊 + 半透明底色」，替代
/// liquid_glass_widgets 的 `AdaptiveGlass`：
/// - 着色器经 `BackdropFilterLayer` + `ImageFilter.shader` 绑定背景采样
///   （第一个 sampler 由引擎绑定到玻璃下方的实时内容），无需像旧 LiquidWave
///   那样整页离屏捕获，成本更低；
/// - 全档真液态生效（BiliPai 三档配方：低/中=CLEAR 零模糊、高=BALANCED
///   4dp）；液态玻璃关闭时的毛玻璃回退走 [pseudoLiquidSurface]。
///
/// **静止缓存（停下不动缓存当前效果）**：玻璃只分「背板」与「内容」两层——
///   背板（模糊 + 液态折射 + 底色）是昂贵的实时 BackdropFilter；内容（封面/
///   进度/文字/按钮）永远实时。当全局处于静止（非滚动、非转场）时，把背板
///   抓一次屏缓存成图，之后每帧只是 blit 这张静态图（零 BackdropFilter、零
///   高斯、零 shader 采样），保留了液态观感（边带折射/饱和度/底色），而不是
///   退化成纯毛玻璃。一旦开始滚动/转场（背板在动）立即丢弃缓存回退实时。
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
    required this.child,
  });

  /// 玻璃圆角（逻辑像素），裁剪成胶囊/圆角矩形。
  final double radius;

  /// 折射强度：滚动波浪位移幅度（0=无波浪）。
  final double refract;

  /// 色差强度：RGB 通道分离幅度。
  final double chroma;

  /// 主体模糊 sigma（逻辑像素）：由 compose 的 outer 真高斯（GPU 高斯，无
  /// 重影上限）承担，shader 内不承担模糊（σ0 单点采样）。
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

  /// 径向深度效应（BiliPai/Halcyon 水滴 depthEffect=true）：>0 时把径向
  /// 方向掺进折射梯度，中心内容也参与「鼓起」折射（放大镜观感）。仅水滴
  /// 类小圆面开启；壳体表面保持 Halcyon 默认关闭。
  final double depthEffect;

  /// 始终实时渲染（不参与「静止冻结背板」优化）。
  ///
  /// 开启后该表面不做抓屏冻结，任何时刻都走实时 BackdropFilter + 液态
  /// shader，且涟漪时钟常转——适用于需要拖拽 / 平移盖到不同内容上、不能
  /// 容忍冻结背板错位的浮层（迷你播放条）。代价是静止时也持续实时渲染
  /// （面积小、成本可控）；关闭则维持静止冻结缓存以省电。
  final bool alwaysLive;

  final Widget child;

  @override
  State<BiliPaiGlass> createState() => _BiliPaiGlassState();
}

class _BiliPaiGlassState extends State<BiliPaiGlass>
    with TickerProviderStateMixin {
  ui.FragmentShader? _shader;

  /// 进程内共享的已加载 program：BiliPaiGlass 会在容器/顶栏切换时频繁重新
  /// 挂载（如横屏各容器覆盖层顶栏都是独立实例），若每次都异步重载 shader，
  /// 新实例首帧走纯色回退 → 顶栏「掉玻璃闪纯色一帧」。缓存后新实例在
  /// initState 同步创建 shader，首帧即为玻璃。
  static ui.FragmentProgram? _cachedProgram;
  static Future<ui.FragmentProgram>? _programFuture;

  /// 背板 RepaintBoundary 的 key：静止时抓屏背板（仅玻璃背板，不含内容）。
  final GlobalKey _backingKey = GlobalKey();

  /// 静止缓存的背板图（零成本复用）。null = 实时 BackdropFilter。
  ui.Image? _frozen;

  /// 当前是否静止（非滚动且非转场）。
  bool _idle = false;

  bool _capturing = false;
  Timer? _idleDebounce;

  /// 背板「实时 ↔ 冻结」十字淡变控制器：0=纯实时，1=纯冻结图。进入滚动态
  /// （退冻结）140ms、退出滚动态（进冻结）420ms——对齐 BiliPai
  /// LIQUID_GLASS_REUSE_PARITY「材质进入滚动态 140ms、退出滚动态 420ms」，
  /// 避免实时↔冻结硬切导致的视觉闪烁。
  late final AnimationController _fade;

  /// 持续涟漪时钟：驱动 shader 的 uTime（槽 19），让玻璃在静止 / 拖拽（底图
  /// 不动）时也带轻微液态流动，而不止是停在模糊上。仅实时背板（非冻结）时
  /// 运行；冻结（blit 缓存图）后停表省电。
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
    // 直接驱动背板绘制层的淡变值，避免淡变期间每帧重建整个 widget 树。
    _fade.addListener(_onFadeTicked);
    // 持续涟漪：值 0→1 映射为 uTime 秒（1 rev = 8s），非零起始避免首帧
    // 时间被清零。仅实时背板时向前走。
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

  /// 把当前淡变值写入背板图元（仅重绘，不重建 widget）。
  void _onFadeTicked() {
    if (!mounted) return;
    final ro = _backingKey.currentContext?.findRenderObject();
    if (ro is RenderLiquidBacking) ro.fadeBlend = _fade.value;
  }

  /// 把涟漪时钟值写入背板 shader 的 uTime 并触发实时重绘。涟漪只在非静止
  /// （实时背板）时运行，冻结（blit 缓存图）后停表、不会再触发重绘，故
  /// 这里无条件重绘刷新背板即可。
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
      // 加载失败保持 null，build 走纯色回退。
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

  /// 全局静止/活动切换：静止且无缓存 → 稍后抓屏冻结；活动 → 淡变退冻结
  /// 回退实时（背板在动，缓存已失效）。滚动/转场/拖动任一活动即非静止。
  void _onGlobalState() {
    if (!mounted) return;
    // 常驻实时模式：不吃冻结优化，始终实时渲染液态 shader + 涟漪常转
    // （涟漪从 initState 起 repeat，这里不 stop、不 capture、不 fade）。
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

  /// 退出滚动态 → 进冻结：把背板从实时淡变到缓存的冻结图（BiliPai 420ms）。
  void _startFadeIn() {
    if (_fade.value >= 0.999) return;
    _fade.animateTo(
      1,
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeOut,
    );
  }

  /// 进入滚动态 → 退冻结：把背板从冻结图淡变回实时（BiliPai 140ms）。淡变
  /// 完成即彻底丢弃缓存——冻结图此刻已与实时无异，留着只是浪费显存。
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

  /// 抓屏背板：在实时 BackdropFilter 还挂着时把「已渲染的液态背板」栅格化成
  /// 一张图，之后静止期间直接 blit，不再跑实时滤镜。
  Future<void> _capture() async {
    if (_capturing || !mounted || _frozen != null) return;
    final ro = _backingKey.currentContext?.findRenderObject();
    if (ro is! RenderRepaintBoundary) return;
    // RepaintBoundary 尚未完成本帧绘制（刚挂载 / 布局尺寸变化，如旋转）时，
    // 立即 toImage 会触发 debugNeedsPaint 断言并抓到半成品。推迟到下一帧
    // 绘制完成后重试。release 下 debugNeedsPaint 恒为 false，行为与原先一致。
    if (ro.debugNeedsPaint) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _frozen == null) _capture();
      });
      return;
    }
    _capturing = true;
    try {
      final dpr = MediaQuery.devicePixelRatioOf(context);
      final image = await ro.toImage(pixelRatio: dpr);
      // 抓屏期间又开始运动 / 组件已卸载：本次结果作废。
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

    // 背板与内容分层：背板（Positioned.fill，含 RepaintBoundary 供抓屏）在最
    // 下，内容永远实时叠在上面。两者合并的 Stack 尺寸 = 内容尺寸（背板只是
    // 填充），与旧的包裹式布局尺寸一致。
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
            ),
          ),
        ),
        // 内容保持实时（旋转封面/进度环/文字/按钮不被冻结）。
        ClipRRect(
          borderRadius: BorderRadius.circular(widget.radius),
          child: widget.child,
        ),
      ],
    );
  }
}

/// 液态玻璃「背板」层：只渲染玻璃填充（模糊 + 液态折射 + 底色/饱和度），
/// 不含任何内容。静止时可被抓屏冻结成图。
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

  /// 静止缓存图（null = 实时渲染）。
  final ui.Image? frozen;

  /// 背板「实时 ↔ 冻结」淡变值（0=纯实时，1=纯冻结图）。
  final double fadeBlend;

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
      ..devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
  }
}

/// BiliPai 液态玻璃背板自绘渲染对象。
///
/// 布局：填满父级约束（Stack 的 Positioned.fill）。绘制：裁剪成圆角胶囊后，
/// 用 `BackdropFilterLayer` + `ImageFilter.shader` 对背景施加 BiliPai 波浪
/// 扭曲，再铺底色/饱和度。若设置了冻结图 [frozen]，则直接 blit 该图（零
/// 实时滤镜）。
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
///   槽 18   uDepthEffect     —— 径向深度效应（水滴类小圆面开启）
///   采样器0 uImage           —— 引擎绑定的实时背景
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
        _depthEffect = depthEffect,
        _frozen = frozen,
        _fadeBlend = fadeBlend,
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

  /// 持续涟漪时钟秒值（驱动 shader 槽 19 uTime）。仅存值不触发重绘——重绘
  /// 由宿主 _onRippleTick 按「实时背板」口径主动 markNeedsPaint，避免冻结
  /// 后仍每帧重绘。
  double uiTime = 0;

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

  final LayerHandle<BackdropFilterLayer> _blurHandle =
      LayerHandle<BackdropFilterLayer>();
  final LayerHandle<BackdropFilterLayer> _shaderHandle =
      LayerHandle<BackdropFilterLayer>();
  final LayerHandle<ClipPathLayer> _clipHandle = LayerHandle<ClipPathLayer>();

  /// 模糊 filter 缓存，按 sigma 失效，避免每帧重建。
  ui.ImageFilter? _cachedBlurFilter;
  double _cachedBlurSigma = -1;

  @override
  void performLayout() {
    size = constraints.biggest;
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    // 实时路径需要跟随滚动重绘（背板在动时每帧重新捕获背景）。
    globalScrollOffset.addListener(_onScrollChanged);
  }

  @override
  void detach() {
    globalScrollOffset.removeListener(_onScrollChanged);
    super.detach();
  }

  /// 滚动时标记重绘，仅实时（未冻结）时生效；冻结状态下背板静止、无需重绘。
  void _onScrollChanged() {
    if (_frozen == null) markNeedsPaint();
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

  /// 冻结路径：直接 blit 缓存的背板图（圆角外透明），零实时滤镜开销。
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

  /// 十字淡变路径：先画实时背板（blur+shader BackdropFilter），再把冻结图以
  /// [fade]（0~1）半透明叠上去。仅「实时 ↔ 冻结」切换的 140/420ms 窗口触发，
  /// 平时不走这里，避免实时滤镜长期驻留。
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

  /// 实时路径：两个兄弟 BackdropFilterLayer（blur 在下、shader 在上）铺满
  /// 玻璃圆角区域。可在 [overlay] 注入叠加绘制（十字淡变时叠冻结图）。
  void _paintLive(
    PaintingContext context,
    Offset offset, {
    BackingOverlayCallback? overlay,
  }) {
    if (!attached) return;
    final dpr = _devicePixelRatio;
    final screen = _screenSize;

    // 玻璃表面在屏幕空间的物理像素位置/尺寸：SDF 以玻璃局部坐标计算，才能
    // 让「贴近边」的透镜折射/边缘光精确贴合胶囊边缘（而非全屏边缘）。
    final globalPos = localToGlobal(Offset.zero);
    final glassOrigin = Offset(globalPos.dx * dpr, globalPos.dy * dpr);
    final glassSize = Size(size.width * dpr, size.height * dpr);

    // 分层（Halcyon/BiliPai FloatingBottomBar 同序）：blur 在下、lens 在上——
    // Compose 里 effects = [vibrancy, blur(4dp), lens(24dp,24dp)]，折射采样
    // 的是「已模糊」的背景，整块玻璃（含边带）全是模糊内容，没有裸露的
    // 折射锐利环；反序（shader 下、blur 上 + 内缩留裸边）会产生原始折射环
    // 贴着模糊内部的拼接缝（「折射对不上背景」的根因）。
    final bg = _backgroundColor;

    // Pass1 模糊 filter 按 sigma 缓存；shader filter 每帧重建（包内同做法）。
    // 注意：ImageFilter.blur 的 sigma 就是逻辑像素（画布坐标系），不能再乘
    // dpr——乘过会导致模糊强度虚高 ~3 倍（实测中心糊成一片）。
    final targetSigma = _blurSigma;
    if (_cachedBlurFilter == null || _cachedBlurSigma != targetSigma) {
      _cachedBlurFilter =
          ui.ImageFilter.blur(sigmaX: targetSigma, sigmaY: targetSigma);
      _cachedBlurSigma = targetSigma;
    }
    // 层对象每帧新建（句柄只保留最新一层供 dispose 清理）：复用同一
    // BackdropFilterLayer 时，Impeller 对 shader 背板快照按层实例缓存，
    // 玻璃平移（层位置变化、背后内容不变）时不会重新快照——拖动播放条
    // 「折射效果留在原地」的根因。新建层实例强制引擎每帧重新抓背板。
    final blurLayer = _blurHandle.layer = BackdropFilterLayer();
    blurLayer.filter = _cachedBlurFilter!;

    final clipPath = Path()
      ..addRRect(RRect.fromRectAndRadius(
        Offset.zero & size,
        Radius.circular(_radius),
      ));

    final a = bg.a;
    // 折射位移安全钳制：向内采样存在 ~A/2 的「跳过区」（深度小于该值的
    // 内容永远不被边带采样）。钳制下限按 BiliPai 自身比例取 0.375×短边
    // （64dp 底栏 → 24dp 位移；56dp 水滴 14dp 不受限）：再低的话位移会被
    // 4dp 模糊抹平——边带与内部糊成一片「纯模糊」，折射完全不可见。
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
      // 边带安全钳制：带厚不超过短边 42%，保证小表面（顶栏胶囊等）中心
      // 留出至少 16% 的不折射净区，避免「整个玻璃都在弯」（BiliPai 按
      // 高度等比缩放 refractionHeight，此处用尺寸钳制等效兜底）。
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
        // Pass1（下）：真高斯模糊背景（Halcyon blur(4dp)）。
        context.pushLayer(blurLayer, (context, offset) {}, offset);
        // Pass2（上）：折射 shader 采样上面的模糊结果做边缘透镜位移，
        // 并铺底色/饱和度/抖动——整块玻璃含边带全是模糊内容（BiliPai 同序）。
        context.pushLayer(shaderLayer, (context, offset) {}, offset);
        // 十字淡变：在实时背板之上叠冻结图。
        overlay?.call(context, offset);
      },
    );
  }

  @override
  void dispose() {
    // 提前清掉 layer 上的 filter 引用，避免 GPU 关闭时资源滞留（对齐包内做法）。
    _blurHandle.layer?.filter = ui.ImageFilter.blur(sigmaX: 0, sigmaY: 0);
    _shaderHandle.layer?.filter = ui.ImageFilter.blur(sigmaX: 0, sigmaY: 0);
    _blurHandle.layer = null;
    _shaderHandle.layer = null;
    _clipHandle.layer = null;
    _cachedBlurFilter = null;
    super.dispose();
  }
}