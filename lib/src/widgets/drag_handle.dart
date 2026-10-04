import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../player/player_provider.dart';
import '../theme/theme_icon.dart';

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

class DragHandle extends ConsumerWidget {
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
  Widget build(BuildContext context, WidgetRef ref) {
    final icon = themeSlotIcon(
      ref,
      'lib.drag',
      fallback: Icons.drag_indicator,
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

/// 桌面端同款两位序号：01、02…
String padRowIndex(int index) => (index + 1).toString().padLeft(2, '0');

/// 行首槽位（桌面端 SongTable 同款三态）：
/// 当前播放行显示频谱条（播放=动画/暂停=静态），其余默认显示序号；
/// draggable 时按住约 300ms 变为拖拽把手并触发拖拽，松手还原序号。
class SongRowLeading extends ConsumerStatefulWidget {
  const SongRowLeading({
    super.key,
    required this.index,
    required this.songPath,
    this.draggable = false,
  });

  final int index;
  final String songPath;
  final bool draggable;

  @override
  ConsumerState<SongRowLeading> createState() => _SongRowLeadingState();
}

class _SongRowLeadingState extends ConsumerState<SongRowLeading> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final currentPath =
        ref.watch(playerProvider.select((s) => s.current?.path));
    final isPlaying = ref.watch(playerProvider.select((s) => s.isPlaying));
    final scheme = Theme.of(context).colorScheme;

    Widget child;
    if (currentPath != null && currentPath == widget.songPath) {
      child = _SpectrumBars(playing: isPlaying);
    } else if (widget.draggable && _pressed) {
      child = themeSlotIcon(
        ref,
        'lib.drag',
        fallback: Icons.drag_indicator,
        size: 22,
        color: scheme.outline,
      );
    } else {
      child = Text(
        padRowIndex(widget.index),
        style: TextStyle(
          fontSize: 12,
          fontFeatures: const [FontFeature.tabularFigures()],
          color: scheme.outline,
        ),
      );
    }

    return Listener(
      onPointerDown: widget.draggable
          ? (_) {
              if (!_pressed) setState(() => _pressed = true);
            }
          : null,
      onPointerUp: (_) {
        if (_pressed) setState(() => _pressed = false);
      },
      onPointerCancel: (_) {
        if (_pressed) setState(() => _pressed = false);
      },
      child: SizedBox(
        width: 28,
        height: 44,
        child: Center(
          child: widget.draggable
              ? _HoldDragStartListener(index: widget.index, child: child)
              : child,
        ),
      ),
    );
  }
}

/// 频谱条：复刻桌面 spectrum keyframes（0%:4 25%:14 50%:6 75%:12 100%:4，
/// 延迟 0/0.2/0.4s）；暂停时为静态短条 6/10/4（60% 透明度）。
class _SpectrumBars extends StatefulWidget {
  const _SpectrumBars({required this.playing});

  final bool playing;

  @override
  State<_SpectrumBars> createState() => _SpectrumBarsState();
}

class _SpectrumBarsState extends State<_SpectrumBars>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  );

  @override
  void initState() {
    super.initState();
    if (widget.playing) _c.repeat();
  }

  @override
  void didUpdateWidget(covariant _SpectrumBars oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.playing != oldWidget.playing) {
      widget.playing ? _c.repeat() : _c.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  double _heightOf(double t) {
    t = t % 1.0;
    const vals = [4.0, 14.0, 6.0, 12.0, 4.0];
    for (var i = 0; i < 4; i++) {
      if (t <= (i + 1) * 0.25) {
        final f = (t - i * 0.25) / 0.25;
        return vals[i] + (vals[i + 1] - vals[i]) * f;
      }
    }
    return 4;
  }

  Widget _bar(double height, double alpha) => Container(
        width: 3,
        height: height,
        decoration: BoxDecoration(
          color: const Color(0xFFEC4141).withValues(alpha: alpha),
          borderRadius: BorderRadius.circular(2),
        ),
      );

  @override
  Widget build(BuildContext context) {
    if (!widget.playing) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _bar(6, 0.6),
          const SizedBox(width: 3),
          _bar(10, 0.6),
          const SizedBox(width: 3),
          _bar(4, 0.6),
        ],
      );
    }
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _bar(_heightOf(_c.value - 0.0), 1),
          const SizedBox(width: 3),
          _bar(_heightOf(_c.value - 0.2), 1),
          const SizedBox(width: 3),
          _bar(_heightOf(_c.value - 0.4), 1),
        ],
      ),
    );
  }
}