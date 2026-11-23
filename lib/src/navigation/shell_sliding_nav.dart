part of 'shell.dart';


/// 顶层水滴快照：_SlidingNavBottom 每帧写入，NavDropletOverlay 消费渲染

class NavDropletSnapshot {
  const NavDropletSnapshot({
    required this.rect,
    required this.shear,
    required this.liquid,
    required this.radius,
    required this.refract,
    required this.band,
    required this.chroma,
    required this.depth,
    required this.press,
    required this.isDark,
    required this.barTop,
    required this.barHeight,
  });

  /// 水滴屏幕坐标矩形（帧末实测，含底栏显隐动画变换）
  final Rect rect;

  /// 拖拽水平剪切（果冻拉伸的斜切分量）
  final double shear;

  /// true=液态水滴（按住/滑动中），false=静息浅色胶囊
  final bool liquid;
  final double radius;
  final double refract;
  final double band;
  final double chroma;

  /// 凸透镜深度（∝mf，长按渐强；驱动 shader 全表面放大+边带径向）
  final double depth;
  final double press;
  final bool isDark;

  /// 底栏玻璃面顶缘的全局逻辑 Y（_barKey RenderBox 实测）。顶层水滴的
  /// 反圆孔裁剪（_DropletHoleClipper）按此取「栏顶以下」条带：真实图标
  /// 只在栏内让位折射图标，越过栏顶的 badge 不裁
  final double barTop;

  /// 底栏玻璃面的视觉高度（含显隐动画/FittedBox 变换，逻辑口径）。
  /// 色散外溢带 = 水滴半径 − 栏轨半高（BiliPai
  /// resolveFloatingDockChromaticGapBand 同构：彩虹只在水滴超出栏缘的
  /// 月牙带）
  final double barHeight;
}


final ValueNotifier<NavDropletSnapshot?> navDropletSnapshot = ValueNotifier(
  null,
);

/// 水滴换页弹簧按飞行距离自适应（见 _flightSpringFor）；stiffness 统一
/// 460（ζ≈0.5-0.78 对应 damping 21.5-33.4）
const double kNavDropletStiffness = 460;

/// 距离自适应阻尼：把过冲钉成固定 ~0.06 页签（≈9px）的绝对距离，
/// 而非随飞行距离等比放大的百分比——欠阻尼弹簧过冲百分比只跟 ζ 有
/// 关，2 页签（首页↔插件 ~280px）7.5% 是 21px、1 页签只有 ~10px，
/// 长飞「冲过头」观感远猛于短飞（用户实测）。按距离反解 ζ：
/// f=exp(-πζ/√(1-ζ²)) → ζ=ln(1/f)/√(π²+ln²(1/f))；钳在 [0.5, 0.78]
/// ——0.5 保短程仍有明显回弹，0.78 保证长程不变成纯平移
SpringDescription _flightSpringFor(double dist) {
  final f = (0.06 / dist.abs()).clamp(0.026, 0.7);
  final lnf = -math.log(f);
  final zeta = (lnf / math.sqrt(math.pi * math.pi + lnf * lnf)).clamp(
    0.5,
    0.78,
  );
  return SpringDescription(
    mass: 1,
    stiffness: kNavDropletStiffness,
    damping: 2 * zeta * math.sqrt(kNavDropletStiffness),
  );
}

/// 落定判定容差（用于 SpringSimulation.tolerance）：默认 0.001 页签
/// ≈0.2px 太苛刻，欠阻尼弹簧的亚像素尾摆会拖住 completed 2-3 帧，
/// 回弹明明已结束水滴还停在大尺寸等才缩——肉眼不可见的 2px/12px/s
/// 即视为落定
const Tolerance kNavDropletTolerance = Tolerance(
  distance: 0.01,
  velocity: 0.06,
);

/// 顶层水滴 overlay 宿主：挂在 app.dart builder Stack 中 mini 播放条之上。
/// 底栏指示水滴独立于底栏树渲染——长按放大可鼓出栏缘、覆盖并折射上方
/// 内容（对齐 B 站参考效果），不再被顶层播放条盖住上缘。

class NavDropletOverlay extends ConsumerStatefulWidget {
  const NavDropletOverlay({super.key});

  @override
  ConsumerState<NavDropletOverlay> createState() => _NavDropletOverlayState();
}

class _NavDropletOverlayState extends ConsumerState<NavDropletOverlay> {
  @override
  void initState() {
    super.initState();
    navDropletSnapshot.addListener(_onSnapshot);
    // 栏内容捕获纹理到货（液态起始帧 postFrame，约滞后 1-2 帧）：重建
    // 把纹理传给水滴透镜，圆内开始合成锐利折射图标
    navDropletTabTexture.addListener(_onSnapshot);
    // 页面原始内容捕获纹理到货（按压起始帧）：重建把纹理传给透镜，
    // 按压态启用原始内容折射（uPageOn=1）
    navDropletPageTexture.addListener(_onSnapshot);
  }

  @override
  void dispose() {
    navDropletSnapshot.removeListener(_onSnapshot);
    navDropletTabTexture.removeListener(_onSnapshot);
    navDropletPageTexture.removeListener(_onSnapshot);
    super.dispose();
  }

