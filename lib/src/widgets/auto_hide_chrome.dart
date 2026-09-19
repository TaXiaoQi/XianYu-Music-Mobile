import 'package:flutter/material.dart';

class AutoHideChrome extends StatelessWidget {
  const AutoHideChrome({
    super.key,
    required this.visible,
    required this.alignment,
    required this.child,
  });

  final bool visible;

  final AlignmentGeometry alignment;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: AnimatedSize(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOutCubic,
        alignment: alignment,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          opacity: visible ? 1 : 0,
          child: visible
              ? child
              : const SizedBox(width: double.infinity),
        ),
      ),
    );
  }
}
