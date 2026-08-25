import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../core/settings.dart';
import '../player/player_provider.dart';
import 'cover_image.dart';
import 'glass_settings.dart';

/// 迷你播放条：旋转封面 + 环形进度 + 上一首/播放/下一首，支持手势拖拽与防透传点击。
class MiniPlayerBar extends ConsumerStatefulWidget {
  const MiniPlayerBar({
    super.key,
    this.onPanStart,
    this.onPanUpdate,
    this.onPanEnd,
    this.onPanCancel,
  });

  final GestureDragStartCallback? onPanStart;
  final GestureDragUpdateCallback? onPanUpdate;
  final GestureDragEndCallback? onPanEnd;
  final VoidCallback? onPanCancel;

  @override
  ConsumerState<MiniPlayerBar> createState() => _MiniPlayerBarState();
}

class _MiniPlayerBarState extends ConsumerState<MiniPlayerBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin;

  @override
  void initState() {
    super.initState();
    _spin = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    );
    if (ref.read(playerProvider).isPlaying) _spin.repeat();
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = ref.watch(playerProvider);
    final current = player.current;
    if (current == null) return const SizedBox.shrink();

    // 播放时旋转封面，暂停时停住（在 build 后回调，避免 build 中 setState）。
    ref.listen(playerProvider, (prev, next) {
      if (next.isPlaying && !_spin.isAnimating) {
        _spin.repeat();
      } else if (!next.isPlaying && _spin.isAnimating) {
        _spin.stop();
      }
    });

    final scheme = Theme.of(context).colorScheme;
    final progress = player.duration <= 0
        ? 0.0
        : (player.position / player.duration).clamp(0.0, 1.0);

    final lowPerf = ref.watch(
      settingsProvider.select(
          (s) => performancePriority(s.valueOrNull ?? const AppSettings())),
    );
    final liquid =
        (ref.watch(settingsProvider.select((s) => s.valueOrNull?.liquidGlass)) ??
            true) &&
            !lowPerf;

    final content = Padding(
      padding: const EdgeInsets.fromLTRB(6, 6, 10, 6),
      child: Row(
        children: [
          _RotatingDisc(
            current: current,
            progress: progress,
            spin: _spin,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  current.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  current.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.skip_previous),
            iconSize: 22,
            onPressed: () => ref.read(playerProvider.notifier).previous(),
          ),
          IconButton(
            icon: Icon(
              player.isPlaying ? Icons.pause : Icons.play_arrow,
              color: scheme.primary,
            ),
            iconSize: 26,
            onPressed: () => ref.read(playerProvider.notifier).toggle(),
          ),
          IconButton(
            icon: const Icon(Icons.skip_next),
            iconSize: 22,
            onPressed: () => ref.read(playerProvider.notifier).next(),
          ),
        ],
      ),
    );

    return GestureDetector(
      onPanStart: widget.onPanStart,
      onPanUpdate: widget.onPanUpdate,
      onPanEnd: widget.onPanEnd,
      onPanCancel: widget.onPanCancel,
      onTap: () => context.push('/player'),
      behavior: HitTestBehavior.opaque,
      child: liquid
          ? _liquidSurface(context, content)
          : _frostedSurface(context, content, lowPerf: lowPerf),
    );
  }

  /// 液态玻璃表面：与底栏同一套参数，保证两者观感一致。
  Widget _liquidSurface(BuildContext context, Widget content) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return AdaptiveGlass(
      // 高 58，圆角取一半成胶囊。
      shape: const LiquidRoundedRectangle(borderRadius: 29),
      settings: liquidGlassSettings(isDark),
      // 常驻浮层：premium 全管线 shader 在二级页面滚动时持续重算会超 GPU 预算，
      // 改用轻量 shader 的 standard（5-10x 更快，文档推荐滚动/常驻场景）。
      quality: GlassQuality.standard,
      child: SizedBox(height: 58, child: content),
    );
  }

  /// 毛玻璃表面：液态玻璃关闭时使用。
  Widget _frostedSurface(BuildContext context, Widget content, {bool lowPerf = false}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = lowPerf
        ? (isDark ? const Color(0xE62A2A2E) : const Color(0xF0FFFFFF))
        : (isDark
            ? Colors.white.withValues(alpha: 0.10)
            : Colors.white.withValues(alpha: 0.52));
    final border = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : Colors.white.withValues(alpha: 0.40);
    final surface = Container(
      height: 58,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.45 : 0.2),
            blurRadius: 26,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: content,
    );
    if (lowPerf) return surface;
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: surface,
      ),
    );
  }
}

/// 旋转封面 + 环形进度。
class _RotatingDisc extends StatelessWidget {
  const _RotatingDisc({
    required this.current,
    required this.progress,
    required this.spin,
  });

  final QueueItem current;
  final double progress;
  final AnimationController spin;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 46,
      height: 46,
      child: CustomPaint(
        painter: _RingPainter(
          progress: progress,
          color: Theme.of(context).colorScheme.primary,
        ),
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: ClipOval(
            child: AnimatedBuilder(
              animation: spin,
              builder: (context, _) => Transform.rotate(
                angle: spin.value * 2 * math.pi,
                child: CoverImage(
                  songPath: current.path,
                  networkUrl: current.coverUrl,
                  width: 40,
                  height: 40,
                  radius: 0,
                  icon: Icons.music_note,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter({required this.progress, required this.color});
  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 3.0;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - stroke / 2;
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = Colors.white.withValues(alpha: 0.12);
    canvas.drawCircle(center, radius, track);
    if (progress > 0) {
      final arc = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = color;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -math.pi / 2,
        2 * math.pi * progress.clamp(0.0, 1.0),
        false,
        arc,
      );
    }
  }

  @override
  bool shouldRepaint(_RingPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.color != color;
}