  void _onSnapshot() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final s = navDropletSnapshot.value;
    // 底栏 hidden = navBarHidden 计数 >0 || 非 root 路径（设置等页面走
    // 后者且会 postFrame 重写快照，仅靠清快照拦不住残影），overlay 显隐
    // 条件必须与 _ShellScaffold 的 hidden 完全一致
    final chromeHidden =
        ref.watch(navBarHiddenProvider) > 0 ||
        !ref.watch(navOnRootPathProvider);
    return Positioned.fill(
      child: IgnorePointer(
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          // 液态 shader 0.01 保温防重显黑闪；毛玻璃归零停绘防淡入闪白
          opacity: chromeHidden ? glassHiddenOpacityFloor(ref) : 1.0,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // chromeHidden 时不渲染快照：快照是逐帧写入的「活性数据」，
              // 底栏隐藏后不再更新，残留旧几何会被全亮画成灰圆残影
              //（Impeller 下 0.01 兜底绘制也会以异常 alpha 泄漏）
              if (!chromeHidden && s != null)
                Positioned.fromRect(
                  rect: s.rect,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      // 暗晕已删除（用户否决「外面一圈东西」）：黑模糊环在
                      // 彩色内容上读成脏晕，BiliPai 水滴外圈就是干净的，
                      // 立体感由 rim/反光弧承担，不靠外阴影
                      Transform(
                        alignment: Alignment.center,
                        transform: Matrix4.identity()..setEntry(0, 1, s.shear),
                        child: ClipRRect(
                                // 胶囊水滴（BiliPai LiquidIndicator 同构）：
                                // 圆角 = rect 高/2 成 stadium，契合底栏
                                borderRadius: BorderRadius.circular(
                                  s.rect.height / 2,
                                ),
                                clipBehavior: Clip.antiAlias,
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    // 整圆水滴透镜（对齐 BiliPai LiquidIndicator
                                    // 单一渲染者架构）：overlay 位于 mini 播放条
                                    // 之上，其 backdrop = 页面 + 底栏完整渲染
                                    // 结果（combinedBackdrop 的 Flutter 等价物
                                    // ——底栏此时不再开透镜，见
                                    // shell_bottom_bar._liquidGlass）。shader
                                    // 走水滴分支：blur 后的合成面 + tint
                                    // = B 站「白色玻璃面」，捕获纹理合成锐利
                                    // 放大图标，边带折射 + 7 谱色散全量生效。
                                    // tint 动态反色（BiliPai 空闲水滴面
                                    // Shadow/Highlight 同构）：按水滴圆心处
                                    // 实时折射内容亮度选黑/白 10%——纯色
                                    // 白底上白 tint 水滴完全隐形（用户截图
                                    // 否决），壁纸/暗色页面同理自适应。
                                    // backgroundColor 仅作 shader 不可用
                                    // 时的纯 blur 兜底 tint；壳路径折射/
                                    // 放大全关（edgeAmount/depthEffect/chroma
                                    // 归零），避免与水滴分支双重作用
                                    LiveLiquidSurface(
                                      radius: s.radius,
                                      refract: 0,
                                      chroma: 0,
                                      // 水滴预模糊 0（BiliPai 透镜清晰
                                      // 同构）：镜面采样原始合成结果，
                                      // 此前 2.5σ 经按压放大 1.39× 变
                                      // ≈3.5σ 显糊（用户截图「怎么这么
                                      // 糊」）。玻璃感由 tint/阴影承担
                                      blurSigma: 0,
                                      backgroundColor: bilipaiGlassTint(
                                        s.isDark,
                                        LiquidGlassQuality.medium,
                                      ),
                                      tintInvert: true,
                                      // 栏顶/栏底 y（槽 36/42）：独立透镜
                                      // 「完整区域画面」归属判据——压缩
                                      // 采样坐标落在栏上下缘之间读栏面
                                      //（缩小的底栏），缘外读缩栏露出的
                                      // 上下原始内容（BiliPai
                                      // combinedBackdrop 等效观感）
                                      barTop: s.barTop,
                                      barBottom: s.barTop + s.barHeight,
                                      specular: 0.12,
                                      edgeAmount: 0,
                                      saturation: 1.5,
                                      depthEffect: 0,
                                      droplet: true,
                                      // 静息与按压同一管线（用户要求对齐）：
                                      // 静息 depth=0 零放大，图标 1:1 清晰
                                      // 入玻璃面；按压渐强放大
                                      dropletDepth: s.liquid
                                          ? s.depth.clamp(0.0, 1.0)
                                          : 0.0,
                                      dropletBand: s.band,
                                      dropletRefract: s.refract,
                                      // 色散下限 0.5：栏面为均匀白底，色散
                                      // 只在外溢月牙带可读，档位值（0.25）
                                      // 幅度太小读不出彩虹
                                      dropletChroma: math.max(0.5, s.chroma),
                                      // 色散外溢带（BiliPai
                                      // chromaticEdgeBand）：水滴超出栏缘的
                                      // 溢出量，彩虹只画上下缘外溢月牙带；
                                      // 未溢出（静息）为 0=无色散
                                      dropletGapBand: math.max(
                                        0.0,
                                        s.radius - s.barHeight / 2,
                                      ),
                                      iconImage: navDropletTabTexture.value?.image,
                                      iconOrigin:
                                          navDropletTabTexture.value?.rect
                                              .topLeft ??
                                          Offset.zero,
                                      iconSize:
                                          navDropletTabTexture.value?.rect.size ??
                                          Size.zero,
                                      // 页面原始内容捕获纹理（采样器 2）：
                                      // 按压态透镜折射原始页面内容
                                      //（BiliPai materialBackdrop 等价物）；
                                      // null 时 shader 退回玻璃面分支
                                      pageImage:
                                          navDropletPageTexture.value?.image,
                                      pageOrigin:
                                          navDropletPageTexture.value?.rect
                                              .topLeft ??
                                          Offset.zero,
                                      pageSize:
                                          navDropletPageTexture.value?.rect
                                              .size ??
                                          Size.zero,
                                      child: const SizedBox.expand(),
                                    ),
                                    // 阴影已删（用户反馈：放大水滴带阴影）：
                                    // 黑 tint 厚度阴影是「烟熏圆」观感的来源，
                                    // 通透透镜只留中心高光与顶部透光
                                    CustomPaint(
                                      painter: _DropletEdgePainter(
                                        s.press,
                                        s.isDark,
                                        thicknessShadow: false,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 底栏内容高度：iOS 上 70pt 相对原生 Liquid Glass 标签栏（约 83pt）
/// 明显扁窄（用户反馈 iOS 26 观感），抬到 80pt；安卓维持 70pt 不变。
/// 固定底栏与悬浮液态底栏共用，水滴尺寸随高度比例推导
double get navBarContentHeight =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS ? 80.0 : 70.0;

class _SlidingNavBottom extends StatefulWidget {
  const _SlidingNavBottom({
    required this.index,
    required this.items,
    required this.onSelect,
    this.lens = false,
    this.glassBuilder,
    this.lensBoost = 1.0,
    this.edgeBoost = 1.0,
    this.dropletChroma = 0.5,
  });

  final int index;
  final ValueChanged<int> onSelect;

  /// 页签列表（含按需出现的插件伪页签），由 shell 侧按设置传入
  final List<BottomNavItem> items;

  final bool lens;

  final double lensBoost;
  final double edgeBoost;
  final double dropletChroma;

  final Widget Function(Widget content)? glassBuilder;

  @override
  State<_SlidingNavBottom> createState() => _SlidingNavBottomState();
}

class _SlidingNavBottomState extends State<_SlidingNavBottom>
    with TickerProviderStateMixin {
  AnimationController? _pressC;
  AnimationController get _press => _pressC ??= AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 150),
  );

  AnimationController? _moveC;
  // 显示位可为 2（三页签，插件页签开启时）：AnimationController 默认
  // upperBound=1.0 会把指示器位置钳在中间页签——弹簧动画 0→2 钳停在 1，
  // 自愈赋值 2.0 也被钳回 1。必须解除上界。下界同样必须放开：
  // lowerBound=0 会把回首页（target=0）的欠阻尼过冲钳死在 0，
  // 只有首页的回弹凭空消失（去我的/插件页上界畅通各有回弹——
  // 用户实测「回首页弹跳很少」的根因）
  AnimationController get _move =>
      _moveC ??= AnimationController(
        vsync: this,
        lowerBound: double.negativeInfinity,
        upperBound: double.infinity,
      );

  Ticker? _springTickerC;
  Ticker get _springTicker => _springTickerC ??= createTicker(_onSpringTick);
  Duration _springLast = Duration.zero;

  void _ensureTicker() {
    if (!_springTicker.isActive) {
      _springLast = Duration.zero;
      _springTicker.start();
    }
  }

  void _onSpringTick(Duration elapsed) {
    final rawDt = (elapsed - _springLast).inMicroseconds / 1e6;
    _springLast = elapsed;
    final dt = (rawDt < 0 || rawDt > 0.05) ? 0.016 : rawDt;

    final dragging = _dragging || _pageDrag;
    final vn = dragging ? (_dragVel.abs() / 4.0).clamp(0.0, 1.0) : 0.0;
    const defX = 0.40, compY = 0.54;
    final tX = dragging ? vn * defX : 0.0;
    final tY = dragging ? -vn * defX * compY : 0.0;
    const sStiff = 620.0, sDamp = 22.9;
    _sxSpd += ((tX - _sxPos) * sStiff - _sxSpd * sDamp) * dt;
    _sxPos += _sxSpd * dt;
    _sySpd += ((tY - _syPos) * sStiff - _sySpd * sDamp) * dt;
    _syPos += _sySpd * dt;

    final settled =
        !_dragging &&
        !_pageDrag &&
        _sxSpd.abs() < 0.001 &&
        _sxPos.abs() < 0.002 &&
        _sySpd.abs() < 0.001 &&
        _syPos.abs() < 0.002;
    if (settled) {
      _sxPos = _sxSpd = _syPos = _sySpd = 0;
      _springTicker.stop();
    }
    if (mounted) setState(() {});
  }

  bool _dragging = false;
  double _dragPos = 0;
  double _dragVel = 0;
  double _sxPos = 0, _sxSpd = 0;
  double _syPos = 0, _sySpd = 0;
  Duration? _lastDragTime;

  // ---- 手动拖拽换页的水滴跟手（消费 PageSwitchTabView.tabSwipePageFraction）----
  // 页面横拖时水滴在相邻页签间等比插值+保持液态胀大，随页面实时移动；
  // 松手（弹滚边界，fraction 归 -1）即刻脱钩交还弹簧动画，收敛到预测
  // 落定页签（tabSwipeReleasePage）
  bool _pageDrag = false;
  double _pageDragPos = 0;
  double _pageDragVel = 0;

  /// 拖拽末段运动方向（缓速松手时回弹方向兜底用）
  double _pageDragDir = 1;
  int _lastPageUs = 0;

  void _onPageFraction() {
    if (!mounted) return;
    final f = tabSwipePageFraction.value;
    if (f < 0) {
      if (!_pageDrag) return;
      _pageDrag = false;
      // 松手（fraction 归 -1，页面弹滚刚起步）即刻交还弹簧：press 顶
      // 满 1 保持液态放大（dropletOn 靠 press 续命），水滴带过冲回弹
      // 飞向目标、与页面弹滚并行收敛，落定（completed → _onMoveStatus）
      // 后统一收缩归位。页面弹滚本身无回弹，水滴必须脱钩自飞才有
      // 「弹一下」；且弹滚减速到底才交还的话，水滴会等页面停稳后才
      // 后补回弹（用户实测观感脱节）
      _flight = true;
      if (!_press.isAnimating) {
        _press.value = 1;
      }
      // 靶心用预测落定页（PageSwitchTabView 按 PageScrollPhysics 发布）：
      // 弹滚未过半程松手时 index 还是旧页签，按它收敛会先反向飞再被
      // index 更新的 redirect 纠正（观感抽动）
      final target =
          _dispIndexOf(tabSwipeReleasePage.value ?? widget.index).toDouble();
      // 水滴贴住目标或缓速松手时真实初速≈0，过冲会消失：补最小初速
      // 保证每记松手都有可见回弹（快甩按真实速度放大）。方向跟靶心：
      // 回弹落空（票回原页）时速度票不可信，反向初速会先把水滴甩离靶
      // 心再折返；靶心同位（原地 pop）才沿用拖拽速度/末段方向
      final toward = (target - _move.value).sign;
      final dir = toward != 0
          ? toward
          : _pageDragVel.abs() > 0.05
              ? _pageDragVel.sign
              : (_pageDragDir != 0 ? _pageDragDir : 1.0);
      _move.animateWith(
        SpringSimulation(
          _flightSpringFor(target - _move.value),
          _move.value,
          target,
          // 方向性最小初速：保证缓速松手也有一记可见回弹；上限 1.2
          // 页签/s——贴着目标松手时过高初速会显著加深过冲（飞过头）
          dir * _pageDragVel.abs().clamp(0.8, 1.2),
          tolerance: kNavDropletTolerance,
        ),
      );
      setState(() {});
      return;
    }
    // 分支空间分数位置 → 显示序空间插值（导航栏管理可重排，页签序
    // 与分支序不必相等）
    final from = f.floor().clamp(0, 1 << 30);
    final t = (f - from).clamp(0.0, 1.0);
    final dFrom = _dispIndexOf(from).toDouble();
    final dTo = _dispIndexOf(from + 1).toDouble();
    final disp = dFrom + (dTo - dFrom) * t;
    final now = DateTime.now().microsecondsSinceEpoch;
    if (_pageDrag && _lastPageUs > 0) {
      final dt = (now - _lastPageUs) / 1e6;
      if (dt > 0.004) {
        _pageDragVel = (disp - _pageDragPos) / dt;
        _dragVel = _pageDragVel;
      }
    } else {
      _pageDragVel = 0;
      _dragVel = 0;
    }
    if ((disp - _pageDragPos).abs() > 0.0005) _pageDragDir = (disp - _pageDragPos).sign;
    _lastPageUs = now;
    // 横滑中途接管：点击换页的放大飞行态作废，改由横滑路径统一
    // 管理（液态保持由 pageDragging 驱动，松手回落见 f<0 分支）
    _flight = false;
    _pageDrag = true;
    _pageDragPos = disp;
    _move.stop();
    _move.value = disp;
    _ensureTicker();
    setState(() {});
  }

  /// 底栏玻璃胶囊定位键：顶层水滴快照在帧末用它实测栏的屏幕位置
  final GlobalKey _barKey = GlobalKey();

  /// 页签内容组锚点（每 tab 一把，包住「图标+文字」竖排整组）：水滴
  /// 垂直中心跟随实测组中心——视觉居中要以整组为准，锚图标中心会把
  /// 文字压在圆的下缘（观感偏上），锚 bar 算术中心与组中心等价但经
  /// 组锚点实测免受内容布局变化影响
  List<GlobalKey> _anchorKeys = const [];

  /// 树内水滴（降级路径）用的内容组中心纵坐标缓存（NaN=未量到，回退 bar 中心）
  double _anchorCyLocal = double.nan;

  /// 栏内容捕获键：包住 tabRow（图标+文字）的 RepaintBoundary。液态
  /// 期间低频 toImage 成纹理喂底栏玻璃 shader 采样器 1（BiliPai
  /// tabsBackdrop 等价物），水滴圆内折射出整个底部栏图标
  final GlobalKey _tabCaptureKey = GlobalKey();

  /// 最近一次栏内容捕获（null=尚未捕获，shader uIconOn=0 仅折射玻璃面）
  NavDropletTabTexture? _tabTex;

  /// 上次捕获时刻（120ms 节流：图标 accent 变色/布局微动重捕获）
  DateTime _tabTexAt = DateTime.fromMillisecondsSinceEpoch(0);

  bool _tabCaptureScheduled = false;

  /// 上一帧帧末实测的 tabRow 屏幕矩形（几何稳定门）：与当前帧不同 =
  /// 入场动画/视图尺寸未定，localToGlobal rect 与 toImage 内容不一致
  Rect? _lastTabRect;

  /// 几何稳定探测续帧计数（上限 40 帧 ≈ 670ms，防动画永不落定时空旋）
  int _tabRectRetries = 0;

  /// State 装载时刻：冷启动入场动画（栏内容 stagger/pop，图标内容级
  /// 放大，rect 稳定门探不到）结束前的首捕会把放大帧烘焙进纹理并被静
  /// 息水滴永久沿用（用户截图：巨大红图标+双胶囊弧+黑缺口）——首捕
  /// 推迟到装载 2.5s 后
  final DateTime _bornAt = DateTime.now();

  /// 本页被覆盖路由的转场动画。壳层视差平移（_SmoothFadeForwards 的
  /// -25% 平移）由它驱动：转场每帧 tick 重建底栏 → _syncSnapshot 帧末
  /// 量到实时几何 → 顶层水滴全程跟随，不会把转场中间几何烙进快照。
  /// 没有它，pop 首帧 rebuild 时几何尚未变化（与冻结值相同）→ 追帧链
  /// 不续 → 转场全程盲区，快照停在错误位置，直到下一次交互才飞回。
  Animation<double>? _coverAnim;

  void _onCoverAnimStatus(AnimationStatus status) {
    // 转场落定/退场后强制同步一次：视差已停但栏显隐 scale 动画可能
    // 未结束，补一帧让快照收敛到真实静息几何（防终点残偏）
    if (status == AnimationStatus.completed ||
        status == AnimationStatus.dismissed) {
      if (mounted) setState(() {});
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final anim = ModalRoute.of(context)?.secondaryAnimation;
    if (!identical(anim, _coverAnim)) {
      _coverAnim?.removeStatusListener(_onCoverAnimStatus);
      _coverAnim = anim;
      anim?.addStatusListener(_onCoverAnimStatus);
    }
  }

  /// 分支索引 → 显示序下标（导航栏管理可重排，两者不必相等）
  int _dispIndexOf(int branchIndex) {
    final i = widget.items.indexWhere((it) => it.branchIndex == branchIndex);
    return i < 0 ? 0 : i;
  }

  @override
  void initState() {
    super.initState();
    _move.value = _dispIndexOf(widget.index).toDouble();
    _move.addStatusListener(_onMoveStatus);
    tabSwipePageFraction.addListener(_onPageFraction);
  }

  /// 点击换页的「放大飞行」态：true=水滴应保持液态放大，直到换页
  /// 弹簧自然落定（completed）再收缩归位——与横滑换页同语言
  bool _flight = false;

  /// 启动换页弹簧（靶心取当前 index 的显示序）
  void _startFlightSpring(double v0) {
    final target = _dispIndexOf(widget.index).toDouble();
    _move.animateWith(
      SpringSimulation(
        _flightSpringFor(target - _move.value),
        _move.value,
        target,
        v0,
        tolerance: kNavDropletTolerance,
      ),
    );
  }

  void _onMoveStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || !_flight) return;
    // 连点 redirect 的等待拍里旧弹簧提前收敛（completed）：不终结
    // flight——whenComplete 胀满链还挂着，起飞时 v0=0 照样飞向新靶心；
    // 此处提前终结会让 _startFlightSpring 的守卫吞掉起飞，水滴只能
    // 靠自愈兜底瞬移（弹簧拍整段消失）
    if (_press.isAnimating) return;
    _flight = false;
    if (mounted && !_dragging && !_pageDrag) {
      _press.reverse();
      setState(() {});
    }
  }

  @override
  void didUpdateWidget(covariant _SlidingNavBottom oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 导航栏管理改排序后 items 顺序变了但 index（分支索引）可能不变，
    // 水珠必须跟随新显示位，否则停在上一个顺序的旧位置
    final orderChanged = !_sameDisplayOrder(widget.items, oldWidget.items);
    // 页面横拖中：水滴由 tabSwipePageFraction 逐帧驱动，index 半程变更
    // 的弹簧不得抢写 _move（拖拽落定的收敛由 _onPageFraction 统一接管）
    if (!_dragging && !_pageDrag) {
      if (orderChanged) {
        _flight = false;
        _move.stop();
        _move.value = _dispIndexOf(widget.index).toDouble();
        _press.reverse();
      } else if (widget.index != oldWidget.index) {
        // 点击换页与横滑同语言：先原地放大成液态水滴，胀满瞬间链式
        // 起飞弹簧（带回弹），落定（completed 回调）收缩归位。放大与
        // 弹簧同启动会「边飞边胀」掩盖膨胀；固定延时守卫则会在胀满
        // 后干等（用户实测），链式无此问题
        _flight = true;
        if (_press.value > 0.99) {
          // 已胀满（按住复按/接力改靶）：无 swell 拍，直接带速度接力
          // 起飞。此刻上一次落定的 reverse 可能刚被 _setPressed(false)
          // 拉起（tap-up 先于 didUpdateWidget）：不掐掉的话水滴会在
          // 飞行途中被收缩到 0、塌成静态胶囊一帧再靠 dragMf 复活
          _press
            ..stop()
            ..forward();
          _startFlightSpring(_move.isAnimating ? _move.velocity : 0);
        } else {
          // 胀满即起飞（从当前值续胀，不回退重胀）；弹翅未收敛的连点
          // 改靶（redirect）也走同一拍，不抢跑——旧飞行中立即换弹簧
          // 靶心会把半胀水滴直接甩出去，边飞边胀，「原地放大→再飞」
          // 的两拍被吞（用户实测）。等待拍里旧弹簧继续滑向旧靶心，
          // 起飞瞬间取当时速度接力；若旧弹簧恰好先收敛，completed 由
          // _onMoveStatus 的 _press.isAnimating 守卫放过，v0=0 照常起飞
          _press.forward().whenComplete(() {
            // 被打断（新按压/拖拽接管）时 value<0.9 不飞，由打断方
            // 接管（拖拽走 pageDrag、重胀走新 whenComplete 链）
            if (!mounted || !_flight || _dragging || _pageDrag) return;
            if (_press.value < 0.9) return;
            _startFlightSpring(_move.isAnimating ? _move.velocity : 0);
          });
        }
      }
    }
  }

  bool _sameDisplayOrder(List<BottomNavItem> a, List<BottomNavItem> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].branchIndex != b[i].branchIndex) return false;
    }
    return true;
  }

  /// 栏内容纹理捕获（overlay 水滴存在期间低频，静息含在内）：帧末对
  /// tabRow 的 RepaintBoundary toImage。子树无 backdrop 滤镜，离屏渲染
  /// 采样不会黑帧；捕获区域同帧实测（与 NavDropletSnapshot.rect 同一
  /// localToGlobal 坐标系，含底栏显隐动画 paint 变换）。旧图在替换帧末
  /// 释放（shader/raster 可能仍在采样上一帧的层）
  void _scheduleTabCapture({required bool liquid}) {
    if (!liquid || _tabCaptureScheduled) return;
    // 按压/拖动期间跳过：此时栏内容行带 14% 压扁变换，toImage 图像
    // （边界自身图层，不含祖先变换）与 localToGlobal rect（含变换）
    // 不匹配 → UV 映射把图标压歪；这张歪纹理会被静息水滴沿用（「移动
    // 后静态水滴图标歪」）。松手后 build 重跑会以恒等变换补捕。
    // 飞行切换期间同样跳过：页签图标 pop 缩放动画进行中，toImage 抓到
    // 放大中的图标 → 巨大图标烘焙进纹理；飞行落定后无新 build 补捕，
    // 脏纹理永久留在静息水滴（用户截图：静息双胶囊+巨大红图标）。
    // 落定帧 setState 会以恒等变换补捕干净纹理
    if (_press.value > 0.001 || _dragging || _pageDrag || _flight) return;
    if (_tabTex != null &&
        DateTime.now().difference(_tabTexAt).inMilliseconds < 120) {
      return;
    }
    _tabCaptureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _tabCaptureScheduled = false;
      if (!mounted) return;
      _captureTabRowWhenStable();
    });
  }

