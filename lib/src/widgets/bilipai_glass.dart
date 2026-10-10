import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import '../core/application_logger.dart';
import 'blur_budget.dart';
import 'chrome_glass_frame.dart';
import 'glass_settings.dart';
import 'liquid_wave.dart';
part 'bilipai_glass.backing.dart';
part 'bilipai_glass.rim.dart';

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

  // 全局首烘串行链：转场结束沿会让转场中挂载的所有液态实例在同一
  // 时刻（160ms 去抖对齐）并发 toImage 读回型离屏渲染，raster 单帧
  // 内挤满读回任务 = push 落定后集中掉帧（我的→设置首屏多个液态实例；
  // 二级页首屏无实例故一直流畅）。改为全局一次只跑一个，实例间留
  // 一帧间隙让 raster 喘息
  static Future<void> _captureQueue = Future<void>.value();

  // 最近一次路由转场落定时刻（多实例共享写，用于首烘打点对齐掉帧时刻）
  static DateTime? _lastTransitionEnd;

  final GlobalKey _backingKey = GlobalKey();

  ui.Image? _frozen;

  // _frozen 是否为整屏 chrome 缓存帧（决定 frozen 绘制走裁剪还是整图）
  bool _frozenIsChromeFrame = false;

  // _frozen 为 chrome 缓存帧时该帧的抓取区域（null=整屏），与图像成对
  // 更新：滚动补帧只抓 chrome 面并集区域，裁剪源矩形须减区域原点
  Rect? _frozenRegion;

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
    if (widget.useChromeFrame) {
      chromeGlassFrame.addListener(_onChromeFrameChanged);
    }
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
    _lastTransitionEnd = DateTime.now();
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
        _frozenRegion = frame.region;
        _frozenIsChromeFrame = true;
        _fade.value = 1;
        _fade.reverse();
      } else {
        _frozenRegion = null;
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
    // 换页滑动（PageView 整段 320ms）：chrome 面只在首拍切入缓存帧裁剪
    // 模式（无 backdrop 采样），随后整段静默——滚动帧模式依赖的抓帧侧
    // 已被换页门控停掉，逐帧 setState/重建只剩纯开销；其余实例保留
    // retained 层由合成器继续采样，玻璃观感跟随滑动
    if (globalIsTabSwitching.value) {
      if (widget.useChromeFrame &&
          !_routeTransition &&
          (_frozen == null || !_frozenIsChromeFrame)) {
        final frame = chromeGlassFrame.value;
        if (frame != null) {
          final old = _frozen;
          _frozen = frame.image.clone();
          _frozenRegion = frame.region;
          _frozenIsChromeFrame = true;
          _fade.stop();
          _fade.value = 1;
          _onFadeTicked();
          setState(() {});
          if (old != null) {
            SchedulerBinding.instance
                .addPostFrameCallback((_) => old.dispose());
          }
        }
      }
      return;
    }
    // 转场中保图：IME 弹起等视口变化会在转场中产生滚动信号，此时炸图
    // 会让玻璃从烘焙图突变为兜底 blur+tint（跳变）；转场落定后由 resume 接管
    if (!_routeTransition) {
      if (_frozen != null && !_frozenIsChromeFrame) {
        final old = _frozen!;
        _frozen = null;
        _frozenIsChromeFrame = false;
        SchedulerBinding.instance.addPostFrameCallback((_) => old.dispose());
      } else if (widget.useChromeFrame) {
        // 滚动中改画 chrome 缓存帧裁剪（无 backdrop 采样）：帧由抓帧侧
        // 50ms 节流低频刷新，透底滞后与液态波动离散化在模糊下无感——
        // 玻璃效果全程在线，滚动中采样成本归零。fadeBlend 拉满=纯帧显示
        final frame = chromeGlassFrame.value;
        if (frame != null && _fade.value < 0.999) {
          final old = _frozen;
          _frozen = frame.image.clone();
          _frozenRegion = frame.region;
          _frozenIsChromeFrame = true;
          _fade.stop();
          _fade.value = 1;
          _onFadeTicked();
          if (old != null) {
            SchedulerBinding.instance
                .addPostFrameCallback((_) => old.dispose());
          }
        }
      }
    }
    // frozen == null 时也要重建：滚动信号切换兜底/实时渲染模式
    setState(() {});
  }

  // 滚动中帧模式跟随：抓帧侧低频刷新 chrome 帧后换新图重绘。
  // 只在滚动帧模式稳态（fadeBlend=1）跟随：交叉淡回中换帧会把叠加
  // 内容从旧帧突变为新帧——转场结束 adopt 淡回（420ms）与转场 false
  // 沿安排的 350ms 抓帧几乎必然重叠，帧里透底内容新旧页面不同，
  // 跳变即「切页闪」；fade=0 时帧不显示，换帧无意义
  void _onChromeFrameChanged() {
    if (!mounted || !widget.useChromeFrame) return;
    if (_frozen == null || !_frozenIsChromeFrame) return;
    if (globalIsTransitioning.value) return;
    if (_fade.value < 0.999) return;
    final frame = chromeGlassFrame.value;
    if (frame == null) return;
    final old = _frozen;
    _frozen = frame.image.clone();
    _frozenRegion = frame.region;
    setState(() {});
    if (old != null) {
      SchedulerBinding.instance.addPostFrameCallback((_) => old.dispose());
    }
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
    // 换页滑动中液态波动静默：波动 tick 每帧 markNeedsPaint 会让全部
    // 实例在换页动画期间逐帧重建 shader 层，与转场同口径冻结（落定后
    // 由 idle 信号恢复波动）
    if (globalIsTabSwitching.value) return;
    // 路由转场中波动静默：转场中新挂载的实例（如设置页悬浮态首屏的
    // 返回钮/标题/搜索条液态胶囊）initState 即 ripple.repeat，此前每帧
    // markNeedsPaint 击穿「转场静态帧」机制——RepaintBoundary 被强推
    // 重绘，兜底 blur backdrop 逐帧重采样（我的→设置 push 卡顿残留源；
    // 二级页首屏无液态实例故一直正常）。老实例转场沿已 _ripple.stop()
    // 不受影响；落定沿 _onTransitionChanged 按 !_idle 恢复波动相位
    if (globalIsTransitioning.value) return;
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
    } catch (e) {
      AppLog.debug('ui', '加载液态玻璃着色器失败: $e');
    }
  }

  @override
  void dispose() {
    globalIsScrolling.removeListener(_onGlobalState);
    globalIsTransitioning.removeListener(_onTransitionChanged);
    globalIsDragging.removeListener(_onGlobalState);
    globalScrollTick.removeListener(_onOwnerScrollTick);
    chromeGlassFrame.removeListener(_onChromeFrameChanged);
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
      // 滚动/拖拽结束：帧模式交叉淡回实时渲染，液态观感无缝续展。
      // frozen 保留（fadeBlend=0 时不显示），下次滚动直接复用
      if (_frozenIsChromeFrame && _fade.value > 0.001) {
        _fade.reverse();
      }
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

  // 首烘入全局串行链：多个实例同刻到达时按入队顺序逐个执行，
  // 实例间 16ms 间隙错开 toImage 读回（见 _captureQueue 注释）
  Future<void> _capture() {
    final task = _captureQueue.then((_) async {
      await _runCapture();
      // 实例间错峰间隙：留一帧时长给 raster 线程，避免连续读回
      await Future<void>.delayed(const Duration(milliseconds: 16));
    });
    // 吞错保持队列活跃：单个实例 capture 异常不能让后续实例饿死
    _captureQueue = task.catchError((_) {});
    return task;
  }

  Future<void> _runCapture() async {
    // chrome 缓存帧挂着不挡烘焙：帧模式玻璃画帧（烘焙产物本就不上屏，
    // 仅作为 backdrop 已验证就绪标志+启用液态 shader 的前提），挡门会
    // 让滚动后新实例的首烘永远推迟
    if (_capturing ||
        !mounted ||
        (_frozen != null && !_frozenIsChromeFrame) ||
        _hasCaptured) {
      return;
    }
    // 换页滑动中不做首烘：上一次 idle 安排的去抖可能落在动画中途，
    // toImage 读回型离屏渲染会加重换页掉帧；落定后 idle 归位沿会重排
    if (globalIsTabSwitching.value) return;
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
    // debugNeedsPaint 是 debug-only API（release 下一读即抛
    // LateInitializationError），必须用 kDebugMode 短路。
    if (kDebugMode && ro.debugNeedsPaint) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && (_frozen == null || _frozenIsChromeFrame)) _capture();
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
          globalIsTransitioning.value ||
          globalIsTabSwitching.value) {
        image.dispose();
        return;
      }
      _captureRetry?.cancel();
      // 首烘渐显：boot 归零后 320ms 内液态参数从兜底观感平滑浮现
      // （见 _paintLive 内 boot 缩放），替代烘焙完成即突变的硬切
      _boot.value = 0;
      setState(() {
        _hasCaptured = true;
        // 滚动中 chrome 帧模式（fadeBlend=1）保持画帧，不拽回实时渲染；
        // 其余情况归零回实时渲染（首烘后 blur+tint 兜底让位实时路径）
        if (!_frozenIsChromeFrame || _fade.value < 0.001) {
          _fade.value = 0;
        }
        _onFadeTicked();
      });
      _boot.forward();
      // 首烘执行时刻打点：与 perf 窗口的 jank 帧时刻对齐，验证串行
      // 错峰后读回不再与掉帧帧重叠
      final sinceTransition = _lastTransitionEnd;
      AppLog.debug(
        'perf',
        sinceTransition == null
            ? 'capture inst=${identityHashCode(this).toRadixString(16)}'
            : 'capture inst=${identityHashCode(this).toRadixString(16)} '
                '@+${DateTime.now().difference(sinceTransition).inMilliseconds}ms',
      );
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
              frozenChromeRegion: _frozenRegion,
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
