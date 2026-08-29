import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';

/// 全局滚动状态：滚动中为 true，滚动停止 200ms 后置回 false。
final ValueNotifier<bool> globalIsScrolling = ValueNotifier(false);
Timer? _scrollTimer;

/// 标记一次滚动活动（滚动通知每帧调用，内部防抖：停止后延迟复位）。
void markScrollActivity() {
  globalIsScrolling.value = true;
  _scrollTimer?.cancel();
  _scrollTimer = Timer(const Duration(milliseconds: 200), () {
    globalIsScrolling.value = false;
  });
}

/// 全局路由转场状态：push/pop 后 400ms 内为 true（转场动画窗口）。
final ValueNotifier<bool> globalIsTransitioning = ValueNotifier(false);
Timer? _transitionTimer;

/// 标记一次路由转场活动。
void markTransitionActivity() {
  globalIsTransitioning.value = true;
  _transitionTimer?.cancel();
  _transitionTimer = Timer(const Duration(milliseconds: 400), () {
    globalIsTransitioning.value = false;
  });
}

/// 路由转场监听：push/pop/remove 时标记转场活动，供全局 blur 预算降级。
class TransitionTracker extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      markTransitionActivity();

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      markTransitionActivity();

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      markTransitionActivity();
}

/// 把 [ValueNotifier] 包成可被 ref.watch 的 bool provider（实时跟随）。
/// flutter_riverpod 2.6.1 已移除旧版 ValueNotifierProvider，这里用更底层的
/// NotifierProvider + 监听器复刻等价的「跟随外部 ValueNotifier」语义。
class _ValueNotifierState extends Notifier<bool> {
  _ValueNotifierState(this._source);

  final ValueNotifier<bool> _source;
  late final VoidCallback _listener;

  @override
  bool build() {
    _listener = () => state = _source.value;
    _source.addListener(_listener);
    ref.onDispose(() => _source.removeListener(_listener));
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

/// 玻璃表面类型（决定基础模糊预算与降级优先级）。
enum BlurSurfaceType {
  /// 顶栏：滚动/转场时保持模糊（最需要稳定的玻璃），仅缩小输入。
  header,

  /// 底栏/迷你播放条：滚动/转场时降级。
  bottomBar,

  /// 抽屉/底部面板/弹窗内容：滚动/转场时降级。
  drawerOrSheet,

  /// 悬浮浮层：滚动/转场时降级。
  overlay,

  /// 通用表面。
  generic,
}

/// 运动档位（用户可感知的动态强度偏好）。
enum MotionTier {
  reduced,
  normal,
  enhanced,
}

/// 模糊预算：某表面当前可用的模糊上限与补偿系数。
class BlurBudget {
  const BlurBudget({
    required this.maxBlurLevel,
    required this.backgroundAlphaMultiplier,
    required this.allowRealtime,
  });

  /// 0=最轻（接近实色） 1=标准 2=满档。
  final int maxBlurLevel;

  /// 半透明铺底 alpha 的乘数（预算不足时更透，配合轻模糊）。
  final double backgroundAlphaMultiplier;

  /// 是否允许实时高成本模糊（滚动/转场/低动态时关闭）。
  final bool allowRealtime;
}

/// 全局统一的 blur 预算降级策略（借鉴 BiliPai BlurBudgetPolicy）：
/// 表面类型给基础预算，再按运动档位/滚动/转场/强制低预算逐级降级，
/// 降级时缩小模糊并用铺底透明度补偿。
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

  // 滚动/转场：非顶栏表面降级到最轻。例外：bottomBar（迷你播放条/底栏/横屏侧栏）
  // 面积小、模糊成本极低，若随滚动把 sigma 降到最轻，叠加本就较高的铺底透明度，
  // 会让下方滚动的列表内容清晰透出播放条（「透底」）。故 bottomBar 滚动/转场时
  // 保持满档模糊，仅关闭实时输入（sigma 略缩）。
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

/// 模糊输入缩放：实时模式 1.0；降级（滚动/转场/低动态）时按表面类型缩小
/// 高斯模糊输入，省算力同时保留一定玻璃质感。
double resolveBlurInputScale(BlurBudget budget, BlurSurfaceType type) {
  if (budget.allowRealtime) return 1.0;
  return switch (type) {
    BlurSurfaceType.header => 0.88,
    BlurSurfaceType.drawerOrSheet => 0.84,
    BlurSurfaceType.bottomBar => 0.82,
    BlurSurfaceType.overlay => 0.84,
    BlurSurfaceType.generic => 0.84,
  };
}

/// 结合预算得到表面实际高斯模糊 sigma。
///
/// [maxBlurLevel] 决定强度档（0=最轻，1/2=满档），再乘降级输入缩放。
double surfaceBlurSigma({
  required double base,
  required BlurBudget budget,
  required BlurSurfaceType type,
}) {
  final levelScale = switch (budget.maxBlurLevel) {
    0 => 0.6,
    _ => 1.0,
  };
  return base * levelScale * resolveBlurInputScale(budget, type);
}

/// 结合预算调整半透明铺底 alpha（预算不足时更透）。
///
/// beta9 对齐：伪毛玻璃透明度恒定，不随滚动/转场预算降低——否则每次切页或
/// 滚动后玻璃铺底变透明、磨砂感变浅（整体观感与 beta9 不一致），鼠标滚动/转场
/// 时只靠 sigma 缩放控制磨砂算力即可。故直接返回原填充色，不再乘降档系数。
Color surfaceFillWithBudget(Color baseFill, BlurBudget budget) => baseFill;

/// 当前全局生效的模糊预算（综合低性能模式/滚动/转场状态）。
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