  /// 帧末几何稳定探测 + 捕获：tabRow 屏幕矩形连续两帧一致才落捕——
  /// 冷启动入场动画/视图尺寸未定期间 localToGlobal rect 与 toImage
  /// 内容不一致，巨大错位图标 + 越界内容被烘焙进纹理且此后无 build
  /// 补捕，静息水滴永久显示垃圾（用户截图：巨大红图标+双胶囊弧+黑缺
  /// 口）。动画期间自续 postFrame 重探，落定帧必然触发捕获（无需额外
  /// build）；上限 40 帧 ≈ 670ms 防永不落定空旋
  Future<void> _captureTabRowWhenStable() async {
    // 探针期间新按压/拖拽/飞行：变形中的栏面不捕（同 _scheduleTabCapture）
    if (_press.value > 0.001 || _dragging || _pageDrag || _flight) return;
    // 底栏卸载重挂（二级页 push/pop 触发 _FixedChrome AnimatedSize 卸载）
    // 时继承上一次挂载的捕获纹理：dispose 不再清纹理（所有权移交本
    // 挂载），直接沿用即刻恢复静息水滴图标，跳过下方 2.5s 首捕门——
    // 否则每次切页回来图标都要等 2.5s 才出现（用户报障）。rect 稳定门
    // 保留，重挂后正常补捕会以新纹理替换
    if (_tabTex == null) {
      final inherited = navDropletTabTexture.value;
      if (inherited != null) {
        _tabTex = inherited;
        _tabTexAt = DateTime.now();
        _lastTabRect = null;
        _tabRectRetries = 0;
      }
    }
    // 首捕入场动画窗口：自续 postFrame 重探，2.5s 后自然落捕
    if (_tabTex == null &&
        DateTime.now().difference(_bornAt).inMilliseconds < 2500) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _captureTabRowWhenStable();
      });
      return;
    }
    final ro = _tabCaptureKey.currentContext?.findRenderObject();
    if (ro is! RenderRepaintBoundary ||
        !ro.attached ||
        !ro.hasSize ||
        ro.size.isEmpty) {
      return;
    }
    if (kDebugMode && ro.debugNeedsPaint) return;
    // rect 必须用变换后尺寸：app 内容在 FittedBox 缩放内，ro.size 是
    // 布局尺寸（未含缩放），而 shader 采样坐标是屏上物理像素——
    // uIconSize = rect.size × viewDpr 必须等于栏内容的屏上物理尺寸
    //（= 布局 × 缩放 dpr），用布局尺寸会让 UV 放大 1/缩放倍，折射
    // 内容随距离线性偏移
    final topLeft = ro.localToGlobal(Offset.zero);
    final bottomRight =
        ro.localToGlobal(Offset(ro.size.width, ro.size.height));
    final rect = Rect.fromPoints(topLeft, bottomRight);
    if (_lastTabRect != rect) {
      _lastTabRect = rect;
      if (_tabRectRetries < 40) {
        _tabRectRetries++;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _captureTabRowWhenStable();
        });
      }
      return;
    }
    _tabRectRetries = 0;
    try {
        final dpr = MediaQuery.devicePixelRatioOf(context);
        final img = await ro.toImage(pixelRatio: dpr);
        if (!mounted) {
          img.dispose();
          return;
        }
        final old = _tabTex;
        setState(() {
          _tabTex = NavDropletTabTexture(image: img, rect: rect);
          _tabTexAt = DateTime.now();
        });
        AppLog.debug(
          'glass',
          '[XYTabCap] rect=$rect roSize=${ro.size} dpr=$dpr '
          'img=${img.width}x${img.height}',
        );
        navDropletTabTexture.value = _tabTex;
        if (old != null) {
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => old.image.dispose(),
          );
        }
      } catch (_) {
        // 捕获失败保持上次纹理（透镜退化为纯玻璃面折射，不闪黑）
      }
  }

  @override
  void dispose() {
    // 栏内容纹理不清不释放：底栏卸载重挂（二级页 push/pop）时后继挂载
    // 在 _captureTabRowWhenStable 开头继承该纹理，静息水滴图标即时恢复；
    // 若此后永久不再挂载（横屏侧栏模式），仅滞留一张 ui.Image 至进程
    // 结束（可接受）。旧图统一在替换路径帧末释放（_captureTabRowWhenStable）
    // 底栏卸载（横屏侧栏/固定底栏切换等）时清顶层水滴快照，防残影。
    // 推迟到帧末：dispose 可能发生在 finalizeTree 的锁定窗口（chrome
    // 整树卸载帧），同步写 ValueNotifier 会通知 NavDropletOverlay 在
    // 锁定树中 setState 抛「widget tree was locked」异常
    WidgetsBinding.instance.addPostFrameCallback((_) {
      navDropletSnapshot.value = null;
    });
    tabSwipePageFraction.removeListener(_onPageFraction);
    _coverAnim?.removeStatusListener(_onCoverAnimStatus);
    _moveC?.dispose();
    _springTickerC?.dispose();
    _pressC?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.items;
    return AnimatedBuilder(
      // _coverAnim（被覆盖路由转场）参与驱动：转场期间每帧重建并实测
      // 栏几何，快照水滴跟随壳层视差全程移动，不再冻结在转场中间值
      animation: Listenable.merge([_move, _press, _coverAnim]),
      builder: (context, _) => LayoutBuilder(
        builder: (context, constraints) {
          final overlayDroplet = widget.lens && widget.glassBuilder != null;
          final maxW = constraints.maxWidth;
          final maxH = overlayDroplet
              ? navBarContentHeight
              : (constraints.maxHeight.isFinite
                    ? constraints.maxHeight
                    : navBarContentHeight);
          final tabW = (maxW - 20) / items.length;
          // 水滴直径：0.95 倍内容高（用户要求加大——0.8 倍圈住图标+文字
          // 太紧，BiliPai 水滴几乎占满栏内容高）。按压胀大走 overlay 不受
          // 此限；树内降级路径的 k 钳（maxH/dropH）仅兜底防溢出
          final dropH = (maxH * 0.95).clamp(56.0, 72.0);
          final pos = _dragging
              ? _dragPos
              : _pageDrag
              ? _pageDragPos
              : _move.value;

          // 自愈兜底：水珠静息位必须等于选中页签的显示位。didUpdateWidget
          // 的弹簧动画可能被转场锁帧/外部 stop 等打断而停在半途，这里检测
          // 到非拖拽、非动画下的偏离时修正。
          // 不能在本回调（LayoutBuilder 布局期嵌套 buildScope）里直接赋
          // _move.value：赋值会 notifyListeners → AnimatedBuilder.setState，
          // 给布局回调的祖先标脏被框架禁止（「setState() or markNeedsBuild()
          // called during build」），异常还会中止当帧子树更新——指示器冻结
          // 在旧帧、修正永不落地（debug logcat 反复复现）。改为帧末执行：
          // 帧回调里标脏合法，下一帧按修正值落位收敛，不会循环
          // 放大飞行窗口（_flight，弹簧未启动）同样豁免：此时
          // !_move.isAnimating 成立，兜底会把水滴瞬移到目标页签，
          // 「先放大再移动」的分相就被打穿成直接平移
          if (!_dragging &&
              !_pageDrag &&
              !_flight &&
              !_move.isAnimating) {
            final target = _dispIndexOf(widget.index).toDouble();
            if ((_move.value - target).abs() > 0.001) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted ||
                    _dragging ||
                    _pageDrag ||
                    _flight ||
                    _move.isAnimating) {
                  return;
                }
                final now = _dispIndexOf(widget.index).toDouble();
                if ((_move.value - now).abs() > 0.001) {
                  _move.value = now;
                }
              });
            }
          }

          final pageDragging = _dragging || _pageDrag;
          // 速度接力：拖拽中用触点速度；松手后弹簧飞行速度接管，水滴
          // 随减速自然收缩，避免落定瞬间形态突变
          final velTab = pageDragging
              ? _dragVel.abs()
              : (_move.isAnimating ? _move.velocity.abs() : 0.0);
          final velPx = velTab * tabW;
          final dragMf = pageDragging
              ? math.max(0.18, (velPx / 2600).clamp(0.0, 1.0))
              : (velPx > 45 ? ((velPx - 45) / 1400).clamp(0.0, 1.0) : 0.0);
          final pressG = Curves.easeOut.transform(_press.value);
          // 页面横拖没有 _press 按压量（那是页签自身的按下动画），水滴
          // 只有速度分量、胀大和高光都弱于点击态。补等效按压分量 1.0，
          // 让滑动水滴与点击水滴观感一致（速度分量继续叠加，甩动更胀）
          final effPress = math.max(pressG, _pageDrag ? 1.0 : 0.0);
          final mf = math.max(effPress, dragMf);

          if (pageDragging && !_springTicker.isActive) _ensureTicker();

          // 按压胀大系数对齐 BiliPai HyperIsland：按压 bloom 上限
          // 78/56 ≈ 1.39（LiquidIndicator 56dp→78dp），0.55 会推到 1.55+
          double k = 1 + dragMf * 0.22 + effPress * 0.39;
          if (!overlayDroplet) {
            // 树内水滴（玻璃引擎降级路径）嵌入玻璃内部，按住胀大被玻璃裁剪，
            // 上限钳到栏高防硬切边。overlay 顶层水滴不钳——它画在 mini 播放条
            // 之上，鼓出栏缘覆盖折射上方内容正是设计意图。
            k = math.min(k, maxH / dropH);
          } else {
            k = math.min(k, 1.39);
          }
          final stretchX = pageDragging ? _sxPos : 0.0;
          final stretchY = pageDragging ? _syPos : 0.0;
          // 红色胶囊（非液态）样式：滑动选择时长度收一点，松手回到原长。
          // 用 _press 驱动，收和放都是 150ms 平滑过渡，不会在松手瞬间硬跳；
          // 横向也不再跟着 k 变长，否则快速拖动时反而比静止时更长。
          final squeeze = widget.lens ? 1.0 : 1 - pressG * 0.15;
          final sx = widget.lens
              ? k * (1 + stretchX)
              : (1 + stretchX) * squeeze;
          final sy = k * (1 + stretchY);

          final d = dropH;
          final bool scaledIndicator = overlayDroplet;
          // 静息态 = 深色底座胶囊（对齐 BiliPai：静息是深色玻璃底片，
          // 不做折射）；按下/拖动放大时才切液态透镜（通透折射整个背景）
          final dropletOn = pageDragging || pressG > 0.005 || dragMf > 0.005;
          Widget indicator;
          if (widget.lens && dropletOn) {
            // 折射参数对齐 BiliPai LiquidGlassTuning：refractionHeight 10dp、
            // refractionAmount 14dp（按 56dp 水滴比例换算）——band 16/amount 18
            // 的旧配方边带近参考 2 倍厚，色散被摊薄成宽白边。
            // band 随按压 10→30dp：BiliPai 按压态 refractionHeight 放大到
            // 接近水滴半径，底栏边缘穿过水滴中部也在折射带内被大幅弯折
            //（「底栏弯曲」的核心）；固定 10dp 只弯贴边细环，栏缘穿过
            // 内部 1:1 区纹丝不动（用户对比截图否决）
            final band = d * (10.0 + 20.0 * mf) / 56.0 * widget.edgeBoost;
            final amount = d * 14.0 / 56.0 * mf * widget.lensBoost;
            final isDark = Theme.of(context).brightness == Brightness.dark;
            final press = pressG.clamp(0.0, 1.0);
            indicator = ClipOval(
              clipBehavior: Clip.antiAlias,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  LiveLiquidSurface(
                    radius: scaledIndicator ? d * sy / 2 : d / 2,
                    refract: amount,
                    chroma: widget.dropletChroma,
                    blurSigma: 0,
                    // 栏面同款玻璃底色仅作 shader 不可用时的兜底 tint；
                    // 启用后按折射内容亮度动态反色（同顶层静息水滴，
                    // 浅色内容上深色环/白水滴隐形一并修复）
                    backgroundColor: bilipaiGlassTint(
                      Theme.of(context).brightness == Brightness.dark,
                      LiquidGlassQuality.medium,
                    ),
                    tintInvert: true,
                    specular: 0.12,
                    edgeAmount: band,
                    saturation: 1.4,
                    depthEffect: 1.0,
                    child: const SizedBox.expand(),
                  ),
                  CustomPaint(
                    painter: _DropletEdgePainter(
                      press,
                      isDark,
                      // 放大态同为通透透镜：阴影只属于静息深色底座
                      thicknessShadow: false,
                    ),
                  ),
                ],
              ),
            );
          } else {
            if (widget.lens) {
              // 静息液态水滴已并入顶层 overlay，与按压水滴同一渲染管线
              // （用户要求「和放大的水滴对齐」）：树内不再渲染。原因——
              // 树内嵌套采样拿不到玻璃引擎的磨砂 backdrop，shader 玻璃面
              // 回退成不透明灰块且盖住图标（用户截图否决）；overlay 的
              // backdrop = 页面+栏面完整渲染结果，白玻璃面/捕获图标纹理/
              // 边带折射与按压态完全一致，静息仅 depth=0（零放大）
              indicator = const SizedBox.shrink();
            } else {
              // 非液态：红色胶囊
              indicator = DecoratedBox(
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(d / 2),
                ),
                child: const SizedBox.expand(),
              );
            }
          }

          // 液态指示器横向 1.3 倍纵轴：按压水滴成宽 stadium（BiliPai
          // LiquidIndicator 同构，用户实测认可），静息底座同宽但形状是
          // 连续曲率圆角矩形（「和底栏一样的长方形圆」，纯椭圆已否决）
          final indicatorW = widget.lens ? d * 1.30 : (tabW - 8);

          if (_anchorKeys.length != items.length) {
            _anchorKeys = List.generate(items.length, (_) => GlobalKey());
          }

          final tabRow = Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < items.length; i++)
                    Expanded(
                      child: _NavTab(
                        item: items[i],
                        selected: items[i].branchIndex == widget.index,
                        anchorKey: _anchorKeys.length == items.length
                            ? _anchorKeys[i]
                            : null,
                        iconScale: widget.lens
                            ? 1 + 0.38 * (1 - (i - pos).abs()).clamp(0.0, 1.0)
                            : 1.0,
                        onTap: () => widget.onSelect(items[i].branchIndex),
                        suppressSplash: widget.lens,
                      ),
                    ),
                ],
              ),
            ),
          );

          // 液态路径：真实图标在水滴圆内让位 shader 折射图标（反圆裁剪，
          // 仅栏顶以下——越过栏顶的 badge 不裁，overlay 折射层不含栏内容，
          // 裁掉会凭空消失）；RepaintBoundary 在裁剪内侧，捕获的纹理不裁
          //（完整图标行）。非液态/降级路径不裁不包。裁剪必须只作用于
          // 绘制（_PaintOnlyHoleClip）——静息水滴也由 overlay 重画图标后
          // 孔恒存在，ClipPath 连命中一起裁会让图标区域的点击/长按穿透
          // 底栏落到页面内容（误开歌单/来源弹层、长按无水滴的根因）
          final tabRowVisible = overlayDroplet
              ? _PaintOnlyHoleClip(
                  clipper: _DropletHoleClipper(
                    contentKey: _tabCaptureKey,
                    barKey: _barKey,
                  ),
                  child: RepaintBoundary(key: _tabCaptureKey, child: tabRow),
                )
              : tabRow;

          final gestures = Listener(
            onPointerDown: widget.lens
                ? (e) => _onPointerDown(e, tabW, items.length)
                : null,
            onPointerUp: widget.lens ? (_) => _setPressed(false) : null,
            onPointerCancel: widget.lens ? (_) => _onPressCancel() : null,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onHorizontalDragStart: (d) => _onDragStart(d, tabW, items.length),
              onHorizontalDragUpdate: (d) =>
                  _onDragUpdate(d, tabW, items.length),
              onHorizontalDragEnd: (d) => _onDragEnd(d, tabW, items.length - 1),
              onHorizontalDragCancel: () => _onDragCancel(items.length - 1),
              child: Stack(
                children: [
                  // 树内水滴渲染在 tabRow 之下（BiliPai 同构：indicator 在
                  // icon 层下层，折射只作用栏后内容，图标始终清晰在最上）。
                  // 玻璃引擎可用时静息也走树内（!dropletOn），按压胀大才
                  // 交给顶层 overlay（!dropletOn 时 overlay 静息不画）
                  if (!overlayDroplet || !dropletOn)
                    Builder(
                      builder: (context) {
                        // 树内水滴（降级路径）同样锚定实测内容组中心：
                        // build 期布局未定，先用量到的上一帧值，帧末校准
                        final cy = _anchorCyLocal.isFinite
                            ? _anchorCyLocal
                            : maxH / 2;
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (!mounted) return;
                          final b = _barKey.currentContext?.findRenderObject()
                              as RenderBox?;
                          if (b == null || !b.attached || !b.hasSize) return;
                          final measured = _anchorGroupCyLocal(
                            b,
                            fallback: maxH / 2,
                          );
                          if ((_anchorCyLocal - measured).abs() > 0.1) {
                            _anchorCyLocal = measured;
                            setState(() {});
                          }
                        });
                        return Positioned(
                          left: 10 + pos * tabW + (tabW - indicatorW) / 2,
                          top: cy - dropH / 2,
                          height: dropH,
                          width: indicatorW,
                          child: IgnorePointer(
                            child: Transform(
                              alignment: Alignment.center,
                              transform: Matrix4.diagonal3Values(sx, sy, 1)
                                ..setEntry(0, 1, _dragVel.sign * _sxPos * 0.15),
                              child: indicator,
                            ),
                          ),
                        );
                      },
                    ),
                  // 行压扁已撤（几何自洽优先）：按压时压扁变换会让
                  // 水滴圆心/孔洞（跟行实测，含变换）与图标纹理（恒
                  // 等变换的捕获 rect）三方错位——真实图标被孔盖住、
                  // 图标副本偏位（用户截图）。底栏缩小感由透镜边带
                  // 折射弯折内容表达
                  tabRowVisible,
                ],
              ),
            ),
          );

          if (overlayDroplet) {
            final w = indicatorW * sx;
            // 胶囊水滴（BiliPai 同构）：横向绽放全量、纵向按压凸出栏缘
            //——BiliPai 白底效果图：透镜上下真实鼓出 dock（78dp 透镜 /
            // 56dp dock），凸出月牙直接透栏外页面内容。旧 0.60 纵向阻尼
            // 把水滴压在栏高内，露出带只能靠 shader 竖向键控合成——黑带
            // /连接处下潜两轮修复的根源；凸出后 shader 回归 BiliPai 纯
            // 径向场，合成边界整体撤销。×1.35：栏高 86dp 下按压胀幅
            //（sy 至多 1.39）换算出 ~15dp 总凸出，接近 BiliPai 比例
            final h = dropH * (1 + (sy - 1) * 1.35);
            var cx = 10 + pos * tabW + tabW / 2;
            // 栏缘墙：放大水滴的渲染落点钳在栏内容区内。只钳快照 cx、
            // 不钳 pos 本体——弹簧回弹与拖拽插值不受影响，撞墙段由
            // 尺寸脉冲继续表达回弹。墙深 16 = 8 基础余量 + 6 外扩余量
            // + 2 贴壁微露。
            // 钳制前校验区间：转场/首帧布局 maxW 可能极小（push 期间
            // 0 宽过场），此时 16+w/2 > maxW-16-w/2，clamp 直接抛
            // ArgumentError 且每帧 fatal——底栏整树不渲染（真机日志
            // Invalid argument(s): 59.225 定位）。退化时跳过钳制
            final wallLo = 16 + w / 2;
            final wallHi = maxW - 16 - w / 2;
            if (wallHi >= wallLo) {
              cx = cx.clamp(wallLo, wallHi);
            }
            // 顶层水滴快照：水滴不再渲染在底栏树内，而是逐帧把几何/参数写进
            // navDropletSnapshot，由 app.dart 顶层 NavDropletOverlay（位于
            // mini 播放条之上）绘制——水滴独立于底栏边界，长按放大可鼓出
            // 栏缘、覆盖并折射上方内容，不再被顶层播放条盖住上缘。
            // rect 在帧末实测（此时布局已定，localToGlobal 含显隐动画变换）。
            final isDark = Theme.of(context).brightness == Brightness.dark;
            _syncSnapshot(
              cx: cx,
              w: w,
              h: h,
              maxH: maxH,
              liquid: dropletOn,
              radius: d * sy / 2,
              // 边带折射恒定全强度（用户否决随按压缩放：静息水滴在内容
              // 丰富背景上没有折射定义就糊成一团看不见）。方向分流在
              // shader 内做：静息向内（旧观感）、按住向外（BiliPai 吸入）。
              // ×1.25 基础强化：栏面为均匀白色，弯曲只在图标/栏缘/上方
              // 内容处可读。按压不再额外增益——band 同步放大到 30dp 后
              // 弯折已覆盖大半水滴面，位移再增益会过冲
              refract: d * 14.0 / 56.0 * widget.lensBoost * 1.25,
              // band 随按压 10→30dp（同树内按压路径）：BiliPai 按压态
              // refractionHeight 接近水滴半径，底栏边缘穿过水滴中部也
              // 被大幅弯折；固定 10dp 栏缘在内部 1:1 区不动（用户否决）
              band: d * (10.0 + 20.0 * mf) / 56.0 * widget.edgeBoost,
              chroma: widget.dropletChroma,
              shear: _dragVel.sign * _sxPos * 0.12,
              depth: 1.0 * mf,
              press: pressG.clamp(0.0, 1.0),
              isDark: isDark,
            );
            // 捕获 tabRow 纹理（shader 采样器 1）：水滴圆内合成图标。
            // 静息也捕获——静息水滴已并入 overlay 同一管线（图标来自
            // 纹理，实图标被孔裁剪让位），只在液态捕获会让静息玻璃面
            // 空白无图标（用户截图否决）
            _scheduleTabCapture(liquid: overlayDroplet);
            return widget.glassBuilder!(
              SizedBox(key: _barKey, height: maxH, child: gestures),
            );
          }
          if (navDropletSnapshot.value != null) {
            // 降级为树内水滴（玻璃引擎不可用）时清掉顶层快照，避免残影
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) navDropletSnapshot.value = null;
            });
          }
          return gestures;
        },
      ),
    );
  }

  void _setPressed(bool down) {
    if (down) {
      // 打断保持原则：飞行/胀大/落定收缩中再按下都从当前值续胀，
      // 严禁 from:0 重启——上一次落定的 reverse 还在跑时（value≈0.9）
      // 重启会把已放大的水滴瞬间打回 0，快照写出一帧静态胶囊
      // （liquid=false），放大效果被吞、指示器肉眼可见变异
      if (!_flight) _press.forward();
    } else if (!_dragging && !_flight) {
      // 点击换页飞行中不得在此收缩：落定由 _onMoveStatus 统一接管
      _press.reverse();
    }
  }

  /// 内容组中心在 bar 坐标系下的纵向位置（bar 盒带 paint 变换时同矩阵换算）
  double _anchorGroupCyLocal(RenderBox bar, {required double fallback}) {
    for (final key in _anchorKeys) {
      final ro = key.currentContext?.findRenderObject();
      if (ro is! RenderBox || !ro.attached || !ro.hasSize) continue;
      final globalCenter = ro.localToGlobal(ro.size.center(Offset.zero));
      return bar.globalToLocal(globalCenter).dy;
    }
    return fallback;
  }

  /// 顶层水滴快照同步：帧末实测底栏几何写快照；rect 未稳定时逐帧重写
  /// 直至收敛。仅靠 build 触发的单次写入会把显隐动画起步帧的几何烙进
  /// 快照（AnimatedScale 0.92→1.0 的 paint 变换参与 localToGlobal）——
  /// 静息态不再 rebuild，动画结束后顶层水滴停在错位处，直到下一次交互
  /// 逐帧跳回（二级页返回时指示器「乱飞」的根因）
  void _syncSnapshot({
    required double cx,
    required double w,
    required double h,
    required double maxH,
    required bool liquid,
    required double radius,
    required double refract,
    required double band,
    required double chroma,
    required double shear,
    required double depth,
    required double press,
    required bool isDark,
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // push 覆盖转场中静默：底栏正让位淡出、顶层水滴不渲染快照
      //（chromeHidden），追帧链每帧 localToGlobal+写快照+通知 overlay
      // rebuild 是纯开销（root→sub 转场掉帧源之一）；pop（reverse）的
      // 视差追帧保留
      if (_coverAnim?.status == AnimationStatus.forward) return;
      final b = _barKey.currentContext?.findRenderObject() as RenderBox?;
      if (b == null || !b.attached || !b.hasSize) return;
      // 垂直锚定实测内容组中心（图标+文字整组）：视觉居中以整组为准，
      // 锚图标中心会把文字压在圆的下缘。取第一把可用的组 key（同排等高）
      final cy = _anchorGroupCyLocal(b, fallback: maxH / 2);
      // 逻辑中心点过同一 paint 变换（显隐动画 scale 参与矩阵），
      // 避免未缩放逻辑 cx 与缩放后 origin 混算产生错位。
      // 对角两点都过变换：样式大小档把路由子树按 FittedBox 等比
      // 放大，若只变换 topLeft 而宽高保持未缩放逻辑值，rect 中心会
      // 整体向左上偏 (1-s)×(w/2, h/2)——大/特大档水滴明显偏左上
      final topLeft = b.localToGlobal(Offset(cx - w / 2, cy - h / 2));
      final bottomRight = b.localToGlobal(Offset(cx + w / 2, cy + h / 2));
      final rect = Rect.fromPoints(topLeft, bottomRight);
      // 玻璃面顶缘全局 Y：顶层水滴折射层的上/栏内分界（见 snapshot.barTop）
      final barTop = b.localToGlobal(Offset.zero).dy;
      // 玻璃面视觉高度（逻辑口径）：色散外溢带 = 水滴半径 − 栏轨半高
      final barHeight =
          (b.localToGlobal(Offset(0, b.size.height)).dy - barTop).abs();
      // 变换后 rect 的视觉尺寸随底栏同步放大，作用半径取短边一半
      // 保持全局像素口径一致（overlay 的 liquid shader/胶囊圆角按
      // rect 实际尺寸取形）
      radius = rect.shortestSide / 2;
      final prev = navDropletSnapshot.value;
      final rectStable = prev != null && prev.rect == rect;
      // 交互中 press/refract 等随 rebuild 逐帧渐变，有变必须写快照；
      // rect 稳定（且无 rebuild 驱动）后循环自然终止，静息零开销
      final changed =
          prev == null ||
          prev.rect != rect ||
          prev.liquid != liquid ||
          prev.press != press ||
          prev.radius != radius ||
          prev.refract != refract ||
          prev.band != band ||
          prev.depth != depth ||
          prev.shear != shear ||
          prev.barTop != barTop ||
          prev.barHeight != barHeight;
      if (changed) {
        navDropletSnapshot.value = NavDropletSnapshot(
          rect: rect,
          shear: shear,
          liquid: liquid,
          radius: radius,
          refract: refract,
          band: band,
          chroma: chroma,
          depth: depth,
          press: press,
          isDark: isDark,
          barTop: barTop,
          barHeight: barHeight,
        );
      }
      if (!rectStable) {
        // 几何仍在过渡（显隐动画/布局变化）：下一帧继续同步
        _syncSnapshot(
          cx: cx,
          w: w,
          h: h,
          maxH: maxH,
          liquid: liquid,
          radius: radius,
          refract: refract,
          band: band,
          chroma: chroma,
          shear: shear,
          depth: depth,
          press: press,
          isDark: isDark,
        );
      }
    });
  }

  void _onPointerDown(PointerDownEvent e, double tabW, int count) {
    _setPressed(true);
  }

  void _onPressCancel() {
    if (_dragging || _flight) return;
    _press.reverse();
    _move.stop();
    // 回弹落点必须换算显示序：widget.index 是分支索引，导航栏管理
    // 重排后两者不等，裸用会把水珠弹到错误页签
    _move.value = _dispIndexOf(widget.index).toDouble();
  }

  void _onDragStart(DragStartDetails d, double tabW, int count) {
    _dragging = true;
    _dragVel = 0;
    _lastDragTime = d.sourceTimeStamp;
    _dragPos = ((d.localPosition.dx - 10) / tabW - 0.5).clamp(0.0, count - 1.0);
    _move.stop();
    _move.value = _dragPos;
    _press.forward(from: 0);
    _ensureTicker();
    setState(() {});
  }

  void _onDragUpdate(DragUpdateDetails d, double tabW, int count) {
    final prev = _dragPos;
    _dragPos = ((d.localPosition.dx - 10) / tabW - 0.5).clamp(0.0, count - 1.0);
    _move.stop();
    _move.value = _dragPos;
    final ts = d.sourceTimeStamp;
    final prevTs = _lastDragTime;
    _lastDragTime = ts;
    if (ts != null && prevTs != null) {
      final dt = (ts - prevTs).inMicroseconds / 1e6;
      if (dt > 0.004) _dragVel = (_dragPos - prev) / dt;
    }
    setState(() {});
  }

  void _onDragEnd(DragEndDetails d, double tabW, int maxIndex) {
    final vTab = d.velocity.pixelsPerSecond.dx / tabW;
    final projected = (_dragPos + vTab * 0.12).clamp(0.0, maxIndex.toDouble());
    _commitDragTarget(
      projected.roundToDouble().clamp(0.0, maxIndex.toDouble()),
    );
  }

  void _onDragCancel(int maxIndex) {
    _commitDragTarget(_dispIndexOf(widget.index).toDouble());
  }

  void _commitDragTarget(double target) {
    _dragging = false;
    // 与横滑松手同语言：保持按压放大随弹簧飞行回弹，落定统一收缩
    _flight = true;
    _move.animateWith(
      SpringSimulation(
        _flightSpringFor(target - _move.value),
        _move.value,
        target,
        _dragVel,
        tolerance: kNavDropletTolerance,
      ),
    );
    final idx = target.round();
    // 拖拽目标是显示序下标，回调换算成 shell 分支索引
    if (idx != _dispIndexOf(widget.index)) {
      if (idx >= 0 && idx < widget.items.length) {
        widget.onSelect(widget.items[idx].branchIndex);
      } else {
        setState(() {});
      }
    } else {
      setState(() {});
    }
  }
}

