import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
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
                      isPlaying: player.isPlaying,
                      visible: _showLyrics,
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

/// 剥离所有音源（酷我/酷狗/LX/KRC/YRC/QRC 等）内嵌的逐字时间戳与元数据标签。
String _cleanLyricText(String raw) {
  if (raw.isEmpty) return '';

  String text = raw;

  // 1. 过滤元数据控制头 [ar:xx], [ti:xx], [al:xx], [by:xx], [offset:xx], [kuwo:xx], [kugou:xx], [hash:xx] 等
  text = text.replaceAll(
      RegExp(r'\[(ar|ti|al|by|offset|kuwo|kugou|hash|sign|qq|total|language|types):[^\]]*\]',
          caseSensitive: false),
      '');

  // 2. 过滤酷狗 KRC / YRC 圆括号逐字时间戳 (如 (1234,500,0) 或 (1234,500))
  text = text.replaceAll(RegExp(r'\(\d+,\d+(?:,\d+)?\)'), '');

  // 3. 过滤方括号内嵌逐字时间戳 [1234,5678]
  text = text.replaceAll(RegExp(r'\[\d+,\d+\]'), '');

  // 4. 过滤尖括号时间戳 <2688,-2688> 或 <00:12.34>
  text = text.replaceAll(RegExp(r'<[^>]*>'), '');

  return text.trim();
}

/// 单字/单词逐字时间数据 (单位: 秒)
class _LyricWordItem {
  final String text;
  final double start;
  final double end;

  const _LyricWordItem({
    required this.text,
    required this.start,
    required this.end,
  });
}

/// 单行歌词数据
class _LyricLineItem {
  final int timeMs;

  /// 行结束时间（毫秒）；0 表示未知，解析后由边界修正补齐。
  final int endTimeMs;
  final String text;
  final String? translation;
  final List<_LyricWordItem> words;

  const _LyricLineItem({
    required this.timeMs,
    this.endTimeMs = 0,
    required this.text,
    this.translation,
    this.words = const [],
  });
}

/// 歌词展示组件：逐字卡拉OK填充 + 自动滚屏，点击可切回封面。
///
/// 逐字效果移植自桌面端方案：positionStream 约 200ms 一跳，直接驱动逐字
/// 填充会呈阶梯跳变；这里用 Ticker 每帧外推（显示进度 = 锚点进度 + 锚点
/// 以来的流逝时间），实现 60fps 平滑扫字。
class _LyricsView extends ConsumerStatefulWidget {
  const _LyricsView({
    required this.current,
    required this.position,
    required this.isPlaying,
    required this.visible,
    required this.onTap,
  });

  final QueueItem? current;
  final double position; // 播放进度（秒，来自 positionStream 锚点）
  final bool isPlaying; // 是否正在播放（驱动逐帧插值时钟）
  final bool visible; // 歌词视图是否可见（不可见时停帧省电）
  final VoidCallback onTap;

  @override
  ConsumerState<_LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends ConsumerState<_LyricsView>
    with TickerProviderStateMixin {
  List<_LyricLineItem> _lines = [];
  bool _loading = false;
  String? _loadedPath;
  final ScrollController _scrollCtrl = ScrollController();

  /// 用户是否手动翻看/拖动了歌词
  bool _userInteracted = false;
  Timer? _recenterTimer;
  int _lastActiveIndex = -1;

  /// 逐字卡拉OK时钟（等价桌面端 rAF 驱动 setCurrentTime）。
  late final Ticker _ticker;
  final Stopwatch _anchorWatch = Stopwatch();

  /// 最近一次 positionStream 锚点进度（秒）。
  double _anchorPos = 0;

  /// 当前帧用于渲染的平滑进度（秒）。
  double _displayPos = 0;

  @override
  void initState() {
    super.initState();
    _anchorPos = widget.position;
    _displayPos = widget.position;
    _ticker = createTicker(_onTick);
    _syncTicker();
    _fetchLyrics();
  }

  @override
  void didUpdateWidget(_LyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.current?.path != widget.current?.path) {
      // 换歌：重置插值时钟并重新拉取歌词
      _anchorPos = widget.position;
      _displayPos = widget.position;
      _lastActiveIndex = -1;
      _syncTicker();
      _fetchLyrics();
      return;
    }

    // 进度锚点更新：与外推值偏差过大视为用户 Seek
    final jumped = (widget.position - _displayPos).abs() > 1.2;
    _anchorPos = widget.position;
    _anchorWatch.reset();
    if (jumped) {
      _recenterTimer?.cancel();
      _userInteracted = false;
      _displayPos = widget.position;
      _autoScrollToActiveLine(force: true);
    } else if (!widget.isPlaying) {
      // 暂停态直接定格在新锚点
      _displayPos = widget.position;
    }
    _syncTicker();
    _autoScrollToActiveLine();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _recenterTimer?.cancel();
    _scrollCtrl.dispose();
    super.dispose();
  }

