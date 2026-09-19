import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';

final ValueNotifier<bool> globalIsScrolling = ValueNotifier(false);
Timer? _scrollTimer;

void markScrollActivity() {
  globalIsScrolling.value = true;
  _scrollTimer?.cancel();
  _scrollTimer = Timer(const Duration(milliseconds: 200), () {
    globalIsScrolling.value = false;
  });
}

final ValueNotifier<bool> globalIsTabSwitching = ValueNotifier(false);

void setTabSwitching(bool value) {
  globalIsTabSwitching.value = value;
}

final ValueNotifier<bool> globalIsDragging = ValueNotifier(false);

void setGlobalDragging(bool value) {
  globalIsDragging.value = value;
}

final ValueNotifier<bool> globalIsTransitioning = ValueNotifier(false);
Timer? _transitionTimer;

void markTransitionActivity() {
  globalIsTransitioning.value = true;
  _transitionTimer?.cancel();
  _transitionTimer = Timer(const Duration(milliseconds: 400), () {
    globalIsTransitioning.value = false;
  });
}

class TransitionTracker extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    markTransitionActivity();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    markTransitionActivity();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      markTransitionActivity();
}

class _ValueNotifierState extends Notifier<bool> {
  _ValueNotifierState(this._source);

  final ValueNotifier<bool> _source;
  late final VoidCallback _listener;
  var _disposed = false;

  @override
  bool build() {
    _listener = () {
      final value = _source.value;
      scheduleMicrotask(() {
        if (_disposed) return;
        state = value;
      });
    };
    _source.addListener(_listener);
    ref.onDispose(() {
      _disposed = true;
      _source.removeListener(_listener);
    });
    return _source.value;
  }
}

final isScrollingProvider =
    NotifierProvider<_ValueNotifierState, bool>(
      () => _ValueNotifierState(globalIsScrolling),
    );
final isTransitioningProvider =
    NotifierProvider<_ValueNotifierState, bool>(
      () => _ValueNotifierState(globalIsTransitioning),
    );

enum BlurSurfaceType {
  header,

  bottomBar,

  drawerOrSheet,

  overlay,

  generic,
}

enum MotionTier {
  reduced,
  normal,
  enhanced,
}

class BlurBudget {
  const BlurBudget({
    required this.maxBlurLevel,
    required this.backgroundAlphaMultiplier,
    required this.allowRealtime,
  });

  final int maxBlurLevel;

  final double backgroundAlphaMultiplier;

  final bool allowRealtime;
}

BlurBudget resolveBlurBudget({
  required BlurSurfaceType type,
  required MotionTier motionTier,
  required bool isScrolling,
  required bool isTransitionRunning,
  bool forceLowBudget = false,
}) {
  var maxBlurLevel = switch (type) {
    BlurSurfaceType.header => 2,
    BlurSurfaceType.drawerOrSheet => 2,
    BlurSurfaceType.bottomBar => 1,
    BlurSurfaceType.overlay => 1,
    BlurSurfaceType.generic => 1,
  };
  var alphaMul = switch (type) {
    BlurSurfaceType.header => 1.0,
    BlurSurfaceType.drawerOrSheet => 1.0,
    BlurSurfaceType.bottomBar => 0.95,
    BlurSurfaceType.overlay => 0.92,
    BlurSurfaceType.generic => 0.95,
  };
  var allowRealtime = true;

  if (motionTier == MotionTier.reduced) {
    maxBlurLevel = 0;
    alphaMul *= 0.9;
    allowRealtime = false;
  }

  if (isScrolling || isTransitionRunning) {
    if (type != BlurSurfaceType.header &&
        type != BlurSurfaceType.bottomBar) {
      maxBlurLevel = math.min(maxBlurLevel, 0);
      alphaMul *= 0.92;
    }
    allowRealtime = false;
  }

  if (forceLowBudget) {
    maxBlurLevel = 0;
    alphaMul *= 0.9;
    allowRealtime = false;
  }

  return BlurBudget(
    maxBlurLevel: maxBlurLevel.clamp(0, 2),
    backgroundAlphaMultiplier: alphaMul.clamp(0.70, 1.10),
    allowRealtime: allowRealtime,
  );
}

double nonRealtimeBlurInputScale(BlurSurfaceType type) => switch (type) {
  BlurSurfaceType.header => 0.60,
  BlurSurfaceType.drawerOrSheet => 0.84,
  BlurSurfaceType.bottomBar => 0.70,
  BlurSurfaceType.overlay => 0.84,
  BlurSurfaceType.generic => 0.84,
};

double resolveBlurInputScale(BlurBudget budget, BlurSurfaceType type) {
  if (budget.allowRealtime) return 1.0;
  return nonRealtimeBlurInputScale(type);
}

double surfaceBlurSigma({
  required double base,
  required BlurBudget budget,
  required BlurSurfaceType type,
  bool crispAtRest = false,
}) {
  return base;
}

Color surfaceFillWithBudget(Color baseFill, BlurBudget budget) => baseFill;

final blurBudgetProvider = Provider.family<BlurBudget, BlurSurfaceType>(
  (ref, type) {
    final lowPerf = ref.watch(settingsProvider.select(
        (s) => performancePriority(s.valueOrNull ?? const AppSettings())));
    return resolveBlurBudget(
      type: type,
      motionTier: lowPerf ? MotionTier.reduced : MotionTier.normal,
      isScrolling: ref.watch(isScrollingProvider),
      isTransitionRunning: ref.watch(isTransitioningProvider),
      forceLowBudget: lowPerf,
    );
  },
);
