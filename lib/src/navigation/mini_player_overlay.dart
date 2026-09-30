import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

  /// 位置档位（是否坐在页面底部低位）：实时跟随当前页面，
  /// 变化通过与页面切换同节奏的隐式动画同步过渡
  bool _lowState = false;

  @override
  void initState() {
    super.initState();
    _lowState = ref.read(navBarHiddenProvider) > 0;
    // hiddenCount 的增减都发生在页面进出（转场）期间，变化立即同步：
    // 档位滑动、显隐淡入淡出与页面切换动画同节奏、同步完成
    ref.listenManual(navBarHiddenProvider, (_, _) => _syncLow());
    playerOpenNotifier.addListener(_onPlayerOpenChanged);
  }

  @override
  void dispose() {
    playerOpenNotifier.removeListener(_onPlayerOpenChanged);
    super.dispose();
  }

  void _syncLow() {
    if (!mounted) return;
    // 档位实时跟随当前页面：变化通过与页面切换同节奏的隐式动画
    // 与转场同步完成，吸附也随切换动画同步执行
    final low = ref.read(navBarHiddenProvider) > 0;
    if (low != _lowState) setState(() => _lowState = low);
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
    double maxTop,
  ) {
    setState(() {
      _isPlayerDragging = false;
    });
    setGlobalDragging(false);

    final l = _playerLeft;
    final t = _playerTop;
    if (l == null || t == null) return;
    if (t >= maxTop - 48.0) {
      // 停在底部停靠带内：吸附归位——清除自定义位置，条滑回当前页面的
      // 停靠档位并恢复档位跟随（store 必须一并清空，否则 stale 的
      // 自定义位置会在 build 回退链中被重新采用，条永远回不到停靠档）
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
            : (screenSize.height - safeBottom - 58.0 - 64.0));

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