class _NavTab extends ConsumerWidget {
  const _NavTab({
    required this.item,
    required this.selected,
    required this.onTap,
    this.iconScale = 1.0,
    this.suppressSplash = false,
    this.anchorKey,
  });

  final BottomNavItem item;
  final bool selected;
  final VoidCallback onTap;
  final double iconScale;

  final bool suppressSplash;

  /// 内容组锚点：供水滴几何实测（见 _anchorKeys）
  final GlobalKey? anchorKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final primary = scheme.primary;
    final color = selected
        ? primary
        : scheme.onSurfaceVariant.withValues(alpha: 0.6);
    final tab = Container(
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(vertical: 4),
      // 锚点包整组（图标+文字竖排）：水滴视觉居中于组中心而非图标
      // 中心——锚图标会把文字压在圆的下缘，观感整体偏上
      child: KeyedSubtree(
        key: anchorKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Transform.scale(
              scale: iconScale,
              child: themeSlotIcon(
                ref,
                item.themeSlot,
                fallback: item.icon,
                size: 22,
                color: color,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              navTitle(context, item),
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
    if (suppressSplash) {
      return PressableScale(
        pressScale: 0.92,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: tab,
        ),
      );
    }
    return PressableScale(
      pressScale: 0.92,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: tab,
      ),
    );
  }
}

/// 水滴圆孔裁剪：液态期间真实 tabRow 在水滴圆内让位 shader 折射图标
///（圆内 shader 已用捕获纹理重画折射图标，实图标不裁会以原样叠在折射
/// 图上方成双影）；圆外照常显示。仅裁栏顶以下——overlay 折射层只含
/// 页面内容（不含栏子树），越过栏顶的 badge 若被裁会凭空消失
class _DropletHoleClipper extends CustomClipper<Path> {
  const _DropletHoleClipper({required this.contentKey, required this.barKey});

