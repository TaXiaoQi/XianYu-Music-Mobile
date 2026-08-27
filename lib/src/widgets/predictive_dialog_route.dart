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
              return _DialogPredictiveBackTransition(
                animation: animation,
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

/// 弹窗的预测性返回跟手过渡。
///
/// 与「整页×圆角矩形」的系统式缩屏不同，居中小弹窗如果整屏缩进会很重，
/// 还容易因提交阶段额外做一次朝右上角的位移而与手指脱节。这里改为一整段
/// 与手指完全同步的单一进度：
/// - 手势期间按 `animation.value`（== 1 - 系统 progress）一路跟手；
/// - 居中轻缩放（1.0→0.90）+ 纵向微随手指 + 整体淡出；
/// - 松手提交时沿同一曲线平滑收到终点（不再弹跳/跳角），观感连贯，接近
///   系统/Edge/Telegram 那种「一路跟着缩小下去」的丝滑感。
class _DialogPredictiveBackTransition extends StatefulWidget {
  const _DialogPredictiveBackTransition({
    required this.animation,
    required this.startBackEvent,
    required this.currentBackEvent,
    required this.child,
  });

  final Animation<double> animation;
  final PredictiveBackEvent? startBackEvent;
  final PredictiveBackEvent? currentBackEvent;
  final Widget child;

  @override
  State<_DialogPredictiveBackTransition> createState() =>
      _DialogPredictiveBackTransitionState();
}

class _DialogPredictiveBackTransitionState
    extends State<_DialogPredictiveBackTransition> {
  static const double _kShrink = 0.10; // 1.0 -> 0.90
  static const double _kMaxShift = 36.0;

  double _lastShiftY = 0;

  double _shiftY(double screenH) {
    final from = widget.startBackEvent?.touchOffset?.dy;
    final to = widget.currentBackEvent?.touchOffset?.dy;
    // 提交阶段事件被清空，沿用抬手前最后一刻的位移，避免松手瞬间回弹跳位。
    if (from == null || to == null) return _lastShiftY;
    final raw = to - from;
    final eased = Curves.easeOut.transform((raw.abs() / screenH).clamp(0.0, 1.0));
    return _lastShiftY =
        (eased * raw.sign * _kMaxShift).clamp(-_kMaxShift, _kMaxShift);
  }

  @override
  Widget build(BuildContext context) {
    final screenH = MediaQuery.sizeOf(context).height;
    return AnimatedBuilder(
      animation: widget.animation,
      builder: (context, child) {
        // 手指未动时 animation.value 归一为 0，进/退过程中单调走到 1（收起），
        // 提交时不额外起动画，同一进度一路收尾 → 连贯。
        final t = widget.animation.value.clamp(0.0, 1.0).toDouble();
        final eased = Curves.easeIn.transform(t);
        final scale = 1.0 - _kShrink * eased;
        final opacity = 1.0 - Curves.easeInOut.transform(t);
        final shiftY = _shiftY(screenH) * (1 - 0.4 * t);
        return Opacity(
          opacity: opacity.clamp(0.0, 1.0),
          child: Transform.translate(
            offset: Offset(0, shiftY),
            child: Transform.scale(
              scale: scale,
              alignment: Alignment.center,
              child: child,
            ),
          ),
        );
      },
      child: widget.child,
    );
  }
}
