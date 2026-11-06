part of 'routes.dart';

Page<void> _coverBackPage(
  BuildContext context,
  WidgetBuilder builder, {
  LocalKey? key,
  String? location,
}) {
  final predictiveBack =
      ProviderScope.containerOf(context, listen: false)
          .read(settingsProvider)
          .valueOrNull
          ?.enablePredictiveBack ??
      true;
  return _CoverBackPage(
    key: key,
    builder: builder,
    predictiveBack: predictiveBack,
    location: location,
  );
}

bool _enablePredictiveBack(BuildContext context) =>
    ProviderScope.containerOf(context, listen: false)
        .read(settingsProvider)
        .valueOrNull
        ?.enablePredictiveBack ??
    true;

bool _livePredictiveBack(BuildContext? context, bool fallback) {
  if (context == null) return fallback;
  return ProviderScope.containerOf(context, listen: false)
          .read(settingsProvider)
          .valueOrNull
          ?.enablePredictiveBack ??
      true;
}

/// iOS 无系统预测返回事件源，左边缘滑动由应用内触摸驱动合成事件
/// （ios_edge_back_driver）。「预测返回」设置约束的是 Android 系统手势
/// 入口，iOS 边缘返回不应被它连坐禁用（否则默认关闭时全线失效）。
bool get _edgeBackAlwaysOn =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

PageTransitionStyle _pageTransitionStyle(BuildContext context) =>
    ProviderScope.containerOf(context, listen: false)
        .read(settingsProvider)
        .valueOrNull
        ?.pageTransitionStyle ??
    PageTransitionStyle.cover;

bool _isSmooth(BuildContext context) =>
    _pageTransitionStyle(context) == PageTransitionStyle.smooth;

Page<void> _coverPage(
  BuildContext context,
  WidgetBuilder builder, {
  LocalKey? key,
  String? location,
}) {
  return _CoverPage(
    key: key,
    builder: builder,
    predictiveBack: _enablePredictiveBack(context),
    location: location,
  );
}

PageRoute<T> coverPageRoute<T>(
  BuildContext context,
  WidgetBuilder builder, {
  RouteSettings? settings,
}) {
  return _CoverRoute<T>(
    settings: settings ?? RouteSettings(),
    builder: builder,
    predictiveBack: _enablePredictiveBack(context),
    // 播放 Navigator 上的命令式覆盖页（如音效页）经 settings.name 携带
    // matchedLocation，喂给 RoutePageBackdrop 解析主题包每页壁纸
    location: settings?.name,
  );
}

class _CoverPage extends Page<void> {
  const _CoverPage({
    super.key,
    required this.builder,
    required this.predictiveBack,
    this.location,
  });

  final WidgetBuilder builder;
  final bool predictiveBack;

  /// matchedLocation：主题包每页壁纸按此解析页面 id
  final String? location;

  @override
  Route<void> createRoute(BuildContext context) {
    return _CoverRoute(
      settings: this,
      builder: builder,
      predictiveBack: predictiveBack,
      location: location,
    );
  }
}

mixin _CoverGestureCommit<T> on PageRoute<T> {
  @override
  void handleCommitBackGesture() {
    final AnimationController? ctrl = controller;
    navigator?.pop();
    if (ctrl != null && ctrl.isAnimating) {
      late final AnimationStatusListener listener;
      listener = (AnimationStatus status) {
        navigator?.didStopUserGesture();
        ctrl.removeStatusListener(listener);
      };
      ctrl.addStatusListener(listener);
    } else {
      navigator?.didStopUserGesture();
    }
  }
}

class _CoverRoute<T> extends PageRoute<T> with _CoverGestureCommit<T> {
  _CoverRoute({
    required super.settings,
    required this.builder,
    required this.predictiveBack,
    this.location,
  });

  final WidgetBuilder builder;
  final bool predictiveBack;

  /// matchedLocation：主题包每页壁纸按此解析页面 id
  final String? location;

  @override
  bool get popGestureEnabled =>
      isCurrent &&
      (_edgeBackAlwaysOn ||
          _livePredictiveBack(navigator?.context, predictiveBack));

  // 时间戳打点：didPush（动画 forward 起点）与 defer init（buildPage
  // 首帧）的时间差与各自状态。实测 gap≈9ms 且 init 已 completed
  // value=1.00——非首帧阻塞，而是 ModalRoute 入场首帧 offstage 代理
  // 指向 kAlwaysCompleteAnimation（详见 buildPage 注释）
  @override
  TickerFuture didPush() {
    final c = controller;
    AppLog.debug(
      'nav',
      'cover didPush t=${DateTime.now().millisecondsSinceEpoch % 1000000} '
      'status=${c?.status} v=${c?.value.toStringAsFixed(2)}',
    );
    return super.didPush();
  }

