import 'dart:ui' show clampDouble;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 让任意 [PageRoute] 参与 Android 预测返回的公共转场组件。
///
/// 系统预测返回手势开始时，[WidgetsBinding] 会遍历所有
/// [WidgetsBindingObserver]，只有返回 true 的 observer 才会被认领并驱动跟手
/// 动画；否则 commit 时直接 [WidgetsBinding.handlePopRoute]（无跟手行程）。
/// 因此任何需要跟手行程的路由（弹窗、播放页、普通二级页面）都必须挂载
/// [PredictiveBackGestureDetector]。
///
/// 用法：在路由的 [PageRoute.buildTransitions] 中包裹本组件，手势进行时
/// （`route.popGestureInProgress`）渲染 [PredictiveBackSharedElementPageTransition]
/// 跟手缩放，非手势的打开/关闭（按钮、编程、系统返回）渲染自定义转场。
class PredictiveBackGestureDetector extends StatefulWidget {
  const PredictiveBackGestureDetector({super.key, required this.route, required this.builder});

  final PredictiveBackGestureDetectorWidgetBuilder builder;
  final PageRoute<dynamic> route;

  @override
  State<PredictiveBackGestureDetector> createState() => _PredictiveBackGestureDetectorState();
}

class _PredictiveBackGestureDetectorState extends State<PredictiveBackGestureDetector>
    with WidgetsBindingObserver {
  /// True when the predictive back gesture is enabled.
  bool get _isEnabled {
    return widget.route.isCurrent && widget.route.popGestureEnabled;
  }

  PredictiveBackPhase get phase => _phase;
  PredictiveBackPhase _phase = PredictiveBackPhase.idle;
  set phase(PredictiveBackPhase phase) {
    if (_phase != phase && mounted) {
      setState(() => _phase = phase);
    }
  }

  /// 本路由是否真正认领了当前手势。
  ///
  /// `WidgetsBindingObserver` 的预测返回回调是**全局广播**：任何路由的手势
  /// 都会通知到所有 detector。`popGestureInProgress` 又是 navigator 全局
  /// 标志（`isCurrent && userGestureInProgress`）——弹窗提交 pop 的几帧里
  /// `userGestureInProgress` 仍为 true、下层路由已变回 current，下层会
  /// 误判「自己正被手势返回」而切入跟手转场分支（内部 Transform 子树以
  /// 无效事件重建），在布局完成前被绘制导致
  /// `RenderBox was not laid out: RenderTransform` 崩溃。因此分支判断只信
  /// 本路由自己认领的手势，不信全局标志。
  bool _owned = false;

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
    final bool gestureInProgress = !backEvent.isButtonEvent && _isEnabled;
    if (!gestureInProgress) {
      // 未认领：不置 phase、不残留状态（此前无条件置 start 会污染其他
      // 路由手势期间本 detector 的 phase）。
      return false;
    }
    _owned = true;
    phase = PredictiveBackPhase.start;

    widget.route.handleStartBackGesture(progress: 1 - backEvent.progress);
    startBackEvent = currentBackEvent = backEvent;
    return true;
  }

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent backEvent) {
    if (!_owned) return;
    phase = PredictiveBackPhase.update;

    widget.route.handleUpdateBackGestureProgress(progress: 1 - backEvent.progress);
    currentBackEvent = backEvent;
  }

  @override
  void handleCancelBackGesture() {
    if (!_owned) return;
    _owned = false;
    // 取消后立刻回到 idle：跟手分支退出，路由自身的反向过渡随动画回弹
    //（与原先经 popGestureInProgress 门控后的实际行为一致）。
    phase = PredictiveBackPhase.idle;

    widget.route.handleCancelBackGesture();
    startBackEvent = currentBackEvent = null;
  }

  @override
  void handleCommitBackGesture() {
    if (!_owned) return;
    _owned = false;
    // 提交后立刻回到 idle：pop 动画由路由自身的反向过渡接管（isCurrent 在
    // pop 开始即失效，与原先经 popGestureInProgress 门控后的实际行为一致），
    // 同时避免本 detector 残留 commit 桩状态。
    phase = PredictiveBackPhase.idle;

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
    // 非认领路由恒为 idle：其他路由（如上层弹窗）的手势期间，本路由的
    // builder 不会进入跟手转场分支，保持静止。
    return widget.builder(
      context,
      _owned ? phase : PredictiveBackPhase.idle,
      _owned ? startBackEvent : null,
      _owned ? currentBackEvent : null,
    );
  }
}

/// 覆盖式安卓转场 [PageTransitionsBuilder]。
///
/// 非手势的打开/关闭用「新页从右侧滑入覆盖旧页、旧页静止」的经典覆盖式动画
/// （贴近 Android 原生 Nagivate 覆盖，区别于 M3 FadeForwards 的「两页并排
/// 横切+淡入」）。开启预测返回时（[PredictiveBackPageTransitionsBuilder] 之外
/// 也可用本类），手势中走官方整屏缩放跟手，非手势沿用覆盖滑动。
class CoverPageTransitionsBuilder extends PageTransitionsBuilder {
  const CoverPageTransitionsBuilder({this.predictiveBack = true, this.backgroundColor});

  /// 是否在 Android 13+ 接管预测返回手势做跟手行程。
  final bool predictiveBack;

