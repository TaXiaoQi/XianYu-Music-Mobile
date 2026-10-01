import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import 'blur_budget.dart';
import 'chrome_glass_frame.dart';
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
    this.useChromeFrame = false,
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

  // chrome 缓存帧开关：转场降级窗口（shader 采样失效）改为画整屏缓存帧中
  // 自己区域的裁剪（无采样），落定后交叉淡回实时渲染——液态观感全程连续。
  // 仅 shell 常驻 chrome 条开启（底栏/悬浮顶栏/悬浮搜索条）；
  // 页内玻璃不开启（其转场观感由路由快照保护）
  final bool useChromeFrame;

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

  // _frozen 是否为整屏 chrome 缓存帧（决定 frozen 绘制走裁剪还是整图）
  bool _frozenIsChromeFrame = false;

  bool _idle = false;

  bool _routeTransition = false;

  bool _capturing = false;

  // 是否成功烘焙过至少一次：区分「新实例等待首烘」（毛玻璃 blur+tint
  // 兜底，禁 shader）与「滚动中临时炸图」（实时渲染，backdrop 已就绪不会黑）
  bool _hasCaptured = false;
  Timer? _idleDebounce;
  // 首烘重试用独立 Timer：滚动信号翻转 busy 会 cancel _idleDebounce，
  // 若共用会让打字/滑动等高频滚动场景的首烘永远被推迟
  Timer? _captureRetry;

  // adopt 交叉淡回兜底 Timer：异常路径下 fadeBlend 卡住时强制归零
  Timer? _adoptGuard;

  DateTime _captureCooldownUntil = DateTime.fromMillisecondsSinceEpoch(0);

  late final AnimationController _fade;

  // 首烘渐显：兜底 blur+tint → 液态 shader 的交叉过渡。烘焙完成时 boot
  // 从 0 升到 1，液态参数（折射/高光/边缘/tint）随之浮现，替代「下一帧
  // 突变」的硬切；不用 opacity 包 shader（saveLayer 内采样会黑底）
  late final AnimationController _boot;

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
    _boot = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
      value: 1,
    );
    _boot.addListener(_onBootTicked);
    _ripple = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
      value: 3.0,
    )..repeat();
    _ripple.addListener(_onRippleTick);
    globalIsScrolling.addListener(_onGlobalState);
    globalIsTransitioning.addListener(_onTransitionChanged);
    globalIsDragging.addListener(_onGlobalState);
    globalScrollTick.addListener(_onOwnerScrollTick);
    _routeTransition = globalIsTransitioning.value;
  }

  void _onTransitionChanged() {
    if (!mounted) return;
    if (_routeTransition == globalIsTransitioning.value) return;
    if (globalIsTransitioning.value) {
      // 转场开始：静默记录，不 setState、不改渲染参数——RepaintBoundary
      // 不重绘，合成器继续使用转场前最后一次正常渲染的 layer（静态帧）。
      // 屏上玻璃观感连续且无采样；任何 toImage 产物一律不参与展示
      _routeTransition = true;
      _ripple.stop();
      _captureRetry?.cancel();
      return;
    }
    _idleDebounce?.cancel();
    // 冷却只需覆盖「转场动画刚结束 backdrop 层短暂重建」的窗口；
    // 700ms 会让转场中挂载的新实例兜底拖太久
    _captureCooldownUntil =
        DateTime.now().add(const Duration(milliseconds: 350));
    // _onGlobalState 不监听 transitioning 翻转：转场结束时若
    // scrolling/dragging 已归位，手动把 _idle 同步回 true，
    // 否则首烘会被 stale 检查（!_idle）永久拒绝
    if (!globalIsScrolling.value && !globalIsDragging.value) {
      _idle = true;
    }
    if (widget.alwaysLive || !_idle) {
      if (!_ripple.isAnimating) _ripple.repeat();
    } else {
      _ripple.stop();
    }
    setState(() {
      _routeTransition = false;
      // 烘焙图（toImage 离屏采样产物）不可展示：转场结束直接丢图，
      // 恢复实时渲染——此时 backdrop 已就绪，静态帧切 live 观感连续。
      // chrome 缓存帧例外：它是屏上合成产物（非离屏采样），可以展示——
      // 落定后继续画缓存帧，交叉淡回实时渲染，液态观感无缝续展
      final old = _frozen;
      _frozen = null;
      final frame = widget.useChromeFrame ? chromeGlassFrame.value : null;
      if (frame != null) {
        _frozen = frame.image.clone();
        _frozenIsChromeFrame = true;
        _fade.value = 1;
        _fade.reverse();
      } else {
        _frozenIsChromeFrame = false;
        _fade.value = 0;
      }
      if (old != null) {
        SchedulerBinding.instance
            .addPostFrameCallback((_) => old.dispose());
      }
    });
    // adopt 交叉淡回兜底：420ms 后 fade 必须归零回实时渲染。异常路径
    // （监听时序、控制器被抢占）会让 fadeBlend 卡在中间值，缓存帧裁剪
    // 带着旧内容永久叠在实时渲染上（顶/底栏旧页文字残影），且静止抓帧
    // 会把残影烙进新帧自我延续——定时强制归零斩断该循环
    _adoptGuard?.cancel();
    _adoptGuard = Timer(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      if (_fade.value > 0) {
        _fade.stop();
        _fade.value = 0;
      }
    });
    // 转场中挂载的新实例（hasCaptured=false，一直在 blur+tint 兜底）：
    // 必须在这里主动安排首烘，否则 _idle 翻转后没有任何机制唤醒它，
    // 要等用户下一次滚动才有机会——兜底会一直挂死不启用液态 shader
    if (!widget.alwaysLive && !_hasCaptured) {
      _scheduleCapture();
    }
  }

  void _onOwnerScrollTick() {
    if (!mounted) return;
    // 转场中保图：IME 弹起等视口变化会在转场中产生滚动信号，此时炸图
    // 会让玻璃从烘焙图突变为兜底 blur+tint（跳变）；转场落定后由 resume 接管
    if (_frozen != null && !_routeTransition) {
      final old = _frozen!;
      _frozen = null;
      _frozenIsChromeFrame = false;
      SchedulerBinding.instance.addPostFrameCallback((_) => old.dispose());
    }
    // frozen == null 时也要重建：滚动信号切换兜底/实时渲染模式
    setState(() {});
  }

  void _onFadeTicked() {
    if (!mounted) return;
    final ro = _backingKey.currentContext?.findRenderObject();
    if (ro is RenderLiquidBacking) ro.fadeBlend = _fade.value;
  }

  void _onBootTicked() {
    if (!mounted) return;
    final ro = _backingKey.currentContext?.findRenderObject();
    if (ro is RenderLiquidBacking) ro.bootBlend = _boot.value;
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
    globalIsTransitioning.removeListener(_onTransitionChanged);
    globalIsDragging.removeListener(_onGlobalState);
    globalScrollTick.removeListener(_onOwnerScrollTick);
    _idleDebounce?.cancel();
    _captureRetry?.cancel();
    _adoptGuard?.cancel();
    _fade.dispose();
    _boot.dispose();
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
      if (!_hasCaptured) _scheduleCapture();
    } else {
      _idleDebounce?.cancel();
      // 转场中不重启波动，落定时由 _onTransitionChanged 恢复相位
      if (!_routeTransition && !_ripple.isAnimating) _ripple.repeat();
    }
  }

  void _scheduleCapture() {
    _idleDebounce?.cancel();
    _idleDebounce = Timer(const Duration(milliseconds: 160), () {
      if (mounted) _capture();
    });
  }

  Future<void> _capture() async {
    if (_capturing || !mounted || _frozen != null || _hasCaptured) return;
    if (DateTime.now().isBefore(_captureCooldownUntil)) {
      // 冷却结束后自动重试首烘（独立 Timer，不受滚动信号 cancel 影响）；
      // 否则首烘被冷却吞掉后要等下一次滚动/轮播事件才有机会
      _captureRetry?.cancel();
      _captureRetry = Timer(
        _captureCooldownUntil.difference(DateTime.now()) +
            const Duration(milliseconds: 16),
        () {
          if (mounted) _capture();
        },
      );
      return;
    }
    final ro = _backingKey.currentContext?.findRenderObject();
    if (ro is! RenderRepaintBoundary) {
      return;
    }
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
          globalIsTransitioning.value) {
        image.dispose();
        return;
      }
      _captureRetry?.cancel();
      // 首烘渐显：boot 归零后 320ms 内液态参数从兜底观感平滑浮现
      // （见 _paintLive 内 boot 缩放），替代烘焙完成即突变的硬切
      _boot.value = 0;
      setState(() {
        _hasCaptured = true;
        _fade.value = 0;
        _onFadeTicked();
      });
      _boot.forward();
      // toImage 离屏渲染中 shader 的 backdrop 采样无内容（产物恒黑），
      // 图不保存不展示——capture 仅作为「backdrop 已验证就绪」的一次性
      // 标志，图立即释放（从未上屏，无 scene 引用）
      image.dispose();
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

    // 静态帧方案：转场中靠「不重绘」保留转场前的正常玻璃 layer（见
    // _onTransitionChanged）；从未验证过 backdrop 的新实例先用毛玻璃
    // blur+tint 渲染（见 paint/_paintLive，禁 shader），烘焙后切液态；
    // 已验证实例其余时刻一律实时渲染（静止/滚动/落定 backdrop 均就绪）
    final solidOnly = !widget.alwaysLive && !_hasCaptured;

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
              bootBlend: _boot.value,
              freshBackdrop: widget.freshBackdrop,
              solidOnly: solidOnly,
              useChromeFrame: widget.useChromeFrame,
              frozenIsChromeFrame: _frozenIsChromeFrame,
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
    this.bootBlend = 1.0,
    this.freshBackdrop = false,
    this.solidOnly = false,
    this.useChromeFrame = false,
    this.frozenIsChromeFrame = false,
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

  /// 首烘渐显：0=兜底观感（液态参数归零），1=完整液态
  final double bootBlend;

  final bool freshBackdrop;

  final bool solidOnly;

  final bool useChromeFrame;

  final bool frozenIsChromeFrame;

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
      bootBlend: bootBlend,
      freshBackdrop: freshBackdrop,
      solidOnly: solidOnly,
      useChromeFrame: useChromeFrame,
      frozenIsChromeFrame: frozenIsChromeFrame,
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
    ..bootBlend = bootBlend
    ..freshBackdrop = freshBackdrop
    ..solidOnly = solidOnly
    ..useChromeFrame = useChromeFrame
    ..frozenIsChromeFrame = frozenIsChromeFrame
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
    double bootBlend = 1.0,
    required bool freshBackdrop,
    required bool solidOnly,
    required bool useChromeFrame,
    required bool frozenIsChromeFrame,
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
       _bootBlend = bootBlend,
       _freshBackdrop = freshBackdrop,
       _solidOnly = solidOnly,
       _useChromeFrame = useChromeFrame,
       _frozenIsChromeFrame = frozenIsChromeFrame,
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

  // 首烘渐显：0=兜底观感（液态参数归零），1=完整液态
  double _bootBlend = 1.0;
  double get bootBlend => _bootBlend;
  set bootBlend(double value) {
    final v = value.clamp(0.0, 1.0).toDouble();
    if (_bootBlend == v) return;
    _bootBlend = v;
    markNeedsPaint();
  }

  bool _freshBackdrop;
  bool get freshBackdrop => _freshBackdrop;
  set freshBackdrop(bool value) {
    if (_freshBackdrop == value) return;
    _freshBackdrop = value;
    markNeedsPaint();
  }

  bool _solidOnly = false;
  bool get solidOnly => _solidOnly;
  set solidOnly(bool value) {
    if (_solidOnly == value) return;
    _solidOnly = value;
    markNeedsPaint();
  }

  bool _useChromeFrame = false;
  bool get useChromeFrame => _useChromeFrame;
  set useChromeFrame(bool value) {
    if (_useChromeFrame == value) return;
    _useChromeFrame = value;
    markNeedsPaint();
  }

  bool _frozenIsChromeFrame = false;
  bool get frozenIsChromeFrame => _frozenIsChromeFrame;
  set frozenIsChromeFrame(bool value) {
    if (_frozenIsChromeFrame == value) return;
    _frozenIsChromeFrame = value;
    markNeedsPaint();
  }

  // chrome 缓存帧当前是否可用作本面的裁剪源：
  // 存在、抓帧 dpr 与当前一致、抓帧逻辑尺寸与当前屏一致（旋转/分屏后失效）
  bool _chromeFrameUsable() {
    final frame = chromeGlassFrame.value;
    if (frame == null) return false;
    if ((frame.dpr - _devicePixelRatio).abs() > 0.01) return false;
    final screen = _screenSize;
    if ((frame.logicalSize.width - screen.width).abs() > 0.5 ||
        (frame.logicalSize.height - screen.height).abs() > 0.5) {
      return false;
    }
    return true;
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
    registerChromeFace(this);
    globalScrollOffset.addListener(_onScrollChanged);
    globalScrollTick.addListener(_onScrollTick);
    globalIsTransitioning.addListener(_onTransitionBlurSync);
    _liveUseShader = !globalIsTransitioning.value;
  }

  @override
  void detach() {
    unregisterChromeFace(this);
    globalScrollOffset.removeListener(_onScrollChanged);
    globalScrollTick.removeListener(_onScrollTick);
    globalIsTransitioning.removeListener(_onTransitionBlurSync);
    super.detach();
  }

  // 转场中 shader 降级开关（由 _onTransitionBlurSync 维护）
  bool _liveUseShader = true;

  void _onTransitionBlurSync() {
    // 转场边沿必须各重绘一次：即使 Dart 侧不重绘，retained 的旧图层树
    // 每帧仍会在合成期重新采样 backdrop——转场动画中 ImageFilter.shader
    // 的 backdrop 采样在部分设备/Impeller 上失效（毛玻璃普通 blur 同场景
    // 正常，液态玻璃整段色块且因静态帧"不更新"）。上升沿换纯 blur 层
    // （=毛玻璃路径，已验证可用），下降沿恢复 shader
    _liveUseShader = !globalIsTransitioning.value;
    markNeedsPaint();
  }

  void _onScrollChanged() {
    // 转场中完全静默：滚动信号（含转场动画/IME 视口变化驱动）持续到来
    // 时若每帧 markNeedsPaint，静态帧被反复重绘、兜底 blur+tint 每帧生效，
    // 玻璃条整段失去静态帧——静默才能让旧 layer 静态帧真正保留
    if (globalIsTransitioning.value) return;
    if (_frozen == null) markNeedsPaint();
  }

  void _onScrollTick() {
    // 转场中保帧（同上）：滚动信号来自 IME 弹起等视口变化，
    // 炸图/重绘都会破坏静态帧
    if (globalIsTransitioning.value) return;
    if (_frozen != null) {
      _frozen = null;
      _fadeBlend = 0;
    }
    markNeedsPaint();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (size.isEmpty) return;
    final frozen = _frozen;
    final fade = _fadeBlend;
    // 转场降级窗口（_liveUseShader=false）：shader 采样失效，但 chrome
    // 缓存帧是上次正常合成的液态输出——直接画自己区域的裁剪即可复现
    // 上次观感，无任何采样。优先级最高（覆盖兜底/交叉淡入分支）
    if (_useChromeFrame && !_liveUseShader && _chromeFrameUsable()) {
      _paintChromeFrame(context, offset, chromeGlassFrame.value!.image);
      return;
    }
    if (frozen != null && fade > 0.001) {
      if (fade >= 0.999) {
        _paintFrozen(context, offset, frozen);
      } else {
        _paintCrossfade(context, offset, frozen, fade);
      }
    } else {
      // 所有实例（含未验证新实例）实时渲染，与毛玻璃行为对齐：毛玻璃
      // 全程无守卫、实时采样 backdrop，转场从不出问题——因为快照层
      // 的 live 子树恒定完整渲染，backdrop 任何时刻都有内容可采。此前的
      // transitionSolid（transitioning && !snapshotReady）会把整个转场打成
      // 纯色块：globalSnapshotReady 只在「img 上屏且 moving」的 build 里置
      // true，而 capture 普遍晚于动画结束（debug 首帧阻塞下必然如此），
      // pop 又从 dismissed 起步 moving 恒 false——ready 转场中恒 false，
      // 任何一次被迫重绘都会把静态帧换成色块并因静默一直挂到转场结束。
      // 未验证新实例不再画不透明实底（色块阶段可见），而是走同一条
      // live 路径的纯 blur+tint 兜底，shader 由 _paintLive 内部禁用
      _paintLive(context, offset);
    }
  }

  // 画整屏缓存帧中本面区域的裁剪：源矩形按静止布局位置×抓帧 dpr 映射，
  // 裁剪到圆角矩形（缓存帧里圆角外是旧页面像素，不能带出来）。
  // 纯 drawImageRect，无 backdrop 层无采样。alpha 供落定交叉淡回叠加用
  void _paintChromeFrame(
    PaintingContext context,
    Offset offset,
    ui.Image image, {
    double alpha = 1.0,
  }) {
    final dpr = _devicePixelRatio;
    // 采样原点取抓帧时登记的静止布局位置（chromeFaceStaticOrigin）：
    // 转场中 localToGlobal 会被底栏 hidden 动画（AnimatedScale 0.92⇄1.0）
    // 的祖先变换污染，源矩形算偏后裁剪内容与实时渲染错位成双影
    final globalPos =
        chromeFaceStaticOrigin(this) ?? localToGlobal(Offset.zero);
    final src = Rect.fromLTWH(
      globalPos.dx * dpr,
      globalPos.dy * dpr,
      size.width * dpr,
      size.height * dpr,
    );
    final imgRect = Rect.fromLTWH(
      0,
      0,
      image.width.toDouble(),
      image.height.toDouble(),
    );
    final clipped = src.intersect(imgRect);
    if (clipped.isEmpty) return;
    final canvas = context.canvas;
    canvas.save();
    canvas.clipRRect(
      RRect.fromRectAndRadius(offset & size, Radius.circular(_radius)),
    );
    canvas.drawImageRect(
      image,
      clipped,
      Rect.fromLTWH(
        offset.dx + (clipped.left - src.left) / dpr,
        offset.dy + (clipped.top - src.top) / dpr,
        clipped.width / dpr,
        clipped.height / dpr,
      ),
      Paint()
        ..filterQuality = FilterQuality.medium
        ..color = Colors.white.withValues(alpha: alpha),
    );
    canvas.restore();
  }

  void _paintFrozen(
    PaintingContext context,
    Offset offset,
    ui.Image image,
  ) {
    // chrome 缓存帧是整屏图：画本面区域裁剪，整图缩进玻璃矩形会串页
    if (_frozenIsChromeFrame) {
      _paintChromeFrame(context, offset, image);
      return;
    }
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
      // chrome 缓存帧是整屏图：叠加必须裁剪到本面区域——原实现把整图
      // 无裁剪画在玻璃原点上，上一页整屏叠在当前页上
      if (_frozenIsChromeFrame) {
        _paintChromeFrame(context, offset, image, alpha: fade);
        return;
      }
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
    // 转场中降级为纯 blur（毛玻璃路径）：转场动画里 ImageFilter.shader
    // 的 backdrop 采样在部分设备/Impeller 上失效——毛玻璃同场景正常、
    // 液态玻璃整段色块。合成期会拿 retained 的旧 shader 层持续产出坏帧，
    // 所以必须由 _onTransitionBlurSync 在边沿重绘换层。
    // 未验证实例（_solidOnly）一律禁 shader：backdrop 未经烘焙确认，
    // 裸采样有闪黑风险；纯 blur（毛玻璃路径）无此风险——不透明实底
    // 兜底由此替换为 blur+tint 兜底，首烘完成后才启用液态 shader
    final useShader = _liveUseShader && !_solidOnly;
    // 首烘渐显：boot=0 时液态参数归零、观感与兜底 blur+tint 一致，
    // 1.0 为完整液态；平面 tint 以 (1-boot) 反向退场与 shader 内 tint
    // 接力（总 tint 恒定），折射/高光/边缘平滑浮现——替代烘焙完成的
    // 下一帧突变。不可用 opacity 包 shader：saveLayer 内采样黑底
    final boot = _bootBlend;
    final BackdropFilterLayer? shaderLayer;
    if (useShader) {
      _shader
        ..setFloat(0, screen.width * dpr)
        ..setFloat(1, screen.height * dpr)
        ..setFloat(2, globalScrollOffset.value)
        ..setFloat(3, refractPx * boot)
        ..setFloat(4, _chroma)
        ..setFloat(5, 0.0)
        ..setFloat(6, bg.r * a * boot)
        ..setFloat(7, bg.g * a * boot)
        ..setFloat(8, bg.b * a * boot)
        ..setFloat(9, a * boot)
        ..setFloat(10, _specular * boot)
        ..setFloat(11, _radius * dpr)
        ..setFloat(12, glassOrigin.dx)
        ..setFloat(13, glassOrigin.dy)
        ..setFloat(14, glassSize.width)
        ..setFloat(15, glassSize.height)
        ..setFloat(
          16,
          math.min(_edgeAmount, math.min(size.width, size.height) * 0.42) *
              dpr *
              boot,
        )
        ..setFloat(17, 1.0 + (_saturation - 1.0) * boot)
        ..setFloat(18, _depthEffect * boot)
        ..setFloat(19, uiTime);
      shaderLayer = _shaderHandle.layer = BackdropFilterLayer();
      shaderLayer.filter = ui.ImageFilter.shader(_shader);
    } else {
      _shaderHandle.layer = null;
      shaderLayer = null;
    }

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
        context.pushLayer(blurLayer, (context, offset) {
          // 兜底面 tint：未验证实例全强度（shader 关闭，boot 不参与）；
          // 首烘渐显期以 (1-boot) 反向退场，与 shader 内 tint 接力使
          // 总 tint 恒定；已烘焙实例的非渐显态不画（与原行为一致）
          final flatTint =
              _solidOnly ? 1.0 : (useShader ? 1.0 - boot : 0.0);
          if (flatTint > 0.001) {
            context.canvas.drawRect(
              offset & size,
              Paint()
                ..color = _backgroundColor
                    .withValues(alpha: _backgroundColor.a * flatTint),
            );
          }
        }, offset);
        if (shaderLayer != null) {
          context.pushLayer(shaderLayer, (context, offset) {}, offset);
        }
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