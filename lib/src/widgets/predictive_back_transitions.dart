import 'dart:ui' show clampDouble;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/application_logger.dart';
// 循环依赖说明：detector 需要感知播放页开合来做跨 navigator 认领互斥
//（routes.dart 已 import 本文件；本文件仅取其顶层 notifier/key，无初始化环）
import '../navigation/routes.dart'
    show playerNavigatorKey, playerOpenNotifier;

const bool kFrameworkPredictiveCompare = false;

/// 预测返回手势的可用屏宽（逻辑像素）：合成进度按首触点到当前触点的
/// 横向位移占屏宽比例计算。
double predictiveBackScreenWidth() {
  final view = WidgetsBinding.instance.platformDispatcher.implicitView;
  final size = view?.physicalSize;
  if (view == null || size == null || size.isEmpty) return 360;
  return size.width / view.devicePixelRatio;
}

/// 系统手势进度合成器（ROM 门控兜底）。
///
/// 部分系统认领预测返回后逐帧 progress 恒 0（引擎送达值恒 0，见
/// MainActivity.registerBackGestureObserver 注释），页面全程不动、松手
/// 直接跳 commit/cancel。用触点位移合成进度驱动动画：
///  · 连续 2 帧零进度且位移 >24px 才接管——真系统从第 1 帧就吐真进度，
///    永不进入合成，行为不变；
///  · 接管瞬间以当帧位移为进度原点：页面从静止连续起步，消除「前几帧
///    不动、接管帧瞬跳到已滑距离」的开始端抽搐；
///  · 系统 micro 噪声（孤立 1~2 帧 p>0.02，实测在 commit 前吐 0.05/0.117）
///    不交还：单帧毛刺就关闭合成会让页面在合成进度与系统微值之间来回
///    瞬跳（中途回跳抽搐），连续 3 帧有效进度才认定系统真正接管。
class BackGestureProgressSynth {
  Offset? firstTouch;

  int updateCount = 0;

  int zeroStreak = 0;

  int sysStreak = 0;

  bool synth = false;

  bool engagedThisFrame = false;

  double lastProgress = 0;

  double _signedAtEngage = 0;

  void reset() {
    firstTouch = null;
    updateCount = 0;
    zeroStreak = 0;
    sysStreak = 0;
    synth = false;
    engagedThisFrame = false;
    lastProgress = 0;
    _signedAtEngage = 0;
  }

  double _signedDelta(PredictiveBackEvent backEvent) {
    final touch = backEvent.touchOffset;
    if (touch == null || firstTouch == null) return 0;
    final dx = touch.dx - firstTouch!.dx;
    return backEvent.swipeEdge == SwipeEdge.right ? -dx : dx;
  }

  /// 消费一帧系统事件，返回该帧应使用的有效进度（0~1）。
  double progressOf(PredictiveBackEvent backEvent) {
    final touch = backEvent.touchOffset;
    firstTouch ??= touch;
    updateCount++;
    engagedThisFrame = false;
    final p = backEvent.progress;
    lastProgress = p;
    if (p <= 0.001) {
      zeroStreak++;
      sysStreak = 0;
    } else {
      zeroStreak = 0;
      sysStreak = p > 0.02 ? sysStreak + 1 : 0;
      if (sysStreak >= 3) synth = false;
    }
    final displaced = firstTouch != null && touch != null &&
        (touch - firstTouch!).distance > 24;
    if (!synth && p <= 0.001 && zeroStreak >= 2 && displaced) {
      synth = true;
      engagedThisFrame = true;
      _signedAtEngage = _signedDelta(backEvent);
    }
    double effective = p;
    if (synth) {
      final s = (_signedDelta(backEvent) - _signedAtEngage) /
          predictiveBackScreenWidth();
      if (s > p) effective = clampDouble(s, 0.0, 1.0);
    }
    return effective;
  }
}

class PredictiveBackGestureDetector extends StatefulWidget {
  const PredictiveBackGestureDetector({super.key, required this.route, required this.builder});

  final PredictiveBackGestureDetectorWidgetBuilder builder;
  final PageRoute<dynamic> route;

  @override
  State<PredictiveBackGestureDetector> createState() => _PredictiveBackGestureDetectorState();
}

