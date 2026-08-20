import 'dart:convert';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../src/core/db_path.dart';
import '../../src/core/settings.dart';
import '../../src/favorites/favorites_provider.dart';
import '../../src/navigation/shell.dart';
import '../../src/player/player_provider.dart';
import '../../src/rust/api.dart';
import '../../src/widgets/cover_image.dart';

/// 正在播放页：现代毛玻璃风格。
/// 封面大圆角浮于流光背景之上，支持点击封面在“封面模式”与“歌词模式”间平滑切换。
class PlayerPage extends ConsumerStatefulWidget {
  const PlayerPage({super.key});

  @override
  ConsumerState<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends ConsumerState<PlayerPage> {
  /// 是否显示歌词视图
  bool _showLyrics = false;

  @override
  Widget build(BuildContext context) {
    final player = ref.watch(playerProvider);
    final current = player.current;
    final notifier = ref.read(playerProvider.notifier);
    final scheme = Theme.of(context).colorScheme;

    final coverSize = MediaQuery.of(context).size.width * 0.68;

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
                      Expanded(
                        child: Text(
                          _showLyrics ? '歌词' : '正在播放',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w600),
                        ),
                      ),
                      IconButton(
                        icon: Icon(
                          _showLyrics ? Icons.image_outlined : Icons.lyrics_outlined,
                          size: 22,
                        ),
                        onPressed: () {
                          setState(() {
                            _showLyrics = !_showLyrics;
                          });
                        },
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                // 中间区域：封面 / 歌词模式平滑切换
                AnimatedCrossFade(
                  firstChild: GestureDetector(
                    onTap: () {
                      setState(() {
                        _showLyrics = true;
                      });
                    },
                    child: _BigCover(current: current),
                  ),
                  secondChild: SizedBox(
                    height: coverSize + 20,
                    width: double.infinity,
                    child: _LyricsView(
                      current: current,
                      position: player.position,
                      onTap: () {
                        setState(() {
                          _showLyrics = false;
                        });
                      },
                    ),
                  ),
                  crossFadeState: _showLyrics
                      ? CrossFadeState.showSecond
                      : CrossFadeState.showFirst,
                  duration: const Duration(milliseconds: 260),
                ),
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

/// 大封面：本地/在线封面，无封面时回退渐变占位。
class _BigCover extends StatelessWidget {
  const _BigCover({required this.current});

  final QueueItem? current;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = MediaQuery.of(context).size.width * 0.68;
    return Center(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(32),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.18),
            width: 1.0,
          ),
          boxShadow: [
            BoxShadow(
              color: scheme.primary.withValues(alpha: 0.28),
              blurRadius: 36,
              spreadRadius: 2,
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(31),
          clipBehavior: Clip.antiAlias,
          child: current == null
              ? _placeholder(scheme, size)
              : CoverImage(
                  songPath: current!.path,
                  networkUrl: current!.coverUrl,
                  width: size,
                  height: size,
                  radius: 31,
                  gradient: [
                    scheme.primary,
                    scheme.primary.withValues(alpha: 0.72)
                  ],
                ),
        ),
      ),
    );
  }

  Widget _placeholder(ColorScheme scheme, double size) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [scheme.primary, scheme.primary.withValues(alpha: 0.72)],
        ),
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
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final playerLiquid = ref.watch(settingsProvider
            .select((s) => s.valueOrNull?.playerLiquidGlass)) ??
        true;

    final content = Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
      child: current == null
          ? const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: Text('暂无播放')),
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _TitleRow(current: current!),
                if (player.error != null) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(Icons.error_outline,
                          size: 15, color: scheme.error),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          player.error!,
                          style:
                              TextStyle(fontSize: 12, color: scheme.error),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 14),
                _ProgressBar(player: player, notifier: notifier),
                const SizedBox(height: 6),
                _Controls(player: player, notifier: notifier),
              ],
            ),
    );

    if (playerLiquid) {
      return AdaptiveGlass(
        shape: const LiquidRoundedRectangle(borderRadius: 26),
        settings: liquidGlassSettings(isDark),
        child: content,
      );
    }

    final glassColor = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.white.withValues(alpha: 0.6);

    return ClipRRect(
      borderRadius: BorderRadius.circular(26),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
        child: Container(
          decoration: BoxDecoration(
            color: glassColor,
            borderRadius: BorderRadius.circular(26),
            border: Border.all(
                color: Colors.white.withValues(alpha: isDark ? 0.12 : 0.5)),
          ),
          child: content,
        ),
      ),
    );
  }
}