  /// 每帧外推平滑进度并刷新逐字填充。
  void _onTick(Duration _) {
    final next = _anchorPos + _anchorWatch.elapsedMilliseconds / 1000.0;
    if ((next - _displayPos).abs() < 0.002) return;
    _displayPos = next;
    _autoScrollToActiveLine();
    setState(() {});
  }

  /// 根据播放/可见状态启停逐帧时钟。
  void _syncTicker() {
    final shouldRun = widget.isPlaying && widget.visible;
    if (shouldRun && !_ticker.isActive) {
      _anchorPos = widget.position;
      _displayPos = _anchorPos;
      _anchorWatch
        ..reset()
        ..start();
      _ticker.start();
    } else if (!shouldRun && _ticker.isActive) {
      _ticker.stop();
      _anchorWatch.stop();
      if (!widget.isPlaying) {
        // 暂停：定格在锚点
        _displayPos = _anchorPos;
      }
    }
  }

  void _onUserScrollStart() {
    _recenterTimer?.cancel();
    if (!_userInteracted) {
      setState(() {
        _userInteracted = true;
      });
    }
  }

  void _scheduleAutoRecenter() {
    _recenterTimer?.cancel();
    // 用户停止翻看 4 秒后，自动平滑对齐重聚焦到当前播放行
    _recenterTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && _userInteracted) {
        _recenterToActiveLine();
      }
    });
  }

  void _recenterToActiveLine() {
    _recenterTimer?.cancel();
    if (mounted) {
      setState(() {
        _userInteracted = false;
      });
      _autoScrollToActiveLine(force: true);
    }
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
      String jsonStr = '';

      if (item.isOnline && item.source != null && item.onlineInfoJson != null) {
        // 在线曲目：通过 Rust 接口在线抓取指定音源的歌词 (kw/kg/tx/wy/mg)
        final rawResultStr = await fetchLyricFromSource(
          source: item.source!,
          songInfoJson: item.onlineInfoJson!,
        );

        if (rawResultStr != 'null' && rawResultStr.isNotEmpty) {
          String lyricsToParse = '';

          // 提取 LyricResult JSON 对象中的真实歌词正文 (lxlyric > lyric)
          try {
            final lyricObj = jsonDecode(rawResultStr) as Map<String, dynamic>;
            final lxlyric = lyricObj['lxlyric'] as String? ?? '';
            final lyric = lyricObj['lyric'] as String? ?? '';
            final tlyric = lyricObj['tlyric'] as String? ?? '';

            if (lxlyric.trim().isNotEmpty) {
              lyricsToParse = lxlyric;
            } else if (lyric.trim().isNotEmpty) {
              if (tlyric.trim().isNotEmpty && !lyric.contains('tlyric')) {
                lyricsToParse = '$lyric\n$tlyric';
              } else {
                lyricsToParse = lyric;
              }
            }
          } catch (_) {
            lyricsToParse = rawResultStr;
          }

          if (lyricsToParse.trim().isNotEmpty) {
            jsonStr = await parseLyrics(rawLyrics: lyricsToParse);
          }
        }
      } else {
        // 本地曲目：通过数据库及本地资源提取
        final dbPath = await ref.read(dbPathProvider.future);
        jsonStr = await getSongLyricsPayload(dbPath: dbPath, path: item.path);
      }

      if (jsonStr.isNotEmpty && jsonStr != 'null') {
        final map = jsonDecode(jsonStr) as Map<String, dynamic>;

        final rawLines = (map['displayLines'] as List?) ??
            (map['display_lines'] as List?) ??
            (map['lines'] as List?) ??
            [];

        final lines = <_LyricLineItem>[];

        for (final item in rawLines) {
          if (item is Map<String, dynamic>) {
            double timeSec = 0.0;
            if (item['time'] is num) {
              timeSec = (item['time'] as num).toDouble();
            } else if (item['timeMs'] is num) {
              timeSec = (item['timeMs'] as num).toDouble() / 1000.0;
            } else if (item['startTime'] is num) {
              timeSec = (item['startTime'] as num).toDouble();
            } else if (item['startTimeMs'] is num) {
              timeSec = (item['startTimeMs'] as num).toDouble() / 1000.0;
            }

            // 行结束时间（Rust 侧 camelCase 序列化为 endTime）
            double endTimeSec = 0.0;
            final rawEndTime = item['endTime'] ?? item['end_time'];
            if (rawEndTime is num) {
              endTimeSec = rawEndTime.toDouble();
            } else if (item['endTimeMs'] is num) {
              endTimeSec = (item['endTimeMs'] as num).toDouble() / 1000.0;
            }

            final rawText = (item['text'] as String?) ?? '';
            final text = _cleanLyricText(rawText);

            final rawTrans = (item['translation'] as String?);
            final translation = rawTrans != null ? _cleanLyricText(rawTrans) : null;

            // 提取 Rust 侧解析出来的逐字 words 数组 (包含每个字/词的 start/end 秒数)
            final words = <_LyricWordItem>[];
            final rawWords = item['words'] as List?;
            if (rawWords != null && rawWords.isNotEmpty) {
              for (final w in rawWords) {
                if (w is Map<String, dynamic>) {
                  final wText = _cleanLyricText((w['text'] as String?) ?? '');
                  final wStart = (w['start'] as num?)?.toDouble() ?? 0.0;
                  final wEnd = (w['end'] as num?)?.toDouble() ?? 0.0;
                  if (wText.isNotEmpty) {
                    words.add(_LyricWordItem(
                      text: wText,
                      start: wStart,
                      end: wEnd,
                    ));
                  }
                }
              }
            }

            if (text.isNotEmpty) {
              lines.add(_LyricLineItem(
                timeMs: (timeSec * 1000).toInt(),
                endTimeMs: (endTimeSec * 1000).round(),
                text: text,
                translation: (translation != null && translation.isNotEmpty)
                    ? translation
                    : null,
                words: words,
              ));
            }
          }
        }

        if (lines.isNotEmpty && mounted) {
          setState(() {
            _lines = _normalizeBoundaries(lines);
            _loading = false;
          });
          _autoScrollToActiveLine();
          return;
        }
      }

      if (mounted) {
        setState(() {
          _lines = [];
          _loading = false;
        });
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

  /// 时间边界修正（移植自桌面端 converters.ts）：
  /// - 行结束时间缺失/无效时，用下一行起点回推（提前量 = min(300ms, 间隔×25%)，
  ///   行最短 40ms）；最后一行给 5s 宽松结束
  /// - 词的 end 裁剪到下一词 start 与行结束之内（最短 20ms），
  ///   避免相邻词重叠导致的填充回跳
  List<_LyricLineItem> _normalizeBoundaries(List<_LyricLineItem> lines) {
    final result = <_LyricLineItem>[];
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final startMs = line.timeMs.toDouble();
      final nextStartMs =
          i + 1 < lines.length ? lines[i + 1].timeMs.toDouble() : double.infinity;

      var endMs = line.endTimeMs.toDouble();
      if (endMs <= startMs) {
        if (nextStartMs.isFinite) {
          final gap = nextStartMs - startMs;
          final leadIn = math.min(300.0, gap * 0.25);
          endMs = nextStartMs - leadIn;
        } else {
          endMs = startMs + 5000;
        }
      }
      endMs = math.max(endMs, startMs + 40);

      final words = <_LyricWordItem>[];
      for (var j = 0; j < line.words.length; j++) {
        final w = line.words[j];
        final wStartMs = w.start * 1000.0;
        var wEndMs = w.end * 1000.0;
        if (j + 1 < line.words.length) {
          wEndMs = math.min(wEndMs, line.words[j + 1].start * 1000.0);
        }
        wEndMs = math.min(wEndMs, endMs);
        wEndMs = math.max(wEndMs, wStartMs + 20);

        // 移植 MusicFree splitWordToChars：多字符词拆成逐字符子词，
        // 时长按字符数均分——英文单词也能逐字母卡拉OK
        // （中文音源逐字数据通常已是单字，不受影响）。
        final chars = w.text.runes.toList();
        if (chars.length > 1) {
          final durMs = (wEndMs - wStartMs) / chars.length;
          for (var c = 0; c < chars.length; c++) {
            words.add(_LyricWordItem(
              text: String.fromCharCode(chars[c]),
              start: (wStartMs + durMs * c) / 1000.0,
              end: (wStartMs + durMs * (c + 1)) / 1000.0,
            ));
          }
        } else {
          words.add(_LyricWordItem(
            text: w.text,
            start: wStartMs / 1000.0,
            end: wEndMs / 1000.0,
          ));
        }
      }

      result.add(_LyricLineItem(
        timeMs: line.timeMs,
        endTimeMs: endMs.round(),
        text: line.text,
        translation: line.translation,
        words: words,
      ));
    }
    return result;
  }

  void _autoScrollToActiveLine({bool force = false}) {
    if (_lines.isEmpty || !_scrollCtrl.hasClients) return;
    if (_userInteracted && !force) return; // 用户正在手动翻看歌词中，暂不打扰

    final curMs = (_displayPos * 1000).toInt();

    int activeIndex = 0;
    for (int i = 0; i < _lines.length; i++) {
      if (_lines[i].timeMs <= curMs) {
        activeIndex = i;
      } else {
        break;
      }
    }

    if (activeIndex == _lastActiveIndex && !force) return;
    _lastActiveIndex = activeIndex;

    // 计算实际滚动的目标 Offset（使高亮行尽量靠近视图中央）
    final maxScroll = _scrollCtrl.position.maxScrollExtent;
    final itemRatio = activeIndex / (_lines.length > 1 ? (_lines.length - 1) : 1);
    final targetOffset = maxScroll * itemRatio;

    _scrollCtrl.animateTo(
      targetOffset.clamp(0.0, maxScroll),
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final curMs = (_displayPos * 1000).toInt();

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
      content = NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification is UserScrollNotification) {
            _onUserScrollStart();
            _scheduleAutoRecenter();
          }
          return false;
        },
        child: ListView.builder(
          controller: _scrollCtrl,
          padding: const EdgeInsets.symmetric(vertical: 90, horizontal: 24),
          itemCount: _lines.length,
          itemBuilder: (context, idx) {
            final line = _lines[idx];
            final isActive = idx == activeIndex;
            final isPrimaryColor = isActive;

          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Column(
              children: [
                // 逐字歌词渲染 (若包含 words 且当前处于活跃高亮行，走卡拉OK渲染)
                if (isActive && line.words.isNotEmpty)
                  Wrap(
                    alignment: WrapAlignment.center,
                    children: [
                      for (final w in line.words)
                        _buildKaraokeWordWidget(
                          w,
                          _displayPos,
                          scheme,
                        ),
                    ],
                  )
                else
                  AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 220),
                    style: TextStyle(
                      fontSize: isActive ? 18 : 15,
                      fontWeight:
                          isActive ? FontWeight.w700 : FontWeight.w500,
                      color: isPrimaryColor
                          ? const Color(0xFFEC4141)
                          : scheme.onSurface.withValues(alpha: 0.45),
                      height: 1.4,
                    ),
                    child: Text(
                      line.text,
                      textAlign: TextAlign.center,
                    ),
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
          );
          },
        ),
      );
    }

    return GestureDetector(
      onTap: widget.onTap,
      behavior: HitTestBehavior.opaque,
      child: Stack(
        alignment: Alignment.center,
        children: [
          content,

          // 用户手动滑动脱焦后，右下角弹出“回到正在播放”悬浮按钮
          if (_userInteracted)
            Positioned(
              right: 18,
              bottom: 18,
              child: InkWell(
                onTap: _recenterToActiveLine,
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEC4141).withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.3),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.gps_fixed, size: 15, color: Colors.white),
                      SizedBox(width: 6),
                      Text(
                        '回到正在播放',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 渲染单个词/字的卡拉OK漫过染色高光
  Widget _buildKaraokeWordWidget(
    _LyricWordItem word,
    double position,
    ColorScheme scheme,
  ) {
    final duration = math.max(0.001, word.end - word.start);
    final progress = ((position - word.start) / duration).clamp(0.0, 1.0);

    const activeColor = Color(0xFFEC4141);
    final inactiveColor = scheme.onSurface.withValues(alpha: 0.45);

    const style = TextStyle(
      fontSize: 18,
      fontWeight: FontWeight.w700,
      height: 1.4,
    );

    if (progress <= 0) {
      return Text(
        word.text,
        style: style.copyWith(color: inactiveColor),
      );
    }

    if (progress >= 1.0) {
      return Text(
        word.text,
        style: style.copyWith(color: activeColor),
      );
    }

    // 正在唱当前词：渐变染色漫过 (ShaderMask)。
    // 填充前沿之后带 10% 宽度的羽化软边，对应桌面端 AMLL 的 wordFadeWidth 扫字效果。
    final featherEnd = (progress + 0.1).clamp(0.0, 1.0);
    return ShaderMask(
      shaderCallback: (bounds) {
        return LinearGradient(
          colors: [activeColor, inactiveColor],
          stops: [progress, featherEnd],
        ).createShader(bounds);
      },
      child: Text(
        word.text,
        style: style.copyWith(color: Colors.white),
      ),
    );
  }
}
