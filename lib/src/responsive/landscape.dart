import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../navigation/shell.dart' show isLandscapeProvider;

class LandscapeGate extends ConsumerWidget {
  const LandscapeGate({
    super.key,
    required this.portrait,
    required this.landscape,
  }) : sequential = false;

  const LandscapeGate.sequential({
    super.key,
    required this.portrait,
    required this.landscape,
  }) : sequential = true;

  final Widget portrait;

  final Widget landscape;

  final bool sequential;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isLandscape = ref.watch(isLandscapeProvider);
    if (sequential) {
      return _SequentialFadeGate(
        isLandscape: isLandscape,
        portrait: portrait,
        landscape: landscape,
      );
    }
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 240),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      layoutBuilder: (currentChild, previousChildren) => Stack(
        fit: StackFit.expand,
        alignment: Alignment.center,
        children: [...previousChildren, ?currentChild],
      ),
      child: KeyedSubtree(
        key: ValueKey(isLandscape),
        child: isLandscape ? landscape : portrait,
      ),
    );
  }
}

class _SequentialFadeGate extends StatefulWidget {
  const _SequentialFadeGate({
    required this.isLandscape,
    required this.portrait,
    required this.landscape,
  });

  final bool isLandscape;
  final Widget portrait;
  final Widget landscape;

  @override
  State<_SequentialFadeGate> createState() => _SequentialFadeGateState();
}

class _SequentialFadeGateState extends State<_SequentialFadeGate>
    with SingleTickerProviderStateMixin {
  AnimationController? _cC;
  AnimationController get _c => _cC ??= AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 130),
  );

  late bool _showLandscape = widget.isLandscape;

  int _gen = 0;

  @override
  void didUpdateWidget(_SequentialFadeGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isLandscape != widget.isLandscape) {
      _swapTo(widget.isLandscape);
    }
  }

  Future<void> _swapTo(bool target) async {
    final gen = ++_gen;
    try {
      await _c.forward().orCancel;
    } catch (_) {
      return;
    }
    if (!mounted || gen != _gen) return;
    setState(() => _showLandscape = target);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || gen != _gen) return;
    _c.duration = const Duration(milliseconds: 200);
    try {
      await _c.reverse().orCancel;
    } catch (_) {
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 1, end: 0).animate(
        CurvedAnimation(parent: _c, curve: Curves.easeInOut),
      ),
      child: _showLandscape ? widget.landscape : widget.portrait,
    );
  }

  @override
  void dispose() {
    _cC?.dispose();
    super.dispose();
  }
}

bool useLandscape(WidgetRef ref) => ref.watch(isLandscapeProvider);