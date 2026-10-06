part of 'bilipai_glass.dart';

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
    // 登记状态随开关同步：缓存帧面进出登记表与 attach/detach 口径一致
    if (attached) {
      value ? registerChromeFace(this) : unregisterChromeFace(this);
    }
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
    // 仅缓存帧面登记：登记表供转场裁剪（_paintChromeFrame）查表与抓帧
    // 遍历登记原点，不画缓存帧的实例（播放条 alwaysLive 满血、播放页
    // 液态等）登记无意义，白耗每次抓帧的 localToGlobal——从离屏缓存
    // 体系摘出
    if (_useChromeFrame) {
      registerChromeFace(this);
    }
    globalScrollOffset.addListener(_onScrollChanged);
    globalScrollTick.addListener(_onScrollTick);
    globalIsTransitioning.addListener(_onTransitionBlurSync);
    _liveUseShader = !globalIsTransitioning.value;
  }

  @override
  void detach() {
    if (_useChromeFrame) {
      unregisterChromeFace(this);
    }
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
    // 玻璃条整段失去静态帧——静默才能让旧 layer 静态帧真正保留。
    // 换页滑动（PageView）同口径：retained 层由合成器持续采样 backdrop
    if (globalIsTransitioning.value || globalIsTabSwitching.value) return;
    if (_frozen == null) markNeedsPaint();
  }

  void _onScrollTick() {
    // 转场中保帧（同上）：滚动信号来自 IME 弹起等视口变化，
    // 炸图/重绘都会破坏静态帧
    // 换页滑动同口径静默：chrome 面的帧模式切换由 State 层首拍处理，
    // 这里不再逐帧 markNeedsPaint（每帧重建 blur+shader 两层 backdrop
    // 是换页卡顿主源）
    if (globalIsTransitioning.value || globalIsTabSwitching.value) return;
    // chrome 缓存帧保留：滚动中玻璃改画帧裁剪（帧由抓帧侧低频刷新），
    // 只有普通烘焙图才需要炸图切实时渲染
    if (_frozen != null && !_frozenIsChromeFrame) {
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

    // 转场窗口 blur 层静默：BackdropFilter 采样在合成期逐帧重执行，
    // 转场动画每帧 backdrop 变化 = 每帧全量 blur（设置页 3 个新液态
    // 实例的兜底 blur+chrome 条兜底不可用面，是「我的→设置」push 转
    // 场中段 raster 卡主源；毛玻璃链路有 blurBudget 转场降级而此处
    // 恒全量，同场景毛玻璃流畅液态掉帧即此差异）。动画中 blur+tint
    // 与半透明 tint 平涂不可分辨，降级为纯 tint；落定沿
    // _onTransitionBlurSync 重绘自动恢复。chromeFrame 实例已在 paint
    // 入口走缓存帧裁剪，不进此路径
    final skipBlur = !_liveUseShader;

    final forceFresh = _freshBackdrop || globalIsDragging.value;
    final targetSigma = _blurSigma;
    _cachedBlurFilter = forceFresh
        ? cheapBackdropBlurFresh(targetSigma)
        : (_cachedBlurFilter != null && _cachedBlurSigma == targetSigma
            ? _cachedBlurFilter!
            : cheapBackdropBlur(targetSigma));
    _cachedBlurSigma = targetSigma;
    final BackdropFilterLayer? blurLayer;
    if (skipBlur) {
      _blurHandle.layer = null;
      blurLayer = null;
    } else {
      final layer = _blurHandle.layer = BackdropFilterLayer();
      layer.filter = _cachedBlurFilter!;
      blurLayer = layer;
    }

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
        void paintFlatTint(PaintingContext context, Offset offset) {
          // 兜底面 tint：未验证实例全强度（shader 关闭，boot 不参与）；
          // 首烘渐显期以 (1-boot) 反向退场，与 shader 内 tint 接力使
          // 总 tint 恒定；已烘焙实例的非渐显态不画（与原行为一致）。
          // 转场静默窗口 blur 层已摘除，全强度 tint 平涂补位
          final flatTint = skipBlur
              ? 1.0
              : (_solidOnly ? 1.0 : (useShader ? 1.0 - boot : 0.0));
          if (flatTint > 0.001) {
            context.canvas.drawRect(
              offset & size,
              Paint()
                ..color = _backgroundColor
                    .withValues(alpha: _backgroundColor.a * flatTint),
            );
          }
        }

        if (blurLayer != null) {
          context.pushLayer(blurLayer, paintFlatTint, offset);
        } else {
          paintFlatTint(context, offset);
        }
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
