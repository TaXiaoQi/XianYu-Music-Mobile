import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/player/player_provider.dart';

/// 正在播放页：现代毛玻璃风格。
/// 封面大圆角浮于流光背景之上，下方毛玻璃控制卡承载进度与按钮。
class PlayerPage extends ConsumerWidget {
  const PlayerPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerProvider);
    final current = player.current;
    final notifier = ref.read(playerProvider.notifier);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: scheme.surface,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 背景：封面取色氛围光斑
          const _AmbientBackground(),
          SafeArea(
            child: Column(
              children: [
                // 顶栏
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.keyboard_arrow_down, size: 28),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                      const Expanded(
                        child: Text(
                          '正在播放',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w600),
                        ),
                      ),
                      const SizedBox(width: 48), // 平衡左侧按钮宽度
                    ],
                  ),
                ),
                const Spacer(),
                // 封面（大圆角 + 柔和投影）
                const _BigCover(),
                const Spacer(),
                // 毛玻璃控制卡
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                  child: _GlassControlCard(
                    player: player,
                    notifier: notifier,
                    current: current,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 背景氛围光斑：用主题色与深色点缀营造流光感。
class _AmbientBackground extends StatelessWidget {
  const _AmbientBackground();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final primary = scheme.primary;
    return Stack(
      fit: StackFit.expand,
      children: [
        Container(color: scheme.surface),
        Positioned(
          top: -120,
          left: -80,
          child: _blob(primary.withValues(alpha: 0.28), 340),
        ),
        Positioned(
          bottom: -100,
          right: -90,
          child: _blob(primary.withValues(alpha: 0.16), 300),
        ),
        Positioned(
          top: 240,
          right: -120,
          child: _blob(scheme.tertiary.withValues(alpha: 0.12), 260),
        ),
        // 全屏模糊，把光斑晕开成柔光
        BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 60, sigmaY: 60),
          child: Container(color: Colors.transparent),
        ),
      ],
    );
  }

  Widget _blob(Color color, double size) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(shape: BoxShape.circle, color: color),
      );
}

/// 封面占位：渐变 + 音符，圆角与投影。
class _BigCover extends StatelessWidget {
  const _BigCover();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = MediaQuery.of(context).size.width * 0.62;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [scheme.primary, scheme.primary.withValues(alpha: 0.72)],
        ),
        boxShadow: [
          BoxShadow(
            color: scheme.primary.withValues(alpha: 0.35),
            blurRadius: 40,
            offset: const Offset(0, 18),
          ),
        ],
      ),
      child: Icon(Icons.music_note,
          size: size * 0.34, color: Colors.white.withValues(alpha: 0.92)),
    );
  }
}

/// 毛玻璃控制卡：标题 + 进度 + 播放控制。
class _GlassControlCard extends ConsumerWidget {
  const _GlassControlCard({
    required this.player,
    required this.notifier,
    required this.current,
  });
  final PlaybackState player;
  final PlayerNotifier notifier;
  final QueueItem? current;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final glassColor = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.white.withValues(alpha: 0.6);

    return ClipRRect(
      borderRadius: BorderRadius.circular(26),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
        child: Container(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
          decoration: BoxDecoration(
            color: glassColor,
            borderRadius: BorderRadius.circular(26),
            border: Border.all(
                color: Colors.white.withValues(alpha: isDark ? 0.12 : 0.5)),
          ),
          child: current == null
              ? const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: Text('暂无播放')),
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _TitleRow(current: current!),
                    const SizedBox(height: 14),
                    _ProgressBar(player: player, notifier: notifier),
                    const SizedBox(height: 6),
                    _Controls(player: player, notifier: notifier),
                  ],
                ),
        ),
      ),
    );
  }
}

class _TitleRow extends StatelessWidget {
  const _TitleRow({required this.current});
  final QueueItem current;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                current.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 3),
              Text(
                current.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        IconButton(
          icon: const Icon(Icons.favorite_border),
          onPressed: () {},
        ),
      ],
    );
  }
}

class _ProgressBar extends ConsumerWidget {
  const _ProgressBar({required this.player, required this.notifier});
  final PlaybackState player;
  final PlayerNotifier notifier;

  String _fmt(double s) {
    final m = s ~/ 60;
    final sec = (s % 60).floor();
    return '${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final dur = player.duration <= 0 ? 1.0 : player.duration;
    return Column(
      children: [
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3,
            activeTrackColor: scheme.primary,
            inactiveTrackColor: scheme.onSurface.withValues(alpha: 0.12),
            thumbColor: scheme.primary,
            overlayColor: scheme.primary.withValues(alpha: 0.16),
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
          ),
          child: Slider(
            value: player.position.clamp(0, dur),
            max: dur,
            onChanged: (v) => notifier.seek(v),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(_fmt(player.position),
                  style: TextStyle(
                      fontSize: 11, color: scheme.onSurfaceVariant)),
              Text(_fmt(dur),
                  style: TextStyle(
                      fontSize: 11, color: scheme.onSurfaceVariant)),
            ],
          ),
        ),
      ],
    );
  }
}

class _Controls extends ConsumerWidget {
  const _Controls({required this.player, required this.notifier});
  final PlaybackState player;
  final PlayerNotifier notifier;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final icons = [Icons.repeat, Icons.repeat_one, Icons.shuffle];
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        IconButton(
          iconSize: 21,
          icon: Icon(icons[player.playMode],
              color: scheme.onSurfaceVariant),
          onPressed: notifier.cyclePlayMode,
        ),
        IconButton(
          iconSize: 32,
          icon: const Icon(Icons.skip_previous),
          onPressed: notifier.previous,
        ),
        // 主题色实心播放键
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: scheme.primary,
            boxShadow: [
              BoxShadow(
                color: scheme.primary.withValues(alpha: 0.4),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: IconButton(
            icon: Icon(
              player.isPlaying ? Icons.pause : Icons.play_arrow,
              color: Colors.white,
            ),
            iconSize: 34,
            onPressed: notifier.toggle,
          ),
        ),
        IconButton(
          iconSize: 32,
          icon: const Icon(Icons.skip_next),
          onPressed: notifier.next,
        ),
        IconButton(
          iconSize: 21,
          icon: Icon(Icons.queue_music, color: scheme.onSurfaceVariant),
          onPressed: () {},
        ),
      ],
    );
  }
}
