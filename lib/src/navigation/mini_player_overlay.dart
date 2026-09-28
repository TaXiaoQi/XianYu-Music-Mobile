import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart'
    show ImperativeRouteMatch, RouteMatchBase, ShellRouteMatch;

import '../core/settings.dart';
import '../widgets/blur_budget.dart';
import '../widgets/mini_player_bar.dart';
import 'routes.dart';
import 'shell.dart';

/// mini 播放条顶层宿主：
/// 挂载在 MaterialApp.builder 中 Navigator 之上的兄弟层级，
/// 让播放条成为全局最上层 chrome——所有页面（含播放页）的转场
/// 都从播放条背后滑过，实现无缝衔接。
/// 显隐跟随 chrome（hidden），与顶栏/底栏的节奏保持一致。
class MiniPlayerOverlay extends ConsumerStatefulWidget {
  const MiniPlayerOverlay({super.key});

  @override
  ConsumerState<MiniPlayerOverlay> createState() => _MiniPlayerOverlayState();
}

class _MiniPlayerOverlayState extends ConsumerState<MiniPlayerOverlay> {
  double? _playerTop;
  double? _playerLeft;

  Offset? _lastSeenShared;

  bool? _lastFloating;
  bool? _lastSide;

  bool _isPlayerDragging = false;

  bool _isRootPath = true;

  /// 上一帧的 hidden：用于判定转场起点是否可见
  bool _lastHidden = false;

  /// 从根路径推入二级页时置位：转场中全局条保持可见，
  /// 落定（globalIsTransitioning 复位）后清零并淡出交接
  bool _pendingHide = false;

  static const _rootPaths = {'/', '/home', '/mine'};

  /// 栈顶路由的真实路径。
  /// go_router 的 currentConfiguration.uri 只统计非 imperative 匹配：
  /// push('/player') 之后它仍是 '/'，必须下钻 ImperativeRouteMatch。
  String get _topPath {
    final config = appRouter.routerDelegate.currentConfiguration;
    RouteMatchBase m = config.matches.last;
    while (m is ShellRouteMatch && m.matches.isNotEmpty) {
      m = m.matches.last;
    }
    if (m is ImperativeRouteMatch) return m.matches.uri.path;
    return config.uri.path;
  }

  @override
  void initState() {
    super.initState();
    _isRootPath = _rootPaths.contains(_topPath);
    appRouter.routerDelegate.addListener(_onRouteChanged);
    globalIsTransitioning.addListener(_onTransitionChanged);
    playerOpenNotifier.addListener(_onPlayerOpenChanged);
  }

  @override
  void dispose() {
    appRouter.routerDelegate.removeListener(_onRouteChanged);
    globalIsTransitioning.removeListener(_onTransitionChanged);
    playerOpenNotifier.removeListener(_onPlayerOpenChanged);
    super.dispose();
  }

  void _onRouteChanged() {
    if (!mounted) return;
    setState(() {
      final next = _rootPaths.contains(_topPath);
      // 从根路径（条可见）覆盖推入二级页：转场中保持全局条原位可见，
      // 页面从条背后滑过；不能依赖此处读 globalIsTransitioning——
      // routerDelegate 通知先于 NavigatorObserver.didPush 触发
      if (_isRootPath && !next && !_lastHidden) {
        _pendingHide = true;
      }
      _isRootPath = next;
    });
  }

