import 'dart:ui' show clampDouble;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 让弹窗参与 Android 预测返回的自定义页面路由。
///
/// 原生 [DialogRoute]（showDialog 产生）不是 PageRoute，Navigator 的预测返回
/// 接管器（_PredictiveBackGestureDetectorState）要求 `route.isCurrent &&
/// route.popGestureEnabled` 才会返回 true——只有用
/// [PredictiveBackPageTransitionsBuilder] 构建过渡的页面路由满足。因此普通
/// 弹窗在预测返回手势下既无跟手行程也无法跟手，只走一次性 pop。
///
/// 本路由把弹窗建模为 [PageRoute]，过渡交给
/// [PredictiveBackPageTransitionsBuilder]，让弹窗获得与二级页面一致的预测
/// 返回「行程」：手指拖动时整屏缩放成圆角矩形跟随，松手提交即关闭弹窗。
///
/// 预测返回的「手指信息」（progress/swipeEdge/touchOffset）由系统经
/// `OnBackInvokedCallback` 下发给框架，框架再通过 [TransitionRoute] 的默认
/// 钩子把 progress 写进路由动画控制器驱动缩放。这里**不做任何自定义手势
/// 接管、也不留兜底**，完全照抄 PiliNara/main 的做法——只提供
/// [PredictiveBackPageTransitionsBuilder] 并保持默认钩子不变，因此同一设备上
/// 能得到与二级页面完全一致的跟手行程。
///
/// 使用要点：必须经 root Navigator push（GoRouter 的预测返回只认 root
/// Navigator）；不要包在 showDialog 里，直接调用 [Navigator.push] 或
/// [showPredictiveDialog]。
class PredictiveBackDialogRoute<T> extends PageRoute<T> {
  PredictiveBackDialogRoute({
    required this.builder,
    this.dismissible = false,
    this.closableByBack = true,
    super.settings,
  });

  final WidgetBuilder builder;

  /// 是否能点击遮罩关闭（桌面端「禁止关闭」语义：默认 false）。
  final bool dismissible;

  /// 系统返回 / 预测返回能否关闭弹窗（Android 标准：返回关闭与点遮罩解耦，
  /// 默认 true，即使点遮罩/下滑被禁用也能用返回关闭）。
  final bool closableByBack;

  @override
  bool get opaque => false;

  @override
  bool get maintainState => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 300);

  @override
  bool get barrierDismissible => dismissible;

  @override
  String? get barrierLabel => dismissible ? 'Close' : null;

  // 遮罩由 buildPage 自行绘制，路由层不透出 barrier。
  @override
  Color? get barrierColor => null;

  // 满足预测返回接管条件：成为当前页且允许「返回关闭」时，返回手势才跟手。
  // 预测返回手势本身交给 TransitionRoute 的默认实现即可（与 PiliNara 一致）。
  @override
  bool get popGestureEnabled => isCurrent && closableByBack;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final scrim =
        (isDark ? Colors.black : Colors.black).withValues(alpha: isDark ? 0.54 : 0.32);
    // 点遮罩关闭由 dismissible 控制；返回与预测返回由 closableByBack 控制。
    // 两者独立：桌面端语义默认禁用点遮罩关闭，但 Android 返回仍能关闭弹窗。
    return PopScope(
      canPop: closableByBack,
      child: Material(
        type: MaterialType.transparency,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 半透明遮罩：dismissible 时点击关掉，否则拦截点击不穿透。
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: dismissible ? () => Navigator.of(context).pop() : null,
              child: Container(color: scrim),
            ),
            Center(child: builder(context)),
          ],
        ),
      ),
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // 关键：必须「始终」挂载 _PredictiveBackGestureDetector（WidgetsBinding
    // observer），否则手势开始时（popGestureInProgress 仍为 false）没有
    // observer 认领预测返回，弹窗全程无跟手反馈，只能滑到系统提交阈值才
    // 瞬间关闭——表现为「要滑很长一段才有反应」。detector 内部再按
    // popGestureInProgress 分流：手势中走官方 predictive 过渡（整屏缩放跟手），
    // 非手势的打开/关闭（按钮、编程、系统返回）用纯淡入淡出。
    return _PredictiveBackGestureDetector(
      route: this,
      builder:
          (
            BuildContext context,
            _PredictiveBackPhase phase,
            PredictiveBackEvent? startBackEvent,
            PredictiveBackEvent? currentBackEvent,
          ) {
            if (popGestureInProgress) {
              return _PredictiveBackSharedElementPageTransition(
                animation: animation,
                phase: phase,
                secondaryAnimation: secondaryAnimation,
                startBackEvent: startBackEvent,
                currentBackEvent: currentBackEvent,
                child: child,
              );
            }
            final curved = CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
              reverseCurve: Curves.easeInCubic,
            );
            return FadeTransition(opacity: curved, child: child);
          },
    );
  }
}

