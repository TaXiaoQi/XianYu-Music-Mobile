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
  VoidCallback? _routeAnimListener;
  Animation<double>? _routeAnim;
  ModalRoute<dynamic>? _route;
  bool _routeChecking = false;
  int _routeCheckFrames = 0;

  @override
  void initState() {
    super.initState();
    // 播完直接还原为普通子树：去掉动画包装，无障碍语义完整暴露，
    // 且不再逐帧 rebuild。还原时子树是全新 element/render object，
    // 语义节点从零构建，不会撞语义重建断言。
    _ctrl.addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) setState(() {});
    });
  }

  // 转场中挂载的列表（push 落定前首屏 build）错峰计时推迟到本路由
  // 转场动画落定：此前延迟从列表挂载起算，push 转场 250ms 内前几行的
  // 逐帧 rebuild+重绘与整页平移逐帧叠加，是列表页（本地歌曲/喜欢/最近/
  // 歌单等）push 掉帧主源。落定前行动画停在 t=0（Opacity 0 跳过绘制，
  // 子树保持挂载，封面仍并行加载）；无转场场景（根页签首挂/
  // maintainState 复挂）动画已落定，零延迟保持原行为。
  // 判定必须走 controller 真值：ModalRoute 入场首帧把路由置 offstage
  // （Hero 测量终位机制），route.animation 代理临时指向
  // kAlwaysCompleteAnimation 恒读 completed——首读值/status 判定从未
  // 生效，行动画在转场中照跑（_RouteDeferredBody 实证）。controller 是
  // protected 触不可及，改为 offstage 窗口内逐帧重验 route.animation：
  // offstage 解除后该动画即转场真值，值监听 value>=1 即落定（status
  // 事件存在丢失边角）。重验设上限兜底，防常驻 offstage（被上层不透明
  // 页盖住等）时永远等不到落定
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route ??= ModalRoute.of(context);
    if (_delayTimer != null || _routeAnim != null || _routeChecking) return;
    _routeChecking = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _verifyRouteSettled());
  }

  void _verifyRouteSettled() {
    if (!mounted) return;
    final route = _route;
    final anim = route?.animation;
    if (route == null || anim == null) {
      _routeChecking = false;
      _arm();
      return;
    }
    if (route.offstage) {
      if (++_routeCheckFrames > 12) {
        _routeChecking = false;
        _arm();
        return;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) => _verifyRouteSettled());
      return;
    }
    _routeChecking = false;
    if (anim.value >= 1.0) {
      _arm();
      return;
    }
    _routeAnim = anim;
    _routeAnimListener = () {
      if (_routeAnim!.value < 1.0) return;
      _disarmRoute();
      if (mounted) _arm();
    };
    _routeAnim!.addListener(_routeAnimListener!);
  }

  void _disarmRoute() {
    final listener = _routeAnimListener;
    if (listener != null) _routeAnim?.removeListener(listener);
    _routeAnimListener = null;
    _routeAnim = null;
  }

  void _arm() {
    _delayTimer = Timer(widget.delay, () {
      if (mounted) _ctrl.forward();
    });
  }

  @override
  void dispose() {
    _disarmRoute();
    _delayTimer?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 系统关闭动画（无障碍「移除动画」）时直接呈现最终状态
    if (MediaQuery.of(context).disableAnimations || _ctrl.isCompleted) {
      return widget.child;
    }
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, child) {
        final t = _ease.transform(_ctrl.value);
        // 延迟期（t=0）不能用 SizedBox.shrink 卸载子树：那样封面 widget
        // 不在树上、图片请求被拖到该行动画开始才发起，表现为封面跟着
        // 动画逐行批量替换。Opacity 0 时 RenderOpacity 跳过绘制（视觉
        // 不可见）但子树保持挂载，封面在错峰等待期即并行加载——与桌面
        // 端卡片挂载即拉图的行为对齐。
        //
        // 动画期整个子树 ExcludeSemantics 且恒定不变：RenderOpacity 会
        // 在 alpha=0 时把子树剔出语义树、alpha>0 又加回来，语义结构
        // 逐帧翻转会在 flushSemantics 撞 '!child.attached' 断言（debug
        // 下每帧 fatal，错误上报跟着刷爆服务端限流，登录后所有请求
        // 连带 429）。入场动画本就无需暴露无障碍节点，播完即还原。
        return ExcludeSemantics(
          child: Opacity(
            opacity: t,
            child: Transform.translate(
              offset: Offset(0, widget.offsetY * (1 - t)),
              child: Transform.scale(
                scale: widget.scaleFrom + (1 - widget.scaleFrom) * t,
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
    this.durationMs = 400,
    required this.onClosed,
  });

  final int baseDelayMs;

  final int staggerMs;

  final int rowMs;

  final int maxRows;

  final int marginMs;

  /// 单行入场时长（桌面端榜单/搜索网格为 600ms）
  final int durationMs;

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

  /// 提前关窗（如用户开始滚动）：窗口内已构建的行继续播完，
  /// 之后构建的行原样呈现，避免滚动中段的行带着大延迟空白闪现。
  void stop() {
    if (!_active) return;
    _timer?.cancel();
    _active = false;
    onClosed();
  }

  /// 行构建时包裹：窗口未开启原样返回；窗口内按窗口内行序给延迟，
  /// 超过 maxRows 的行同时入场（缓存预构建行不拖长整体节奏）。
  Widget wrap(int index, Widget child) {
    if (!_active) return child;
    _firstIndex ??= index;
    final order = (index - _firstIndex!).clamp(0, maxRows);
    return StaggerIn(
      delay: Duration(milliseconds: baseDelayMs + order * staggerMs),
      duration: Duration(milliseconds: durationMs),
      child: child,
    );
  }
}
