import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class _HoldDragStartListener extends StatefulWidget {
  const _HoldDragStartListener({required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  State<_HoldDragStartListener> createState() => _HoldDragStartListenerState();
}

class _DelayedDragRecognizerListener extends ReorderableDelayedDragStartListener {
  const _DelayedDragRecognizerListener({
    required super.child,
    required super.index,
  });

  @override
  MultiDragGestureRecognizer createRecognizer() {
    return DelayedMultiDragGestureRecognizer(
      delay: const Duration(milliseconds: 300),
      debugOwner: this,
    );
  }
}

class _HoldDragStartListenerState extends State<_HoldDragStartListener> {
  Timer? _haptic;

  void _onDown(PointerDownEvent _) {
    _haptic?.cancel();
    _haptic = Timer(const Duration(milliseconds: 300), () {
      if (mounted) HapticFeedback.mediumImpact();
    });
  }

  void _clear() {
    _haptic?.cancel();
    _haptic = null;
  }

  @override
  void dispose() {
    _clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _onDown,
      child: _DelayedDragRecognizerListener(
        index: widget.index,
        child: widget.child,
      ),
    );
  }
}

class ReorderableRowDragStart extends StatelessWidget {
  const ReorderableRowDragStart({
    super.key,
    required this.index,
    required this.child,
  });

  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return _HoldDragStartListener(index: index, child: child);
  }
}

class DragHandle extends StatelessWidget {
  const DragHandle({
    super.key,
    required this.index,
    this.enabled = true,
    this.size = 22,
    this.width = 28,
    this.height = 44,
  });

  final int index;
  final bool enabled;
  final double size;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final icon = Icon(
      Icons.drag_indicator,
      size: size,
      color: Theme.of(context).colorScheme.outline,
    );
    return SizedBox(
      width: width,
      height: height,
      child: Center(
        child: enabled
            ? _HoldDragStartListener(index: index, child: icon)
            : icon,
      ),
    );
  }
}