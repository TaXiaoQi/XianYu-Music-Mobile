import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';

final ValueNotifier<bool> globalIsScrolling = ValueNotifier(false);
final ValueNotifier<int> globalScrollTick = ValueNotifier(0);
Timer? _scrollTimer;

void markScrollActivity() {
  globalIsScrolling.value = true;
  globalScrollTick.value++;
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

Timer? _dragReleaseTimer;

void setGlobalDragging(bool value) {
  if (value) _dragReleaseTimer?.cancel();
  globalIsDragging.value = value;
}

void releaseGlobalDragging() {
  _dragReleaseTimer?.cancel();
  _dragReleaseTimer = Timer(const Duration(milliseconds: 400), () {
    globalIsDragging.value = false;
  });
}

final ValueNotifier<bool> globalIsTransitioning = ValueNotifier(false);
Timer? _transitionTimer;

void markTransitionActivity() {
  globalIsTransitioning.value = true;
  _transitionTimer?.cancel();
  _transitionTimer = Timer(const Duration(milliseconds: 600), () {
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
final isTabSwitchingProvider =
    NotifierProvider<_ValueNotifierState, bool>(
      () => _ValueNotifierState(globalIsTabSwitching),
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
  bool isTabSwitching = false,
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

  if (isTabSwitching && type == BlurSurfaceType.generic) {
    // 换页横移窗口（仅 iOS 激活，见 blurBudgetProvider）：页内毛玻璃卡片
    // 的 backdrop 输入随整屏平移逐帧变化、全量重采样，是 iOS 横移掉帧
    // 主源之一。窗口仅数百 ms，卡片退实色不可感（安卓先例 ab2c7104）。
    // 仅限 generic：顶栏/底栏/mini 条带不做横移优化、与安卓完全对齐
    // （条带全屏可控，横移开销由液态玻璃缓存帧/静态帧机制承担；sigma
    // 归 0 摘层会令条带中途树结构突变，与 chrome 缓存帧裁剪叠加实测
    // 撕出双底栏残影）。路由转场不走此路（isTransition 由快照/液态
    // 降级机制承担，转场期卡片材质突变观感风险高）
    maxBlurLevel = math.min(maxBlurLevel, 0);
    alphaMul *= 0.92;
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

double surfaceBlurSigma({
  required double base,
  required BlurBudget budget,
  required BlurSurfaceType type,
  bool crispAtRest = false,
}) {
  // 预算接真（消费方据 sigma<=0 整层摘除 BackdropFilter）：level 0 的面
  // sigma 归 0——σ=0 仍走 saveLayer+backdrop 制备，不摘层没有降载收益。
  // 仅 generic 卡片接真：条带面（header/bottomBar）与安卓完全对齐，恒回
  // base（lowPerf 档条带的实色降级走 glassShouldUseSolid，不在此叠加，
  // 否则安卓条带也会因 level 0 被摘层、观感变化）
  if (type == BlurSurfaceType.generic && budget.maxBlurLevel <= 0) {
    return 0;
  }
  return base;
}

Color surfaceFillWithBudget(Color baseFill, BlurBudget budget) => baseFill;

final blurBudgetProvider = Provider.family<BlurBudget, BlurSurfaceType>(
  (ref, type) {
    final lowPerf = ref.watch(settingsProvider.select(
        (s) => performancePriority(s.valueOrNull ?? const AppSettings())));
    // 换页横移降载仅 iOS 激活（用户决策 2026-11）：安卓/鸿蒙不监听该
    // 信号，观感与重建行为零变化
    final iosMotion =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
    return resolveBlurBudget(
      type: type,
      motionTier: lowPerf ? MotionTier.reduced : MotionTier.normal,
      isScrolling: ref.watch(isScrollingProvider),
      isTransitionRunning: ref.watch(isTransitioningProvider),
      isTabSwitching: iosMotion && ref.watch(isTabSwitchingProvider),
      forceLowBudget: lowPerf,
    );
  },
);