  /// tabRow 的 RepaintBoundary 键（兼作坐标换算盒：Center 撑满 bar 盒）
  final GlobalKey contentKey;

  /// 底栏盒键（栏顶全局 y 换算）
  final GlobalKey barKey;

  @override
  Path getClip(Size size) {
    final base = Path()..addRect(Offset.zero & size);
    final snap = navDropletSnapshot.value;
    // 静息也裁：静息水滴同样由 overlay 用捕获纹理重画图标（与按压态
    // 同一管线），实图标不裁会在玻璃面内叠成双影
    if (snap == null) return base;
    final ro = contentKey.currentContext?.findRenderObject();
    if (ro is! RenderBox || !ro.attached || !ro.hasSize) return base;
    // 快照几何为全局逻辑坐标（与 _syncSnapshot 同帧实测、含 paint 变换），
    // 换算到裁剪盒本地。胶囊孔与 overlay 的 ClipRRect 同形（横向半长 =
    // rect 宽/2、圆角 = rect 高/2），真实图标在整颗胶囊内让位折射图标
    final center = ro.globalToLocal(snap.rect.center);
    final capsuleRect = Rect.fromCenter(
      center: center,
      width: snap.rect.width,
      height: snap.rect.height,
    );
    final capsule = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          capsuleRect,
          Radius.circular(snap.rect.height / 2),
        ),
      );
    final barRo = barKey.currentContext?.findRenderObject();
    var barTopLocal = 0.0;
    if (barRo is RenderBox && barRo.attached && barRo.hasSize) {
      barTopLocal = ro.globalToLocal(Offset(0, snap.barTop)).dy;
    }
    // 孔 = 胶囊 ∩ 栏顶以下条带
    final strip = Path()
      ..addRect(
        Rect.fromLTRB(
          -size.width,
          barTopLocal,
          size.width * 2,
          size.height * 2,
        ),
      );
    final hole = Path.combine(PathOperation.intersect, capsule, strip);
    return Path.combine(PathOperation.difference, base, hole);
  }

  @override
  bool shouldReclip(_DropletHoleClipper oldClipper) => true;
}

