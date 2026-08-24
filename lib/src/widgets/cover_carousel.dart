import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../home/home_providers.dart';
import '../player/player_provider.dart';
import 'cover_image.dart';

/// 首页顶端轮播块：固定 2 页（第 1 页正在播放单曲，第 2 页听歌统计数据）。
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
    if (p.current != null && p.isPlaying) _eq.repeat();
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
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted) return;
      final next = (_index + 1) % 2;
      _controller.animateToPage(
        next,
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final player = ref.watch(playerProvider);

    // 频谱条只在正在播放时运转
    ref.listen(playerProvider, (prev, next) {
      final shouldRun = next.current != null && next.isPlaying;
      if (shouldRun && !_eq.isAnimating) {
        _eq.repeat();
      } else if (!shouldRun && _eq.isAnimating) {
        _eq.stop();
      }
    });

    return Column(
      children: [
        SizedBox(
          height: 240,
          child: PageView(
            controller: _controller,
            onPageChanged: (i) {
              setState(() => _index = i);
              _startTimer();
            },
            children: [
              // 第 1 页：正在播放单曲
              _NowPlayingCard(
                player: player,
                eq: _eq,
                onTap: () => context.push('/player'),
              ),
              // 第 2 页：听歌数据统计
              const _StatsCard(),
            ],
          ),
        ),
        const SizedBox(height: 10),
        _Dots(count: 2, index: _index),
      ],
    );
  }
}

/// 第 1 页：正在播放卡片。
class _NowPlayingCard extends StatelessWidget {
  const _NowPlayingCard({
    required this.player,
    required this.eq,
    required this.onTap,
  });

  final PlaybackState player;
  final AnimationController eq;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final item = player.current;
    if (item == null) {
      return const _EmptyCarousel();
    }

    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: Stack(
          fit: StackFit.expand,
          children: [
            CoverImage(
              songPath: item.path,
              networkUrl: item.coverUrl,
              width: double.infinity,
              height: double.infinity,
              radius: 0,
              icon: Icons.album,
            ),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Colors.black87],
                ),
              ),
            ),
            Positioned(
              left: 20,
              right: 20,
              bottom: 20,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _PlayingBadge(eq: eq, isPlaying: player.isPlaying),
                  const SizedBox(height: 10),
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 21,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                      shadows: [Shadow(color: Colors.black45, blurRadius: 8)],
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    item.artist.isEmpty ? item.album : item.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.white.withValues(alpha: 0.8),
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

/// 第 2 页：听歌数据统计卡片。
class _StatsCard extends ConsumerWidget {
  const _StatsCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final statsAsync = ref.watch(listenStatsProvider);
    final scheme = Theme.of(context).colorScheme;

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            const Color(0xFF1E2638),
            scheme.surfaceContainerHigh,
          ],
        ),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.insights,
                  size: 18,
                  color: scheme.primary,
                ),
              ),
              const SizedBox(width: 8),
              const Text(
                '听歌数据统计',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Colors.white70,
                ),
              ),
            ],
          ),
          const Spacer(),
          statsAsync.when(
            loading: () => const Center(
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
            error: (_, _) => const Text(
              '暂无统计数据',
              style: TextStyle(color: Colors.white54),
            ),
            data: (stats) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '累计听歌总时长',
                  style: TextStyle(fontSize: 12, color: Colors.white54),
                ),
                const SizedBox(height: 4),
                Text(
                  stats.totalDurationText,
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: _SubStatItem(
                        icon: Icons.today,
                        label: '今天听歌时长',
                        value: stats.todayDurationText,
                      ),
                    ),
                    Expanded(
                      child: _SubStatItem(
                        icon: Icons.queue_music,
                        label: '今天已听',
                        value: '${stats.todayPlayCount} 首',
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Spacer(),
        ],
      ),
    );
  }
}

class _SubStatItem extends StatelessWidget {
  const _SubStatItem({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon,
            size: 16, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 6),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: const TextStyle(fontSize: 10, color: Colors.white54),
            ),
            Text(
              value,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          ],
        ),
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
      height: 240,
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
        color: Theme.of(context).colorScheme.primary,
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
              color: i == index
                  ? Theme.of(context).colorScheme.primary
                  : Colors.white38,
              borderRadius: BorderRadius.circular(6),
            ),
          ),
      ],
    );
  }
}
