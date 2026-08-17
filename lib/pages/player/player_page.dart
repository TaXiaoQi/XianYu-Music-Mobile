import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/player/player_provider.dart';

/// 正在播放页（小而美：封面 + 进度 + 控制 + 歌词占位）。
class PlayerPage extends ConsumerWidget {
  const PlayerPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerProvider);
    final current = player.current;
    final notifier = ref.read(playerProvider.notifier);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.keyboard_arrow_down),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text('正在播放'),
        centerTitle: true,
      ),
      body: current == null
          ? const Center(child: Text('暂无播放'))
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  children: [
                    const Spacer(),
                    _BigCover(current.title),
                    const SizedBox(height: 24),
                    Text(
                      current.title,
                      style: const TextStyle(
                          fontSize: 20, fontWeight: FontWeight.bold),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      current.artist,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                      textAlign: TextAlign.center,
                    ),
                    const Spacer(),
                    _ProgressBar(player: player, notifier: notifier),
                    const SizedBox(height: 8),
                    _Controls(player: player, notifier: notifier),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
    );
  }
}

class _BigCover extends StatelessWidget {
  const _BigCover(this.title);
  final String title;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Container(
        width: 260,
        height: 260,
        color: scheme.primaryContainer,
        alignment: Alignment.center,
        child: Icon(Icons.music_note,
            size: 80, color: scheme.onPrimaryContainer),
      ),
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
    final dur = player.duration <= 0 ? 1.0 : player.duration;
    return Column(
      children: [
        Slider(
          value: player.position.clamp(0, dur),
          max: dur,
          onChanged: (v) => notifier.seek(v),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(_fmt(player.position), style: const TextStyle(fontSize: 12)),
              Text(_fmt(dur), style: const TextStyle(fontSize: 12)),
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
    final icons = [
      Icons.repeat,
      Icons.repeat_one,
      Icons.shuffle,
    ]; // 0 顺序(列表循环) 1 单曲循环 2 随机
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        IconButton(
          iconSize: 22,
          icon: Icon(icons[player.playMode]),
          onPressed: notifier.cyclePlayMode,
        ),
        IconButton(
          iconSize: 40,
          icon: const Icon(Icons.skip_previous, size: 36),
          onPressed: notifier.previous,
        ),
        IconButton(
          iconSize: 56,
          icon: Icon(
            player.isPlaying ? Icons.pause_circle : Icons.play_circle,
          ),
          onPressed: notifier.toggle,
        ),
        IconButton(
          iconSize: 40,
          icon: const Icon(Icons.skip_next, size: 36),
          onPressed: notifier.next,
        ),
        IconButton(
          iconSize: 22,
          icon: const Icon(Icons.queue_music),
          onPressed: () {},
        ),
      ],
    );
  }
}