  @override
  void install() {
    super.install();
    overlayEntries.first.opaque = opaque;
  }

  @override
  bool get opaque => true;

  @override
  bool canTransitionTo(TransitionRoute<dynamic> nextRoute) =>
      nextRoute is PageRoute && nextRoute.opaque;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  bool get barrierDismissible => false;

  @override
  bool get maintainState => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 250);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    // 转场期间维持内容渲染（用户否决空壳方案：离屏缓存+渲显分离架构下
    // 页面观感完整，性能由 stagger 推迟/液态垫降级/信号静默承担）。
    // _RouteDeferredBody 恒即时落定，仅保留时间戳打点作诊断。
    return AppPageBackground(
        child: _RouteDeferredBody(builder: builder, animation: animation));
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (kFrameworkPredictiveCompare) {
      return const PredictiveBackPageTransitionsBuilder(
        fallbackColor: Colors.transparent,
      ).buildTransitions(this, context, animation, secondaryAnimation, child);
    }
    // iOS 左缘返回手势覆盖条：包在转场层外侧，成为 hit-test 最内层
    // （先于页面内识别器收事件与 sweep，见 EdgeBackGestureScope）
    return EdgeBackGestureScope(
      child: PredictiveBackGestureDetector(
        route: this,
        builder: (context, phase, startBackEvent, currentBackEvent) {
          if (_isSmooth(context)) {
            final smooth = _SmoothFadeForwards(
              animation: animation,
              secondaryAnimation: secondaryAnimation,
              child: child,
            );
            if (phase == PredictiveBackPhase.idle) return smooth;
            // 手势期不能用 smooth：DualTransitionBuilder 按 animation.status
            // 切换正反向，预测返回期间控制器直接改 value、status 停在
            // completed，正向分支一动不动（松手 pop 才开始动画）。
            // 手势期直接用值驱动反向退出（平移+淡出）：_fadeOut/
            // _backwardTranslation 的曲线以「pop 开始 t=0」为基准，须套
            // ReverseAnimation 翻转时间轴——直喂原始 animation 会在拖拽
            // 起手就算出 opacity=0（页面瞬间消失，看似丢上一页）。
            // 内容与 cover 同款走离屏快照：实时渲染会让液态玻璃逐帧
            // 重抓背板与平移竞速产生抽搐。不套 TransitionBackdrop：cover
            // 样式下层页被转场隐藏需实底兜底，平移样式下层页真实渲染。
            final rev = ReverseAnimation(animation);
            return FadeTransition(
              opacity: _SmoothFadeForwards._gestureFadeOut.animate(rev),
              child: SlideTransition(
                position: _SmoothFadeForwards._backwardTranslation.animate(rev),
                // 页面底色/壁纸（RoutePageBackdrop）在统一包装段，提前
                // return 会绕过它——手势期页面变透明直接透下层。包在
                // 平移/淡出内侧，底色随页面一起位移淡出。
                child: RoutePageBackdrop(
                  completion: animation,
                  location: location,
                  child: RouteStaticSnapshot(animation: animation, child: child),
                ),
              ),
            );
          }
        final isPortrait =
            MediaQuery.orientationOf(context) == Orientation.portrait;
        final page = isPortrait
            ? RouteStaticSnapshot(animation: animation, child: child)
            : FadeTransition(
                opacity: CurvedAnimation(
                  parent: animation,
                  curve: const Interval(0, 0.45, curve: Curves.easeOutCubic),
                  reverseCurve:
                      const Interval(0, 0.45, curve: Curves.easeOutCubic),
                ),
                child: child,
              );
        final content = RoutePageBackdrop(
          completion: animation,
          location: location,
          child: page,
        );
        if (isPortrait &&
            phase != PredictiveBackPhase.idle &&
            !_edgeBackAlwaysOn) {
          // 预测返回手势期（含 commit/cancel 收尾）：Android 16 同款整页
          // 缩小卡片（缩放+贴边位移+圆角+纵向跟随），下层页面从缩小露出
          // 的区域透出。此前手势期沿用平移基线，观感是「整页盖走」而非
          // 官方缩小返回。
          // iOS 例外：触摸驱动的边缘返回（ios_edge_back_driver）按 iOS
          // 原生习惯走基线滑动——整页 1:1 跟手平移、下层透出，缩卡是
          // Android 转场语言，iOS 用户从未见过、手感怪异。
          return PredictiveBackSharedElementPageTransition(
            animation: animation,
            secondaryAnimation: secondaryAnimation,
            phase: phase,
            startBackEvent: startBackEvent,
            currentBackEvent: currentBackEvent,
            child: content,
          );
        }
        final curved = CurvedAnimation(
          parent: animation,
          curve: isPortrait ? Curves.linear : Curves.easeOut,
          reverseCurve: isPortrait ? Curves.linear : Curves.easeOut.flipped,
        );
        final begin = isPortrait ? const Offset(1, 0) : const Offset(0.25, 0);
        final iosGestureSlide =
            isPortrait && _edgeBackAlwaysOn && phase != PredictiveBackPhase.idle;
        return SlideTransition(
          position: Tween<Offset>(begin: begin, end: Offset.zero)
              .animate(curved),
          child: iosGestureSlide
              // iOS 手势期左缘动态阴影：强化两页叠放的层次（原生观感）
              ? DecoratedBox(
                  decoration: BoxDecoration(
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.18),
                        blurRadius: 12,
                        spreadRadius: -2,
                        offset: const Offset(-5, 0),
                      ),
                    ],
                  ),
                  child: content,
                )
              : content,
        );
        },
      ),
    );
  }
}