/// 仅裁剪绘制、不裁剪命中的胶囊孔裁剪容器：真实 tabRow 在水滴胶囊内
/// 让位 overlay 重画图标（paint 裁剪），但命中测试保持完整——若用
/// ClipPath，孔连命中一起裁掉，图标区域的点击/长按会穿透底栏落到
/// 页面内容上（误触页面元素）
class _PaintOnlyHoleClip extends SingleChildRenderObjectWidget {
  const _PaintOnlyHoleClip({required this.clipper, super.child});

  final CustomClipper<Path> clipper;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderPaintOnlyHoleClip(clipper);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderPaintOnlyHoleClip renderObject,
  ) {
    renderObject.clipper = clipper;
  }
}

class _RenderPaintOnlyHoleClip extends RenderProxyBox {
  _RenderPaintOnlyHoleClip(this._clipper);

  CustomClipper<Path> _clipper;

  set clipper(CustomClipper<Path> value) {
    if (identical(_clipper, value)) return;
    if (attached) _clipper.removeListener(_markNeedsPaint);
    _clipper = value;
    if (attached) _clipper.addListener(_markNeedsPaint);
    _markNeedsPaint();
  }

  void _markNeedsPaint() {
    if (attached) markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _clipper.addListener(_markNeedsPaint);
  }

