import 'package:flutter/material.dart';

class CoverFadeIn {
  const CoverFadeIn._();

  static const Duration duration = Duration(milliseconds: 300);

  static ImageFrameBuilder frameBuilder({required Widget placeholder}) {
    return (context, child, frame, wasSynchronouslyLoaded) {
      if (wasSynchronouslyLoaded) return child;
      if (frame == null) return placeholder;
      return _FadeInOnLoad(child: child);
    };
  }
}

class _FadeInOnLoad extends StatefulWidget {
  const _FadeInOnLoad({required this.child});

  final Widget child;

  @override
  State<_FadeInOnLoad> createState() => _FadeInOnLoadState();
}

class _FadeInOnLoadState extends State<_FadeInOnLoad>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: CoverFadeIn.duration,
      value: 0,
    );
    _opacity = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(opacity: _opacity, child: widget.child);
  }
}