class _CoverBackPage extends Page<void> {
  const _CoverBackPage({
    super.key,
    required this.builder,
    required this.predictiveBack,
    this.location,
  });

  final WidgetBuilder builder;
  final bool predictiveBack;

  /// matchedLocation：主题包每页壁纸按此解析页面 id
  final String? location;

  @override
  Route<void> createRoute(BuildContext context) {
    return _CoverBackRoute(
      settings: this,
      builder: builder,
      predictiveBack: predictiveBack,
      location: location,
    );
  }
}

class _CoverBackRoute extends PageRoute<void> with _CoverGestureCommit<void> {
  _CoverBackRoute({
    required super.settings,
    required this.builder,
    required this.predictiveBack,
    this.location,
  });

  final WidgetBuilder builder;
  final bool predictiveBack;

  /// matchedLocation：主题包每页壁纸按此解析页面 id
  final String? location;

  @override
  bool get popGestureEnabled =>
      isCurrent &&
      (_edgeBackAlwaysOn ||
          _livePredictiveBack(navigator?.context, predictiveBack));

  // 时间戳打点（同 _CoverRoute）：实测确认 offstage 代理机制，非首帧阻塞
  @override
  TickerFuture didPush() {
    final c = controller;
    AppLog.debug(
      'nav',
      'coverBack didPush t=${DateTime.now().millisecondsSinceEpoch % 1000000} '
      'status=${c?.status} v=${c?.value.toStringAsFixed(2)}',
    );
    return super.didPush();
  }

  @override
  bool get opaque => true;

  @override
  bool canTransitionTo(TransitionRoute<dynamic> nextRoute) =>
      nextRoute is PageRoute && nextRoute.opaque;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  bool get barrierDismissible => false;