  @override
  void detach() {
    _clipper.removeListener(_markNeedsPaint);
    super.detach();
  }

  // 命中测试沿用 RenderProxyBox 默认（子树原样命中、不被孔裁）——
  // 裁剪只发生在 paint
  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null) return;
    context.pushClipPath(
      needsCompositing,
      offset,
      Offset.zero & size,
      _clipper.getClip(size),
      super.paint,
      clipBehavior: Clip.antiAlias,
    );
  }
}

/// 水滴表面材质：对齐 BiliPai LiquidIndicator.drawLiquidSphereSurface——
/// 中央径向高光 + 顶部透光/底部厚度 + sweep 环形 rim（左上反光弧已删，
/// 用户否决）。全部为清晰渐变，不用 MaskFilter 模糊笔触——白底栏上叠
/// 糊白高光只会糊成一团。不做主题色微染（用户指定：水滴应是透明玻璃，
/// 不染色）
class _DropletEdgePainter extends CustomPainter {
  const _DropletEdgePainter(this.progress, this.isDark, {this.thicknessShadow = true});

  final double progress;
  final bool isDark;

  /// 底部「厚度阴影」渐变开关：放大水滴（顶层 overlay/树内放大态）关闭——
  /// 用户反馈放大的水滴带阴影像烟熏圆；静息深色底座水滴保留
  final bool thicknessShadow;

