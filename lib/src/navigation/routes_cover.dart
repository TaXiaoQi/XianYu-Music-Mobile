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
  bool get popGestureEnabled => isCurrent && _livePredictiveBack(navigator?.context, predictiveBack);

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
    // defer 必须监听真控制器而非 buildPage 的 animation 参数：ModalRoute
    // 在入场首帧把路由置 offstage，animation 代理临时指向
    // kAlwaysCompleteAnimation（供 Hero 测量终位），initState 恒读到
    // completed value=1.00，defer 从未生效。controller.view 才是转场真值。
    return AppPageBackground(
        child: _RouteDeferredBody(
            builder: builder, animation: controller!.view));
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
    return PredictiveBackGestureDetector(
      route: this,
      builder: (context, phase, startBackEvent, currentBackEvent) {
        if (_isSmooth(context)) {
          return _SmoothFadeForwards(
            animation: animation,
            secondaryAnimation: secondaryAnimation,
            child: child,
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
        if (isPortrait && phase != PredictiveBackPhase.idle) {
          // 预测返回手势期（含 commit/cancel 收尾）：Android 16 同款整页
          // 缩小卡片（缩放+贴边位移+圆角+纵向跟随），下层页面从缩小露出
          // 的区域透出。此前手势期沿用平移基线，观感是「整页盖走」而非
          // 官方缩小返回
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
        return SlideTransition(
          position: Tween<Offset>(begin: begin, end: Offset.zero)
              .animate(curved),
          child: content,
        );
      },
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
  bool get popGestureEnabled => isCurrent && _livePredictiveBack(navigator?.context, predictiveBack);

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
    // 同 _CoverRoute：监听 controller.view 而非 offstage 代理
    return AppPageBackground(
        child: _RouteDeferredBody(
            builder: builder, animation: controller!.view));
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
    return PredictiveBackGestureDetector(
      route: this,
      builder: (context, phase, startBackEvent, currentBackEvent) {
        if (_isSmooth(context)) {
          final smooth = _SmoothFadeForwards(
            animation: animation,
            secondaryAnimation: secondaryAnimation,
            child: child,
          );
          if (phase == PredictiveBackPhase.idle) return smooth;
          return TransitionBackdrop(
            child: Stack(
              children: [
                smooth,
                PredictiveCoverReturnView(animation: animation),
              ],
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
        final Widget transition;
        if (isPortrait && phase != PredictiveBackPhase.idle) {
          // 手势期（含 commit/cancel 收尾）：整页缩小卡片，同 _CoverRoute；
          // 飞回封面（PredictiveCoverReturnView）继续叠加在其上
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
            reverseCurve: isPortrait ? Curves.linear : Curves.easeOut.flipped,
          );
          final begin = isPortrait ? const Offset(1, 0) : const Offset(0.25, 0);
          transition = SlideTransition(
            position: Tween<Offset>(begin: begin, end: Offset.zero)
                .animate(curved),
            child: content,
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
    );
  }
}

/// cover 覆盖路由页体延迟构建：转场动画落定前只渲染背景空壳，落定后才
/// 调 builder 构建页面。本地页数据同步可读，此前挂载即全量构建+布局+
/// 封面解码与 250ms 转场逐帧叠加，是列表页（本地歌曲/喜欢/最近/歌单）
/// 与设置页 push 掉帧源；在线页网络异步天然错峰，本组件把本地页拉齐
/// 同构观感（转场滑入背景、落定内容浮现）。落定后挂载的列表 StaggerIn
/// 逐行入场（此时 route animation 已 completed、零延迟）无缝衔接。
/// push 后立即 pop 的路径动画走 reverse 永不 completed，listener 随
/// route.dispose 回收，页面从未构建无副作用。
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