  @override
  bool get maintainState => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 250);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    // 同 _CoverRoute：转场期间维持内容渲染，_RouteDeferredBody 仅作诊断
    return AppPageBackground(
        child: _RouteDeferredBody(builder: builder, animation: animation));
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (kFrameworkPredictiveCompare) {
      return const PredictiveBackPageTransitionsBuilder(
        fallbackColor: Colors.transparent,
      ).buildTransitions(this, context, animation, secondaryAnimation, child);
    }
    // iOS 左缘返回手势覆盖条：同 _CoverRoute（hit-test 最内层先认领）
    return EdgeBackGestureScope(
      child: PredictiveBackGestureDetector(
        route: this,
        builder: (context, phase, startBackEvent, currentBackEvent) {
          if (_isSmooth(context)) {
            final smooth = _SmoothFadeForwards(
              animation: animation,
              secondaryAnimation: secondaryAnimation,
              child: child,
            );
            if (phase == PredictiveBackPhase.idle) return smooth;
            // 手势期不能用 smooth：DualTransitionBuilder 按 status 切换
            // 正反向，预测返回期间 status 停在 completed 不跟手；直接用
            // 值驱动反向退出（同 _CoverRoute：ReverseAnimation 翻转时间
            // 轴 + 离屏快照防玻璃抽搐，不套 TransitionBackdrop 以免盖住
            // 真实渲染的下层页）
            final rev = ReverseAnimation(animation);
            return FadeTransition(
              opacity: _SmoothFadeForwards._gestureFadeOut.animate(rev),
              child: SlideTransition(
                position: _SmoothFadeForwards._backwardTranslation.animate(rev),
                // 同 _CoverRoute：提前 return 绕过了统一包装段的底色
                child: RoutePageBackdrop(
                  completion: animation,
                  location: location,
                  child: RouteStaticSnapshot(animation: animation, child: child),
                ),
              ),
            );
          }
          final isPortrait =
              MediaQuery.orientationOf(context) == Orientation.portrait;
          final page = isPortrait
              ? RouteStaticSnapshot(animation: animation, child: child)
              : FadeTransition(
                  opacity: CurvedAnimation(
                    parent: animation,
                    curve:
                        const Interval(0, 0.45, curve: Curves.easeOutCubic),
                    reverseCurve:
                        const Interval(0, 0.45, curve: Curves.easeOutCubic),
                  ),
                  child: child,
                );
          final content = RoutePageBackdrop(
            completion: animation,
            location: location,
            child: page,
          );
          final Widget transition;
          if (isPortrait &&
              phase != PredictiveBackPhase.idle &&
              !_edgeBackAlwaysOn) {
            // 手势期（含 commit/cancel 收尾）：整页缩小卡片，同 _CoverRoute；
            // 飞回封面（PredictiveCoverReturnView）继续叠加在其上。
            // iOS 例外走基线滑动（缩卡是 Android 转场语言）
            transition = PredictiveBackSharedElementPageTransition(
              animation: animation,
              secondaryAnimation: secondaryAnimation,
              phase: phase,
              startBackEvent: startBackEvent,
              currentBackEvent: currentBackEvent,
              child: content,
            );
          } else {
            final curved = CurvedAnimation(
              parent: animation,
              curve: isPortrait ? Curves.linear : Curves.easeOut,
              reverseCurve:
                  isPortrait ? Curves.linear : Curves.easeOut.flipped,
            );
            final begin =
                isPortrait ? const Offset(1, 0) : const Offset(0.25, 0);
            final iosGestureSlide = isPortrait &&
                _edgeBackAlwaysOn &&
                phase != PredictiveBackPhase.idle;
            transition = SlideTransition(
              position: Tween<Offset>(begin: begin, end: Offset.zero)
                  .animate(curved),
              child: iosGestureSlide
                  // iOS 手势期左缘动态阴影：同 _CoverRoute
                  ? DecoratedBox(
                      decoration: BoxDecoration(
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.18),
                            blurRadius: 12,
                            spreadRadius: -2,
                            offset: const Offset(-5, 0),
                          ),
                        ],
                      ),
                      child: content,
                    )
                  : content,
            );
          }
          if (phase != PredictiveBackPhase.idle) {
            return Stack(
              children: [
                transition,
                PredictiveCoverReturnView(animation: animation),
              ],
            );
          }
          return transition;
        },
      ),
    );
  }
}

/// cover 覆盖路由页体诊断壳：入转场时打 defer init/settled 时间戳。
/// 空壳延迟构建方案已否决（转场中纯背景滑入，下一页内容缺失）——页面
/// 性能由离屏缓存+渲显分离架构承担（RepaintBoundary retained 帧、
/// StaggerIn 转场后错峰、液态垫/信号静默）。buildPage 传入的 animation
/// 是 ModalRoute 的 offstage 代理（入场首帧指向 kAlwaysCompleteAnimation），
/// initState 恒读到 completed value=1.00 即时落定，内容恒直接构建渲染。
class _RouteDeferredBody extends StatefulWidget {
  const _RouteDeferredBody({required this.builder, required this.animation});

  final WidgetBuilder builder;

  final Animation<double> animation;

  @override
  State<_RouteDeferredBody> createState() => _RouteDeferredBodyState();
}

class _RouteDeferredBodyState extends State<_RouteDeferredBody> {
  late bool _settled = widget.animation.value >= 1.0;
  // 勿改回 late：late 字段首次访问才初始化，唯一访问点在 settled 打点处，
  // 那时才 start() 导致 elapsed 恒 0ms，日志会误导为「转场瞬跳 1.0」
  final Stopwatch _sinceInit = Stopwatch()..start();
  VoidCallback? _listener;

  @override
  void initState() {
    super.initState();
    AppLog.debug(
      'nav',
      'defer init t=${DateTime.now().millisecondsSinceEpoch % 1000000} '
      'status=${widget.animation.status} '
      'value=${widget.animation.value.toStringAsFixed(2)}',
    );
    if (_settled) return;
    _listener = _onTick;
    widget.animation.addListener(_listener!);
  }

  // 值监听即落定真值，不依赖 status 语义边角；逐帧比较只是一次 double 判断
  void _onTick() {
    if (widget.animation.value < 1.0) return;
    _cleanup();
    AppLog.debug('nav', 'defer settled +${_sinceInit.elapsedMilliseconds}ms');
    if (mounted) setState(() => _settled = true);
  }

  void _cleanup() {
    final listener = _listener;
    if (listener != null) widget.animation.removeListener(listener);
    _listener = null;
  }

  @override
  void dispose() {
    _cleanup();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_settled) return widget.builder(context);
    return const SizedBox.expand();
  }
}