  @override
  void paint(Canvas canvas, Size size) {
    final p = progress.clamp(0.0, 1.0);
    if (p <= 0) return;
    if (size.width <= 0 || size.height <= 0) return;
    final outer = Offset.zero & size;
    const white = Colors.white;

    // ② 中央径向高光：中心亮→外缘消失（BiliPai centerGlow radial）。
    // 白量已压低（用户反馈静态不够黑）
    final glow = 0.06 + 0.10 * p;
    canvas.drawRect(
      outer,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(0, 0.08),
          radius: 0.9,
          colors: [
            white.withValues(alpha: glow),
            white.withValues(alpha: glow * 0.35),
            white.withValues(alpha: 0),
          ],
        ).createShader(outer),
    );

    // ③ 纵向渐变：顶部透光 → 底部厚度阴影（BiliPai verticalGradient）。
    // thicknessShadow=false（放大水滴）时底部黑量归零，只留顶部透光
    canvas.drawRect(
      outer,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            white.withValues(alpha: (isDark ? 0.04 : 0.05) + 0.02 * p),
            white.withValues(alpha: 0),
            Colors.black.withValues(
              alpha: thicknessShadow
                  ? (isDark ? 0.10 : 0.08) * (0.5 + 0.5 * p)
                  : 0,
            ),
          ],
        ).createShader(outer),
    );

    // ④ 环形 rim 已删除（用户否决）：暗色描边叠在 tint 上读成"一圈更黑
    // 的边"。圆界由 tint 对比自然显形，立体感只靠中心微亮+底部厚度
    // ⑤ 左上镜面反光弧已删除（用户否决）：小圆上读成左侧一道怪弧线
  }

  @override
  bool shouldRepaint(_DropletEdgePainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.isDark != isDark;
}
