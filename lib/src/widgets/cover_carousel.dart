import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../player/player_provider.dart';
import 'cover_image.dart';

/// 封面轮播：展示播放队列封面，自动轮播 + 红色"播放中"徽章 + 频谱动效。
class CoverCarousel extends ConsumerStatefulWidget {
  const CoverCarousel({super.key});

  @override
  ConsumerState<CoverCarousel> createState() => _CoverCarouselState();
}

class _CoverCarouselState extends ConsumerState<CoverCarousel>
    with SingleTickerProviderStateMixin {
  final PageController _controller = PageController();
  Timer? _timer;
  int _index = 0;
  late final AnimationController _eq;

  @override
  void initState() {
    super.initState();
    _eq = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );
    final p = ref.read(playerProvider);
    if (p.queue.isNotEmpty && p.isPlaying) _eq.repeat();
    _startTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    _eq.dispose();
    super.dispose();
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 4), (_) {
      final queue = ref.read(playerProvider).queue;
      if (queue.length > 1) {
        final next = (_index + 1) % queue.length;
        _controller.animateToPage(
          next,
          duration: const Duration(milliseconds: 500),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final player = ref.watch(playerProvider);
    final queue = player.queue;

    // 频谱条只在有队列且播放时运转，省电。
    ref.listen(playerProvider, (prev, next) {
      final shouldRun = next.queue.isNotEmpty && next.isPlaying;
      if (shouldRun && !_eq.isAnimating) {
        _eq.repeat();
      } else if (!shouldRun && _eq.isAnimating) {
        _eq.stop();
      }
    });

    if (queue.isEmpty) {
      return const _EmptyCarousel();
    }
    return Column(
      children: [
        SizedBox(
          height: 260,
          child: PageView.builder(
            controller: _controller,
            itemCount: queue.length,
            onPageChanged: (i) {
              setState(() => _index = i);
              _startTimer();
            },
            itemBuilder: (context, i) {
              final item = queue[i];
              return _CarouselCard(
                item: item,
                isCurrent: i == player.queueIndex,
                isPlaying: player.isPlaying,
                eq: _eq,
                onTap: () => context.push('/player'),
              );
            },
          ),
        ),
        const SizedBox(height: 12),
        _Dots(count: queue.length, index: _index),
      ],
    );
  }
}

class _EmptyCarousel extends StatelessWidget {
  const _EmptyCarousel();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 260,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            scheme.surfaceContainerHigh,
            scheme.surfaceContainer,
          ],
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.music_note, size: 44, color: scheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(
            '暂无播放',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _CarouselCard extends StatelessWidget {
  const _CarouselCard({
    required this.item,
    required this.isCurrent,
    required this.isPlaying,
    required this.eq,
    required this.onTap,
  });

  final QueueItem item;
  final bool isCurrent;
  final bool isPlaying;
  final AnimationController eq;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: Stack(
          fit: StackFit.expand,
          children: [
            CoverImage(
              songPath: item.path,
              width: double.infinity,
              height: double.infinity,
              radius: 0,
              icon: Icons.album,
              gradient: const [Color(0xFFEC4141), Color(0xFF3A6CF5)],
            ),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Colors.black54],
                ),
              ),
            ),
            Positioned(
              left: 22,
              right: 22,
              bottom: 22,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (isCurrent)
                    _PlayingBadge(eq: eq, isPlaying: isPlaying),
                  const SizedBox(height: 10),
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                      shadows: [Shadow(color: Colors.black45, blurRadius: 8)],
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    item.artist.isEmpty ? item.album : item.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.white.withValues(alpha: 0.78),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 红色"播放中"徽章 + 三根频谱条动效。
class _PlayingBadge extends StatelessWidget {
  const _PlayingBadge({required this.eq, required this.isPlaying});

  final AnimationController eq;
  final bool isPlaying;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFFEC4141),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 16,
            height: 10,
            child: AnimatedBuilder(
              animation: eq,
              builder: (context, _) {
                final t = eq.value;
                return Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    _bar(t, 0),
                    _bar(t, 0.25),
                    _bar(t, 0.5),
                  ],
                );
              },
            ),
          ),
          const SizedBox(width: 6),
          const Text(
            '播放中',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  Widget _bar(double t, double phase) {
    final h = isPlaying
        ? 4 + 5 * (0.5 + 0.5 * math.sin(t * 2 * math.pi + phase * 2 * math.pi))
        : 4.0;
    return Container(
      width: 2.5,
      height: h,
      margin: const EdgeInsets.symmetric(horizontal: 1),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }
}

class _Dots extends StatelessWidget {
  const _Dots({required this.count, required this.index});

  final int count;
  final int index;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < count; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            margin: const EdgeInsets.symmetric(horizontal: 3),
            width: i == index ? 18 : 6,
            height: 6,
            decoration: BoxDecoration(
              color: i == index ? const Color(0xFFEC4141) : Colors.white38,
              borderRadius: BorderRadius.circular(6),
            ),
          ),
      ],
    );
  }
}