/// 打开一个支持预测返回的弹窗（root Navigator，可被返回手势跟手关闭）。
Future<T?> showPredictiveDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = false,
  bool closableByBack = true,
}) {
  final navigator = Navigator.of(context, rootNavigator: true);
  return navigator.push<T>(
    PredictiveBackDialogRoute<T>(
      builder: builder,
      dismissible: barrierDismissible,
      closableByBack: closableByBack,
    ),
  );
}

// ---------------------------------------------------------------------------
// 以下两个类照抄 Flutter framework 的 _PredictiveBackGestureDetector 与
// _PredictiveBackSharedElementPageTransition（BSD-3-Clause），保证与系统二级
// 页面完全一致的预测返回跟手行程。区别仅在于非手势分支使用本项目的纯淡入
// 淡出，而非框架的 FadeForwards 回退。
// ---------------------------------------------------------------------------

/// The phases of a predictive back gesture.
enum _PredictiveBackPhase {
  /// There is no active predictive back gesture in progress.
  idle,

  /// The user pointer has contacted the screen.
  start,

  /// The user pointer has moved.
  update,

  /// The user pointer has released in a position in which Android has
  /// determined that the back gesture is successful and the current route
  /// should be popped.
  commit,

  /// The user pointer has released in a position in which Android has
  /// determined that the back gesture should be canceled and the original route
  /// should be shown.
  cancel,
}

typedef _PredictiveBackGestureDetectorWidgetBuilder =
    Widget Function(
      BuildContext context,
      _PredictiveBackPhase phase,
      PredictiveBackEvent? startBackEvent,
      PredictiveBackEvent? currentBackEvent,
    );

class _PredictiveBackGestureDetector extends StatefulWidget {
  const _PredictiveBackGestureDetector({required this.route, required this.builder});

  final _PredictiveBackGestureDetectorWidgetBuilder builder;
  final PageRoute<dynamic> route;

  @override
  State<_PredictiveBackGestureDetector> createState() => _PredictiveBackGestureDetectorState();
}

class _PredictiveBackGestureDetectorState extends State<_PredictiveBackGestureDetector>
    with WidgetsBindingObserver {
  /// True when the predictive back gesture is enabled.
  bool get _isEnabled {
    return widget.route.isCurrent && widget.route.popGestureEnabled;
  }

  _PredictiveBackPhase get phase => _phase;
  _PredictiveBackPhase _phase = _PredictiveBackPhase.idle;
  set phase(_PredictiveBackPhase phase) {
    if (_phase != phase && mounted) {
      setState(() => _phase = phase);
    }
  }

  /// The back event when the gesture first started.
  PredictiveBackEvent? get startBackEvent => _startBackEvent;
  PredictiveBackEvent? _startBackEvent;
  set startBackEvent(PredictiveBackEvent? startBackEvent) {
    if (_startBackEvent != startBackEvent && mounted) {
      setState(() => _startBackEvent = startBackEvent);
    }
  }

  /// The most recent back event during the gesture.
  PredictiveBackEvent? get currentBackEvent => _currentBackEvent;
  PredictiveBackEvent? _currentBackEvent;
  set currentBackEvent(PredictiveBackEvent? currentBackEvent) {
    if (_currentBackEvent != currentBackEvent && mounted) {
      setState(() => _currentBackEvent = currentBackEvent);
    }
  }

  // Begin WidgetsBindingObserver.

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) {
    phase = _PredictiveBackPhase.start;
    final bool gestureInProgress = !backEvent.isButtonEvent && _isEnabled;
    if (!gestureInProgress) {
      return false;
    }

    widget.route.handleStartBackGesture(progress: 1 - backEvent.progress);
    startBackEvent = currentBackEvent = backEvent;
    return true;
  }

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent backEvent) {
    phase = _PredictiveBackPhase.update;

    widget.route.handleUpdateBackGestureProgress(progress: 1 - backEvent.progress);
    currentBackEvent = backEvent;
  }

  @override
  void handleCancelBackGesture() {
    phase = _PredictiveBackPhase.cancel;

    widget.route.handleCancelBackGesture();
    startBackEvent = currentBackEvent = null;
  }

  @override
  void handleCommitBackGesture() {
    phase = _PredictiveBackPhase.commit;

    widget.route.handleCommitBackGesture();
    startBackEvent = currentBackEvent = null;
  }

  // End WidgetsBindingObserver.

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final _PredictiveBackPhase effectivePhase = widget.route.popGestureInProgress
        ? phase
        : _PredictiveBackPhase.idle;
    return widget.builder(context, effectivePhase, startBackEvent, currentBackEvent);
  }
}

