import 'package:flutter/material.dart';

class LandscapePageFade extends StatefulWidget {
  const LandscapePageFade({
    super.key,
    required this.open,
    required this.trigger,
    required this.child,
  });

  final bool open;

  final Object? trigger;

  final Widget? child;

  static const _duration = Duration(milliseconds: 220);
  static const _ease = Cubic(0.16, 1.0, 0.3, 1.0);

  @override
  State<LandscapePageFade> createState() => _LandscapePageFadeState();
}

class _LandscapePageFadeState extends State<LandscapePageFade>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;
  late final Animation<double> _scale;

  Widget? _shown;

  bool _out = false;

  Widget? _pending;

  int _gen = 0;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: LandscapePageFade._duration);
    final curve = CurvedAnimation(
      parent: _c,
      curve: LandscapePageFade._ease,
    );
    _fade = curve;
    _slide = Tween<Offset>(
      begin: const Offset(0, 8),
      end: Offset.zero,
    ).animate(curve);
    _scale = Tween<double>(begin: 0.996, end: 1).animate(curve);
    if (widget.open && widget.child != null) {
      _shown = widget.child;
      _c.forward();
    }
  }

  @override
  void didUpdateWidget(LandscapePageFade old) {
    super.didUpdateWidget(old);
    if (!widget.open || widget.child == null) {
      if (_shown != null && !_out) _beginOut(null);
      return;
    }
    if (_shown == null) {
      setState(() => _shown = widget.child);
      _c.forward(from: 0);
    } else if (widget.trigger != old.trigger) {
      if (_out) {
        _pending = widget.child;
      } else {
        _beginOut(widget.child);
      }
    } else {
      _shown = widget.child;
    }
  }

  void _beginOut(Widget? target) {
    _out = true;
    _pending = target;
    final gen = ++_gen;
    _c.reverse().whenComplete(() {
      if (!mounted || gen != _gen) return;
      setState(() {
        _shown = _pending;
        _pending = null;
        _out = false;
      });
      if (_shown != null) _c.forward(from: 0);
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    if (shown == null) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: _c,
      child: shown,
      builder: (context, child) {
        final t = _c.value;
        if (_out) {
          return Opacity(
            opacity: t,
            child: Transform.translate(
              offset: Offset(0, -6 * (1 - t)),
              child: Transform.scale(
                scale: 0.996 + 0.004 * t,
                child: child,
              ),
            ),
          );
        }
        return Transform.translate(
          offset: _slide.value,
          child: Transform.scale(
            scale: _scale.value,
            child: Opacity(opacity: _fade.value, child: child),
          ),
        );
      },
    );
  }
}
