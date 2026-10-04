import 'dart:async';

import 'package:flutter/material.dart';

/// 列表入场逐行动画：行淡入 + 上移归位 + 缩放归位，与桌面端榜单式入场同一套
/// 曲线（cubic-bezier(0.16, 1, 0.3, 1)）与密集列表节奏（40ms 错峰 / 400ms 时长）。
class StaggerIn extends StatefulWidget {
  const StaggerIn({
    super.key,
    required this.delay,
    required this.child,
    this.duration = const Duration(milliseconds: 400),
    this.offsetY = 30.0,
    this.scaleFrom = 0.96,
  });

  final Duration delay;

  final Widget child;

  final Duration duration;

  final double offsetY;

  final double scaleFrom;

  @override
  State<StaggerIn> createState() => _StaggerInState();
}

class _StaggerInState extends State<StaggerIn>
    with SingleTickerProviderStateMixin {
  static const Cubic _ease = Cubic(0.16, 1, 0.3, 1);

  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: widget.duration,
  );
  Timer? _delayTimer;

  @override
  void initState() {
    super.initState();
    _delayTimer = Timer(widget.delay, () {
      if (mounted) _ctrl.forward();
    });
  }

  @override
  void dispose() {
    _delayTimer?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 系统关闭动画（无障碍「移除动画」）时直接呈现最终状态
    if (MediaQuery.of(context).disableAnimations) return widget.child;
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, child) {
        final t = _ease.transform(_ctrl.value);
        if (t <= 0) return const SizedBox.shrink();
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, widget.offsetY * (1 - t)),
            child: Transform.scale(
              scale: widget.scaleFrom + (1 - widget.scaleFrom) * t,
              child: child,
            ),
          ),
        );
      },
      child: widget.child,
    );
  }
}

/// 「入场窗口」：列表挂载时开窗，窗口内构建的行按窗口内行序错峰入场；
/// 关窗后构建的行（滚动加载、排序/批量切换触发的重建）原样呈现，
/// 避免列表中段的行带着大延迟空白闪现。
class StaggerWindow {
  StaggerWindow({
    this.baseDelayMs = 40,
    this.staggerMs = 40,
    this.rowMs = 400,
    this.maxRows = 14,
    this.marginMs = 120,
    required this.onClosed,
  });

  final int baseDelayMs;

  final int staggerMs;

  final int rowMs;

  final int maxRows;

  final int marginMs;

  /// 关窗回调：宿主在里面做 mounted 检查后 setState。
  final VoidCallback onClosed;

  bool _active = false;
  int? _firstIndex;
  Timer? _timer;

  /// initState 里调用：开窗并安排自动关窗。
  void start() {
    _active = true;
    _firstIndex = null;
    _timer?.cancel();
    _timer = Timer(
      Duration(
        milliseconds:
            baseDelayMs + (maxRows - 1) * staggerMs + rowMs + marginMs,
      ),
      () {
        _active = false;
        onClosed();
      },
    );
  }

  void dispose() {
    _timer?.cancel();
  }

  /// 行构建时包裹：窗口未开启原样返回；窗口内按窗口内行序给延迟，
  /// 超过 maxRows 的行同时入场（缓存预构建行不拖长整体节奏）。
  Widget wrap(int index, Widget child) {
    if (!_active) return child;
    _firstIndex ??= index;
    final order = (index - _firstIndex!).clamp(0, maxRows);
    return StaggerIn(
      delay: Duration(milliseconds: baseDelayMs + order * staggerMs),
      child: child,
    );
  }
}