/// Android's predictive back page shared element transition.
class _PredictiveBackSharedElementPageTransition extends StatefulWidget {
  const _PredictiveBackSharedElementPageTransition({
    required this.animation,
    required this.secondaryAnimation,
    required this.phase,
    required this.startBackEvent,
    required this.currentBackEvent,
    required this.child,
  });

  final Animation<double> animation;
  final Animation<double> secondaryAnimation;
  final _PredictiveBackPhase phase;
  final PredictiveBackEvent? startBackEvent;
  final PredictiveBackEvent? currentBackEvent;
  final Widget child;

  @override
  State<_PredictiveBackSharedElementPageTransition> createState() =>
      _PredictiveBackSharedElementPageTransitionState();
}

class _PredictiveBackSharedElementPageTransitionState
    extends State<_PredictiveBackSharedElementPageTransition>
    with SingleTickerProviderStateMixin {
  // Constants as per the motion specs
  // https://developer.android.com/design/ui/mobile/guides/patterns/predictive-back#motion-specs
  static const double _kMinScale = 0.90;
  static const double _kDivisionFactor = 20.0;
  static const double _kMargin = 8.0;
  static const double _kYPositionFactor = 0.1;

  // The duration of the commit transition.
  //
  // This is not the same as PredictiveBackPageTransitionsBuilder's duration,
  // which is the duration of widget.animation, so an Interval is used.
  static const int _kCommitMilliseconds = 400;
  static const Curve _kCurve = Curves.easeInOutCubicEmphasized;
  static const Interval _kCommitInterval = Interval(
    0.0,
    _kCommitMilliseconds / FadeForwardsPageTransitionsBuilder.kTransitionMilliseconds,
    curve: _kCurve,
  );

  // A fallback corner radius used when the display corner radii are
  // unavailable (e.g., on Android API levels below 31, iOS, and other
  // platforms).
  static const double _kDeviceBorderRadius = 32.0;

  // Provides a smooth transition between the default radius and the
  // _kDeviceBorderRadius, when the display corner radii are unavailable.
  final Tween<double> _borderRadiusTween = Tween<double>(begin: 0.0, end: _kDeviceBorderRadius);

  // The route fades out after commit.
  final Tween<double> _opacityTween = Tween<double>(begin: 1.0, end: 0.0);

  // The route shrinks during the gesture and animates back to normal after
  // commit.
  final Tween<double> _scaleTween = Tween<double>(begin: 1.0, end: _kMinScale);

  // An animation that stays constant at zero before the commit, and after the
  // commit goes from zero to one.
  final ProxyAnimation _commitAnimation = ProxyAnimation();

  // An animation that goes from zero to a maximum of one during a predictive
  // back gesture, and then at commit, it goes from its current value to zero.
  // Used for animations that follow the gesture and then animate back to their
  // original value after commit.
  final ProxyAnimation _bounceAnimation = ProxyAnimation();
  double _lastBounceAnimationValue = 0.0;

  // An animation that proxies to widget.animation during the gesture and then
  // to _commitAnimation after the commit. So, it goes from zero to a maximum of
  // one before commit, and then after commit goes from zero to one again.
  final ProxyAnimation _animation = ProxyAnimation();

  /// The same as widget.animation but with a curve applied.
  CurvedAnimation? _curvedAnimation;

  /// The reverse of _curvedAnimation.
  CurvedAnimation? _curvedAnimationReversed;

  late Animation<Offset> _positionAnimation;

  Offset _lastDrag = Offset.zero;

  // This isn't done as an animation because it's based on the vertical drag
  // amount, not the progression of the back gesture like widget.animation is.
  double _getYShiftPosition(double screenHeight) {
    final double startTouchY = widget.startBackEvent?.touchOffset?.dy ?? 0;
    final double currentTouchY = widget.currentBackEvent?.touchOffset?.dy ?? 0;

    final double yShiftMax = (screenHeight / _kDivisionFactor) - _kMargin;

    final double rawYShift = currentTouchY - startTouchY;
    final double easedYShift =
        Curves.easeOut.transform(clampDouble(rawYShift.abs() / screenHeight, 0.0, 1.0)) *
        rawYShift.sign *
        yShiftMax;

    return clampDouble(easedYShift, -yShiftMax, yShiftMax);
  }

  void _updateAnimations(Size screenSize) {
    _animation.parent = switch (widget.phase) {
      _PredictiveBackPhase.commit => _curvedAnimationReversed,
      _ => widget.animation,
    };

    _bounceAnimation.parent = switch (widget.phase) {
      _PredictiveBackPhase.commit => Tween<double>(
        begin: 0.0,
        end: _lastBounceAnimationValue,
      ).animate(_curvedAnimation!),
      _ => ReverseAnimation(widget.animation),
    };

    _commitAnimation.parent = switch (widget.phase) {
      _PredictiveBackPhase.commit => _animation,
      _ => kAlwaysDismissedAnimation,
    };

    final double xShift = (screenSize.width / _kDivisionFactor) - _kMargin;
    _positionAnimation = _animation.drive(switch (widget.phase) {
      _PredictiveBackPhase.commit => Tween<Offset>(
        begin: _lastDrag,
        end: Offset(screenSize.height * _kYPositionFactor, 0.0),
      ),
      _ => Tween<Offset>(
        // The y position before commit is given by the vertical drag, not by an
        // animation.
        begin: switch (widget.currentBackEvent?.swipeEdge) {
          SwipeEdge.left => Offset(xShift, _getYShiftPosition(screenSize.height)),
          SwipeEdge.right => Offset(-xShift, _getYShiftPosition(screenSize.height)),
          null => Offset(xShift, _getYShiftPosition(screenSize.height)),
        },
        end: Offset.zero,
      ),
    });
  }

  void _updateCurvedAnimations() {
    _curvedAnimation?.dispose();
    _curvedAnimationReversed?.dispose();
    _curvedAnimation = CurvedAnimation(parent: widget.animation, curve: _kCommitInterval);
    _curvedAnimationReversed = CurvedAnimation(
      parent: ReverseAnimation(widget.animation),
      curve: _kCommitInterval,
    );
  }

  @override
  void didUpdateWidget(_PredictiveBackSharedElementPageTransition oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.animation != oldWidget.animation) {
      _updateCurvedAnimations();
    }
    if (widget.phase != oldWidget.phase && widget.phase == _PredictiveBackPhase.commit) {
      _updateAnimations(MediaQuery.sizeOf(context));
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateCurvedAnimations();
    _updateAnimations(MediaQuery.sizeOf(context));
  }

  @override
  void dispose() {
    _curvedAnimation!.dispose();
    _curvedAnimationReversed!.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.animation,
      builder: (BuildContext context, Widget? child) {
        _lastBounceAnimationValue = _bounceAnimation.value;
        return Transform.scale(
          scale: _scaleTween.evaluate(_bounceAnimation),
          child: Transform.translate(
            offset: switch (widget.phase) {
              _PredictiveBackPhase.commit => _positionAnimation.value,
              _ => _lastDrag = Offset(
                _positionAnimation.value.dx,
                _getYShiftPosition(MediaQuery.heightOf(context)),
              ),
            },
            child: Opacity(
              opacity: _opacityTween.evaluate(_commitAnimation),
              child: ClipRRect(
                borderRadius:
                    MediaQuery.displayCornerRadiiOf(context) ??
                    BorderRadius.circular(_borderRadiusTween.evaluate(_bounceAnimation)),
                child: child,
              ),
            ),
          ),
        );
      },
      child: widget.child,
    );
  }
}
