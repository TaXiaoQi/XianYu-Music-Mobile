import 'package:flutter/material.dart';

import 'page_switch_tab_view.dart';

class LandscapeTabSwitcher extends StatefulWidget {
  const LandscapeTabSwitcher({
    super.key,
    required this.currentIndex,
    required this.children,
    this.enabled = true,
    this.suppress = false,
  });

  final int currentIndex;
  final List<Widget> children;

  final bool enabled;

  final bool suppress;

  @override
  State<LandscapeTabSwitcher> createState() => _LandscapeTabSwitcherState();
}

class _LandscapeTabSwitcherState extends State<LandscapeTabSwitcher>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim;
  late final CurvedAnimation _curved;

  int _shownIndex = 0;
  int _pendingIndex = -1;
  bool _animating = false;
  bool _outPhase = false;

  int _gen = 0;

  static const _fadeDuration = Duration(milliseconds: 220);
  static const _ease = Cubic(0.16, 1.0, 0.3, 1.0);

  @override
  void initState() {
    super.initState();
    _shownIndex = widget.currentIndex;
    _anim = AnimationController(vsync: this, duration: _fadeDuration)
      ..value = 1.0;
    _curved = CurvedAnimation(parent: _anim, curve: _ease);
  }

  @override
  void didUpdateWidget(covariant LandscapeTabSwitcher old) {
    super.didUpdateWidget(old);
    if (widget.currentIndex == old.currentIndex) return;
    _pendingIndex = widget.currentIndex;
    if (!widget.enabled || old.suppress) {
      _gen++;
      _animating = false;
      _outPhase = false;
      _anim.stop();
      _anim.value = 1.0;
      setState(() => _shownIndex = _pendingIndex);
      return;
    }
    if (_animating) {
      if (!_outPhase) _beginOut();
    } else {
      _beginOut();
    }
  }

  void _beginOut() {
    _animating = true;
    _outPhase = true;
    final gen = ++_gen;
    _anim.value = 0;
    _anim.forward().whenComplete(() {
      if (!mounted || gen != _gen) return;
      _onOutComplete();
    });
  }

  void _onOutComplete() {
    if (!mounted) return;
    final target = _pendingIndex;
    _outPhase = false;
    _anim.value = 0;
    setState(() => _shownIndex = target);
    if (target != widget.currentIndex) {
      _beginOut();
      return;
    }
    final gen = _gen;
    _anim.forward().whenComplete(() {
      if (!mounted || gen != _gen) return;
      if (mounted) setState(() => _animating = false);
    });
  }

  @override
  void dispose() {
    _curved.dispose();
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final stack = Stack(
      children: [
        for (var i = 0; i < widget.children.length; i++)
          KeyedSubtree(
            key: ValueKey('landscape-branch-$i'),
            child: Offstage(
              offstage: i != _shownIndex,
              child: TabKeepAlivePage(child: widget.children[i]),
            ),
          ),
      ],
    );

    return AnimatedBuilder(
      animation: _anim,
      child: stack,
      builder: (context, child) {
        final t = _curved.value;
        final double opacity;
        final double dy;
        final double scale;
        if (_outPhase) {
          opacity = 1 - t;
          dy = -6 * t;
          scale = 1 - 0.004 * t;
        } else {
          opacity = t;
          dy = 8 * (1 - t);
          scale = 0.996 + 0.004 * t;
        }
        return Opacity(
          opacity: opacity.clamp(0.0, 1.0),
          child: Transform.translate(
            offset: Offset(0, dy),
            child: Transform.scale(
              scale: scale,
              child: IgnorePointer(ignoring: _outPhase, child: child),
            ),
          ),
        );
      },
    );
  }
}
