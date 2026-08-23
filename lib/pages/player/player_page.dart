import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'comment_sheet.dart';
import '../../src/core/db_path.dart';
import '../../src/core/settings.dart';
import '../../src/download/download_provider.dart';
import '../../src/favorites/favorites_provider.dart';
import '../../src/lyrics/lyric_font.dart';
import '../../src/player/player_provider.dart';
import '../../src/rust/api.dart';
import '../../src/widgets/cover_image.dart';
import '../../src/widgets/glass_settings.dart';
import '../../src/widgets/sheet_dialog.dart';

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

  /// 当前歌词是否含罗马音（由 _LyricsView 上报，驱动设置栏罗马音按钮可用态）。
  bool _lyricsViewHasRomaji = false;

  @override
  Widget build(BuildContext context) {
    final player = ref.watch(playerProvider);
    final current = player.current;
    final notifier = ref.read(playerProvider.notifier);
    final scheme = Theme.of(context).colorScheme;

    // 背景是深色模糊封面（学 MusicFree），前景统一按深色主题渲染，
    // 保证浅色系统主题下文字/图标仍可读。
    final bgScheme = scheme.copyWith(
      brightness: Brightness.dark,
      onSurface: Colors.white,
      onSurfaceVariant: Colors.white.withValues(alpha: 0.72),
    );

    final settings = ref.watch(settingsProvider).valueOrNull;
    final fontSizeIdx = settings?.lyricFontSize ?? 1;
    final showTranslation = settings?.showLyricsTranslation ?? true;
    final showRomaji = settings?.showLyricsRomaji ?? false;
    final offsetMs = settings?.lyricOffsetMs ?? 0;
    final hasRomaji = _lyricsViewHasRomaji;

    return Theme(
      data: Theme.of(context).copyWith(
        brightness: Brightness.dark,
        colorScheme: bgScheme,
        iconTheme: Theme.of(context).iconTheme.copyWith(color: Colors.white),
      ),
      child: Scaffold(
        backgroundColor: Color.lerp(scheme.surface, Colors.black, 0.6),
        body: Stack(
          fit: StackFit.expand,
          children: [
          // 背景：模糊封面铺满全屏（学 MusicFree 播放详情页）
          _BlurredCoverBackground(current: current),
          SafeArea(
            child: Stack(
              children: [
                Column(
                  children: [
                    // 顶栏
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
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
                              style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.white.withValues(alpha: 0.9)),
                            ),
                          ),
                          // 右侧留位 48px 占位，保持标题居中
                          const SizedBox(width: 48),
                        ],
                      ),
                    ),
                    // 中间区域：封面模式（居中大封面）/ 歌词模式（Expanded 占满中段空间）
                    if (!_showLyrics) ...[
                      const Spacer(),
                      GestureDetector(
                        onTap: () {
                          setState(() {
                            _showLyrics = true;
                          });
                        },
                        child: _BigCover(current: current),
                      ),
                      const Spacer(),
                    ] else ...[
                      Expanded(
                        child: ClipRect(
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
                            onRomajiAvailable: (has) {
                              if (_lyricsViewHasRomaji != has) {
                                setState(() => _lyricsViewHasRomaji = has);
                              }
                            },
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
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

                // 歌词模式下顶栏最右侧浮动展示毛玻璃设置按钮（与左侧下拉图标/居中标题在同一水平线）
                if (_showLyrics)
                  Positioned(
                    top: 4,
                    right: 12,
                    child: _LyricSettingsRail(
                      fontSizeIdx: fontSizeIdx,
                      showTranslation: showTranslation,
                      showRomaji: showRomaji,
                      offsetMs: offsetMs,
                      hasTranslation: true,
                      hasRomaji: hasRomaji,
                      onFontSize: () =>
                          _LyricsViewState._showFontSizeSheet(context, ref),
                      onToggleTranslation: () {
                        ref
                            .read(settingsProvider.notifier)
                            .setShowLyricsTranslation(!showTranslation);
                      },
                      onToggleRomaji: () {
                        ref
                            .read(settingsProvider.notifier)
                            .setShowLyricsRomaji(!showRomaji);
                      },
                      onOffset: () =>
                          _LyricsViewState._showOffsetSheet(context, ref),
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

/// 模糊封面全屏背景（学 MusicFree 播放详情页）：
/// 封面 cover 填满全屏 + 大半径模糊 + 深色遮罩保证前景可读；
/// 无封面时回退氛围光斑。
///
/// 模糊用 [ImageFiltered] 作用于图片本身而非 BackdropFilter——静态图
/// 只渲染一次即缓存，不参与每帧合成。
class _BlurredCoverBackground extends StatelessWidget {
  const _BlurredCoverBackground({required this.current});

  final QueueItem? current;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final item = current;
    if (item == null) {
      return const _AmbientBackground();
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        // 深色底：封面加载前/加载失败时的兜底
        Container(color: Color.lerp(scheme.surface, Colors.black, 0.6)),
        // 封面铺满全屏 + 大半径模糊（对应 MusicFree blurRadius=50）
        ImageFiltered(
          imageFilter: ImageFilter.blur(
            sigmaX: 50,
            sigmaY: 50,
            tileMode: TileMode.decal,
          ),
          child: CoverImage(
            songPath: item.path,
            networkUrl: item.coverUrl,
            width: double.infinity,
            height: double.infinity,
            radius: 0,
            gradient: [scheme.primary, scheme.primary.withValues(alpha: 0.72)],
            // 全屏背景占位不要中央大图标
            placeholder: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    scheme.primary.withValues(alpha: 0.55),
                    Color.lerp(scheme.surface, Colors.black, 0.6)!,
                  ],
                ),
              ),
            ),
          ),
        ),
        // 深色遮罩：对齐 MusicFree「黑底 + 50% 透明封面」的可读性
        Container(color: Colors.black.withValues(alpha: 0.45)),
      ],
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
                style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: Colors.white),
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
              ref.read(favoritesProvider.notifier).toggle(current),
        ),
        if (current.isOnline)
          IconButton(
            icon: const Icon(Icons.download_outlined),
            onPressed: () {
              ref.read(downloadProvider.notifier).download(current);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('开始下载：${current.title}')),
              );
            },
          ),
        if (current.isOnline)
          IconButton(
            icon: const Icon(Icons.mode_comment_outlined),
            onPressed: () => showSheetDialog<void>(
              context,
              (_) => CommentSheet(songJson: current.onlineSongJson),
            ),
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
          onPressed: () => _showQueueSheet(context, ref, player),
        ),
      ],
    );
  }

  /// 播放队列弹窗：展示/点播/移除/拖拽排序。
  void _showQueueSheet(
      BuildContext context, WidgetRef ref, PlaybackState player) {
    showSheetDialog<void>(
      context,
      (_) => _QueueSheet(player: player),
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
  final String? romaji;
  final List<_LyricWordItem> words;

  const _LyricLineItem({
    required this.timeMs,
    this.endTimeMs = 0,
    required this.text,
    this.translation,
    this.romaji,
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
    required this.onRomajiAvailable,
  });

  final QueueItem? current;
  final double position; // 播放进度（秒，来自 positionStream 锚点）
  final bool isPlaying; // 是否正在播放（驱动逐帧插值时钟）
  final bool visible; // 歌词视图是否可见（不可见时停帧省电）
  final VoidCallback onTap;
  final ValueChanged<bool> onRomajiAvailable;

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

  /// 拖动选行播放（移植自 MusicFree）：视口中心对应的行索引，
  /// 拖动时显示中央指示条，点击播放按钮从该行开始播放。
  int? _draggingIndex;
  Timer? _draggingIndexTimer;

  /// 每行在滚动内容中的布局缓存（内容偏移, 高度），供拖动定位中心行。
  /// 对应 MusicFree LayoutCache 的前缀和，用实测替代估算。
  final Map<int, (double, double)> _lineLayouts = {};

  // 歌词样式设置（build 中从 settingsProvider 同步，供非 build 路径读取）。
  int _fontSizeIdx = 1;
  bool _showTranslation = true;
  bool _showRomaji = false;
  int _offsetMs = 0;

  /// 是否有任一行含罗马音（供设置栏罗马音按钮的可用态判断）。
  bool _hasRomaji = false;

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
      _draggingIndexTimer?.cancel();
      _draggingIndex = null;
      _lineLayouts.clear();
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
    _draggingIndexTimer?.cancel();
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

  // ==================== 拖动选行播放（移植自 MusicFree） ====================

  /// 行布局回调：记录该行在滚动内容中的偏移与高度。
  void _onLineMeasured(int index, double viewportDy, double height) {
    if (!mounted) return;
    _lineLayouts[index] = (viewportDy + _scrollCtrl.offset, height);
  }

  /// 滚动更新：定位视口中心对应的歌词行（MusicFree 的 onScroll 中心命中测试）。
  void _updateDraggingIndex() {
    if (!_scrollCtrl.hasClients || _lines.isEmpty) return;

    final offset = _scrollCtrl.offset;
    final viewport = _scrollCtrl.position.viewportDimension;
    final center = offset + viewport / 2;

    // 在已测量布局中找中心距离最近的行（视口内的行必然已构建测量）。
    int? best;
    var bestDist = double.infinity;
    _lineLayouts.forEach((i, layout) {
      final dist = (layout.$1 + layout.$2 / 2 - center).abs();
      if (dist < bestDist) {
        bestDist = dist;
        best = i;
      }
    });

    if (best != null) {
      final idx = best!.clamp(0, _lines.length - 1);
      if (_draggingIndex != idx) {
        setState(() => _draggingIndex = idx);
      }
      // 停止拖动 2 秒后自动清除（对应 MusicFree useDelayFalsy 2000ms）。
      _draggingIndexTimer?.cancel();
      _draggingIndexTimer = Timer(const Duration(seconds: 2), () {
        if (mounted && _draggingIndex != null) {
          setState(() => _draggingIndex = null);
        }
      });
    }
  }

  /// 从拖动选中的歌词行开始播放（对应 MusicFree onLyricSeekPress）。
  void _seekToDraggingLine() {
    final idx = _draggingIndex;
    if (idx == null || idx < 0 || idx >= _lines.length) return;

    ref.read(playerProvider.notifier).seek(_lines[idx].timeMs / 1000.0);

    // 立即清除拖动状态并回正到目标行。
    _draggingIndexTimer?.cancel();
    setState(() {
      _draggingIndex = null;
      _userInteracted = false;
    });
    _autoScrollToActiveLine(force: true);
  }

  /// 拖动指示条的时间文本（mm:ss）。
  String _draggingTimeLabel() {
    final idx = _draggingIndex;
    if (idx == null || idx < 0 || idx >= _lines.length) return '00:00';
    final s = _lines[idx].timeMs / 1000.0;
    final m = s ~/ 60;
    final sec = (s % 60).floor();
    return '${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
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

            final rawRomaji = (item['romaji'] as String?)?.trim();
            final romaji =
                (rawRomaji != null && rawRomaji.isNotEmpty) ? rawRomaji : null;

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
                romaji: romaji,
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
          _reportRomaji();
          _autoScrollToActiveLine();
          return;
        }
      }

      if (mounted) {
        setState(() {
          _lines = [];
          _loading = false;
        });
        _reportRomaji();
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _lines = [];
          _loading = false;
        });
        _reportRomaji();
      }
    }
  }

  /// 汇总当前歌词是否含罗马音并上报给宿主页（驱动设置栏罗马音按钮可用态）。
  void _reportRomaji() {
    final has = _lines.any((l) => l.romaji != null && l.romaji!.isNotEmpty);
    if (has != _hasRomaji) {
      _hasRomaji = has;
      widget.onRomajiAvailable(has);
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
        romaji: line.romaji,
        words: words,
      ));
    }
    return result;
  }

  void _autoScrollToActiveLine({bool force = false}) {
    if (_lines.isEmpty || !_scrollCtrl.hasClients) return;
    if (_userInteracted && !force) return; // 用户正在手动翻看歌词中，暂不打扰

    final curMs = ((_displayPos - _offsetMs / 1000.0) * 1000).toInt();

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

    // 歌词样式设置（移植自 MF LyricOperations）：字号档位 / 翻译开关 / 时间偏移。
    // 存到字段供 _onTick → _autoScrollToActiveLine 等非 build 路径使用。
    final settings = ref.watch(settingsProvider).valueOrNull;
    _fontSizeIdx = settings?.lyricFontSize ?? 1;
    _showTranslation = settings?.showLyricsTranslation ?? true;
    _showRomaji = settings?.showLyricsRomaji ?? false;
    _offsetMs = settings?.lyricOffsetMs ?? 0;
    final lyricFontFamily =
        (settings?.lyricFontName ?? '').isNotEmpty ? settings!.lyricFontName : null;

    // 档位 → 字号（对应 MF fontSizeMap 的小/标准/大/特大）。
    final inactiveFont = [14.0, 15.5, 17.0, 19.0][_fontSizeIdx];
    final activeFont = inactiveFont + 2.5;
    final transFont = inactiveFont - 2;
    final romajiFont = inactiveFont - 1.5;

    final curMs = ((_displayPos - _offsetMs / 1000.0) * 1000).toInt();

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
          } else if (notification is ScrollUpdateNotification) {
            // 拖动/惯性滚动中：实时定位视口中心行（拖动选行播放）。
            if (_userInteracted) _updateDraggingIndex();
          }
          return false;
        },
        child: ListView.builder(
          controller: _scrollCtrl,
          // 歌词列表内边距：工具栏已移至右上角，底部留空 40px 即可完全无遮挡展现
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 40),
          itemCount: _lines.length,
          itemBuilder: (context, idx) {
            final line = _lines[idx];
            final isActive = idx == activeIndex;
            final isPrimaryColor = isActive;
            final isDragging = idx == _draggingIndex;

          return _MeasuredLine(
            index: idx,
            onMeasured: _onLineMeasured,
            child: Padding(
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
                          _displayPos - _offsetMs / 1000.0,
                          scheme,
                          activeFont,
                          lyricFontFamily,
                        ),
                    ],
                  )
                else
                  AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 220),
                    style: TextStyle(
                      fontSize: isActive ? activeFont : inactiveFont,
                      fontWeight:
                          isActive ? FontWeight.w700 : FontWeight.w500,
                      // 拖动选中行：提亮为白（对应 MusicFree 的 light 样式）
                      color: isDragging
                          ? Colors.white
                          : isPrimaryColor
                              ? const Color(0xFFEC4141)
                              : scheme.onSurface.withValues(alpha: 0.45),
                      height: 1.4,
                      fontFamily: lyricFontFamily,
                    ),
                    child: Text(
                      line.text,
                      textAlign: TextAlign.center,
                    ),
                  ),
                if (_showRomaji &&
                    line.romaji != null &&
                    line.romaji!.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    line.romaji!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: isActive ? romajiFont + 1 : romajiFont,
                      fontWeight:
                          isActive ? FontWeight.w600 : FontWeight.w400,
                      color: isDragging
                          ? Colors.white.withValues(alpha: 0.75)
                          : isPrimaryColor
                              ? const Color(0xFFEC4141).withValues(alpha: 0.75)
                              : scheme.onSurface.withValues(alpha: 0.32),
                      height: 1.2,
                      fontFamily: lyricFontFamily,
                    ),
                  ),
                ],
                if (_showTranslation &&
                    line.translation != null &&
                    line.translation!.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    line.translation!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize:
                          isActive ? transFont + 1.5 : transFont,
                      fontWeight:
                          isActive ? FontWeight.w600 : FontWeight.w400,
                      color: isDragging
                          ? Colors.white.withValues(alpha: 0.8)
                          : isPrimaryColor
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

          // 拖动选行指示条（移植自 MusicFree draggingTime）：
          // 拖动歌词时在中央显示目标时间 + 播放按钮，点按从该行开始播放。
          if (_draggingIndex != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  // 时间胶囊
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      _draggingTimeLabel(),
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.white.withValues(alpha: 0.87),
                        fontFeatures: const [
                          FontFeature.tabularFigures()
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  // 中央基准横线：穿过视口中心的选中行
                  Expanded(
                    child: Container(
                      height: 1,
                      color: Colors.white.withValues(alpha: 0.35),
                    ),
                  ),
                  const SizedBox(width: 10),
                  // 播放按钮：从选中行开始播放
                  _DraggingPlayButton(onPressed: _seekToDraggingLine),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// 字号调节面板（对应 MF SetFontSize 面板：小/标准/大/特大四档滑杆）。
  static void _showFontSizeSheet(BuildContext context, WidgetRef ref) {
    showSheetDialog<void>(
      context,
      (sheetCtx) {
        final notifier = ref.read(settingsProvider.notifier);
        var current =
            ref.read(settingsProvider).valueOrNull?.lyricFontSize ?? 1;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('歌词字号',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                StatefulBuilder(
                  builder: (ctx, setSheetState) {
                    return Row(
                      children: [
                        ...List.generate(4, (i) {
                          final labels = ['小', '标准', '大', '特大'];
                          return Expanded(
                            child: InkWell(
                              onTap: () {
                                setSheetState(() => current = i);
                                notifier.setLyricFontSize(i);
                              },
                              child: Container(
                                alignment: Alignment.center,
                                padding:
                                    const EdgeInsets.symmetric(vertical: 10),
                                margin: const EdgeInsets.only(right: 8),
                                decoration: BoxDecoration(
                                  color: current == i
                                      ? const Color(0xFFEC4141)
                                          .withValues(alpha: 0.14)
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  labels[i],
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: current == i
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                    color: current == i
                                        ? const Color(0xFFEC4141)
                                        : Theme.of(ctx)
                                            .colorScheme
                                            .onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ),
                          );
                        }),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 16),
                const Divider(height: 1),
                const SizedBox(height: 12),
                // 自定义字体导入
                Row(
                  children: [
                    Icon(Icons.font_download_outlined,
                        size: 18,
                        color: Theme.of(context).colorScheme.outline),
                    const SizedBox(width: 8),
                    const Text('自定义歌词字体',
                        style: TextStyle(
                            fontSize: 13.5, fontWeight: FontWeight.w600)),
                    const Spacer(),
                    _FontImportAction(sheetCtx: sheetCtx),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '支持 .ttf / .otf 字体文件，导入后立即应用到歌词',
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.outline,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 歌词偏移校正面板：粗调滑杆(-500~+500, 10ms) + 细调按钮(1/5/10/100ms)，
  /// 拖蓝/暂停时点按微调可精确定位，满足“偏移步进细化”。
  static void _showOffsetSheet(BuildContext context, WidgetRef ref) {
    showSheetDialog<void>(
      context,
      (sheetCtx) {
        final notifier = ref.read(settingsProvider.notifier);
        var value = ref.read(settingsProvider).valueOrNull?.lyricOffsetMs ?? 0;

        void apply(int v, StateSetter setSheetState) {
          setSheetState(() => value = v);
          notifier.setLyricOffsetMs(v);
        }

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('歌词偏移',
                        style: TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w600)),
                    TextButton(
                      onPressed: () {
                        notifier.setLyricOffsetMs(0);
                        Navigator.of(sheetCtx).pop();
                      },
                      child: const Text('重置'),
                    ),
                  ],
                ),
                StatefulBuilder(
                  builder: (ctx, setSheetState) {
                    final scheme = Theme.of(ctx).colorScheme;
                    return Column(
                      children: [
                        // 当前偏移值
                        Text(
                          value > 0
                              ? '提前 ${value}ms'
                              : value < 0
                                  ? '延后 ${-value}ms'
                                  : '无偏移',
                          style: TextStyle(
                            fontSize: 13,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        // 粗调滑杆（10ms 步进）
                        Slider(
                          value: value.toDouble(),
                          min: -500,
                          max: 500,
                          divisions: 100,
                          label: '${value}ms',
                          onChanged: (v) => apply(v.round(), setSheetState),
                        ),
                        // 细调按钮行（1 / 5 / 10 / 100ms 步进）
                        Wrap(
                          alignment: WrapAlignment.center,
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            _offsetStepChip(ctx, '-100', scheme, () =>
                                apply((value - 100).clamp(-500, 500), setSheetState)),
                            _offsetStepChip(ctx, '-10', scheme, () =>
                                apply((value - 10).clamp(-500, 500), setSheetState)),
                            _offsetStepChip(ctx, '-1', scheme, () =>
                                apply((value - 1).clamp(-500, 500), setSheetState)),
                            _offsetStepChip(ctx, '+1', scheme, () =>
                                apply((value + 1).clamp(-500, 500), setSheetState)),
                            _offsetStepChip(ctx, '+10', scheme, () =>
                                apply((value + 10).clamp(-500, 500), setSheetState)),
                            _offsetStepChip(ctx, '+100', scheme, () =>
                                apply((value + 100).clamp(-500, 500), setSheetState)),
                          ],
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 偏移细调小按钮。
  static Widget _offsetStepChip(
    BuildContext ctx,
    String label,
    ColorScheme scheme,
    VoidCallback onTap,
  ) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: scheme.onSurface,
          ),
        ),
      ),
    );
  }

  /// 渲染单个词/字的卡拉OK漫过染色高光
  Widget _buildKaraokeWordWidget(
    _LyricWordItem word,
    double position,
    ColorScheme scheme,
    double fontSize,
    String? fontFamily,
  ) {
    final duration = math.max(0.001, word.end - word.start);
    final progress = ((position - word.start) / duration).clamp(0.0, 1.0);

    const activeColor = Color(0xFFEC4141);
    final inactiveColor = scheme.onSurface.withValues(alpha: 0.45);

    final style = TextStyle(
      fontSize: fontSize,
      fontWeight: FontWeight.w700,
      height: 1.4,
      fontFamily: fontFamily,
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

/// 行测量包装（拖动选行播放）：布局后上报该行在滚动内容中的偏移与高度。
///
/// 用 `RenderAbstractViewport.of` 拿到相对视口的位置，叠加当前滚动偏移
/// 即得内容坐标——等价 MusicFree LayoutCache 的实测前缀和。仅视口附近
/// 的行会被 ListView 构建，缓存规模天然可控。
class _MeasuredLine extends StatefulWidget {
  const _MeasuredLine({
    required this.index,
    required this.onMeasured,
    required this.child,
  });

  final int index;
  final void Function(int index, double viewportDy, double height) onMeasured;
  final Widget child;

  @override
  State<_MeasuredLine> createState() => _MeasuredLineState();
}

class _MeasuredLineState extends State<_MeasuredLine> {
  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final box = context.findRenderObject() as RenderBox?;
      if (box == null || !box.attached || box.hasSize == false) return;
      final viewport = RenderAbstractViewport.of(box);
      final dy = box.localToGlobal(Offset.zero, ancestor: viewport).dy;
      widget.onMeasured(widget.index, dy, box.size.height);
    });
    return widget.child;
  }
}

/// 拖动选行的播放按钮：圆形主题色底 + 白色播放图标。
class _DraggingPlayButton extends StatelessWidget {
  const _DraggingPlayButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFFEC4141),
      shape: const CircleBorder(),
      elevation: 3,
      child: InkWell(
        onTap: onPressed,
        customBorder: const CircleBorder(),
        child: const SizedBox(
          width: 32,
          height: 32,
          child: Icon(Icons.play_arrow, size: 20, color: Colors.white),
        ),
      ),
    );
  }
}

/// 歌词设置悬浮按钮面板（复用悬浮侧边栏 UI 设计）：位于歌词页右上角，点击调出字号/翻译/偏移控件。
class _LyricSettingsRail extends StatefulWidget {
  const _LyricSettingsRail({
    required this.fontSizeIdx,
    required this.showTranslation,
    required this.showRomaji,
    required this.offsetMs,
    required this.hasTranslation,
    required this.hasRomaji,
    required this.onFontSize,
    required this.onToggleTranslation,
    required this.onToggleRomaji,
    required this.onOffset,
  });

  final int fontSizeIdx;
  final bool showTranslation;
  final bool showRomaji;
  final int offsetMs;
  final bool hasTranslation;
  final bool hasRomaji;
  final VoidCallback onFontSize;
  final VoidCallback onToggleTranslation;
  final VoidCallback onToggleRomaji;
  final VoidCallback onOffset;

  @override
  State<_LyricSettingsRail> createState() => _LyricSettingsRailState();
}

class _LyricSettingsRailState extends State<_LyricSettingsRail> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final panelWidth = _expanded ? 46.0 : 40.0;

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
          width: panelWidth,
          decoration: BoxDecoration(
            color: isDark
                ? Colors.white.withValues(alpha: 0.08)
                : Colors.white.withValues(alpha: 0.75),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: Colors.white.withValues(alpha: isDark ? 0.12 : 0.5),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.12),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 1. 右上角毛玻璃主控制 Icon 按钮
              InkWell(
                onTap: () => setState(() => _expanded = !_expanded),
                borderRadius: BorderRadius.circular(20),
                child: SizedBox(
                  width: 40,
                  height: 40,
                  child: Center(
                    child: AnimatedRotation(
                      turns: _expanded ? 0.25 : 0.0,
                      duration: const Duration(milliseconds: 280),
                      curve: Curves.easeOutCubic,
                      child: Icon(
                        Icons.tune_rounded,
                        size: 20,
                        color: _expanded
                            ? const Color(0xFFEC4141)
                            : Colors.white.withValues(alpha: 0.9),
                      ),
                    ),
                  ),
                ),
              ),

              // 2. 展开时向下延伸显示的 3 个工具按钮（字号 / 翻译 / 偏移）
              AnimatedSize(
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: _expanded
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Divider(
                            height: 1,
                            indent: 8,
                            endIndent: 8,
                            thickness: 0.5,
                            color: Colors.white.withValues(alpha: 0.15),
                          ),
                          const SizedBox(height: 4),

                          // (1) 字号按钮
                          _RailIconButton(
                            icon: Icons.format_size_rounded,
                            active: widget.fontSizeIdx != 1,
                            onTap: widget.onFontSize,
                          ),

                          // (2) 翻译开关按钮
                          _RailIconButton(
                            icon: Icons.translate_rounded,
                            active: widget.showTranslation && widget.hasTranslation,
                            disabled: !widget.hasTranslation,
                            onTap: widget.onToggleTranslation,
                          ),

                          // (3) 罗马音开关按钮
                          _RailIconButton(
                            icon: Icons.abc_rounded,
                            active: widget.showRomaji && widget.hasRomaji,
                            disabled: !widget.hasRomaji,
                            onTap: widget.onToggleRomaji,
                          ),

                          // (4) 时间偏移校正按钮
                          _RailIconButton(
                            icon: Icons.av_timer_rounded,
                            active: widget.offsetMs != 0,
                            onTap: widget.onOffset,
                          ),

                          const SizedBox(height: 6),
                        ],
                      )
                    : const SizedBox(width: 40, height: 0),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 自定义歌词字体的导入 / 恢复默认按钮（字号面板内）。
class _FontImportAction extends ConsumerWidget {
  const _FontImportAction({required this.sheetCtx});
  final BuildContext sheetCtx;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fontName = ref.watch(settingsProvider.select(
        (s) => s.valueOrNull?.lyricFontName ?? ''));
    final hasFont = fontName.isNotEmpty;

    if (!hasFont) {
      return TextButton.icon(
        onPressed: () async {
          try {
            final imported = await LyricFontManager.importCustomFont(
              onApplied: (name, path) async {
                final n = ref.read(settingsProvider.notifier);
                await n.setLyricFontPath(path);
                await n.setLyricFontName(name);
              },
            );
            if (imported == null) return;
            if (context.mounted) {
              ScaffoldMessenger.of(sheetCtx)
                ..hideCurrentSnackBar()
                ..showSnackBar(const SnackBar(content: Text('已应用自定义歌词字体')));
            }
          } catch (e) {
            if (context.mounted) {
              ScaffoldMessenger.of(sheetCtx)
                ..hideCurrentSnackBar()
                ..showSnackBar(SnackBar(content: Text('字体导入失败：$e')));
            }
          }
        },
        icon: const Icon(Icons.file_open_outlined, size: 18),
        label: const Text('选择字体'),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '已应用',
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
        TextButton.icon(
          onPressed: () async {
            final n = ref.read(settingsProvider.notifier);
            await n.setLyricFontName('');
            await n.setLyricFontPath('');
          },
          icon: const Icon(Icons.refresh, size: 16),
          label: const Text('恢复默认'),
        ),
      ],
    );
  }
}

class _RailIconButton extends StatelessWidget {
  const _RailIconButton({
    required this.icon,
    required this.active,
    this.disabled = false,
    required this.onTap,
  });

  final IconData icon;
  final bool active;
  final bool disabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const activeColor = Color(0xFFEC4141);
    final inactiveColor = Colors.white.withValues(alpha: disabled ? 0.3 : 0.85);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: InkWell(
        onTap: disabled ? null : onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: active
                ? activeColor.withValues(alpha: 0.15)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(
            icon,
            size: 19,
            color: active ? activeColor : inactiveColor,
          ),
        ),
      ),
    );
  }
}

/// 播放队列弹窗（移植自桌面端播放队列）：
/// 顶部显示当前播放信息，下方为可拖拽排序的队列列表。
class _QueueSheet extends ConsumerStatefulWidget {
  const _QueueSheet({required this.player});

  final PlaybackState player;

  @override
  ConsumerState<_QueueSheet> createState() => _QueueSheetState();
}

class _QueueSheetState extends ConsumerState<_QueueSheet> {
  @override
  Widget build(BuildContext context) {
    final player = ref.watch(playerProvider);
    final scheme = Theme.of(context).colorScheme;
    final queue = player.queue;
    final currentIndex = player.queueIndex;

    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 顶部标题栏
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 12, 4),
          child: Row(
            children: [
              Text(
                '播放队列',
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w700),
              ),
              const SizedBox(width: 8),
              Text(
                '${queue.length} 首',
                style: TextStyle(
                    fontSize: 12, color: scheme.onSurfaceVariant),
              ),
              const Spacer(),
              IconButton(
                icon: Icon(Icons.close, size: 20, color: scheme.onSurfaceVariant),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        if (queue.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 40),
            child: Text(
              '队列为空',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          )
        else
          Flexible(
            child: ReorderableListView.builder(
              shrinkWrap: true,
              buildDefaultDragHandles: false,
              itemCount: queue.length,
              onReorderItem: (oldIndex, newIndex) {
                ref
                    .read(playerProvider.notifier)
                    .reorderQueue(oldIndex, newIndex);
              },
              itemBuilder: (context, index) {
                final item = queue[index];
                final isCurrent = index == currentIndex;
                return ReorderableDelayedDragStartListener(
                  key: ValueKey('${item.path}_$index'),
                  index: index,
                  child: ListTile(
                    dense: true,
                    leading: isCurrent
                        ? Icon(Icons.graphic_eq,
                            size: 18, color: const Color(0xFFEC4141))
                        : Icon(Icons.music_note,
                            size: 18, color: scheme.outline),
                    title: Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        color: isCurrent
                            ? const Color(0xFFEC4141)
                            : scheme.onSurface,
                        fontWeight:
                            isCurrent ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                    subtitle: Text(
                      item.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12, color: scheme.onSurfaceVariant),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: Icon(Icons.drag_handle,
                              size: 18, color: scheme.outline),
                          onPressed: null,
                        ),
                        IconButton(
                          icon: Icon(Icons.close,
                              size: 18, color: scheme.outline),
                          onPressed: () => ref
                              .read(playerProvider.notifier)
                              .removeFromQueue(index),
                        ),
                      ],
                    ),
                    onTap: () {
                      Navigator.of(context).pop();
                      ref
                          .read(playerProvider.notifier)
                          .playQueueItem(index);
                    },
                  ),
                );
              },
            ),
          ),
      ],
    );

    return SafeArea(
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.7,
        ),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: content,
      ),
    );
  }
}
