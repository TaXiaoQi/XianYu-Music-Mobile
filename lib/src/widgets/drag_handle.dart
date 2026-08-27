import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 长按 0.3 秒才触发的拖动监听（与音源页已安装插件一致）：默认
/// ReorderableDelayedDragStartListener 固定为系统长按时长（约 500ms），这里显式
/// 缩短到 0.3 秒，平衡「避免滑动手感卡顿」与「拖动响应速度」。同时在该延迟到期
/// （可开始移动）的那一刻触发一次触觉反馈，与拖拽真正可移动的时机对齐。
///
/// 只能挂在 ReorderableListView / SliverReorderableList 的某个子项内部。
class _HoldDragStartListener extends StatefulWidget {
  const _HoldDragStartListener({required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  State<_HoldDragStartListener> createState() => _HoldDragStartListenerState();
}

/// 把底层拖拽识别延迟固定为与触觉反馈一致的 0.3s。
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
    // Listener 不参与手势竞技场，仅用于与拖拽延迟(0.3s)对齐的触觉反馈；
    // 拖拽识别由内层延迟监听在 0.3s 时触发，二者时刻一致。
    return Listener(
      onPointerDown: _onDown,
      child: _DelayedDragRecognizerListener(
        index: widget.index,
        child: widget.child,
      ),
    );
  }
}

/// 可拖动排序的拖动把手：长按图标 0.3 秒进入拖拽；[enabled] 为 false 时仅展示图标。
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