import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/app_logger.dart';
import '../core/settings.dart';
import '../navigation/page_switch_tab_view.dart';
import 'predictive_back_transitions.dart';

/// 两个根 Tab 之间的「预测返回」。
///
/// 在「我的」根 tab 上做系统边缘返回手势时，跟手预览首页分支并从下方露出，
/// 「我的」分支按预测返回行程缩放/位移/淡出（复用播放页同款
/// [PredictiveBackSharedElementPageTransition]）；提交（松手确认返回）时
/// `goBranch(0)` 切回首页，取消时原路还原。与二级页的预测返回体验统一。
///
/// 仅当：非二级页（无 pop 路由）、不在首页分支、且全局预测返回开关开启时
/// 认领手势。其余情况（首页双击退出 / 二级页 pop / 关闭预测返回）保持原行为，
/// 由 shell 的 PopScope + _handleBack 手动分发兜底。
class PredictiveBackTabContainer extends ConsumerStatefulWidget {
  const PredictiveBackTabContainer({
    super.key,
    required this.navigationShell,
    required this.currentIndex,
    required this.children,
  });

  final StatefulNavigationShell navigationShell;
  final int currentIndex;
  final List<Widget> children;

  @override
  ConsumerState<PredictiveBackTabContainer> createState() =>
      _PredictiveBackTabContainerState();
}

class _PredictiveBackTabContainerState
    extends ConsumerState<PredictiveBackTabContainer>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  /// 页面转场动画值：1 = 完全显示，0 = 完全隐藏（与路由 animation 同语义）。
  late final AnimationController _ctrl;
  PredictiveBackPhase _phase = PredictiveBackPhase.idle;
  PredictiveBackEvent? _startBackEvent;
  PredictiveBackEvent? _currentBackEvent;

  /// 手势开始时所在分支（即退出分支），commit 后 currentIndex 已变为 0，
  /// 但退出动画仍需它，故在认领时锁定。
  int _exitIndex = 1;

  static const _commitDuration = Duration(milliseconds: 400);
  static const _cancelDuration = Duration(milliseconds: 200);

  bool get _inTransition => _phase != PredictiveBackPhase.idle;

  /// 手指拖动切换整页停留后回调：把当前索引同步给 GoRouter 底栏，
  /// 并让 `currentIndex` 变化去驱动收藏/底栏高亮等派生 UI。
  void _onPageSettled(int index) {
    if (index == widget.currentIndex) return;
    widget.navigationShell.goBranch(
      index,
      initialLocation: index == widget.currentIndex,
    );
  }

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, value: 1.0);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ctrl.dispose();
    super.dispose();
  }

  bool _shouldClaim(PredictiveBackEvent backEvent) {
    if (backEvent.isButtonEvent) return false;
    if (widget.children.length < 2) return false;
    if (widget.currentIndex == 0) return false;
    if (GoRouter.of(context).canPop()) return false;
    return ref.read(settingsProvider).valueOrNull?.enablePredictiveBack ?? true;
  }

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) {
    // 荣耀等 OEM 系统会在同一次返回手势内重复派发 onBackStarted：框架每收到
    // 一次 startBackGesture 都会清空 _backGestureObservers 再重新收集，若行程中
    // 这里返回 false，observer 列表变空，后续 updateBackGestureProgress 会被框架
    // 直接丢弃——表现为「触控返回不传滑动数值、无法预测返回」。因此行程中
    // 无条件重新认领（不重置行程），保住 observer 让进度持续送达。
    if (_phase == PredictiveBackPhase.start || _phase == PredictiveBackPhase.update) {
      AppLogger.instance.log('backgesture', 'tab 重复 start 重新认领 progress=${backEvent.progress.toStringAsFixed(3)}');
      return true;
    }
    if (!_shouldClaim(backEvent)) return false;
    _exitIndex = widget.currentIndex;
    _ctrl.stop();
    _ctrl.value = 1 - backEvent.progress;
    setState(() {
      _phase = PredictiveBackPhase.start;
      _startBackEvent = backEvent;
      _currentBackEvent = backEvent;
    });
    AppLogger.instance.log('backgesture', 'tab 认领 start idx=$_exitIndex progress=${backEvent.progress.toStringAsFixed(3)}');
    return true;
  }

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent backEvent) {
    _ctrl.value = 1 - backEvent.progress;
    setState(() {
      _phase = PredictiveBackPhase.update;
      _currentBackEvent = backEvent;
    });
    AppLogger.instance.log('backgesture', 'tab update progress=${backEvent.progress.toStringAsFixed(3)}');
  }

  @override
  void handleCommitBackGesture() {
    if (!_inTransition) return;
    AppLogger.instance.log('backgesture', 'tab commit');
    setState(() => _phase = PredictiveBackPhase.commit);
    _startBackEvent = null;
    _currentBackEvent = null;
    // 切回首页 tab。此时仍处于 overlay 模式（commit 动画期间），由
    // PredictiveBackSharedElementPageTransition 负责「我的」缩放+下移+淡出收尾；
    // 动画结束后切回 AnimatedBranchContainer 正常路径，首页无缝衔接。
    widget.navigationShell.goBranch(0);
    _ctrl.animateTo(0.0, duration: _commitDuration).whenComplete(() {
      if (mounted) setState(() => _phase = PredictiveBackPhase.idle);
    });
  }

  @override
  void handleCancelBackGesture() {
    if (!_inTransition) return;
    AppLogger.instance.log('backgesture', 'tab cancel');
    setState(() => _phase = PredictiveBackPhase.cancel);
    _startBackEvent = null;
    _currentBackEvent = null;
    _ctrl.animateTo(1.0, duration: _cancelDuration).whenComplete(() {
      if (mounted) setState(() => _phase = PredictiveBackPhase.idle);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_inTransition) {
      return PageSwitchTabView(
        currentIndex: widget.currentIndex,
        children: widget.children,
        onPageSettled: _onPageSettled,
      );
    }
    final exit = _exitIndex < widget.children.length
        ? widget.children[_exitIndex]
        : (widget.children.isEmpty
            ? const SizedBox.shrink()
            : widget.children.last);
    // 首页分支作为「上一屏」静态垫底；忽略指针，预览期间不可交互。
    final home = widget.children.isEmpty ? null : widget.children[0];
    return Stack(
      children: [
        if (home != null) Positioned.fill(child: IgnorePointer(child: home)),
        Positioned.fill(
          child: PredictiveBackSharedElementPageTransition(
            animation: _ctrl,
            secondaryAnimation: kAlwaysDismissedAnimation,
            phase: _phase,
            startBackEvent: _startBackEvent,
            currentBackEvent: _currentBackEvent,
            child: exit,
          ),
        ),
      ],
    );
  }
}