class _PredictiveBackGestureDetectorState extends State<PredictiveBackGestureDetector>
    with WidgetsBindingObserver {
  bool get _isEnabled {
    return widget.route.isCurrent && widget.route.popGestureEnabled;
  }

  /// 播放页开着时手势属于播放页（视觉覆盖一切）：其他 navigator 的
  /// detector 让位。各 navigator 的 isCurrent 相互独立（二级页是 appNavigator
  /// 栈顶、播放页是 playerNavigator 栈顶），不加这条两个 detector 会同时
  /// 认领，commit 时一次手势 pop 两个页面
  bool get _coveredByPlayerPage {
    if (!playerOpenNotifier.value) return false;
    final nav = widget.route.navigator;
    return nav == null || nav != playerNavigatorKey.currentState;
  }

  String get _routeName =>
      widget.route.settings.name ?? widget.route.runtimeType.toString();

  PredictiveBackPhase get phase => _phase;
  PredictiveBackPhase _phase = PredictiveBackPhase.idle;
  set phase(PredictiveBackPhase phase) {
    if (_phase != phase && mounted) {
      setState(() => _phase = phase);
    }
  }

  bool _owned = false;

  final BackGestureProgressSynth _synth = BackGestureProgressSynth();

  PredictiveBackEvent? get startBackEvent => _startBackEvent;
  PredictiveBackEvent? _startBackEvent;
  set startBackEvent(PredictiveBackEvent? startBackEvent) {
    if (_startBackEvent != startBackEvent && mounted) {
      setState(() => _startBackEvent = startBackEvent);
    }
  }

  PredictiveBackEvent? get currentBackEvent => _currentBackEvent;
  PredictiveBackEvent? _currentBackEvent;
  set currentBackEvent(PredictiveBackEvent? currentBackEvent) {
    if (_currentBackEvent != currentBackEvent && mounted) {
      setState(() => _currentBackEvent = currentBackEvent);
    }
  }

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) {
    if (_coveredByPlayerPage) {
      AppLog.debug('backgesture', 'decline $_routeName coveredByPlayer');
      return false;
    }
    final bool gestureInProgress = !backEvent.isButtonEvent && _isEnabled;
    if (!gestureInProgress) {
      if (!backEvent.isButtonEvent && widget.route.isCurrent) {
        AppLog.debug('backgesture',
            'decline $_routeName popGestureEnabled=${widget.route.popGestureEnabled}');
      }
      return false;
    }
    AppLog.debug('backgesture', 'claim $_routeName progress=${backEvent.progress.toStringAsFixed(3)}');
    _owned = true;
    _synth.reset();
    phase = PredictiveBackPhase.start;

    widget.route.handleStartBackGesture(progress: 1 - backEvent.progress);
    startBackEvent = currentBackEvent = backEvent;
    return true;
  }

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent backEvent) {
    if (!_owned) return;
    final effective = _synth.progressOf(backEvent);
    if (_synth.engagedThisFrame) {
      AppLog.debug('backgesture', 'synth engage $_routeName');
    }
    phase = PredictiveBackPhase.update;

    widget.route.handleUpdateBackGestureProgress(progress: 1 - effective);
    currentBackEvent = backEvent;
  }

  @override
  void handleCancelBackGesture() {
    if (!_owned) return;
    _owned = false;
    AppLog.debug('backgesture',
        'cancel $_routeName updates=${_synth.updateCount} '
        'last=${_synth.lastProgress.toStringAsFixed(3)} synth=${_synth.synth}');
    // 相位不直接归 idle：cancel 后控制器回弹期间维持手势分支渲染，页面
    // 沿当前动画平滑复位（缩放/位移随控制器一起回去）；回弹收尾再归
    // idle 切回基线分支，否则缩放/贴边状态会在 cancel 瞬间跳回原位
    phase = PredictiveBackPhase.cancel;
    _listenSettle();

    widget.route.handleCancelBackGesture();
    startBackEvent = currentBackEvent = null;
  }

  @override
  void handleCommitBackGesture() {
    if (!_owned) return;
    _owned = false;
    AppLog.debug('backgesture',
        'commit $_routeName updates=${_synth.updateCount} '
        'last=${_synth.lastProgress.toStringAsFixed(3)} synth=${_synth.synth}');
    // commit 后路由随即 pop，收尾动画期间保持 commit 相位：缩小卡片沿
    // commit 映射飞出并淡出，而不是在提交瞬间切回 idle 基线动画
    phase = PredictiveBackPhase.commit;
    _listenSettle();

    widget.route.handleCommitBackGesture();
    startBackEvent = currentBackEvent = null;
  }

  /// cancel/commit 之后路由控制器收尾（回弹或 pop）结束的瞬间把手势相位
  /// 归零。pop 场景路由随后卸载，监听自然失效；回弹场景保证静止后回到
  /// 基线分支（此时控制器=1，两个分支视觉一致，切换无跳变）。
  /// 经 route.animation 挂监听（TransitionRoute.controller 是 protected）。
  void _listenSettle() {
    final anim = widget.route.animation;
    if (anim == null) return;
    late final AnimationStatusListener listener;
    listener = (AnimationStatus status) {
      if (status != AnimationStatus.completed &&
          status != AnimationStatus.dismissed) {
        return;
      }
      anim.removeStatusListener(listener);
      if (!_owned && mounted && _phase != PredictiveBackPhase.idle) {
        phase = PredictiveBackPhase.idle;
      }
    };
    anim.addStatusListener(listener);
  }

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
    // 相位在 cancel/commit 后仍保持（见 _listenSettle），builder 据此在
    // 收尾动画期间维持手势分支渲染，因此这里直接透传当前相位而非按
    // _owned 门控归 idle
    return widget.builder(
      context,
      _phase,
      _startBackEvent,
      _currentBackEvent,
    );
  }
}

