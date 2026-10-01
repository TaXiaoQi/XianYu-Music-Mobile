import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/settings.dart';
import '../widgets/blur_budget.dart';
import '../widgets/mini_player_bar.dart';
import 'routes.dart';
import 'shell.dart';

/// mini 播放条顶层宿主：
/// 挂载在 MaterialApp.builder 中 Navigator 之上的兄弟层级，
/// 让播放条成为全局唯一、常驻最上层的 chrome——所有页面（含播放页）
/// 的转场都从播放条背后滑过，页面不再内嵌自己的播放条。
/// 显隐与位置档位（底栏上方/屏幕底）实时跟随当前页面，变化通过与
/// 切换动画同节奏的隐式动画过渡，与页面转场同步完成。
/// 拖动松手时若停在底部停靠带内则吸附归位，恢复档位跟随。
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

  /// 淡入淡出窗口标记：黑名单页显隐与播放页开合期间播放条透明度<1
  /// （saveLayer 生效），LiveLiquidSurface 的 shader 在其中采样图层自身
  /// 内容（空）→ 黑底；窗口内降级磨砂卡，动画结束后恢复实时液态
  bool _barFading = false;
  Timer? _barFadeTimer;

  /// 完全隐藏（淡出动画结束后）卸载播放条子树：Impeller 下 Opacity(0.01)
  /// 常绘子树的 alpha 泄漏——子树内容以 ~10% 亮度透出成二级页幽灵 bar
  /// （消融实验证实与 BackdropFilter 无关）。淡出结束后整树停绘，恢复
  /// 显示时先挂回子树再从 0.01 淡入；恢复首帧即进磨砂降级窗口，shader
  /// 在 saveLayer 内不活跃，无黑闪
  bool _barGone = false;
  bool? _lastHidden;
  Timer? _barGoneTimer;

  /// 位置档位（是否坐在页面底部低位）：实时跟随当前页面，
  /// 变化通过与页面切换同节奏的隐式动画同步过渡
  bool _lowState = false;

  /// 与 _FixedChrome 的塌缩判据同源：根路径之外一律低位档。
  /// HidesShellChrome 计数保留作 OR 输入，但不再单独兜底——
  /// pushReplacement 等特殊入口下计数可能丢失，路由位置是可靠信号
  static const _rootPaths = {'/', '/home', '/mine'};

  /// mini 播放条页面黑名单（HideMiniBar 混入页）的路由路径：
  /// 持有期间播放条抹除吸附位置——原位淡出、不滑向低位档；
  /// 退出后路径离开集合，档位自动恢复常规跟随
  static const _barHiddenPaths = {
    '/settings',
    '/wallpaper',
    '/library/folders',
    '/search',
    '/home/toplists',
    '/account',
    '/leaderboard',
  };

  static bool _routeHidesBarOnly(String path) =>
      _barHiddenPaths.contains(path);

  static String _routerTopPath(RouteMatchList config) {
    final last = config.matches.lastOrNull;
    if (last is ImperativeRouteMatch) return last.matches.uri.path;
    if (last is RouteMatch) return last.matchedLocation;
    if (last is ShellRouteMatch) return last.matchedLocation;
    return config.uri.path;
  }

  bool get _routeLow => !_rootPaths
      .contains(_routerTopPath(appRouter.routerDelegate.currentConfiguration));

  bool get _routeKeepsBarHidden => _routeHidesBarOnly(
      _routerTopPath(appRouter.routerDelegate.currentConfiguration));

  @override
  void initState() {
    super.initState();
    _lowState = ref.read(navBarHiddenProvider) > 0 || _routeLow;
    if (_routeKeepsBarHidden) _lowState = false;
    // hiddenCount 的增减与路由切换都发生在页面进出（转场）期间，变化立即同步：
    // 档位滑动、显隐淡入淡出与页面切换动画同节奏、同步完成
    ref.listenManual(navBarHiddenProvider, (_, _) => _syncLow());
    ref.listenManual(miniBarHiddenProvider, (_, _) {
      _markBarFading();
      // 黑名单计数归零（pop 回可显示页）后补一次档位同步：routerDelegate
      // 的 pop 通知先于页面 dispose（计数帧末才减），若那次同步被跳过，
      // 档位会卡在隐藏期的值——条停错档
      _syncLow();
    });
    appRouter.routerDelegate.addListener(_syncLow);
    playerOpenNotifier.addListener(_onPlayerOpenChanged);
  }

  @override
  void dispose() {
    appRouter.routerDelegate.removeListener(_syncLow);
    playerOpenNotifier.removeListener(_onPlayerOpenChanged);
    _barFadeTimer?.cancel();
    _barGoneTimer?.cancel();
    super.dispose();
  }

  /// hidden 变化时调度子树卸载/挂回：淡出动画（240ms）结束后整树停绘；
  /// 恢复显示立即挂回并同步进磨砂降级窗口（0.01 saveLayer 内 shader 不活跃）
  void _syncBarGone(bool hidden) {
    if (_lastHidden == hidden) return;
    _lastHidden = hidden;
    if (hidden) {
      _barGoneTimer?.cancel();
      _barGoneTimer = Timer(const Duration(milliseconds: 320), () {
        if (mounted) setState(() => _barGone = true);
      });
    } else {
      _barGoneTimer?.cancel();
      if (_barGone) {
        _barGone = false;
        _barFadeTimer?.cancel();
        _barFading = true;
        _barFadeTimer = Timer(const Duration(milliseconds: 280), () {
          if (mounted) setState(() => _barFading = false);
        });
      }
    }
  }

  void _syncLow() {
    if (!mounted) return;
    // 档位实时跟随当前页面：变化通过与页面切换同节奏的隐式动画
    // 与转场同步完成，吸附也随切换动画同步执行；mini 播放条黑名单页
    // 持有期间抹除吸附位置（原位淡出，无吸附滑动）
    var low = ref.read(navBarHiddenProvider) > 0 || _routeLow;
    if (_routeKeepsBarHidden) low = false;
    if (low != _lowState) setState(() => _lowState = low);
  }

  void _onPlayerOpenChanged() {
    if (!mounted) return;
    _markBarFading();
    setState(() {});
  }

  /// 淡入淡出窗口内降级磨砂卡（chromeDur 约 240ms，留余量）：推迟到帧末
  /// 置位，确保转场首帧（opacity 恒 1，无 saveLayer）不被降级打断
  void _markBarFading() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _barFadeTimer?.cancel();
      setState(() => _barFading = true);
      _barFadeTimer = Timer(const Duration(milliseconds: 280), () {
        if (!mounted) return;
        setState(() => _barFading = false);
      });
    });
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
    double maxTop,
  ) {
    setState(() {
      _isPlayerDragging = false;
    });
    setGlobalDragging(false);

    final l = _playerLeft;
    final t = _playerTop;
    if (l == null || t == null) return;
    if (t >= maxTop - 12.0) {
      // 手动贴底（距停靠档 12px 内）才触发吸附归位——清除自定义位置，
      // 条滑回当前页面的停靠档位并恢复档位跟随（store 必须一并清空，
      // 否则 stale 的自定义位置会在 build 回退链中被重新采用，
      // 条永远回不到停靠档）
      _playerLeft = null;
      _playerTop = null;
      MiniBarPositionStore.shared = null;
      return;
    }
    MiniBarPositionStore.shared = Offset(l, t);
    _playerLeft = null;
    _playerTop = null;
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

    final playerOpen = playerOpenNotifier.value;

    // 黑名单页（设置/搜索等 HideMiniBar）持有期间隐藏：变化通过与
    // 切换动画同节奏的隐式动画与页面转场同步完成
    final pageHidesBar = ref.watch(miniBarHiddenProvider) > 0;
    final hidden = playerOpen || pageHidesBar;
    _syncBarGone(hidden);

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
            ? (_lowState
                ? (screenSize.height - safeBottom - 58.0 - 18.0)
                : (screenSize.height - safeBottom - 18.0 - 70.0 - 58.0))
            : (_lowState
                // 固定底栏在二级页同样塌缩隐藏（_FixedChrome 高度归零），
                // 低位停靠档与悬浮模式一致
                ? (screenSize.height - safeBottom - 58.0 - 18.0)
                : (screenSize.height - safeBottom - 58.0 - 64.0)));

    final batchLift = ref.watch(batchBarLiftProvider);
    final liftedDefaultTop = defaultTop - batchLift;

    final dragMaxTop = () {
      final barH = 58.0;
      if (isSide) return screenSize.height - safeBottom - barH - 12.0 - batchLift;
      if (floating) {
        return _lowState
            ? (screenSize.height - padding.bottom - barH - 12.0)
            : (screenSize.height - safeBottom - 18.0 - 70.0 - barH - batchLift);
      }
      return _lowState
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

    // 播放页在五级模型中高于播放条：推入时条立即让位（播放页物理盖过，
    // 无需渐隐）；返回露出时走 240ms 渐变
    final chromeDur = playerOpen
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
        // 最低 0.01 不归零：opacity=0 会整树停绘，再次显示首帧 backdrop
        // 采样未就绪闪黑；隐去期间保持绘制即无黑闪。Impeller 下 0.01
        // 常绘子树有 alpha 泄漏残影，淡出结束后由 _barGone 整树卸载
        opacity: hidden ? 0.01 : 1.0,
        child: _barGone
            ? const SizedBox.shrink()
            : AnimatedScale(
          duration: chromeDur,
          curve: Curves.easeOutCubic,
          scale: hidden ? 0.92 : 1.0,
          child: IgnorePointer(
            ignoring: hidden,
            child: MiniPlayerBar(
              degraded: hidden || _barFading,
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
              onPanEnd: (d) =>
                  _onPlayerPanEnd(d, defaultLeft, defaultTop, dragMaxTop),
              onPanCancel: _onPlayerPanCancel,
              registerTarget: !hidden,
              heroTag: hidden ? null : 'player-cover',
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
