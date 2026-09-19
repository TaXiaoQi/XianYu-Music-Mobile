import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/app_logger.dart';
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
  late final AnimationController _ctrl;
  PredictiveBackPhase _phase = PredictiveBackPhase.idle;
  PredictiveBackEvent? _startBackEvent;
  PredictiveBackEvent? _currentBackEvent;

  int _exitIndex = 1;

  static const _commitDuration = Duration(milliseconds: 400);
  static const _cancelDuration = Duration(milliseconds: 200);

  bool get _inTransition => _phase != PredictiveBackPhase.idle;

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
    if (ref.read(isLandscapeProvider)) return false;
    if (widget.children.length < 2) return false;
    if (widget.currentIndex == 0) return false;
    if (GoRouter.of(context).canPop()) return false;
    return ref.read(settingsProvider).valueOrNull?.enablePredictiveBack ?? false;
  }

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) {
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
    if (ref.watch(isLandscapeProvider)) {
      return LandscapeTabSwitcher(
        currentIndex: widget.currentIndex,
        enabled: ref.watch(settingsProvider.select(
            (s) => s.valueOrNull?.landscapeTransitionEnabled ?? true)),
        suppress: ref.watch(landscapePaneOpenProvider) ||
            ref.watch(landscapeLibraryProvider) != null,
        children: widget.children,
      );
    }
    if (!_inTransition) {
      return PageSwitchTabView(
        currentIndex: widget.currentIndex,
        onPageSettled: _onPageSettled,
        children: widget.children,
      );
    }
    final exit = _exitIndex < widget.children.length
        ? widget.children[_exitIndex]
        : (widget.children.isEmpty
            ? const SizedBox.shrink()
            : widget.children.last);
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