class CoverPageTransitionsBuilder extends PageTransitionsBuilder {
  const CoverPageTransitionsBuilder({this.predictiveBack = true, this.backgroundColor});

  final bool predictiveBack;

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
    if (kFrameworkPredictiveCompare) {
      return _coverSlide(context, animation, child);
    }
    return PredictiveBackGestureDetector(
      route: route,
      builder: (context, phase, startBackEvent, currentBackEvent) {
        if (phase != PredictiveBackPhase.idle) {
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

  Widget _withBackground(BuildContext context, Widget layer) {
    return TransitionBackdrop(
      backgroundColor: backgroundColor,
      child: layer,
    );
  }

  Widget _coverSlide(BuildContext context, Animation<double> animation, Widget child) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return Stack(
      fit: StackFit.expand,
      children: [
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

class TransitionBackdrop extends ConsumerWidget {
  const TransitionBackdrop({super.key, this.backgroundColor, this.child});

  final Color? backgroundColor;
  final Widget? child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: backgroundColor ?? Theme.of(context).scaffoldBackgroundColor,
      ),
      child: child,
    );
  }
}

enum PredictiveBackPhase {
  idle,

  start,

  update,

  commit,

  cancel,
}

typedef PredictiveBackGestureDetectorWidgetBuilder =
    Widget Function(
      BuildContext context,
      PredictiveBackPhase phase,
      PredictiveBackEvent? startBackEvent,
      PredictiveBackEvent? currentBackEvent,
    );

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
  static const double _kMinScale = 0.90;
  static const double _kDivisionFactor = 20.0;
  static const double _kMargin = 8.0;
  static const double _kYPositionFactor = 0.1;

  static const int _kCommitMilliseconds = 400;
  static const Curve _kCurve = Curves.easeOutCubic;
  static const Interval _kCommitInterval = Interval(
    0.0,
    _kCommitMilliseconds / FadeForwardsPageTransitionsBuilder.kTransitionMilliseconds,
    curve: _kCurve,
  );

  static const double _kDeviceBorderRadius = 32.0;

  final Tween<double> _borderRadiusTween = Tween<double>(begin: 0.0, end: _kDeviceBorderRadius);

  final Tween<double> _opacityTween = Tween<double>(begin: 1.0, end: 0.0);

  final Tween<double> _scaleTween = Tween<double>(begin: 1.0, end: _kMinScale);

  final ProxyAnimation _commitAnimation = ProxyAnimation();

  final ProxyAnimation _bounceAnimation = ProxyAnimation();
  double _lastBounceAnimationValue = 0.0;

  final ProxyAnimation _animation = ProxyAnimation();

  CurvedAnimation? _curvedAnimation;

  CurvedAnimation? _curvedAnimationReversed;

  late Animation<Offset> _positionAnimation;

  Offset _lastDrag = Offset.zero;

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
