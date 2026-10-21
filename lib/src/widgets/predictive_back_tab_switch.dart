import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/settings.dart';
import '../navigation/landscape_tab_switcher.dart';
import '../navigation/page_switch_tab_view.dart';
import '../navigation/shell.dart'
    show
        isLandscapeProvider,
        landscapePaneOpenProvider,
        landscapeLibraryProvider;
import 'predictive_back_transitions.dart';

class PredictiveBackTabContainer extends ConsumerStatefulWidget {
  const PredictiveBackTabContainer({
    super.key,
    required this.navigationShell,
    required this.currentIndex,
    required this.children,
    required this.branchIndices,
  });

  final StatefulNavigationShell navigationShell;
  final int currentIndex;
  final List<Widget> children;

  /// children[i] 对应的 shell 分支索引（分支注册序，恒为 0..n-1）；
  /// 容器内按导航栏管理的显示顺序重排，滑动/返回手势经此换算 goBranch
  final List<int> branchIndices;

  @override
  ConsumerState<PredictiveBackTabContainer> createState() =>
      _PredictiveBackTabContainerState();
}

class _PredictiveBackTabContainerState
    extends ConsumerState<PredictiveBackTabContainer>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  late final AnimationController _ctrl;
  PredictiveBackPhase _phase = PredictiveBackPhase.idle;

  final BackGestureProgressSynth _synth = BackGestureProgressSynth();

  static const _commitDuration = Duration(milliseconds: 400);
  static const _cancelDuration = Duration(milliseconds: 200);

  bool get _inTransition => _phase != PredictiveBackPhase.idle;

  /// 显示序的分支索引（导航栏管理排序过滤插件后的结果）。
  /// PageView/返回手势的页位置都是显示序，goBranch 前经此换算。
  /// build 期传 watch 到的 settings，排序变化即时重排
  List<int> _computeDisplayedBranches(dynamic settings) {
    final showPlugins = settings?.navShowPlugins ?? false;
    final order = settings?.navOrderPortrait ?? kDefaultNavOrder;
    final byBranch = <int, Widget>{
      for (var i = 0; i < widget.children.length; i++)
        widget.branchIndices[i]: widget.children[i],
    };
    final out = <int>[];
    for (final id in order) {
      final bi = switch (id) {
        'home' => 0,
        'mine' => 1,
        'plugin' => 2,
        _ => null,
      };
      if (bi == null || !byBranch.containsKey(bi)) continue;
      if (id == 'plugin' && !showPlugins) continue;
      out.add(bi);
    }
    if (out.isEmpty) out.addAll(byBranch.keys);
    return out;
  }

  List<int> _dispBranches = const [0, 1];

  int _dispPosOf(int branchIndex) {
    final i = _dispBranches.indexOf(branchIndex);
    return i < 0 ? 0 : i;
  }

  void _onPageSettled(int page) {
    if (page < 0 || page >= _dispBranches.length) return;
    final bi = _dispBranches[page];
    if (bi == widget.currentIndex) return;
    widget.navigationShell.goBranch(
      bi,
      initialLocation: bi == widget.currentIndex,
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
    if (ref.read(isLandscapeProvider)) return false;
    if (_dispBranches.length < 2) return false;
    // 仅在最左页禁用返回手势（显示序语义，首页不一定排第一）
    if (_dispPosOf(widget.currentIndex) == 0) return false;
    if (GoRouter.of(context).canPop()) return false;
    return ref.read(settingsProvider).valueOrNull?.enablePredictiveBack ?? false;
  }

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) {
    if (_phase == PredictiveBackPhase.start || _phase == PredictiveBackPhase.update) {
      return true;
    }
    if (!_shouldClaim(backEvent)) return false;
    _ctrl.stop();
    _synth.reset();
    _ctrl.value = 1 - _synth.progressOf(backEvent);
    setState(() => _phase = PredictiveBackPhase.start);
    return true;
  }

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent backEvent) {
    // ROM 门控时系统 progress 恒 0（见 BackGestureProgressSynth），tab 返回
    // 同样需要触点合成进度，否则手势全程冻结、松手直接跳 commit
    final effective = _synth.progressOf(backEvent);
    _ctrl.value = 1 - effective;
    setState(() => _phase = PredictiveBackPhase.update);
  }

  @override
  void handleCommitBackGesture() {
    if (!_inTransition) return;
    setState(() => _phase = PredictiveBackPhase.commit);
    // 回到显示序最左页（排序后不一定是首页分支 0）
    widget.navigationShell.goBranch(
      _dispBranches[0],
      initialLocation: _dispBranches[0] == widget.currentIndex,
    );
    _ctrl.animateTo(0.0, duration: _commitDuration, curve: Curves.easeOutCubic).whenComplete(() {
      if (mounted) setState(() => _phase = PredictiveBackPhase.idle);
    });
  }

  @override
  void handleCancelBackGesture() {
    if (!_inTransition) return;
    setState(() => _phase = PredictiveBackPhase.cancel);
    _ctrl.animateTo(1.0, duration: _cancelDuration, curve: Curves.easeOutCubic).whenComplete(() {
      if (mounted) setState(() => _phase = PredictiveBackPhase.idle);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (ref.watch(isLandscapeProvider)) {
      // 横屏 Stack 按 branchIndices 直取页，顺序无关，rail 已按显示序
      return LandscapeTabSwitcher(
        currentIndex: widget.currentIndex,
        enabled: ref.watch(settingsProvider.select(
            (s) => s.valueOrNull?.landscapeTransitionEnabled ?? true)),
        suppress: ref.watch(landscapePaneOpenProvider) ||
            ref.watch(landscapeLibraryProvider) != null,
        children: widget.children,
      );
    }
    // 竖屏：按导航栏管理排序重排 children（带 key 保证 keepalive 状态跟随分支）
    _dispBranches = _computeDisplayedBranches(
        ref.watch(settingsProvider).valueOrNull);
    final dispChildren = [
      for (final bi in _dispBranches)
        widget.children[widget.branchIndices.indexOf(bi)],
    ];
    final dispPos = _dispPosOf(widget.currentIndex);
    if (!_inTransition) {
      return PageSwitchTabView(
        currentIndex: dispPos,
        onPageSettled: _onPageSettled,
        children: [
          for (var i = 0; i < dispChildren.length; i++)
            KeyedSubtree(
              key: ValueKey('branch-${_dispBranches[i]}'),
              child: dispChildren[i],
            ),
        ],
      );
    }
    final exit = dispPos < dispChildren.length
        ? dispChildren[dispPos]
        : (dispChildren.isEmpty
            ? const SizedBox.shrink()
            : dispChildren.last);
    final home = dispChildren.isEmpty ? null : dispChildren[0];
    return Stack(
      children: [
        if (home != null) Positioned.fill(child: IgnorePointer(child: home)),
        Positioned.fill(
          child: AnimatedBuilder(
            animation: _ctrl,
            builder: (context, _) => FractionalTranslation(
              // 平移返回：当前 tab 页随手势整体右移、下层首页静止透出；
              // commit 时滑出屏幕，cancel 时滑回原位。
              // 此前用的是整页缩小卡片（shared element），与二级页返回
              // 动画同形，tab 切换语义下应为平移
              translation: Offset(1 - _ctrl.value, 0),
              child: exit,
            ),
          ),
        ),
      ],
    );
  }
}