  /// 转场/预测返回时露出的底色（对齐根层真实底色），防止切换瞬间露出透底层。
  final Color? backgroundColor;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 420);

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (!predictiveBack) {
      return _coverSlide(context, animation, child);
    }
    return PredictiveBackGestureDetector(
      route: route,
      builder: (context, phase, startBackEvent, currentBackEvent) {
        // 只在本路由认领的手势中走跟手分支（phase 非 idle），不信 navigator
        // 全局的 popGestureInProgress——否则上层弹窗提交后的几帧里本页会误入
        // 跟手分支引发布局崩溃。
        if (phase != PredictiveBackPhase.idle) {
          // 手势跟手中整屏缩放，会露出本页透底层，故同样铺根层底色，
          // 避免出现透明/黑底闪烁。
          return _withBackground(
            context,
            PredictiveBackSharedElementPageTransition(
              animation: animation,
              phase: phase,
              secondaryAnimation: secondaryAnimation,
              startBackEvent: startBackEvent,
              currentBackEvent: currentBackEvent,
              child: child,
            ),
          );
        }
        return _coverSlide(context, animation, child);
      },
    );
  }

  /// 铺一层根层真实底色（与 [CoverPageTransitionsBuilder.backgroundColor] 一致）。
  Widget _withBackground(BuildContext context, Widget layer) {
    return TransitionBackdrop(
      backgroundColor: backgroundColor,
      child: layer,
    );
  }

  /// 覆盖滑动：本页从右滑入盖住旧页，旧页不动（不参与 secondaryAnimation，
  /// 因而 push 时上一页原地静止、pop 时本页右滑退场）。底部铺一层根层底色，
  /// 让切换全程稳定填充、不露透。
  Widget _coverSlide(BuildContext context, Animation<double> animation, Widget child) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        // 底色固定在底层，不随页面滑动，仅作为切换期间的稳定背景。
        const TransitionBackdrop(),
        SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(1, 0),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        ),
      ],
    );
  }
}

/// 转场/预测返回手势中铺在路由底部的「根层背景」垫底。
///
/// 铺 [backgroundColor]（无值时退回 scaffoldBackgroundColor），保证 opaque
/// 路由不露出 Navigator 之外的透底层。壁纸模式下根层已铺壁纸、页面 Scaffold
/// 透明透出壁纸，此处的实色垫底只会在转场瞬间短暂出现——壁纸只是替换底色，
/// 垫底色即壁纸所替代的那个底色，视觉连续。
class TransitionBackdrop extends StatelessWidget {
  const TransitionBackdrop({super.key, this.backgroundColor, this.child});

  final Color? backgroundColor;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: backgroundColor ?? Theme.of(context).scaffoldBackgroundColor,
      ),
      child: child,
    );
  }
}

/// The phases of a predictive back gesture.
enum PredictiveBackPhase {
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

typedef PredictiveBackGestureDetectorWidgetBuilder =
    Widget Function(
      BuildContext context,
      PredictiveBackPhase phase,
      PredictiveBackEvent? startBackEvent,
      PredictiveBackEvent? currentBackEvent,
    );

/// Android's predictive back page shared element transition.
class PredictiveBackSharedElementPageTransition extends StatefulWidget {
  const PredictiveBackSharedElementPageTransition({
    super.key,
    required this.animation,
    required this.secondaryAnimation,
    required this.phase,
    required this.startBackEvent,
    required this.currentBackEvent,
    required this.child,
  });

  final Animation<double> animation;
  final Animation<double> secondaryAnimation;
  final PredictiveBackPhase phase;
  final PredictiveBackEvent? startBackEvent;
  final PredictiveBackEvent? currentBackEvent;
  final Widget child;

  @override
  State<PredictiveBackSharedElementPageTransition> createState() =>
      _PredictiveBackSharedElementPageTransitionState();
}

class _PredictiveBackSharedElementPageTransitionState
    extends State<PredictiveBackSharedElementPageTransition>
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
      PredictiveBackPhase.commit => _curvedAnimationReversed,
      _ => widget.animation,
    };

    _bounceAnimation.parent = switch (widget.phase) {
      PredictiveBackPhase.commit => Tween<double>(
        begin: 0.0,
        end: _lastBounceAnimationValue,
      ).animate(_curvedAnimation!),
      _ => ReverseAnimation(widget.animation),
    };

    _commitAnimation.parent = switch (widget.phase) {
      PredictiveBackPhase.commit => _animation,
      _ => kAlwaysDismissedAnimation,
    };

    final double xShift = (screenSize.width / _kDivisionFactor) - _kMargin;
    _positionAnimation = _animation.drive(switch (widget.phase) {
      PredictiveBackPhase.commit => Tween<Offset>(
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
  void didUpdateWidget(PredictiveBackSharedElementPageTransition oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.animation != oldWidget.animation) {
      _updateCurvedAnimations();
    }
    // 另一路由的手势进行期间（popGestureInProgress 是 navigator 全局的）本组件
    // 可能以 null 的 back event 被重建，_positionAnimation 由空事件算出（默认左缘）。
    // 真正手势到达且 swipeEdge 变化时不会触发 commit 分支，方向 tween 永远错——
    // 故 swipeEdge 变化时也重新计算动画（对齐 PiliNara 的框架补丁做法）。
    if ((widget.phase != oldWidget.phase && widget.phase == PredictiveBackPhase.commit) ||
        (widget.currentBackEvent != null &&
            widget.currentBackEvent?.swipeEdge != oldWidget.currentBackEvent?.swipeEdge)) {
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
              PredictiveBackPhase.commit => _positionAnimation.value,
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