class _TitleRow extends ConsumerWidget {
  const _TitleRow({required this.current});
  final QueueItem current;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final isFav = ref.watch(favoritesProvider).contains(current.path);
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
          icon: Icon(
            isFav ? Icons.favorite : Icons.favorite_border,
            color: isFav ? scheme.primary : null,
          ),
          onPressed: () =>
              ref.read(favoritesProvider.notifier).toggle(current.path),
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
          // 在线曲目解析直链期间显示加载态，避免看起来无响应。
          child: player.resolving
              ? const Padding(
                  padding: EdgeInsets.all(18),
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: Colors.white,
                  ),
                )
              : IconButton(
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

/// 单行歌词数据
class _LyricLineItem {
  final int timeMs;
  final String text;
  final String? translation;

  const _LyricLineItem({
    required this.timeMs,
    required this.text,
    this.translation,
  });
}

/// 歌词展示组件：支持根据播放进度高亮及自动滚屏，点击可切回封面。
class _LyricsView extends ConsumerStatefulWidget {
  const _LyricsView({
    required this.current,
    required this.position,
    required this.onTap,
  });

  final QueueItem? current;
  final double position; // 播放进度（秒）
  final VoidCallback onTap;

  @override
  ConsumerState<_LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends ConsumerState<_LyricsView> {
  List<_LyricLineItem> _lines = [];
  bool _loading = false;
  String? _loadedPath;
  final ScrollController _scrollCtrl = ScrollController();

  @override
  void initState() {
    super.initState();
    _fetchLyrics();
  }

  @override
  void didUpdateWidget(_LyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.current?.path != widget.current?.path) {
      _fetchLyrics();
    } else {
      _autoScrollToActiveLine();
    }
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _fetchLyrics() async {
    final item = widget.current;
    if (item == null) return;
    if (_loadedPath == item.path && _lines.isNotEmpty) return;

    setState(() {
      _loading = true;
      _loadedPath = item.path;
    });

    try {
      final dbPath = await ref.read(dbPathProvider.future);
      final jsonStr =
          await getSongLyricsPayload(dbPath: dbPath, path: item.path);
      final map = jsonDecode(jsonStr) as Map<String, dynamic>;
      final rawLines = map['lines'] as List? ?? [];

      final lines = rawLines.map((e) {
        final m = e as Map<String, dynamic>;
        return _LyricLineItem(
          timeMs: (m['timeMs'] as num?)?.toInt() ?? 0,
          text: m['text'] as String? ?? '',
          translation: m['translation'] as String?,
        );
      }).toList();

      if (mounted) {
        setState(() {
          _lines = lines;
          _loading = false;
        });
        _autoScrollToActiveLine();
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _lines = [];
          _loading = false;
        });
      }
    }
  }

  void _autoScrollToActiveLine() {
    if (_lines.isEmpty || !_scrollCtrl.hasClients) return;
    final curMs = (widget.position * 1000).toInt();

    int activeIndex = 0;
    for (int i = 0; i < _lines.length; i++) {
      if (_lines[i].timeMs <= curMs) {
        activeIndex = i;
      } else {
        break;
      }
    }

    const double lineEstimateH = 68.0;
    final targetOffset = activeIndex * lineEstimateH;

    _scrollCtrl.animateTo(
      targetOffset.clamp(0.0, _scrollCtrl.position.maxScrollExtent),
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final curMs = (widget.position * 1000).toInt();

    int activeIndex = -1;
    for (int i = 0; i < _lines.length; i++) {
      if (_lines[i].timeMs <= curMs) {
        activeIndex = i;
      } else {
        break;
      }
    }

    Widget content;
    if (_loading) {
      content = const Center(
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    } else if (_lines.isEmpty) {
      content = Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lyrics_outlined,
                size: 40, color: scheme.onSurface.withValues(alpha: 0.35)),
            const SizedBox(height: 10),
            Text(
              '暂无歌词',
              style: TextStyle(
                fontSize: 15,
                color: scheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
          ],
        ),
      );
    } else {
      content = ListView.builder(
        controller: _scrollCtrl,
        padding: const EdgeInsets.symmetric(vertical: 90, horizontal: 24),
        itemCount: _lines.length,
        itemBuilder: (context, idx) {
          final line = _lines[idx];
          final isActive = idx == activeIndex;
          final isPrimaryColor = isActive;

          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 220),
              style: TextStyle(
                fontSize: isActive ? 18 : 15,
                fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                color: isPrimaryColor
                    ? const Color(0xFFEC4141)
                    : scheme.onSurface.withValues(alpha: 0.45),
                height: 1.4,
              ),
              child: Column(
                children: [
                  Text(
                    line.text,
                    textAlign: TextAlign.center,
                  ),
                  if (line.translation != null &&
                      line.translation!.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      line.translation!,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: isActive ? 14 : 12,
                        fontWeight:
                            isActive ? FontWeight.w600 : FontWeight.w400,
                        color: isPrimaryColor
                            ? const Color(0xFFEC4141).withValues(alpha: 0.8)
                            : scheme.onSurface.withValues(alpha: 0.35),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      );
    }

    return GestureDetector(
      onTap: widget.onTap,
      behavior: HitTestBehavior.opaque,
      child: content,
    );
  }
}