  void _onTransitionChanged() {
    if (!mounted) return;
    // 转场通知可能由 Navigator didPush/didPop 在 build 阶段同步广播，
    // 本宿主挂在 Navigator 之外（builder 层），setState 会被
    // "markNeedsBuild during build" 断言拒绝——推迟到帧末执行
    void apply() {
      if (!mounted) return;
      setState(() {
        if (!globalIsTransitioning.value) _pendingHide = false;
      });
    }

    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => apply());
      return;
    }
    apply();
  }

  void _onPlayerOpenChanged() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final floating = ref.read(
            settingsProvider.select((s) => s.valueOrNull?.floatingNavBar)) ??
        true;
    final screen = MediaQuery.maybeOf(context);
    final landscape =
        screen == null || screen.size.width >= screen.size.height * 1.05;
    final side = landscape ||
        (ref.read(settingsProvider
                .select((s) => s.valueOrNull?.navBarPosition)) ==
            NavBarPosition.side);
    if ((_lastFloating != null && _lastFloating != floating) ||
        (_lastSide != null && _lastSide != side)) {
      _playerTop = null;
      _playerLeft = null;
    }
    _lastFloating = floating;
    _lastSide = side;
  }

  void _onPlayerPanStart(DragStartDetails details) {
    setState(() {
      _isPlayerDragging = true;
      _playerLeft ??= MiniBarPositionStore.shared?.dx;
      _playerTop ??= MiniBarPositionStore.shared?.dy;
    });
    setGlobalDragging(true);
  }

  double _playerMinTop(double paddingTop, bool landscape) =>
      paddingTop + 8.0 + (landscape ? 44.0 : 40.0) + 8.0;

  void _onPlayerPanUpdate(
    DragUpdateDetails details,
    Size screenSize,
    EdgeInsets padding,
    double defaultLeft,
    double defaultTop,
    double maxTop,
    double miniBarW,
    double landscapeLeftBound,
    double landscapeRightBound,
    bool landscape,
  ) {
    final currentLeft = _playerLeft ?? defaultLeft;
    final currentTop = _playerTop ?? defaultTop;

    final barW = landscape ? miniBarW : (screenSize.width - 24.0);
    final minLeft = landscape ? landscapeLeftBound : 6.0;
    final maxLeft = landscape
        ? landscapeRightBound
        : (screenSize.width - barW - 6.0);
    final minTop = _playerMinTop(padding.top, landscape);

    setState(() {
      _playerLeft = (currentLeft + details.delta.dx).clamp(
        minLeft,
        maxLeft > minLeft ? maxLeft : minLeft,
      );
      _playerTop = (currentTop + details.delta.dy).clamp(
        minTop,
        maxTop > minTop ? maxTop : minTop,
      );
    });
  }

  void _onPlayerPanEnd(
    DragEndDetails details,
    double defaultLeft,
    double defaultTop,
  ) {
    setState(() {
      _isPlayerDragging = false;
    });
    setGlobalDragging(false);

    final l = _playerLeft;
    final t = _playerTop;
    if (l != null && t != null) {
      MiniBarPositionStore.shared = Offset(l, t);
      _playerLeft = null;
      _playerTop = null;
    }
  }

  void _onPlayerPanCancel() {
    setState(() {
      _isPlayerDragging = false;
    });
    setGlobalDragging(false);
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    final padding = MediaQuery.of(context).padding;
    final safeBottom = padding.bottom;

    final landscape = screenSize.width >= screenSize.height * 1.05;

    final floating =
        ref.watch(settingsProvider.select((s) => s.valueOrNull?.floatingNavBar)) ??
            true;

    final isSide = landscape ||
        (ref.watch(settingsProvider
                .select((s) => s.valueOrNull?.navBarPosition)) ==
            NavBarPosition.side);

    final accountOpen = landscape && ref.watch(landscapeAccountOpenProvider);

    final hiddenCount = ref.watch(navBarHiddenProvider);

    final playerOpen = playerOpenNotifier.value;

    final hidden = hiddenCount > 0 ||
        playerOpen ||
        (!_isRootPath &&
            // 转场期间保持转场起点的可见状态：从根路径覆盖推入二级页时，
            // 全局条原位静止在切换动画图层之上，页面（含其内嵌条）从
            // 背后滑过；落定后再按新路径状态淡出，交接给页面内嵌条
            !_pendingHide);

    final miniBarLow =
        hiddenCount > 0 || (!_isRootPath && !playerOpen);

    final miniBarW = landscape
        ? math.min(screenSize.width * 0.55, 520.0)
        : (screenSize.width - 24.0);

    final leftCutout = landscape ? padding.left : 0.0;
    final rightCutout = landscape ? padding.right : 0.0;

    late final double defaultLeft;
    var landscapeLeftBound = 6.0;
    var landscapeRightBound = 30.0;
    if (landscape) {
      landscapeLeftBound = math.max(leftCutout, 6.0);
      landscapeRightBound = screenSize.width -
          miniBarW -
          (rightCutout > 0 ? rightCutout + 12 : 16);
      defaultLeft = landscapeRightBound > landscapeLeftBound
          ? ((screenSize.width - miniBarW) / 2.0)
              .clamp(landscapeLeftBound, landscapeRightBound)
          : landscapeLeftBound;
    } else {
      defaultLeft = 12.0;
    }
    final defaultTop = isSide
        ? (screenSize.height - safeBottom - 58.0 - 12.0)
        : (floating
            ? (miniBarLow
                ? (screenSize.height - safeBottom - 58.0 - 18.0)
                : (screenSize.height - safeBottom - 18.0 - 70.0 - 58.0))
            : (screenSize.height - safeBottom - 58.0 - 64.0));

    final batchLift = ref.watch(batchBarLiftProvider);
    final liftedDefaultTop = defaultTop - batchLift;

    final dragMaxTop = () {
      final barH = 58.0;
      if (isSide) return screenSize.height - safeBottom - barH - 12.0 - batchLift;
      if (floating) {
        return hidden
            ? (screenSize.height - padding.bottom - barH - 12.0)
            : (screenSize.height - safeBottom - 18.0 - 70.0 - barH - batchLift);
      }
      return hidden
          ? (screenSize.height - padding.bottom - barH - 12.0)
          : (screenSize.height - safeBottom - 64.0 - barH - batchLift);
    }();

    final shared = MiniBarPositionStore.shared;
    final shellMinLeft = landscape ? landscapeLeftBound : 6.0;
    final shellMaxLeft = landscape
        ? landscapeRightBound
        : (screenSize.width - (screenSize.width - 24.0) - 6.0);
    final actualLeft = (_playerLeft ?? shared?.dx ?? defaultLeft)
        .clamp(shellMinLeft,
            shellMaxLeft > shellMinLeft ? shellMaxLeft : shellMinLeft)
        .toDouble();
    final minTopClamped = _playerMinTop(padding.top, landscape);
    final actualTop = (_playerTop ?? shared?.dy ?? liftedDefaultTop)
        .clamp(
            minTopClamped, math.max(minTopClamped, dragMaxTop.toDouble()))
        .toDouble();

    final adoptedExternal =
        shared != null && shared != _lastSeenShared && !_isPlayerDragging;
    _lastSeenShared = shared;

    final rootBarTop = (isSide
            ? (screenSize.height - safeBottom - 58.0 - 12.0)
            : (floating
                ? (screenSize.height - safeBottom - 18.0 - 70.0 - 58.0)
                : (screenSize.height - safeBottom - 58.0 - 64.0))) -
        batchLift;

    if (accountOpen) return const SizedBox.shrink();

    _lastHidden = hidden;

    // 播放页在五级模型中高于播放条：推入时条立即让位（播放页物理盖过，
    // 无需渐隐）；其余显隐（返回露出/根↔二级交接）走 240ms 渐变
    final chromeDur = (hiddenCount > 0 || playerOpen)
        ? Duration.zero
        : const Duration(milliseconds: 240);

    return AnimatedPositioned(
      duration: (_isPlayerDragging || adoptedExternal)
          ? Duration.zero
          : const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
      left: actualLeft,
      top: actualTop,
      width: miniBarW,
      child: AnimatedOpacity(
        duration: chromeDur,
        curve: Curves.easeOutCubic,
        opacity: hidden ? 0.0 : 1.0,
        child: AnimatedScale(
          duration: chromeDur,
          curve: Curves.easeOutCubic,
          scale: hidden ? 0.92 : 1.0,
          child: IgnorePointer(
            ignoring: hidden,
            child: MiniPlayerBar(
              onPanStart: _onPlayerPanStart,
              onPanUpdate: (d) => _onPlayerPanUpdate(
                  d,
                  screenSize,
                  padding,
                  defaultLeft,
                  defaultTop,
                  dragMaxTop,
                  miniBarW,
                  landscapeLeftBound,
                  landscapeRightBound,
                  landscape),
              onPanEnd: (d) => _onPlayerPanEnd(d, defaultLeft, defaultTop),
              onPanCancel: _onPlayerPanCancel,
              registerTarget: !(hiddenCount > 0 && !playerOpen),
              heroTag: (hiddenCount > 0 && !playerOpen) ? null : 'player-cover',
              returnTarget: () => Rect.fromLTWH(
                actualLeft,
                rootBarTop,
                46,
                46,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
