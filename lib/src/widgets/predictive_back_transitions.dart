import 'dart:ui' show clampDouble;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/application_logger.dart';
import '../core/settings.dart';
import 'custom_background.dart';

const bool kFrameworkPredictiveCompare = false;

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

  int _updateCount = 0;

  Offset? _firstTouch;

  int _zeroStreak = 0;

  bool _synth = false;

  double _lastProgress = 0;

  double get _screenWidth {
    final view = WidgetsBinding.instance.platformDispatcher.implicitView;
    final size = view?.physicalSize;
    if (view == null || size == null || size.isEmpty) return 360;
    return size.width / view.devicePixelRatio;
  }

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
    _updateCount = 0;
    _firstTouch = backEvent.touchOffset;
    _zeroStreak = 0;
    _synth = false;
    _lastProgress = 0;
    phase = PredictiveBackPhase.start;

    widget.route.handleStartBackGesture(progress: 1 - backEvent.progress);
    startBackEvent = currentBackEvent = backEvent;
    return true;
  }

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent backEvent) {
    if (!_owned) return;
    final touch = backEvent.touchOffset;
    _firstTouch ??= touch;
    _updateCount++;
    final p = backEvent.progress;
    _lastProgress = p;
    if (p <= 0.001) {
      _zeroStreak++;
    } else {
      _zeroStreak = 0;
      _synth = false;
    }
    if (_updateCount == 1) {
      AppLog.debug('backgesture',
          'update $_routeName #$_updateCount progress=${p.toStringAsFixed(3)} '
          'edge=${backEvent.swipeEdge} '
          'touch=${touch == null ? 'null' : '${touch.dx.toStringAsFixed(0)},${touch.dy.toStringAsFixed(0)}'}');
    }
    final displaced = _firstTouch != null && touch != null &&
        (touch - _firstTouch!).distance > 24;
    if (!_synth && p <= 0.001 && _zeroStreak >= 2 && displaced) {
      _synth = true;
      AppLog.debug('backgesture', 'synth engage $_routeName');
    }
    double effective = p;
    if (_synth && touch != null && _firstTouch != null) {
      final dx = touch.dx - _firstTouch!.dx;
      final signed = backEvent.swipeEdge == SwipeEdge.right ? -dx : dx;
      effective = signed / _screenWidth > p ? clampDouble(signed / _screenWidth, 0.0, 1.0) : p;
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
        'cancel $_routeName updates=$_updateCount '
        'last=${_lastProgress.toStringAsFixed(3)} synth=$_synth');
    phase = PredictiveBackPhase.idle;

    widget.route.handleCancelBackGesture();
    startBackEvent = currentBackEvent = null;
  }

  @override
  void handleCommitBackGesture() {
    if (!_owned) return;
    _owned = false;
    AppLog.debug('backgesture',
        'commit $_routeName updates=$_updateCount '
        'last=${_lastProgress.toStringAsFixed(3)} synth=$_synth');
    phase = PredictiveBackPhase.idle;

    widget.route.handleCommitBackGesture();
    startBackEvent = currentBackEvent = null;
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
    return widget.builder(
      context,
      _owned ? phase : PredictiveBackPhase.idle,
      _owned ? startBackEvent : null,
      _owned ? currentBackEvent : null,
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
    if (backgroundColor != null) {
      return DecoratedBox(
        decoration: BoxDecoration(color: backgroundColor),
        child: child,
      );
    }
    final cb = ref.watch(
      settingsProvider.select((s) => s.valueOrNull?.customBackground),
    );
    if (cb?.active == true) {
      return Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(
            color: Theme.of(context).scaffoldBackgroundColor,
            child: CustomBackgroundLayer(background: cb),
          ),
          ?child,
        ],
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
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
