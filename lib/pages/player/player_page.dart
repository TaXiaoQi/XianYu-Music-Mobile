import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'comment_sheet.dart';
import '../../src/core/db_path.dart';
import '../../src/core/settings.dart';
import '../../src/download/download_provider.dart';
import '../../src/effects/sound_effect_provider.dart';
import '../../src/favorites/favorites_provider.dart';
import '../../src/lyrics/floating_lyrics.dart';
import '../../src/lyrics/lyric_font.dart';
import '../../src/player/online_quality_probe.dart';
import '../../src/player/player_provider.dart';
import '../../src/rust/api.dart';
import '../../src/plugin/plugin_provider.dart';
import '../../src/responsive/landscape.dart';
import '../../src/share/share_service.dart';
import '../../src/share/share_sheet.dart';
import '../../src/widgets/app_toast.dart';
import '../../src/widgets/bilipai_glass.dart';
import '../../src/widgets/blur_budget.dart';
import '../../src/widgets/committed_slider.dart';
import '../../src/widgets/cover_hero.dart';
import '../../src/widgets/cover_image.dart';
import '../../src/widgets/glass_settings.dart';
import '../../src/widgets/modern_dialog.dart';
import '../../src/widgets/predictive_cover_return.dart';
import '../../src/widgets/predictive_dialog_route.dart';
import '../../src/widgets/sheet_dialog.dart';
import '../../src/i18n/i18n.dart';

/// 歌词解析结果缓存（按歌曲路径）：切回同一首歌直接复用，
/// 避免重复网络请求与主线程 JSON 解析。上限防止长期播放后无界增长。
final Map<String, List<_LyricLineItem>> _lyricsCache = {};
const int _lyricsCacheMax = 24;

void _cacheLyrics(String path, List<_LyricLineItem> lines) {
  if (path.isEmpty || lines.isEmpty) return;
  _lyricsCache[path] = lines;
  if (_lyricsCache.length > _lyricsCacheMax) {
    _lyricsCache.remove(_lyricsCache.keys.first);
  }
}

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

  /// 歌词视图实例 key：本播放页实例内横竖屏翻转时 _LyricsView 凭它 reparent
  /// （保留跟随锁定/居中/滚动位置）。key 跟实例走——关闭后销毁，快速重开的
  /// 新实例拿新 key，避免与退出转场中的旧歌词视图撞 GlobalKey。
  final GlobalKey _lyricsKey = GlobalKey();

  /// 当前歌词是否含罗马音（由 _LyricsView 上报，驱动设置栏罗马音按钮可用态）。
  bool _lyricsViewHasRomaji = false;

  /// 已预加载分享链接的歌曲 path（切歌时预生成，避免点击分享才等网络）。
  String? _sharePreloadPath;

  @override
  Widget build(BuildContext context) {
    // 顶层只订阅当前歌曲（切歌才重建整页）；播放态/进度/音量等由各自叶子
    // 组件内部 select 局部刷新，避免任何播放状态变化（暂停/切模式/解析中）
    // 都触发整页重建。position 由进度条/歌词等需要它的组件内部各自 select。
    final current = ref.watch(playerProvider.select((s) => s.current));
    final notifier = ref.read(playerProvider.notifier);
    final scheme = Theme.of(context).colorScheme;

    // 队列被清空/删空（current 非空 → 空）时自动退出播放详情页：
    // 覆盖清空队列、删除最后一首等所有「没有歌曲」的路径。仅在本页处于
    // 栈顶时退出；若队列弹窗盖在本页上，由弹窗的统一关闭逻辑连带退出，
    // 避免双重 pop 把弹窗下面的页面也关掉。
    ref.listen(playerProvider.select((s) => s.current), (prev, next) {
      if (prev != null && next == null && mounted) {
        if (ModalRoute.of(context)?.isCurrent == true) {
          final nav = Navigator.of(context);
          if (nav.canPop()) nav.pop();
        }
      }
    });

    // 播放歌曲变化时预加载分享链接（服务内部对已缓存/生成中的歌去重，重复触发安全）。
    if (current != null && _sharePreloadPath != current.path) {
      _sharePreloadPath = current.path;
      final toPreload = current;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(shareServiceProvider).preload(toPreload);
      });
    }

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
    final playerStyle = settings?.playerStyle ?? PlayerStyle.advanced;

    return Theme(
      data: Theme.of(context).copyWith(
        brightness: Brightness.dark,
        colorScheme: bgScheme,
        iconTheme: Theme.of(context).iconTheme.copyWith(color: Colors.white),
      ),
      child: _DragDismissSheet(
        child: playerStyle == PlayerStyle.traditional
            ? _TraditionalPlayerLayout(
                notifier: notifier,
                current: current,
              )
            : _buildAdvancedBody(
                notifier: notifier,
                current: current,
                scheme: scheme,
                fontSizeIdx: fontSizeIdx,
                showTranslation: showTranslation,
                showRomaji: showRomaji,
                offsetMs: offsetMs,
                hasRomaji: hasRomaji,
              ),
      ),
    );
  }

  /// 「高级模式」正在播放页（现代毛玻璃风格，原布局）。
  Widget _buildAdvancedBody({
    required PlayerNotifier notifier,
    required QueueItem? current,
    required ColorScheme scheme,
    required int fontSizeIdx,
    required bool showTranslation,
    required bool showRomaji,
    required int offsetMs,
    required bool hasRomaji,
  }) {
    // 竖屏＝默认封面页；横屏＝独立一套横向 UI，两套完全分开（见 LandscapeGate）。
    final landscapeBody = _buildLandscapeAdvancedBody(
      notifier: notifier,
      current: current,
      scheme: scheme,
      fontSizeIdx: fontSizeIdx,
      showTranslation: showTranslation,
      showRomaji: showRomaji,
      offsetMs: offsetMs,
      hasRomaji: hasRomaji,
    );
    return LandscapeGate(
      portrait: Scaffold(
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
                            icon: const Icon(
                              Icons.keyboard_arrow_down,
                              size: 28,
                            ),
                            onPressed: () => Navigator.of(context).pop(),
                          ),
                          Expanded(
                            child: Text(
                              _showLyrics ? tr('歌词') : tr('正在播放'),
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: Colors.white.withValues(alpha: 0.9),
                              ),
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
                        child: OpenCoverGuard(
                          child: Center(
                            child: Hero(
                              tag: 'player-cover',
                            flightShuttleBuilder: (ctx, animation, direction,
                                fromCtx, toCtx) {
                              return PlayerCoverShuttle(
                                animation: animation,
                                songPath: current?.path ?? '',
                                networkUrl: current?.coverUrl,
                                fromRadius: 23,
                                toRadius: 31,
                                borderColor:
                                    Colors.white.withValues(alpha: 0.18),
                                shadow: BoxShadow(
                                  color: scheme.primary
                                      .withValues(alpha: 0.28),
                                  blurRadius: 36,
                                  spreadRadius: 2,
                                ),
                                gradient: [
                                  scheme.primary,
                                  scheme.primary.withValues(alpha: 0.72),
                                ],
                              );
                            },
                            child: CoverReturnSource(
                              songPath: current?.path,
                              networkUrl: current?.coverUrl,
                              child: _BigCover(current: current),
                            ),
                          ),
                        ),
                        ),
                      ),
                      const Spacer(),
                    ] else ...[
                      Expanded(
                        child: ClipRect(
                          child: RepaintBoundary(
                            child: _LyricsView(
                              key: _lyricsKey,
                              current: current,
                              visible: _showLyrics,
                              onTap: () {
                                setState(() {
                                  _showLyrics = false;
                                });
                              },
                              onRomajiAvailable: (has) {
                                if (_lyricsViewHasRomaji != has) {
                                  setState(
                                    () => _lyricsViewHasRomaji = has,
                                  );
                                }
                              },
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                    // 毛玻璃控制卡：包一层 RepaintBoundary 隔离成独立图层，
                    // 进度 tick / 歌词切换等 rebuild 时不会重绘整张玻璃卡。
                    RepaintBoundary(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                        child: _GlassControlCard(
                          notifier: notifier,
                          current: current,
                        ),
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
      landscape: landscapeBody,
    );
  }

  /// 「高级模式」横屏横排：左封面 + 右（歌词 + 控制卡），顶栏返回/设置悬浮。
  Widget _buildLandscapeAdvancedBody({
    required PlayerNotifier notifier,
    required QueueItem? current,
    required ColorScheme scheme,
    required int fontSizeIdx,
    required bool showTranslation,
    required bool showRomaji,
    required int offsetMs,
    required bool hasRomaji,
  }) {
    return Scaffold(
      backgroundColor: Color.lerp(scheme.surface, Colors.black, 0.6),
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 背景：模糊封面铺满全屏，与竖屏一致
          _BlurredCoverBackground(current: current),
          SafeArea(
            // 补偿沉浸式下被清零的挖孔安全区，内容不插进摄像头区（背景仍全屏）。
            child: Padding(
              padding: _landscapeCameraCutoutExtra(context),
              child: Stack(
              children: [
                // 主流程纵向排布：顶栏 / 中区（封面+歌词）/ 底部控制带。
                // 注意 Expanded 必须在 Column 内（Stack 会抛 ParentData 错误），
                // 歌词设置按钮经 Stack 的 Positioned 悬浮（见下方）。
                Column(
                  children: [
                // 顶栏：返回 + 居中歌名/歌手（参照桌面版顶部，无「正在播放」占位标题）
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.keyboard_arrow_down, size: 28),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              current?.title ?? tr('正在播放'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                              ),
                            ),
                            if (current?.artist != null)
                              Text(
                                current!.artist,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.white.withValues(alpha: 0.6),
                                ),
                              ),
                          ],
                        ),
                      ),
                      // 右侧留位 44px 占位，保持标题居中
                      const SizedBox(width: 44),
                    ],
                  ),
                ),
                // 中区：左封面 + 右歌词（歌词垂直居中，控制带下沉到底部）
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 0, 12, 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                      // 左封面 + 右歌词：固定横向对半布局，不提供可拖动中线。
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(left: 20),
                          child: LayoutBuilder(
                          builder: (context, cons) {
                            final side = cons.maxWidth;
                            final coverSize = side * 0.9 <
                                    cons.maxHeight * 0.8
                                ? side * 0.9
                                : cons.maxHeight * 0.8;
                            return OpenCoverGuard(
                              child: Center(
                                child: GestureDetector(
                                  onTap: () {
                                    setState(
                                        () => _showLyrics = !_showLyrics);
                                  },
                                child: Hero(
                                  tag: 'player-cover',
                                  flightShuttleBuilder: (ctx, animation,
                                          direction, fromCtx, toCtx) =>
                                      PlayerCoverShuttle(
                                        animation: animation,
                                        songPath: current?.path ?? '',
                                        networkUrl: current?.coverUrl,
                                        fromRadius: 23,
                                        toRadius: 31,
                                        borderColor: Colors.white
                                            .withValues(alpha: 0.18),
                                        shadow: BoxShadow(
                                          color: scheme
                                              .primary
                                              .withValues(alpha: 0.28),
                                          blurRadius: 36,
                                          spreadRadius: 2,
                                        ),
                                        gradient: [
                                          scheme.primary,
                                          scheme
                                              .primary
                                              .withValues(alpha: 0.72),
                                        ],
                                      ),
                                  child: CoverReturnSource(
                                    songPath: current?.path,
                                    networkUrl: current?.coverUrl,
                                    child: _BigCover(
                                      current: current,
                                      size: coverSize,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            );
                          },
                          ),
                        ),
                      ),
                      // 右：歌词视口（剩余宽度占满）
                      Expanded(
                        child: ClipRect(
                          child: RepaintBoundary(
                            child: _LyricsView(
                              key: _lyricsKey,
                              current: current,
                              // 横屏横排下歌词常显
                              visible: _showLyrics,
                              onTap: () {
                                setState(
                                    () => _showLyrics = !_showLyrics);
                              },
                              onRomajiAvailable: (has) {
                                if (_lyricsViewHasRomaji != has) {
                                  setState(
                                    () => _lyricsViewHasRomaji = has,
                                  );
                                }
                              },
                            ),
                          ),
                        ),
                      ),
                            ],
                          ),
                        ),
                      ),
                // 底部：播放控制带（桌面版 PlayerFooter 语义，全宽置底）；整体下移一点
                RepaintBoundary(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                    child: _GlassControlCard(
                      notifier: notifier,
                      current: current,
                      landscape: true,
                    ),
                  ),
                ),
                ],
                ),
                // 歌词设置悬停按钮
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
          ),
        ],
      ),
    );
  }
}

/// 「传统模式」正在播放页（经典 QQ 音乐式布局）：
/// 顶部封面居中，标题/歌手与动作栏在下方，进度条与播放控制固定底部；
/// 顶栏用「封面/歌词」分段切换，也可点击封面切换歌词，封面可开启频谱「闪」动效。
class _TraditionalPlayerLayout extends ConsumerStatefulWidget {
  const _TraditionalPlayerLayout({
    required this.notifier,
    required this.current,
  });
  final PlayerNotifier notifier;
  final QueueItem? current;

  @override
  ConsumerState<_TraditionalPlayerLayout> createState() =>
      _TraditionalPlayerLayoutState();
}

class _TraditionalPlayerLayoutState
    extends ConsumerState<_TraditionalPlayerLayout>
    with SingleTickerProviderStateMixin {
  bool _showLyrics = false;

  /// 歌词视图实例 key：本实例内横竖屏翻转 reparent（同 _PlayerPageState）。
  final GlobalKey _lyricsKey = GlobalKey();

  /// 封面/歌词左右滑动翻页控制器。
  late final PageController _pageController;

  /// 「闪」频谱动效已由音质按钮替换，保留字段仅作封面频谱条的固定开关（默认关闭）。
  final bool _flashOn = false;

  late final AnimationController _eq;

  @override
  void initState() {
    super.initState();
    _eq = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    // 关闭即销毁，默认封面页（0），不再跨开关记忆歌词模式。
    _pageController = PageController(initialPage: 0);
  }

  @override
  void dispose() {
    _eq.dispose();
    _pageController.dispose();
    super.dispose();
  }

  /// 顶栏分段点击：切换到对应页（封面 0 / 歌词 1）。
  void _switchPage(int i) {
    _pageController.animateToPage(
      i,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
    if (_showLyrics != (i == 1)) setState(() => _showLyrics = i == 1);
  }

  /// 依据「闪」开关与播放状态启停频谱动效。
  void _syncEq(bool isPlaying) {
    final run = _flashOn && isPlaying;
    if (run && !_eq.isAnimating) {
      _eq.repeat();
    } else if (!run && _eq.isAnimating) {
      _eq.stop();
      _eq.reset();
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.current;
    // 播放态只在此局部订阅（驱动封面频谱与播放键），不随整页重建。
    final isPlaying = ref.watch(playerProvider.select((s) => s.isPlaying));
    _syncEq(isPlaying);
    // 传统模式横屏：封面与歌词左右并排，取代封面/歌词上下翻页。
    // 竖屏＝默认封面/歌词上下翻页；横屏＝独立一套横向 UI，两套完全分开（见 LandscapeGate）。
    return LandscapeGate(
      portrait: _buildTraditionalPortrait(context, current),
      landscape: _buildTraditionalLandscape(context, current),
    );
  }

  /// 竖屏：顶栏 + 封面/歌词上下翻页 + 动作行 + 进度条 + 播放控制。
  Widget _buildTraditionalPortrait(BuildContext context, QueueItem? current) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        fit: StackFit.expand,
        children: [
          _BlurredCoverBackground(current: current),
          SafeArea(
            child: Column(
              children: [
                _buildTopBar(context),
                // 中间区域：竖屏为封面/歌词左右滑动切换。
                Expanded(
                  child: PageView.builder(
                    controller: _pageController,
                    itemCount: 2,
                    onPageChanged: (i) {
                      if (_showLyrics != (i == 1)) {
                        setState(() => _showLyrics = i == 1);
                      }
                    },
                    itemBuilder: (context, i) {
                      if (i == 0) {
                        return _buildCoverSection(context);
                      }
                      return ClipRect(
                        child: RepaintBoundary(
                          child: _LyricsView(
                            key: _lyricsKey,
                            current: current,
                            visible: _showLyrics,
                            onTap: () {},
                            onRomajiAvailable: (_) {},
                          ),
                        ),
                      );
                    },
                  ),
                ),
                // 竖屏播放控件：动作行 + 进度条 + 播放控制。
                _buildActionsRow(context),
                const SizedBox(height: 4),
                // 进度条（独立图层，tick 不重绘整页）
                RepaintBoundary(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 22),
                    child: _ProgressBar(notifier: widget.notifier),
                  ),
                ),
                _Controls(notifier: widget.notifier),
                // 底部留白：底部整块 UI 再上移一格，避免贴底
                const SizedBox(height: 32),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 横屏：顶栏（仅标题）+ 左封面｜右歌词并排 + 进度条 + 三区控制行，独立一套 UI。
  Widget _buildTraditionalLandscape(BuildContext context, QueueItem? current) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        fit: StackFit.expand,
        children: [
          _BlurredCoverBackground(current: current),
          SafeArea(
            // 补偿沉浸式下被清零的挖孔安全区，内容不插进摄像头区（背景仍全屏）。
            child: Padding(
              padding: _landscapeCameraCutoutExtra(context),
              child: Column(
              children: [
                _buildTopBar(context, landscape: true),
                // 中间区域：横屏为「左封面｜右歌词」并排（歌词常显，封面不滚动歌词），
                // 固定横向对半布局，不提供可拖动中线。
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // 封面整体右移一点：横屏下封面与左缘留出呼吸间距。
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(left: 24),
                          child: _buildCoverSection(
                              context, showLyricPreview: false),
                        ),
                      ),
                      // 歌词贴近放大的封面。
                      Expanded(
                            child: ClipRect(
                              child: RepaintBoundary(
                                child: _LyricsView(
                                  key: _lyricsKey,
                                  current: current,
                                  // 横屏歌词常显
                                  visible: true,
                                  onTap: () {},
                                  onRomajiAvailable: (_) {},
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                // 横屏播放控件：进度条 + 三区控制行（时长/下载/收藏｜播放顺序/三大键/歌词｜音质/音效/队列）。
                RepaintBoundary(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 22),
                    child: _ProgressBar(
                      notifier: widget.notifier,
                      // 时长已移到控制行左下角，进度条这里不再重复显示。
                      showTime: false,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                _LandscapeControlsRow(
                  notifier: widget.notifier,
                  current: current,
                ),
                // 底部留白收紧：整个底栏往下移，更贴近屏幕下缘。
                const SizedBox(height: 16),
              ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 顶栏：返回 / 封面·歌词分段切换（横屏并排时仅标题） / 分享。
  Widget _buildTopBar(BuildContext context, {bool landscape = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_down, size: 28),
            onPressed: () => Navigator.of(context).pop(),
          ),
          Expanded(
            child: Center(
              child: landscape
                  ? Text(
                      widget.current?.title ?? tr('正在播放'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Colors.white.withValues(alpha: 0.94),
                      ),
                    )
                  : _SegmentSwitcher(
                      items: [tr('封面'), tr('歌词')],
                      index: _showLyrics ? 1 : 0,
                      onChanged: _switchPage,
                    ),
            ),
          ),
          IconButton(
            icon: const Icon(
              Icons.ios_share,
              size: 28,
              color: Colors.white,
            ),
            tooltip: tr('分享歌曲'),
            onPressed: () {
              final c = widget.current;
              if (c != null) _shareCurrent(context, ref, c);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildCoverSection(BuildContext context,
      {bool showLyricPreview = true}) {
    // 播放态局部订阅：仅驱动封面频谱，不随整页重建。
    final isPlaying = ref.watch(playerProvider.select((s) => s.isPlaying));
    return LayoutBuilder(
      builder: (context, cons) {
        // 竖屏取较紧凑尺寸，给封面下方信息条(歌名/作者/收藏)与歌词预览留空间；
        // 横屏去掉了信息条，封面放大铺满更多可用高度。
        final coverSize = math.min(
          cons.maxWidth * (showLyricPreview ? 0.85 : 0.92),
          cons.maxHeight * (showLyricPreview ? 0.6 : 0.88),
        );
        // 封面居中后的左右缩进：歌名/收藏/歌词以封面左右边缘为基准对齐。
        final hInset = (cons.maxWidth - coverSize) / 2;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // 封面略下移，与顶部切换 tab 留出呼吸间距
            const SizedBox(height: 14),
            OpenCoverGuard(
              child: Center(
                child: Hero(
                  tag: 'player-cover',
                flightShuttleBuilder:
                    (ctx, animation, direction, fromCtx, toCtx) {
                  final scheme = Theme.of(context).colorScheme;
                  return PlayerCoverShuttle(
                    animation: animation,
                    songPath: widget.current?.path ?? '',
                    networkUrl: widget.current?.coverUrl,
                    fromRadius: 23,
                    toRadius: 23,
                    borderColor: Colors.white.withValues(alpha: 0.14),
                    shadow: BoxShadow(
                      color: Colors.black.withValues(alpha: 0.35),
                      blurRadius: 28,
                      offset: const Offset(0, 10),
                    ),
                    gradient: [
                      scheme.primary,
                      scheme.primary.withValues(alpha: 0.72),
                    ],
                  );
                },
                child: CoverReturnSource(
                  songPath: widget.current?.path,
                  networkUrl: widget.current?.coverUrl,
                  child: _TraditionalCover(
                    size: coverSize,
                    current: widget.current,
                    eq: _eq,
                    flash: _flashOn,
                    playing: isPlaying,
                  ),
                ),
              ),
            ),
            ),
            // 竖屏：封面下方保留歌名/作者/收藏信息条；横屏这些信息冗余
            // （顶部有歌名、底部有收藏），去掉并把空间留给放大的封面。
            if (showLyricPreview) ...[
              const SizedBox(height: 30),
              _buildCaption(context, inset: hInset),
            ],
            // 中部剩余空间：3 行歌词预览，左对齐歌名/封面左边
            // （歌词与歌名/作者分离，位于底部控件与顶部歌名之间的位置）
            Expanded(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: hInset),
                child: Align(
                  alignment: Alignment.centerLeft,
                  // 横屏(showLyricPreview=false)时封面下方只显示封面、不带滚动歌词预览。
                  child: showLyricPreview
                      ? _LyricPreview(current: widget.current)
                      : const SizedBox.shrink(),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// 封面下方的信息条：左边歌名/作者（分开于歌词，不再内嵌歌词预览），右边收藏按钮。
  /// [inset] 与封面居中后的左右缩进一致，使歌名左缘与封面左边、收藏右缘与封面右边对齐。
  Widget _buildCaption(BuildContext context, {required double inset}) {
    final c = widget.current;
    final isFav = c != null &&
        ref.watch(favoritesProvider.select((s) => s.contains(c.path)));
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: inset),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // 歌名过长时在容器内水平滚动展示（加大字号）
                SizedBox(
                  height: (20 * 1.2).ceilToDouble(),
                  child: _Marquee(
                    text: c?.title ?? '',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      height: 1.2,
                    ),
                  ),
                ),
                if (c != null && c.artist.isNotEmpty) ...[
                  const SizedBox(height: 5),
                  Text(
                    c.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.72),
                      fontSize: 14,
                      height: 1.2,
                    ),
                  ),
                ],
              ],
            ),
          ),
          InkWell(
            borderRadius: BorderRadius.circular(22),
            onTap: () {
              if (c != null) {
                ref.read(favoritesProvider.notifier).toggle(c);
              }
            },
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Icon(
                isFav ? Icons.favorite : Icons.favorite_border,
                size: 28,
                color: isFav
                    ? const Color(0xFFEC4141)
                    : Colors.white.withValues(alpha: 0.9),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionsRow(BuildContext context) {
    final sfx = ref.watch(soundEffectProvider).settings;
    final bypass = sfx.bypass;
    final current = widget.current;
    // 下载状态：本地曲天然已在设备；在线曲按下载历史/进行中任务判断。
    final dl = ref.watch(downloadProvider);
    final isLocal = current != null && !current.isOnline;
    final currentQuality = ref.watch(
      playerProvider.select((s) => s.currentQuality),
    );
    final lyricsEnabled = ref.watch(
      settingsProvider.select((s) => s.valueOrNull?.floatingLyricsEnabled ?? false),
    );
    final dlActive = current != null &&
        dl.tasks.any((t) =>
            t.songPath == current.path &&
            (t.status == DownloadStatus.waiting ||
                t.status == DownloadStatus.downloading));
    final dlDone = current != null &&
        (isLocal ||
            dl.history.any((h) => h.songPath == current.path));
    // 动作项纯图标、5 等分+居中铺满一行（与进度条下方播放控件行 5 列严格同轴）。
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Expanded(child: Center(child: _actionItem(
            context,
            icon: Icons.graphic_eq,
            tooltip: tr('音效'),
            active: !bypass,
            // 点击打开音效页（原首页底部栏音效入口已迁入传统播放页）。
            onTap: () => context.push('/effects'),
          ))),
          Expanded(child: Center(child: _qualityActionItem(
            context,
            quality: currentQuality,
            lossless: currentQuality != null &&
                isLosslessQuality(currentQuality),
            onTap: () {
              final c = current;
              if (c == null) return;
              if (c.isOnline) {
                // 在线歌曲：弹出音质选择弹窗，可修改播放音质。
                _showQualitySheet(context, ref);
              } else {
                // 本地音乐按原文件音质直传，无需切换。
                showXianYuToast(context, tr('本地音乐以原音质播放'));
              }
            },
          ))),
          Expanded(child: Center(child: _downloadActionItem(
            context,
            isLocal: isLocal,
            dlActive: dlActive,
            dlDone: dlDone,
            onTap: () {
              if (current == null) return;
              if (dlActive) {
                showXianYuToast(context, tr('正在下载中…'));
                return;
              }
              if (dlDone) {
                showXianYuToast(
                  context,
                  isLocal ? tr('本地音乐已在设备') : tr('已下载，可到下载页查看'),
                );
                return;
              }
              // 在线歌曲：弹出下载音质选择弹窗，选档后按该档下载。
              _showDownloadQualitySheet(context, ref, current);
            },
          ))),
          Expanded(child: Center(child: _actionItem(
            context,
            icon: Icons.chat_bubble_outline,
            // 圆形评论气泡（对齐桌面端 lucide MessageCircle）
            iconWidget: _MessageCircleIcon(
              size: 24,
              color: current != null && current.isOnline
                  ? Colors.white.withValues(alpha: 0.85)
                  : Colors.white.withValues(alpha: 0.32),
            ),
            tooltip: tr('评论'),
            // 本地歌曲无在线评论信息，置灰不可点
            enabled: current != null && current.isOnline,
            onTap: () {
              final c = current;
              if (c == null) return;
              showSheetDialog<void>(
                context,
                (_) => CommentSheet(songJson: c.onlineSongJson!),
              );
            },
          ))),
          // 桌面歌词「词」按钮：与音效/音质/下载/评论并排、位于最右（对齐桌面端 FooterControlIcon 词字样式）
          Expanded(child: Center(child: _lyricsActionItem(context, lyricsEnabled))),
        ],
      ),
    );
  }

  /// 桌面歌词「词」按钮：文字「词」替代图标，开启时主题色高亮。
  Widget _lyricsActionItem(BuildContext context, bool lyricsEnabled) {
    final accent = Theme.of(context).colorScheme.primary;
    return IconButton(
      iconSize: 28,
      tooltip: tr('桌面歌词'),
      icon: Container(
        width: 28,
        height: 28,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: lyricsEnabled
              ? accent.withValues(alpha: 0.14)
              : Colors.transparent,
        ),
        child: Text(
          tr('词'),
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.bold,
            color: lyricsEnabled
                ? accent
                : Colors.white.withValues(alpha: 0.85),
          ),
        ),
      ),
      onPressed: () => _toggleFloatingLyrics(context, ref, lyricsEnabled),
    );
  }

  /// 下载按钮（对齐桌面端）：下载中显示环形加载，已下载显示绿色对勾。
  Widget _downloadActionItem(
    BuildContext context, {
    required bool isLocal,
    required bool dlActive,
    required bool dlDone,
    required VoidCallback onTap,
  }) {
    return IconButton(
      iconSize: 28,
      tooltip: dlDone ? tr('已下载') : (dlActive ? tr('下载中') : tr('下载')),
      icon: dlActive
          ? SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white.withValues(alpha: 0.8),
              ),
            )
          : Icon(
              dlDone ? Icons.check_circle_outline : Icons.download_outlined,
              color: dlDone
                  ? const Color(0xFF07C160)
                  : Colors.white.withValues(alpha: 0.85),
            ),
      onPressed: onTap,
    );
  }

  /// 音质按钮（对齐桌面端）：以文字缩写显示当前音质，无损时主题色高亮。
  Widget _qualityActionItem(
    BuildContext context, {
    required String? quality,
    required bool lossless,
    required VoidCallback onTap,
  }) {
    final accent = Theme.of(context).colorScheme.primary;
    return Tooltip(
      message: tr('音质'),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          width: 36,
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: lossless
                ? accent.withValues(alpha: 0.12)
                : Colors.transparent,
          ),
          child: Text(
            _qualityAbbr(quality),
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: lossless
                  ? accent
                  : Colors.white.withValues(alpha: 0.85),
            ),
          ),
        ),
      ),
    );
  }

  /// 单个动作项：纯图标（对齐播放控件行）；enabled=false 时置灰且不可点。
  Widget _actionItem(
    BuildContext context, {
    required IconData icon,
    Widget? iconWidget,
    String? tooltip,
    bool active = false,
    Color? iconColor,
    bool enabled = true,
    required VoidCallback onTap,
  }) {
    final accent = Theme.of(context).colorScheme.primary;
    return IconButton(
      iconSize: 28,
      tooltip: tooltip,
      icon: iconWidget ??
          Icon(
            icon,
            color: enabled
                ? (iconColor ??
                    (active ? accent : Colors.white.withValues(alpha: 0.85)))
                : Colors.white.withValues(alpha: 0.32),
          ),
      onPressed: enabled ? onTap : null,
    );
  }
}

/// 圆形评论气泡图标（对齐桌面端 lucide MessageCircle）。
class _MessageCircleIcon extends StatelessWidget {
  const _MessageCircleIcon({
    this.size = 24,
    this.color,
  });

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(size),
      painter: _MessageCirclePainter(
        color: color ?? Colors.white.withValues(alpha: 0.85),
      ),
    );
  }
}

class _MessageCirclePainter extends CustomPainter {
  _MessageCirclePainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final s = size.width / 24;
    final path = Path()
      ..moveTo(7.9 * s, 20 * s)
      ..arcToPoint(
        Offset(4 * s, 16.1 * s),
        radius: Radius.circular(9 * s),
        largeArc: true,
        clockwise: false,
      )
      ..lineTo(2 * s, 22 * s)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _MessageCirclePainter oldDelegate) =>
      oldDelegate.color != color;
}

/// 顶栏封面/歌词分段切换控件。
class _SegmentSwitcher extends StatelessWidget {
  const _SegmentSwitcher({
    required this.items,
    required this.index,
    required this.onChanged,
  });
  final List<String> items;
  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < items.length; i++)
            GestureDetector(
              onTap: () => onChanged(i),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: i == index
                      ? Colors.white.withValues(alpha: 0.22)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  items[i],
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: i == index ? FontWeight.w700 : FontWeight.w500,
                    color: Colors.white.withValues(
                      alpha: i == index ? 1 : 0.65,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 封面下歌词预览：取当前播放行的上一行/当前/下一行 共 3 行展示。
class _LyricPreview extends ConsumerStatefulWidget {
  const _LyricPreview({required this.current});
  final QueueItem? current;

  @override
  ConsumerState<_LyricPreview> createState() => _LyricPreviewState();
}

class _LyricPreviewState extends ConsumerState<_LyricPreview> {
  List<_LyricLineItem> _lines = const [];
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_LyricPreview old) {
    super.didUpdateWidget(old);
    if (old.current?.path != widget.current?.path) _load();
  }

  /// 获取插件源歌词（含 MusicFree/LX），返回待解析的纯歌词文本。
  /// 优先级与主歌词面板一致：lxlyric → yrc → qrc → eslrc → lyric。
  Future<String> _fetchPluginPreviewLyric(QueueItem item) async {
    final online = item.onlineSongJson;
    if (online == null || online.isEmpty) return '';
    Map<String, dynamic> parsed;
    try {
      parsed = jsonDecode(online) as Map<String, dynamic>;
    } catch (_) {
      return '';
    }
    final pluginId = parsed['pluginId'] as String?;
    if (pluginId == null || pluginId.isEmpty) return '';
    final sourceKey = parsed['source'] as String? ?? '';
    final musicInfo = parsed['musicInfo'] as Map<String, dynamic>? ?? {};
    try {
      final engine = await ref.read(pluginEngineProvider.future);
      final sources = await engine.store.loadSources();
      final matches = sources.where((s) => s.id == pluginId).toList();
      if (matches.isEmpty) return '';
      final lyric = await engine.getLyric(matches.first, sourceKey, musicInfo);
      if (lyric == null) return '';
      return (lyric['lxlyric'] ??
              lyric['yrc'] ??
              lyric['qrc'] ??
              lyric['eslrc'] ??
              lyric['lyric']) as String? ??
          '';
    } catch (_) {
      return '';
    }
  }

  Future<void> _load() async {
    final item = widget.current;
    final path = item?.path ?? '';
    if (path.isEmpty || _loading || _lines.isNotEmpty) return;
    // 命中缓存：直接复用已解析行，跳过网络请求与解析。
    final cached = _lyricsCache[path];
    if (cached != null && cached.isNotEmpty) {
      if (mounted) setState(() => _lines = cached);
      return;
    }
    _loading = true;
    try {
      String jsonStr = '';
      if (item!.isOnline) {
        // 在线曲目：优先取插件歌词（插件源走 pluginId 命中的插件），
        // 取不到再走 Rust 内置音源在线抓词
        final pluginText = await _fetchPluginPreviewLyric(item);
        if (pluginText.trim().isNotEmpty) {
          jsonStr = await parseLyrics(rawLyrics: pluginText);
        } else if (item.source != null && item.onlineInfoJson != null) {
          // 在线曲目：通过 Rust 接口在线抓取指定音源的歌词
          final rawResultStr = await fetchLyricFromSource(
            source: item.source!,
            songInfoJson: item.onlineInfoJson!,
          );
          if (rawResultStr != 'null' && rawResultStr.isNotEmpty) {
            String lyricsToParse = '';
            try {
              final lyricObj =
                  jsonDecode(rawResultStr) as Map<String, dynamic>;
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
        }
      } else {
        // 本地曲目：通过数据库及本地资源提取
        final dbPath = await ref.read(dbPathProvider.future);
        jsonStr = await getSongLyricsPayload(dbPath: dbPath, path: item.path);
      }
      // 解析移出主线程：JSON 解析 + 边界修正走后台 isolate。
      final parsed = (jsonStr.isNotEmpty && jsonStr != 'null')
          ? await compute(_parseLyricsJson, jsonStr)
          : const <_LyricLineItem>[];
      final lines = await compute(_normalizeBoundaries, parsed);
      if (lines.isNotEmpty) _cacheLyrics(path, lines);
      if (!mounted) return;
      setState(() => _lines = lines);
    } catch (_) {
      if (mounted) setState(() => _lines = const []);
    } finally {
      _loading = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_lines.isEmpty) return const SizedBox.shrink();
    // 预览歌词随播放进度局部刷新（只重建本行组，不影响整页）。
    final posMs = (ref.watch(playerProvider.select((s) => s.position)) * 1000);
    var active = 0;
    for (var i = 0; i < _lines.length; i++) {
      if (_lines[i].timeMs <= posMs) {
        active = i;
      } else {
        break;
      }
    }
    final items = <_LyricLineItem?>[
      active - 1 >= 0 ? _lines[active - 1] : null,
      _lines[active],
      active + 1 < _lines.length ? _lines[active + 1] : null,
    ];
    // 三行窗口随换行整体滚动：旧行上移淡出、新行自下滑入（避免逐字硬切）。
    // 进/出动画均由 AnimatedSwitcher 预先施加 switchIn/OutCurve，
    // 以 ValueKey(active) 区分方向（旧行动画反向播放 1→0，故 tween 同形）。
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 380),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, anim) {
        final isNew = (child.key as ValueKey<int>?)?.value == active;
        final offset = isNew
            ? Tween<Offset>(begin: const Offset(0, 0.6), end: Offset.zero)
            : Tween<Offset>(begin: const Offset(0, -0.6), end: Offset.zero);
        return FadeTransition(
          opacity: anim,
          child: SlideTransition(
            position: anim.drive(offset),
            child: child,
          ),
        );
      },
      child: Column(
        key: ValueKey<int>(active),
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var j = 0; j < items.length; j++)
            if (items[j] != null)
              Padding(
                padding: EdgeInsets.only(
                  top: j == 1 ? 3 : 1,
                  bottom: j == 1 ? 3 : 1,
                ),
                child: Text(
                  items[j]!.text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: j == 1
                        ? Colors.white
                        : Colors.white.withValues(alpha: 0.5),
                    fontSize: j == 1 ? 14 : 12.5,
                    height: 1.2,
                  ),
                ),
              ),
        ],
      ),
    );
  }
}

/// 单行动态跑马灯：文本超出容器宽度时自动无缝横向滚动，否则静态展示。
class _Marquee extends StatefulWidget {
  const _Marquee({required this.text, required this.style});
  final String text;
  final TextStyle style;

  @override
  State<_Marquee> createState() => _MarqueeState();
}

class _MarqueeState extends State<_Marquee>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  double _textWidth = 0;
  static const _gap = 60.0;
  static const _speed = 42.0; // 滚动速度（像素/秒）

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this)
      ..addListener(() => setState(() {}));
    _measure();
  }

  @override
  void didUpdateWidget(covariant _Marquee old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text || old.style != widget.style) _measure();
  }

  void _measure() {
    final tp = TextPainter(
      text: TextSpan(text: widget.text, style: widget.style),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout();
    _textWidth = tp.width;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, cons) {
        final maxWidth = cons.maxWidth;
        // 文本未溢出：静态展示，不启动滚动
        if (_textWidth <= maxWidth) {
          _controller.stop();
          return Align(
            alignment: Alignment.centerLeft,
            child: Text(
              widget.text,
              maxLines: 1,
              softWrap: false,
              style: widget.style,
            ),
          );
        }
        // 无缝循环滚动：总移动距离 = 文本宽 + 间隙，滚动到末尾时第二份文本续上
        final total = _textWidth + _gap;
        final seconds = total / _speed;
        if ((_controller.duration?.inMilliseconds ?? 0) !=
            (seconds * 1000).round()) {
          _controller.duration = Duration(milliseconds: (seconds * 1000).round());
        }
        if (!_controller.isAnimating) _controller.repeat();
        final dx = -_controller.value * total;
        final lineHeight = widget.style.fontSize != null
            ? (widget.style.fontSize! * 1.2).ceilToDouble()
            : 20.0;
        return ClipRect(
          child: SizedBox(
            height: lineHeight,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  left: dx - 20,
                  top: 0,
                  child: Text(
                    widget.text,
                    maxLines: 1,
                    softWrap: false,
                    style: widget.style,
                  ),
                ),
                Positioned(
                  left: dx - 20 + _textWidth + _gap,
                  top: 0,
                  child: Text(
                    widget.text,
                    maxLines: 1,
                    softWrap: false,
                    style: widget.style,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 传统模式大封面：圆角方形 + 阴影，开启「闪」时在底部叠加频谱条。
/// （歌名/收藏信息条挂在封面下方的独立行，不再叠加在封面上。）
class _TraditionalCover extends StatelessWidget {
  const _TraditionalCover({
    required this.size,
    required this.current,
    required this.eq,
    required this.flash,
    required this.playing,
  });
  final double size;
  final QueueItem? current;
  final AnimationController eq;
  final bool flash;
  final bool playing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.14),
          width: 1.0,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 28,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(23),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (current == null)
              DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(23),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      scheme.primary,
                      scheme.primary.withValues(alpha: 0.72),
                    ],
                  ),
                ),
                child: Icon(
                  Icons.music_note,
                  size: size * 0.3,
                  color: Colors.white.withValues(alpha: 0.92),
                ),
              )
            else
              CoverImage(
                songPath: current!.path,
                networkUrl: current!.coverUrl,
                width: size,
                height: size,
                radius: 23,
                highQuality: true,
                gradient: [
                  scheme.primary,
                  scheme.primary.withValues(alpha: 0.72),
                ],
              ),
            if (flash && playing)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _EqStrip(eq: eq),
              ),
          ],
        ),
      ),
    );
  }
}

/// 封面底部频谱条（「闪」动效）：底部渐隐 + 跳动的等化器竖条。
class _EqStrip extends StatelessWidget {
  const _EqStrip({required this.eq});
  final AnimationController eq;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 52,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.transparent,
            Colors.black.withValues(alpha: 0.45),
          ],
        ),
      ),
      child: AnimatedBuilder(
        animation: eq,
        builder: (context, _) {
          final t = eq.value;
          return Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var i = 0; i < 7; i++)
                Container(
                  width: 3,
                  height: 12 +
                      14 *
                          (0.5 +
                              0.5 *
                                  math.sin(
                                    t * 2 * math.pi * 2 + i * 0.8,
                                  )),
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// 横屏摄像头挖孔补偿：播放页沉浸式隐藏系统栏时 [MediaQueryData.padding]
/// 可能被清零，SafeArea 因此失效、内容会插进摄像头区；而 viewPadding 始终
/// 保留物理切口。取 viewPadding 超出 padding 的差值补在 SafeArea 内层
/// （padding 正常时差值为 0，不会双重避让）。背景层不受影响，仍透到挖孔下。
EdgeInsets _landscapeCameraCutoutExtra(BuildContext context) {
  final mq = MediaQuery.of(context);
  if (mq.size.width < mq.size.height * 1.05) return EdgeInsets.zero;
  return EdgeInsets.only(
    left: (mq.viewPadding.left - mq.padding.left).clamp(0.0, double.infinity),
    right: (mq.viewPadding.right - mq.padding.right).clamp(0.0, double.infinity),
  );
}

/// 播放页下拉收回手势：向下拖拽整页跟手位移，松手超过阈值或快速下甩
/// 即关闭页面（关闭时由路由的下滑转场从当前位置继续收到底部），
/// 否则弹回原位。歌词列表等内部纵向滚动手势由滚动视图优先接管。
class _DragDismissSheet extends StatefulWidget {
  const _DragDismissSheet({required this.child});
  final Widget child;

  @override
  State<_DragDismissSheet> createState() => _DragDismissSheetState();
}

class _DragDismissSheetState extends State<_DragDismissSheet>
    with SingleTickerProviderStateMixin {
  static const _dismissDistance = 110.0;
  static const _dismissVelocity = 700.0;

  double _dragY = 0;
  AnimationController? _settle;

  @override
  void dispose() {
    _settle?.dispose();
    super.dispose();
  }

  void _settleBack() {
    _settle?.dispose();
    _settle = null;
    if (!mounted || _dragY <= 0) return;
    final controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _settle = controller;
    final tween = Tween<double>(begin: _dragY, end: 0);
    controller.addListener(() {
      if (!mounted) return;
      setState(() => _dragY = tween.transform(controller.value));
    });
    controller.forward();
  }

  void _onDragUpdate(DragUpdateDetails details) {
    if (_settle != null) {
      _settle!.dispose();
      _settle = null;
    }
    final y = (_dragY + details.delta.dy).clamp(0.0, 4000.0);
    if (y != _dragY) setState(() => _dragY = y);
  }

  void _onDragEnd(DragEndDetails details) {
    if (_dragY > _dismissDistance ||
        details.velocity.pixelsPerSecond.dy > _dismissVelocity) {
      Navigator.of(context).pop();
      return;
    }
    _settleBack();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onVerticalDragUpdate: _onDragUpdate,
      onVerticalDragEnd: _onDragEnd,
      onVerticalDragCancel: _settleBack,
      child: Transform.translate(
        offset: Offset(0, _dragY),
        child: widget.child,
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

    // 低分辨率预烘焙：把封面先渲染到 1/8 尺寸的小图空间里做高斯模糊，再整体
    // 放大铺满（FittedBox）。高斯模糊只在 ~1/64 的像素上计算一次，放大由 GPU
    // 插值完成且模糊天然平滑；RepaintBoundary 把结果冻结成图层，整页上滑/收回
    // 与键盘适配时只搬贴图、不打重采样。
    final size = MediaQuery.of(context).size;
    const downscale = 8.0;
    final smallW = size.width / downscale;
    final smallH = size.height / downscale;
    // 背景模糊恒定为大模糊（MusicFree blurRadius=50），打开/收回全程不变，
    // 不再跟随路由转场动态调 sigma，消除开关过程中背景的观感变化。
    const sigma = 50.0 / downscale;
    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 深色底：封面加载前/加载失败时的兜底
          Container(color: Color.lerp(scheme.surface, Colors.black, 0.6)),
          // 封面铺满全屏 + 大半径模糊（对应 MusicFree blurRadius=50）
          FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: smallW,
              height: smallH,
              child: ImageFiltered(
                imageFilter: ImageFilter.blur(
                  sigmaX: sigma,
                  sigmaY: sigma,
                  tileMode: TileMode.decal,
                ),
                child: CoverImage(
                  songPath: item.path,
                  networkUrl: item.coverUrl,
                  width: smallW,
                  height: smallH,
                  radius: 0,
                  gradient: [
                    scheme.primary,
                    scheme.primary.withValues(alpha: 0.72),
                  ],
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
            ),
          ),
          // 已去掉背景全屏压暗层：歌词/封面直接铺在模糊封面上，观感更亮更通透。
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
        // 光斑已改为径向渐晕，不再需要全屏 sigma60 BackdropFilter。
      ],
    );
  }

  Widget _blob(Color color, double size) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      // 自带 alpha 径向渐晕即为柔光，替代原全屏 sigma60 BackdropFilter（常驻高成本点）。
      gradient: RadialGradient(colors: [color, color.withValues(alpha: 0)]),
    ),
  );
}

/// 大封面：本地/在线封面，无封面时回退渐变占位。
class _BigCover extends StatelessWidget {
  const _BigCover({required this.current, this.size});

  final QueueItem? current;

  /// 指定封面边长；为空时按竖屏直觉取值（屏宽 68%）。
  final double? size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final coverSize = size ?? MediaQuery.of(context).size.width * 0.68;
    return Container(
      width: coverSize,
      height: coverSize,
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
            ? _placeholder(scheme, coverSize)
            : CoverImage(
                songPath: current!.path,
                networkUrl: current!.coverUrl,
                width: coverSize,
                height: coverSize,
                radius: 31,
                highQuality: true,
                gradient: [
                  scheme.primary,
                  scheme.primary.withValues(alpha: 0.72),
                ],
              ),
      ),
    );
  }

  Widget _placeholder(ColorScheme scheme, double coverSize) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [scheme.primary, scheme.primary.withValues(alpha: 0.72)],
        ),
      ),
      child: Icon(
        Icons.music_note,
        size: coverSize * 0.34,
        color: Colors.white.withValues(alpha: 0.92),
      ),
    );
  }
}

/// 毛玻璃控制卡：标题 + 进度 + 播放控制。
class _GlassControlCard extends ConsumerWidget {
  const _GlassControlCard({
    required this.notifier,
    required this.current,
    this.landscape = false,
  });
  final PlayerNotifier notifier;
  final QueueItem? current;
  final bool landscape;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final lowPerf = ref.watch(
      settingsProvider.select(
          (s) => performancePriority(s.valueOrNull ?? const AppSettings())),
    );
    final playerLiquid =
        (ref
            .watch(
              settingsProvider.select((s) => s.valueOrNull?.playerLiquidGlass),
            ) ??
            true) &&
            !lowPerf;
    // 毛玻璃材质开关：关闭时控制卡回退为高不透明度纯色（无模糊）。
    final frosted = ref.watch(
      settingsProvider.select((s) => s.valueOrNull?.frostedGlass ?? true),
    );
    // 全局 blur 预算：滚动/转场时播放页控制卡玻璃降级（drawerOrSheet 档）。
    final budget = ref.watch(blurBudgetProvider(BlurSurfaceType.drawerOrSheet));
    // 错误态只在此局部订阅，不随整页重建。
    final error = ref.watch(playerProvider.select((s) => s.error));

    final content = Padding(
      // 横屏时标题已居中在顶栏，控制卡只留进度 + 三区控制行，内边距收敛。
      padding: landscape
          ? const EdgeInsets.fromLTRB(8, 10, 8, 12)
          : const EdgeInsets.fromLTRB(20, 18, 20, 16),
      child: current == null
          ?   Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: Text(tr('暂无播放'))),
            )
          : landscape
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                RepaintBoundary(
                  child: _ProgressBar(
                    notifier: notifier,
                    // 时长已移到控制行左下角，进度条这里不再重复显示。
                    showTime: false,
                  ),
                ),
                const SizedBox(height: 4),
                _LandscapeControlsRow(notifier: notifier, current: current),
              ],
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _TitleRow(current: current!),
                if (error != null) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(Icons.error_outline, size: 15, color: scheme.error),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          error,
                          style: TextStyle(fontSize: 12, color: scheme.error),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 14),
                // 进度条独立成图层：position tick 只重绘进度条，不重绘整张玻璃卡。
                RepaintBoundary(
                  child: _ProgressBar(notifier: notifier),
                ),
                const SizedBox(height: 6),
                _Controls(notifier: notifier),
              ],
            ),
    );

    // 材质优先级：低性能 > 液态玻璃（固定控件，优先级最高）> 毛玻璃 >
    // 毛玻璃关闭时的纯色回退。液态与毛玻璃可共存，液态只覆盖此控制卡。
    if (lowPerf || (!frosted && !playerLiquid)) {
      // 性能模式 / 毛玻璃关闭且液态未开：更高不透明度纯色补偿模糊缺失，
      // 省去 premium shader 与 BackdropFilter。
      return Container(
        decoration: BoxDecoration(
          color: isDark ? const Color(0xE62A2A2E) : const Color(0xF0FFFFFF),
          borderRadius: BorderRadius.circular(26),
          border: Border.all(
            color: Colors.white.withValues(alpha: isDark ? 0.12 : 0.5),
          ),
        ),
        child: content,
      );
    }

    if (playerLiquid) {
      // BiliPai 液态玻璃控制卡：与底栏/迷你播放条同一套 shader 观感
      // （边缘透镜折射 + 滚动波浪 + 色差），档位联动折射/色差/高光强度。
      final quality = liquidGlassQualitySetting(ref);
      return BiliPaiGlass(
        radius: 26,
        refract: bilipaiRefractOf(quality),
        chroma: bilipaiChromaOf(quality),
        blurSigma: surfaceBlurSigma(
          base: 4,
          budget: budget,
          type: BlurSurfaceType.drawerOrSheet,
        ),
        backgroundColor: bilipaiGlassTint(isDark),
        specular: bilipaiSpecularOf(quality),
        edgeAmount: bilipaiEdgeOf(quality),
        saturation: bilipaiSaturationOf(quality),
        child: content,
      );
    }

    final glassColor = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.white.withValues(alpha: 0.6);

    final sigma = surfaceBlurSigma(
      base: 15,
      budget: budget,
      type: BlurSurfaceType.drawerOrSheet,
    );
    // 降采样模糊（cheapBackdropBlur）：模糊工作量降为 1/16，运动期保持
    // 玻璃恒定（RwaS 口径），sigma 按预算档位缩放。
    return ClipRRect(
      borderRadius: BorderRadius.circular(26),
      child: BackdropFilter(
        filter: cheapBackdropBlur(sigma),
        child: Container(
          decoration: BoxDecoration(
            color: surfaceFillWithBudget(glassColor, budget),
            borderRadius: BorderRadius.circular(26),
            border: Border.all(
              color: Colors.white.withValues(alpha: isDark ? 0.12 : 0.5),
            ),
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
    final currentQuality = ref.watch(
      playerProvider.select((s) => s.currentQuality),
    );
    final lyricsEnabled = ref.watch(
      settingsProvider.select((s) => s.valueOrNull?.floatingLyricsEnabled ?? false),
    );
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
                  color: Colors.white,
                ),
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
        if (current.isOnline)
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => _showQualitySheet(context, ref),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Text(
                _qualityLabel(currentQuality),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.5,
                  color:
                      (currentQuality != null &&
                          isLosslessQuality(currentQuality))
                      ? scheme.primary
                      : Color(0xFFEC4141).withValues(alpha: 0.9),
                ),
              ),
            ),
          ),
        IconButton(
          icon: Icon(
            isFav ? Icons.favorite : Icons.favorite_border,
            color: isFav ? scheme.primary : null,
          ),
          onPressed: () => ref.read(favoritesProvider.notifier).toggle(current),
        ),
        IconButton(
          icon: const Icon(Icons.ios_share),
          tooltip: tr('分享歌曲'),
          onPressed: () => _shareCurrent(context, ref, current),
        ),
        if (current.isOnline)
          IconButton(
            icon: const Icon(Icons.download_outlined),
            onPressed: () => _showDownloadQualitySheet(context, ref, current),
          ),
        if (current.isOnline)
          IconButton(
            icon: const Icon(Icons.mode_comment_outlined),
            onPressed: () => showSheetDialog<void>(
              context,
              (_) => CommentSheet(songJson: current.onlineSongJson),
            ),
          ),
        // 桌面歌词「词」按钮（高级模式）：与收藏/分享/下载/评论并排、位于最右
        InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => _toggleFloatingLyrics(context, ref, lyricsEnabled),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: Container(
              width: 24,
              height: 24,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: lyricsEnabled
                    ? scheme.primary.withValues(alpha: 0.14)
                    : Colors.transparent,
              ),
              child: Text(
                tr('词'),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: lyricsEnabled
                      ? scheme.primary
                      : scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 弹出歌曲分享菜单（分享到 QQ 好友 / QQ 空间 / 复制链接）。
Future<void> _shareCurrent(
    BuildContext context, WidgetRef ref, QueueItem current) async {
  await showSongShareSheet(context, ref: ref, song: current);
}

/// 打开音质选择弹窗（触发全量探测真实可用档位）。
void _showQualitySheet(BuildContext context, WidgetRef ref) {
  final notifier = ref.read(playerProvider.notifier);
  showSheetDialog<void>(
  context,
  (_) => _QualitySheet(notifier: notifier),
);
}

/// 打开下载音质选择弹窗（复用共享探针探测真实可用档位，选档后直接下载）。
void _showDownloadQualitySheet(
    BuildContext context, WidgetRef ref, QueueItem song) {
  final notifier = ref.read(playerProvider.notifier);
  showSheetDialog<void>(
  context,
  (_) => _DownloadQualitySheet(notifier: notifier, song: song),
);
}

/// 把 12 档内部键转成菜单/按钮上的人类可读标签。
String _qualityLabel(String? q) {
  if (q == null || q.isEmpty) return 'HQ';
  switch (q) {
    case 'mgg':
      return 'MGG';
    case '128k':
      return '128K';
    case '192k':
      return '192K';
    case '320k':
      return '320K';
    case 'flac':
      return 'FLAC';
    case 'flac24bit':
      return 'FLAC24';
    case 'hires':
      return 'Hi-Res';
    case 'vinyl':
      return tr('黑胶');
    case 'dolby':
      return tr('杜比');
    case 'atmos':
      return 'Atmos';
    case 'atmos_plus':
      return 'Atmos+';
    case 'master':
      return 'Master';
    default:
      return q.toUpperCase();
  }
}

/// 紧凑体积文本（对齐桌面端 compactFileSize：28.6M / 1.2G / 320K）。
String _compactSize(int bytes) {
  final mb = bytes / 1024 / 1024;
  if (mb >= 1024) return '${(mb / 1024).toStringAsFixed(1)}G';
  if (mb >= 1) return '${mb.toStringAsFixed(1)}M';
  final kb = bytes / 1024;
  if (kb >= 1) return '${kb.round()}K';
  return '${bytes}B';
}

/// 音质档位标签追加实测体积后缀（体积未知时返回空串）。
String _qualitySizeSuffix(String q, Map<String, QualitySizeInfo> sizes) {
  final info = sizes[q];
  if (info == null) return '';
  return ' · ${_compactSize(info.bytes)}';
}

/// 音质选择弹窗：探测并展示当前在线歌曲的真实可用档位，点选即切换。
class _QualitySheet extends ConsumerStatefulWidget {
  const _QualitySheet({required this.notifier});

  final PlayerNotifier notifier;

  @override
  ConsumerState<_QualitySheet> createState() => _QualitySheetState();
}

class _QualitySheetState extends ConsumerState<_QualitySheet> {
  Future<List<String>>? _future;
  Future<Map<String, QualitySizeInfo>>? _sizes;

  @override
  void initState() {
    super.initState();
    _future = widget.notifier.qualityOptions();
    _sizes = _loadSizes();
  }

  /// 体积探测：等档位菜单探测收尾（后台仍在探测时最多等 3 轮），
  /// 再对已解析直链做体积探测，保证弹窗能一次带上大部分档位的体积。
  Future<Map<String, QualitySizeInfo>> _loadSizes() async {
    final future = _future!;
    await future;
    for (var i = 0; i < 3; i++) {
      if (!mounted) return const {};
      if (!ref.read(playerProvider.select((s) => s.qualityMenuProbing))) {
        break;
      }
      await Future.delayed(const Duration(milliseconds: 1500));
    }
    if (!mounted) return const {};
    return widget.notifier.qualitySizes();
  }

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.7,
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
              child: Text(
                tr('音质选择'),
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.2,
                ),
              ),
            ),
            const SizedBox(height: 12),
            FutureBuilder<List<String>>(
              future: _future,
              builder: (ctx, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 48),
                    child: Center(
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    ),
                  );
                }
                final opts = snap.data ?? const <String>[];
                // 兜底：future 返回空但状态里已有探测结果时展示状态结果，
                // 避免探测时序导致菜单空态。
                final fallbackOpts = ref.watch(
                  playerProvider.select((s) => s.availableQualities),
                );
                final shown = opts.isNotEmpty ? opts : fallbackOpts;
                if (shown.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 48),
                    child: Center(child: Text(tr('暂无可切换音质'))),
                  );
                }
                final cur = ref.watch(
                  playerProvider.select((s) => s.currentQuality),
                );
                return FutureBuilder<Map<String, QualitySizeInfo>>(
                  future: _sizes,
                  builder: (ctx, sizeSnap) {
                    final sizes =
                        sizeSnap.data ?? const <String, QualitySizeInfo>{};
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final q in shown) ...[
                            ModernOptionTile<String>(
                              option: ModernChoiceOption(
                                label:
                                    '${_qualityLabel(q)}${_qualitySizeSuffix(q, sizes)}',
                                value: q,
                              ),
                              isSelected: q == cur,
                              onTap: q == cur
                                  ? () {}
                                  : () async {
                                      final ok =
                                          await widget.notifier.switchQuality(
                                        q,
                                      );
                                      if (!ctx.mounted) return;
                                      final overlay = Overlay.of(
                                        ctx,
                                        rootOverlay: true,
                                      );
                                      Navigator.of(ctx).pop();
                                      showXianYuToastByOverlay(
                                        overlay,
                                        ok
                                            ? '已切换为${_qualityLabel(q)}'
                                            : tr('音质切换失败'),
                                      );
                                    },
                            ),
                            const SizedBox(height: 6),
                          ],
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// 下载音质选择弹窗：复用共享探针探测真实可用档位，点选即按该档下载。
class _DownloadQualitySheet extends ConsumerStatefulWidget {
  const _DownloadQualitySheet({required this.notifier, required this.song});

  final PlayerNotifier notifier;
  final QueueItem song;

  @override
  ConsumerState<_DownloadQualitySheet> createState() =>
      _DownloadQualitySheetState();
}

class _DownloadQualitySheetState
    extends ConsumerState<_DownloadQualitySheet> {
  Future<List<String>>? _future;
  Future<Map<String, QualitySizeInfo>>? _sizes;

  @override
  void initState() {
    super.initState();
    _future = widget.notifier.downloadQualityOptions();
    _sizes = _loadSizes();
  }

  /// 体积探测：等档位菜单探测收尾（后台仍在探测时最多等 3 轮），
  /// 再对已解析直链做体积探测，保证弹窗能一次带上大部分档位的体积。
  Future<Map<String, QualitySizeInfo>> _loadSizes() async {
    final future = _future!;
    await future;
    for (var i = 0; i < 3; i++) {
      if (!mounted) return const {};
      if (!ref.read(playerProvider.select((s) => s.qualityMenuProbing))) {
        break;
      }
      await Future.delayed(const Duration(milliseconds: 1500));
    }
    if (!mounted) return const {};
    return widget.notifier.qualitySizes();
  }

  @override
  Widget build(BuildContext context) {
    // 高亮当前播放音质；无播放音质时回退设置中的下载音质。
    final cur = ref.watch(playerProvider.select((s) => s.currentQuality));
    final settingsQ = ref.watch(
      settingsProvider.select((s) => s.valueOrNull?.downloadQuality),
    );
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.7,
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
              child: Text(
                tr('下载音质'),
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.2,
                ),
              ),
            ),
            const SizedBox(height: 12),
            FutureBuilder<List<String>>(
              future: _future,
              builder: (ctx, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 48),
                    child: Center(
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    ),
                  );
                }
                final opts = snap.data ?? const <String>[];
                if (opts.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 48),
                    child: Center(child: Text(tr('暂无可下载音质'))),
                  );
                }
                return FutureBuilder<Map<String, QualitySizeInfo>>(
                  future: _sizes,
                  builder: (ctx, sizeSnap) {
                    final sizes =
                        sizeSnap.data ?? const <String, QualitySizeInfo>{};
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final q in opts) ...[
                            ModernOptionTile<String>(
                              option: ModernChoiceOption(
                                label:
                                    '${_qualityLabel(q)}${_qualitySizeSuffix(q, sizes)}',
                                value: q,
                              ),
                              isSelected: q == cur ||
                                  (cur == null && q == settingsQ),
                              onTap: () {
                                final overlay =
                                    Overlay.of(ctx, rootOverlay: true);
                                Navigator.of(ctx).pop();
                                ref
                                    .read(downloadProvider.notifier)
                                    .download(widget.song, quality: q);
                                showXianYuToastByOverlay(
                                  overlay,
                                  tr('开始下载：{title}（{quality}）', {
                                    'title': widget.song.title,
                                    'quality': _qualityLabel(q),
                                  }),
                                );
                              },
                            ),
                            const SizedBox(height: 6),
                          ],
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _ProgressBar extends ConsumerWidget {
  const _ProgressBar({required this.notifier, this.showTime = true});
  final PlayerNotifier notifier;

  /// 是否在进度条下方显示当前/总时长文本。横屏时长移到控制行左下角，此处关闭。
  final bool showTime;

  String _fmt(double s) {
    final m = s ~/ 60;
    final sec = (s % 60).floor();
    return '${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    // 进度条是唯一随播放进度每秒变化的区域，单独 select position 局部刷新，
    // 不影响上层（顶层已只订阅 current，切歌才重建）。
    final position = ref.watch(playerProvider.select((s) => s.position));
    final dur = ref.watch(playerProvider.select((s) => s.duration));
    final duration = dur <= 0 ? 1.0 : dur;
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
          child: CommittedSlider(
            value: position.clamp(0, duration),
            min: 0,
            max: duration,
            onCommit: (v) => notifier.seek(v),
          ),
        ),
        if (showTime)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _fmt(position),
                  style: TextStyle(
                      fontSize: 11, color: scheme.onSurfaceVariant),
                ),
                Text(
                  _fmt(duration),
                  style:
                      TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _Controls extends ConsumerWidget {
  const _Controls({required this.notifier});
  final PlayerNotifier notifier;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    // 播放态/播放模式/解析中仅在此局部订阅，不随整页重建。
    final playMode = ref.watch(playerProvider.select((s) => s.playMode));
    final resolving = ref.watch(playerProvider.select((s) => s.resolving));
    final isPlaying = ref.watch(playerProvider.select((s) => s.isPlaying));
    // 播放条下一行：4 个侧键统一大小（28）与等距（spaceEvenly），播放键除外保持突出
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        // 5 等分+居中：与进度条上方动作行的 5 列严格同轴（用 Expanded/Center 替代
        // spaceEvenly，避免大播放键拉宽让两排列中心偏移）。
        children: [
          Expanded(child: Center(child: IconButton(
            iconSize: 28,
            icon: _PlayModeIcon(
              mode: playMode,
              color: scheme.onSurfaceVariant,
              size: 28,
            ),
            onPressed: notifier.cyclePlayMode,
          ))),
          Expanded(child: Center(child: IconButton(iconSize: 28, icon: const Icon(Icons.skip_previous), onPressed: notifier.previous))),
          // 主题色实心播放键
          Expanded(child: Center(child: Container(
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
            child: resolving
                ? const Padding(
                    padding: EdgeInsets.all(18),
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: Colors.white,
                    ),
                  )
                : IconButton(
                    icon: Icon(
                      isPlaying ? Icons.pause : Icons.play_arrow,
                      color: Colors.white,
                    ),
                    iconSize: 34,
                    onPressed: notifier.toggle,
                  ),
          ))),
          Expanded(child: Center(child: IconButton(iconSize: 28, icon: const Icon(Icons.skip_next), onPressed: notifier.next))),
          Expanded(child: Center(child: IconButton(iconSize: 28, icon: Icon(Icons.queue_music, color: scheme.onSurfaceVariant), onPressed: () => _showQueueSheet(context, ref)))),
        ],
      ),
    );
  }

  /// 播放队列弹窗：展示/点播/移除/拖拽排序。
  void _showQueueSheet(BuildContext context, WidgetRef ref) {
    showSheetDialog<void>(
        context, (_) => _QueueSheet(player: ref.read(playerProvider)));
  }
}

/// 音质缩写（对齐桌面端 QUALITY_ABBR）。
String _qualityAbbr(String? q) {
  switch (q) {
    case null:
    case '':
      return 'HQ';
    case 'mgg':
      return 'LQ';
    case '128k':
      return '128';
    case '192k':
      return '192';
    case '320k':
      return 'HQ';
    case 'flac':
      return 'SQ';
    case 'flac24bit':
      return 'HR';
    case 'hires':
      return 'HRA';
    case 'vinyl':
      return 'VL';
    case 'dolby':
      return 'DA';
    case 'atmos':
      return 'AT';
    case 'atmos_plus':
      return 'AT+';
    case 'master':
      return 'MS';
    default:
      return q.toUpperCase();
  }
}

/// 横屏底栏三区控制行：左（下载/音效/播放顺序）｜中（上一首/播放/下一首）｜
/// 右（桌面歌词/音质/播放队列）。评论不在此列；横竖屏共用传统动作图标样式。
class _LandscapeControlsRow extends ConsumerWidget {
  const _LandscapeControlsRow({
    required this.notifier,
    required this.current,
  });

  final PlayerNotifier notifier;
  final QueueItem? current;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final accent = scheme.primary;
    // 局部变量承接字段：可被 null 提升（字段在闭包内不提升）。
    final item = current;
    // 局部订阅：仅此底栏随播放态/下载态重建，不波及中区封面/歌词。
    final sfx = ref.watch(soundEffectProvider).settings;
    final bypass = sfx.bypass;
    final dl = ref.watch(downloadProvider);
    final isLocal = item != null && !item.isOnline;
    final currentQuality = ref.watch(
      playerProvider.select((s) => s.currentQuality),
    );
    final lossless = currentQuality != null && isLosslessQuality(currentQuality);
    final lyricsEnabled = ref.watch(
      settingsProvider.select(
          (s) => s.valueOrNull?.floatingLyricsEnabled ?? false),
    );
    final playMode = ref.watch(playerProvider.select((s) => s.playMode));
    final resolving = ref.watch(playerProvider.select((s) => s.resolving));
    final isPlaying = ref.watch(playerProvider.select((s) => s.isPlaying));
    final dlActive = item != null &&
        dl.tasks.any((t) =>
            t.songPath == item.path &&
            (t.status == DownloadStatus.waiting ||
                t.status == DownloadStatus.downloading));
    final dlDone = item != null &&
        (isLocal || dl.history.any((h) => h.songPath == item.path));
    final isFav = item != null &&
        ref.watch(favoritesProvider.select((s) => s.contains(item.path)));
    // 底栏图标统一白 85%（对齐传统动作行），选中/活跃项用主题色。
    final idle = Colors.white.withValues(alpha: 0.85);
    // 左下角时长：仅此时间文本随播放进度局部刷新，不波及其余控制键。
    // 参考桌面端歌词页「当前时间 / 总时长」并排显示，进度条仍留在上方。
    final position = ref.watch(playerProvider.select((s) => s.position));
    final dur = ref.watch(playerProvider.select((s) => s.duration));
    String fmtTime(double s) {
      final m = s ~/ 60;
      final sec = (s % 60).floor();
      return '${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
    }

    // 桌面对齐底部栏（对齐桌面端歌词页布局）：
    // 左簇 [时长 下载 收藏]｜中簇 [播放顺序 上一首 播放 下一首 歌词]｜右簇 [音质 音效 队列]。
    final leftCluster = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 时长（左下角）：桌面端样式「当前时间 / 总时长」
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Text(
            '${fmtTime(position)} / ${dur <= 0 ? '--:--' : fmtTime(dur)}'.trimRight(),
            style: TextStyle(
              fontSize: 12,
              fontFeatures: const [FontFeature.tabularFigures()],
              color: Colors.white.withValues(alpha: 0.6),
            ),
          ),
        ),
        // 下载
        IconButton(
          iconSize: 28,
          tooltip: dlDone ? tr('已下载') : (dlActive ? tr('下载中') : tr('下载')),
          icon: dlActive
              ? SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white.withValues(alpha: 0.8),
                  ),
                )
              : Icon(
                  dlDone ? Icons.check_circle_outline : Icons.download_outlined,
                  color: dlDone ? const Color(0xFF07C160) : idle,
                ),
          onPressed: () {
            if (item == null) return;
            if (dlActive) {
              showXianYuToast(context, tr('正在下载中…'));
              return;
            }
            if (dlDone) {
              showXianYuToast(
                context,
                isLocal ? tr('本地音乐已在设备') : tr('已下载，可到下载页查看'),
              );
              return;
            }
            _showDownloadQualitySheet(context, ref, item);
          },
        ),
        // 收藏（放在下载右边，激活色固定红色）
        IconButton(
          iconSize: 28,
          tooltip: tr('收藏'),
          icon: Icon(
            isFav ? Icons.favorite : Icons.favorite_border,
            color: isFav ? const Color(0xFFEC4141) : idle,
          ),
          onPressed: () {
            if (item != null) {
              ref.read(favoritesProvider.notifier).toggle(item);
            }
          },
        ),
      ],
    );

    final centerCluster = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 播放顺序（三大键左边）
        IconButton(
          iconSize: 28,
          icon: _PlayModeIcon(mode: playMode, color: idle, size: 28),
          onPressed: notifier.cyclePlayMode,
        ),
        IconButton(
          iconSize: 28,
          icon: Icon(Icons.skip_previous, color: idle),
          onPressed: notifier.previous,
        ),
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: accent,
            boxShadow: [
              BoxShadow(
                color: accent.withValues(alpha: 0.4),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: resolving
              ? const Padding(
                  padding: EdgeInsets.all(18),
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: Colors.white,
                  ),
                )
              : IconButton(
                  icon: Icon(
                    isPlaying ? Icons.pause : Icons.play_arrow,
                    color: Colors.white,
                  ),
                  iconSize: 34,
                  onPressed: notifier.toggle,
                ),
        ),
        IconButton(
          iconSize: 28,
          icon: Icon(Icons.skip_next, color: idle),
          onPressed: notifier.next,
        ),
        // 歌词（三大键右边）：桌面歌词「词」入口
        IconButton(
          iconSize: 28,
          tooltip: tr('桌面歌词'),
          icon: Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: lyricsEnabled
                  ? accent.withValues(alpha: 0.14)
                  : Colors.transparent,
            ),
            child: Text(
              tr('词'),
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.bold,
                color: lyricsEnabled ? accent : idle,
              ),
            ),
          ),
          onPressed: () => _toggleFloatingLyrics(context, ref, lyricsEnabled),
        ),
      ],
    );

    final rightCluster = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 音质
        Tooltip(
          message: tr('音质'),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () {
              if (item == null) return;
              if (item.isOnline) {
                _showQualitySheet(context, ref);
              } else {
                showXianYuToast(context, tr('本地音乐以原音质播放'));
              }
            },
            child: Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: lossless
                    ? accent.withValues(alpha: 0.12)
                    : Colors.transparent,
              ),
              child: Text(
                _qualityAbbr(currentQuality),
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: lossless ? accent : idle,
                ),
              ),
            ),
          ),
        ),
        // 音效（音质和队列中间）
        IconButton(
          iconSize: 28,
          tooltip: tr('音效'),
          icon: Icon(Icons.graphic_eq, color: bypass ? idle : accent),
          onPressed: () => context.push('/effects'),
        ),
        // 播放队列
        IconButton(
          iconSize: 28,
          icon: Icon(Icons.queue_music, color: idle),
          onPressed: () => showSheetDialog<void>(
            context,
            (_) => _QueueSheet(player: ref.read(playerProvider)),
          ),
        ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Expanded(
            child: Align(alignment: Alignment.centerLeft, child: leftCluster),
          ),
          Align(alignment: Alignment.center, child: centerCluster),
          Expanded(
            child: Align(alignment: Alignment.centerRight, child: rightCluster),
          ),
        ],
      ),
    );
  }
}

/// 播放顺序图标（对齐桌面端 FooterControlIcon 的线性 SVG 风格）：
/// 0=列表循环、1=单曲循环、2=随机播放。
class _PlayModeIcon extends StatelessWidget {
  const _PlayModeIcon({
    required this.mode,
    required this.color,
    this.size = 24,
  });

  final int mode;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(size),
      painter: _PlayModePainter(mode: mode, color: color),
    );
  }
}

class _PlayModePainter extends CustomPainter {
  _PlayModePainter({required this.mode, required this.color});

  final int mode;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final s = size.width / 24;
    final path = Path();
    if (mode == 0 || mode == 1) {
      // 列表循环 / 单曲循环：Heroicons arrow-path
      path
        ..moveTo(4 * s, 4 * s)
        ..lineTo(4 * s, 9 * s)
        ..lineTo(4.582 * s, 9 * s)
        ..moveTo(19.938 * s, 11 * s)
        ..arcToPoint(
          Offset(4.582 * s, 9 * s),
          radius: Radius.circular(8.001 * s),
          largeArc: false,
          clockwise: false,
        )
        ..moveTo(4.582 * s, 9 * s)
        ..lineTo(9 * s, 9 * s)
        ..moveTo(20 * s, 20 * s)
        ..lineTo(20 * s, 15 * s)
        ..lineTo(19.419 * s, 15 * s)
        ..arcToPoint(
          Offset(4.062 * s, 13 * s),
          radius: Radius.circular(8.003 * s),
          largeArc: false,
          clockwise: true,
        )
        ..moveTo(19.419 * s, 15 * s)
        ..lineTo(15 * s, 15 * s);
    } else {
      // 随机播放：Heroicons arrows-right-left
      path
        ..moveTo(16 * s, 3 * s)
        ..lineTo(21 * s, 3 * s)
        ..lineTo(21 * s, 8 * s)
        ..moveTo(4 * s, 20 * s)
        ..lineTo(21 * s, 3 * s)
        ..moveTo(21 * s, 16 * s)
        ..lineTo(21 * s, 21 * s)
        ..lineTo(16 * s, 21 * s)
        ..moveTo(15 * s, 15 * s)
        ..lineTo(21 * s, 21 * s)
        ..moveTo(4 * s, 4 * s)
        ..lineTo(9 * s, 9 * s);
    }
    canvas.drawPath(path, paint);

    if (mode == 1) {
      final tp = TextPainter(
        text: TextSpan(
          text: '1',
          style: TextStyle(
            fontSize: 10 * s,
            fontWeight: FontWeight.bold,
            color: color,
            height: 1,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(
        canvas,
        Offset(
          (size.width - tp.width) / 2,
          (size.height - tp.height) / 2,
        ),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _PlayModePainter oldDelegate) =>
      oldDelegate.mode != mode || oldDelegate.color != color;
}

/// 切换悬浮歌词（桌面歌词）：未开启且无悬浮窗权限时引导授权。
Future<void> _toggleFloatingLyrics(
  BuildContext context,
  WidgetRef ref,
  bool enabled,
) async {
  final n = ref.read(settingsProvider.notifier);
  if (enabled) {
    await n.setFloatingLyricsEnabled(false);
    return;
  }
  final granted = await FloatingLyricsController.isPermissionGranted();
  if (!granted) {
    if (!context.mounted) return;
    final go = await showPredictiveDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title:   Text(tr('悬浮歌词需要悬浮窗权限')),
        content:   Text(
            tr('开启后歌词窗可显示在其他应用上层。需要前往系统设置授予「显示在其他应用上层」权限。')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child:   Text(tr('取消')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child:   Text(tr('去授权')),
          ),
        ],
      ),
    );
    if (go == true) {
      await FloatingLyricsController.openPermissionSettings();
      await n.setFloatingLyricsEnabled(true);
    }
    return;
  }
  await n.setFloatingLyricsEnabled(true);
}

/// 剥离所有音源（酷我/酷狗/LX/KRC/YRC/QRC 等）内嵌的逐字时间戳与元数据标签。
String _cleanLyricText(String raw) {
  if (raw.isEmpty) return '';

  String text = raw;

  // 1. 过滤元数据控制头 [ar:xx], [ti:xx], [al:xx], [by:xx], [offset:xx], [kuwo:xx], [kugou:xx], [hash:xx] 等
  text = text.replaceAll(
    RegExp(
      r'\[(ar|ti|al|by|offset|kuwo|kugou|hash|sign|qq|total|language|types):[^\]]*\]',
      caseSensitive: false,
    ),
    '',
  );

  // 2. 过滤酷狗 KRC / YRC 圆括号逐字时间戳 (如 (1234,500,0) 或 (1234,500))
  text = text.replaceAll(RegExp(r'\(\d+,\d+(?:,\d+)?\)'), '');

  // 3. 过滤方括号内嵌逐字时间戳 [1234,5678]
  text = text.replaceAll(RegExp(r'\[\d+,\d+\]'), '');

  // 4. 过滤尖括号时间戳 <2688,-2688> 或 <00:12.34>
  text = text.replaceAll(RegExp(r'<[^>]*>'), '');

  return text.trim();
}

/// 将歌词 JSON（displayLines/lines，含 time/endTime/text/translation/romaji/words）
/// 解析为歌词行列表。供歌词视图与封面下预览共用。
List<_LyricLineItem> _parseLyricsJson(String jsonStr) {
  final map = jsonDecode(jsonStr) as Map<String, dynamic>;
  final rawLines =
      (map['displayLines'] as List?) ??
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
      final translation = rawTrans != null
          ? _cleanLyricText(rawTrans)
          : null;

      final rawRomaji = (item['romaji'] as String?)?.trim();
      final romaji = (rawRomaji != null && rawRomaji.isNotEmpty)
          ? rawRomaji
          : null;

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
              words.add(
                _LyricWordItem(text: wText, start: wStart, end: wEnd),
              );
            }
          }
        }
      }

      if (text.isNotEmpty) {
        lines.add(
          _LyricLineItem(
            timeMs: (timeSec * 1000).toInt(),
            endTimeMs: (endTimeSec * 1000).round(),
            text: text,
            translation: (translation != null && translation.isNotEmpty)
                ? translation
                : null,
            romaji: romaji,
            words: words,
          ),
        );
      }
    }
  }
  return lines;
}

/// 时间边界修正（移植自桌面端 converters.ts）：
/// - 行结束时间缺失/无效时，用下一行起点回推（提前量 = min(300ms, 间隔×25%)，
///   行最短 40ms）；最后一行给 5s 宽松结束
/// - 词的 end 裁剪到下一词 start 与行结束之内（最短 20ms），
///   避免相邻词重叠导致的填充回跳
///
/// 顶层函数以便 [compute] 在后台 isolate 中执行。
List<_LyricLineItem> _normalizeBoundaries(List<_LyricLineItem> lines) {
  final result = <_LyricLineItem>[];
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final startMs = line.timeMs.toDouble();
    final nextStartMs = i + 1 < lines.length
        ? lines[i + 1].timeMs.toDouble()
        : double.infinity;

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
          words.add(
            _LyricWordItem(
              text: String.fromCharCode(chars[c]),
              start: (wStartMs + durMs * c) / 1000.0,
              end: (wStartMs + durMs * (c + 1)) / 1000.0,
            ),
          );
        }
      } else {
        words.add(
          _LyricWordItem(
            text: w.text,
            start: wStartMs / 1000.0,
            end: wEndMs / 1000.0,
          ),
        );
      }
    }

    result.add(
      _LyricLineItem(
        timeMs: line.timeMs,
        endTimeMs: endMs.round(),
        text: line.text,
        translation: line.translation,
        romaji: line.romaji,
        words: words,
      ),
    );
  }
  return result;
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
    super.key,
    required this.current,
    required this.visible,
    required this.onTap,
    required this.onRomajiAvailable,
  });

  final QueueItem? current;
  final bool visible; // 歌词视图是否可见（不可见时停帧省电）
  final VoidCallback onTap;
  final ValueChanged<bool> onRomajiAvailable;

  @override
  ConsumerState<_LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends ConsumerState<_LyricsView>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  List<_LyricLineItem> _lines = [];
  bool _loading = false;
  String? _loadedPath;
  final ScrollController _scrollCtrl = ScrollController();

  /// 用户是否手动翻看/拖动了歌词
  bool _userInteracted = false;

  Timer? _recenterTimer;
  int _lastActiveIndex = -1;

  /// 自动居中死区（px）已移除：RwaS 等字号样式下换行无布局跳变。

  /// 横屏歌词字号放大系数（build 时回写；竖屏 1.0 不变）。
  double _fontScale = 1.0;

  // ---- RwaS 换行拽动（LyricPullEngine 移植）----
  // 前进换行时，锚点之后的行在 550ms 窗口内先被“按住”（随滚动补偿位移），
  // 再按 每行递增 delay 逐行弹回落位，形成整组歌词的弹性拽动。
  bool _pullActive = false;
  int _pullAnchor = -1;
  double _pullDistance = 0;
  int _pullDelayMs = 50; // 首行延迟，按滚动距离/视口比在 50→4ms 间取值
  final Stopwatch _pullWatch = Stopwatch();
  final Map<int, double> _pullOffsets = {};

  /// 拽动位移修订号：行内 ListenableBuilder 监听，逐帧只重挂 Transform 不重建内容。
  final ValueNotifier<int> _pullRevision = ValueNotifier<int>(0);

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

  /// 逐字卡拉OK进度（秒），每帧更新；仅活动行染色订阅，避免整页每帧重建。
  final ValueNotifier<double> _progress = ValueNotifier<double>(0);

  /// 当前 build 渲染的活动行索引；_onTick 据此判断是否需要重建列表（换行才重建）。
  int _renderActiveIndex = -1;

  /// 一次性精确居中待办：进入歌词页 / 开始播放（含恢复播放）/ 换歌后置位，
  /// 等当前行完成实测布局后瞬时跳到视口正中（无动画，桌面版 AMLL 同款瞬移）。
  /// 未完成前不做按比例估算的粗略滚动，避免落位后二次动画。
  bool _pendingCenterJump = true;

  /// 上一次歌词视口高度：横竖屏/分屏切换检测用。
  double? _lastViewportHeight;

  // ==================== 模糊行静态烘焙缓存（稳态省逐帧高斯模糊） ====================
  // 稳态（换行/交互过渡结束）后，非活动行的"内容+模糊"几乎不变，却仍每帧
  // 重跑 ImageFiltered 高斯模糊。烘焙方案：稳态行把清晰内容捕获成位图，一次性
  // 施加 blur 后缓存，直接贴 RawImage；换行时只有距离变化的 2 行走实时滤镜。
  // 过渡期（450ms，覆盖 300ms sigma/alpha 与 320ms scale 动画）走实时滤镜，
  // 结束后烘焙落位，视觉无缝（同 sigma 逐像素等价）。

  /// 稳态起始时间戳（ms）。早于该时刻 = 过渡期，走实时滤镜。
  int _blurSteadyAtMs = 0;
  Timer? _blurSteadyTimer;

  /// 烘焙位图缓存（LRU）。key 见 _blurSnapshotKey。
  final Map<String, _BlurredLineSnapshot> _blurSnapshots = {};

  /// 上一次的活动行：自然换行时它从清晰退入模糊，是唯一保留 sigma 过渡
  /// 动画的行（观众可感知）；其余行 sigma 只 ±1~2，直接跳变/贴近档图。
  int _prevActiveIndex = -1;
  static const int _blurSnapshotCap = 20;

  /// 进行中的烘焙任务 key（防重复调度）。
  final Set<String> _blurCapturing = {};

  /// 捕获用 RepaintBoundary 的 GlobalKey（按行号复用，换歌清理）。
  final Map<int, GlobalKey> _blurBoundaryKeys = {};

  /// 是否处于稳态（可使用/可烘焙静态模糊位图）。
  bool get _blurSteady =>
      !_userInteracted &&
      DateTime.now().millisecondsSinceEpoch >= _blurSteadyAtMs;

  /// 进入过渡期：700ms 内走实时滤镜（覆盖 550ms 跟随滚动 + 300ms sigma/alpha
  /// + 320ms scale 动画，避免滚动中途翻稳态），随后定时器触发重建切到烘焙位图。
  void _enterBlurTransition() {
    _blurSteadyAtMs = DateTime.now().millisecondsSinceEpoch + 700;
    _blurSteadyTimer?.cancel();
    _blurSteadyTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() {});
    });
  }

  String _blurSnapshotKey(
      int index, double sigma, double mainFont, int widthBucket) {
    return '${widget.current?.path}|$index|s${sigma.toStringAsFixed(1)}'
        '|f${mainFont.toStringAsFixed(1)}|w$widthBucket'
        '|t${_showTranslation ? 1 : 0}|r${_showRomaji ? 1 : 0}';
  }

  /// 近档兜底：同行、内容字段（字号/宽度/翻译/罗马音）一致、sigma 差 ≤1.5 的
  /// 旧烘焙图。自然换行时每行 sigma 只 ±1~2，直接贴上一档位图在暗淡行
  /// （alpha 0.16~0.28）上无可感差异——省掉换行后整屏重烘焙的 GPU 回读
  /// 与实时滤镜窗口（这是 RwaS 用 GPU RenderEffect 免费得到、Flutter 需要
  /// 烘焙来逼近的流畅度关键）。
  _BlurredLineSnapshot? _findFallbackSnapshot(
      int index, double sigma, double mainFont, int widthBucket) {
    final pathPrefix = '${widget.current?.path}|$index|';
    final tail = '|f${mainFont.toStringAsFixed(1)}|w$widthBucket'
        '|t${_showTranslation ? 1 : 0}|r${_showRomaji ? 1 : 0}';
    _BlurredLineSnapshot? best;
    var bestDiff = 1.5;
    for (final entry in _blurSnapshots.entries) {
      final k = entry.key;
      if (!k.startsWith(pathPrefix) || !k.endsWith(tail)) continue;
      final parts = k.split('|');
      if (parts.length < 3) continue;
      final s = double.tryParse(parts[2].substring(1));
      if (s == null) continue;
      final diff = (s - sigma).abs();
      if (diff <= bestDiff) {
        bestDiff = diff;
        best = entry.value;
      }
    }
    return best;
  }

  /// 烘焙任务队列：稳态翻转时约 9 个可见行同时待烘焙，若同帧集中 toImage
  /// （GPU 回读）+ blur 烘焙会造成换行后明显卡一下——改为每帧最多烘焙一行，
  /// 逐帧摊平开销。
  final List<_BlurCaptureTask> _blurCaptureQueue = [];
  bool _blurCapturePumping = false;

  /// 入队一次烘焙任务（_blurCapturing 防重复），并驱动逐帧泵。
  void _scheduleBlurCapture(int index, String key, double sigma) {
    if (_blurCapturing.contains(key)) return;
    _blurCapturing.add(key);
    _blurCaptureQueue.add(
        _BlurCaptureTask(index: index, key: key, sigma: sigma));
    _pumpBlurCaptures();
  }

  /// 每帧处理一个烘焙任务；处理完若队列非空，下一帧继续。
  void _pumpBlurCaptures() {
    if (_blurCapturePumping || !mounted) return;
    if (_blurCaptureQueue.isEmpty) return;
    _blurCapturePumping = true;
    final task = _blurCaptureQueue.removeAt(0);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await _captureBlurLine(task);
      } finally {
        _blurCapturePumping = false;
        if (mounted && _blurCaptureQueue.isNotEmpty) {
          WidgetsBinding.instance
              .addPostFrameCallback((_) => _pumpBlurCaptures());
        }
      }
    });
  }

  /// 执行单个烘焙：捕获行内容位图 → 一次性施加 blur → 入缓存并触发重建。
  Future<void> _captureBlurLine(_BlurCaptureTask task) async {
    // 行可能在排队期间再次换行（sigma 已变）或用户开始翻看：丢弃过期任务。
    if (!mounted || !_blurSteady) return;
    final gk = _blurBoundaryKeys[task.index];
    final boundary =
        gk?.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null ||
        !boundary.attached ||
        !boundary.hasSize ||
        boundary.debugNeedsPaint) {
      return;
    }
    final dpr =
        MediaQuery.of(context).devicePixelRatio.clamp(1.0, 2.0).toDouble();
    final raw = await boundary.toImage(pixelRatio: dpr);
    final recorder = PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImage(
      raw,
      Offset.zero,
      Paint()
        ..imageFilter = ImageFilter.blur(sigmaX: task.sigma, sigmaY: task.sigma),
    );
    final picture = recorder.endRecording();
    final blurred = await picture.toImage(raw.width, raw.height);
    raw.dispose();
    picture.dispose();
    if (!mounted) {
      blurred.dispose();
      return;
    }
    // LRU 淘汰（Map 按插入序，重插实现"最近使用"）。
    while (_blurSnapshots.length >= _blurSnapshotCap) {
      _blurSnapshots.remove(_blurSnapshots.keys.first)?.dispose();
    }
    _blurSnapshots.remove(task.key)?.dispose();
    _blurSnapshots[task.key] = _BlurredLineSnapshot(
      image: blurred,
      width: boundary.size.width,
      height: boundary.size.height,
    );
    if (mounted) setState(() {});
  }

  void _clearBlurSnapshots() {
    _blurSteadyTimer?.cancel();
    _blurCaptureQueue.clear();
    _blurCapturePumping = false;
    for (final s in _blurSnapshots.values) {
      s.dispose();
    }
    _blurSnapshots.clear();
    _blurCapturing.clear();
    _blurBoundaryKeys.clear();
  }

  @override
  void initState() {
    super.initState();
    final p = ref.read(playerProvider).position;
    _anchorPos = p;
    _displayPos = p;
    _progress.value = p;
    _ticker = createTicker(_onTick);
    _syncTicker();
    _fetchLyrics();
  }

  @override
  void didUpdateWidget(_LyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.current?.path != widget.current?.path) {
      // 换歌：重置插值时钟并重新拉取歌词
      final p = ref.read(playerProvider).position;
      _anchorPos = p;
      _displayPos = p;
      _progress.value = p;
      _lastActiveIndex = -1;
      _renderActiveIndex = -1;
      _pendingCenterJump = true;
      _clearBlurSnapshots();
      _enterBlurTransition();
      _draggingIndexTimer?.cancel();
      _draggingIndex = null;
      _lineLayouts.clear();
      _syncTicker();
      _fetchLyrics();
    } else if (!oldWidget.visible && widget.visible) {
      // 歌词页重新可见：重新居中一次（页面常驻挂载时 visible 切换不走 initState）
      _pendingCenterJump = true;
      _enterBlurTransition();
    }
  }

  // ==================== RwaS 换行拽动（LyricPullEngine 移植） ====================

  /// RwaS 减速插值（LyricPullSpec.interpolate）：距离远小于归一化常量，
  /// factor≈1，退化为 1-(1-p)² 的二次减速。
  static double _pullEase(double p) {
    p = p.clamp(0.0, 1.0);
    return 1.0 - (1.0 - p) * (1.0 - p);
  }

  /// 前进换行时启动拽动：后续行先按住、再逐行弹回。
  void _beginPull(int anchor, double distancePx, double viewport) {
    if (distancePx <= 1 || viewport <= 0) {
      _cancelPull();
      return;
    }
    _pullActive = true;
    _pullAnchor = anchor;
    _pullDistance = distancePx;
    _pullOffsets.clear(); // 丢弃旧一轮拽动残留（含已回退到锚点上方的行）
    // LyricPullSpec.itemDelayMs：距离占视口比例越大 delay 越小（50→4ms）。
    final ratio = (distancePx.abs() / viewport).clamp(0.0, 1.0);
    _pullDelayMs = (50 + ratio * (4 - 50)).round();
    _pullWatch
      ..reset()
      ..start();
  }

  void _cancelPull() {
    if (!_pullActive && _pullOffsets.isEmpty) return;
    _pullActive = false;
    _pullOffsets.clear();
    _pullRevision.value++;
  }

  /// 每帧推进拽动位移（_onTick 驱动，仅播放中运行）。
  void _advancePull() {
    if (!_pullActive) return;
    const durationMs = 550;
    final t = _pullWatch.elapsedMilliseconds;
    final globalE = _pullEase(t / durationMs);
    final contribution = _pullDistance * globalE;
    var changed = _pullOffsets.isNotEmpty;
    var previous = 0.0; // 行序单调钳制：后行不能越过前行（RwaS 同款不变式）
    for (var i = _pullAnchor + 1; i <= _pullAnchor + 16; i++) {
      if (i >= _lines.length) break;
      final startMs = _pullDelayMs * (i - _pullAnchor);
      double offset;
      if (t < startMs) {
        offset = contribution; // 等待期：完全抵消列表滚动，视觉上按住不动
      } else {
        final itemE = _pullEase((t - startMs) / durationMs);
        offset = (contribution - _pullDistance * itemE).clamp(0.0, double.infinity);
      }
      // 单调钳制（取与前行 offset 的较大者）：后行不能越过前行
      final clamped = math.max(offset, previous);
      previous = clamped;
      if (_pullOffsets[i] != clamped) {
        _pullOffsets[i] = clamped;
        changed = true;
      }
    }
    // 结束条件：全局窗口 + 最大行延迟均已过
    if (t >= durationMs + _pullDelayMs * 16) {
      _pullActive = false;
      _pullOffsets.clear();
      changed = true;
    }
    if (changed) _pullRevision.value++;
  }

  /// 播放进度锚点更新（positionStream 约 200ms 一跳）。与外推值偏差过大视为
  /// 用户 Seek。由 build 内 provider 订阅触发，歌词据此推进会；页面其余部分
  /// 不受 position 每秒跳动影响（纯滑动不更新）。
  void _onPositionChanged(double next) {
    final isPlaying = ref.read(playerProvider).isPlaying;
    final jumped = (next - _displayPos).abs() > 1.2;
    _anchorPos = next;
    _anchorWatch.reset();
    if (jumped) {
      _recenterTimer?.cancel();
      _userInteracted = false;
      _displayPos = next;
      _progress.value = next;
      _autoScrollToActiveLine(force: true);
    } else if (!isPlaying) {
      // 暂停态直接定格在新锚点
      _displayPos = next;
      _progress.value = next;
    }
    _syncTicker();
    _autoScrollToActiveLine();
    // 活动行切换时重建列表（seek/暂停跳行也即时刷新高亮）。
    final idx = _activeIndexFor(_displayPos);
    if (idx != _renderActiveIndex) {
      _prevActiveIndex = _renderActiveIndex;
      _renderActiveIndex = idx;
      _enterBlurTransition();
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _progress.dispose();
    _pullRevision.dispose();
    _recenterTimer?.cancel();
    _draggingIndexTimer?.cancel();
    _clearBlurSnapshots();
    _scrollCtrl.dispose();
    super.dispose();
  }

  /// 每帧外推平滑进度并刷新逐字填充。
  void _onTick(Duration _) {
    _advancePull();
    final next = _anchorPos + _anchorWatch.elapsedMilliseconds / 1000.0;
    if ((next - _displayPos).abs() < 0.002) return;
    _displayPos = next;
    _progress.value = next;
    _autoScrollToActiveLine();
    // 仅活动行切换时重建列表（换行才 setState，逐字染色走 ValueListenableBuilder）。
    // 注意：自然换行【不】进入模糊过渡期（_enterBlurTransition）——那会让全部
    // 非活动行退回实时高斯 700ms，是换行掉帧的大头。稳态下各行换行后直接贴
    // 近档兜底图（见 _findFallbackSnapshot），只有旧活动行走一次清晰→模糊过渡。
    final idx = _activeIndexFor(_displayPos);
    if (idx != _renderActiveIndex) {
      _prevActiveIndex = _renderActiveIndex;
      _renderActiveIndex = idx;
      if (mounted) setState(() {});
    }
  }

  /// 根据播放/可见状态启停逐帧时钟。
  void _syncTicker() {
    final st = ref.read(playerProvider);
    final shouldRun = st.isPlaying && widget.visible;
    if (shouldRun && !_ticker.isActive) {
      _anchorPos = st.position;
      _displayPos = _anchorPos;
      _progress.value = _anchorPos;
      // （重新）开始播放：触发一次精确居中（恢复播放/进入歌词页共用此分支）
      _pendingCenterJump = true;
      _anchorWatch
        ..reset()
        ..start();
      _ticker.start();
    } else if (!shouldRun && _ticker.isActive) {
      _ticker.stop();
      _anchorWatch.stop();
      if (!st.isPlaying) {
        // 暂停：定格在锚点，取消进行中的拽动（RwaS isPlaying=false 同款）
        _displayPos = _anchorPos;
        _progress.value = _anchorPos;
        _cancelPull();
      }
    }
  }

  void _onUserScrollStart() {
    _recenterTimer?.cancel();
    _cancelPull();
    if (!_userInteracted) {
      setState(() {
        _userInteracted = true;
      });
    }
  }

  void _scheduleAutoRecenter() {
    _recenterTimer?.cancel();
    // 用户停止翻看 1.8 秒后自动重聚焦当前行（对齐 RwaS follow 恢复延时）。
    _recenterTimer = Timer(const Duration(milliseconds: 1800), () {
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
      // 模糊从 0 弹回目标值有 300ms 动画，过渡期内走实时滤镜
      _enterBlurTransition();
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

    // 命中缓存：直接复用已解析行，跳过网络请求与解析。
    final cached = _lyricsCache[item.path];
    if (cached != null && cached.isNotEmpty) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadedPath = item.path;
          _lines = cached;
        });
        _reportRomaji();
        _autoScrollToActiveLine();
      }
      return;
    }

    setState(() {
      _loading = true;
      _loadedPath = item.path;
    });

    try {
      String jsonStr = '';

      if (item.isOnline) {
        // (A) 插件来源：通过插件 getLyric 拉歌词（与下载流程同款，处理
        // MusicFree 插件的 lxlyric/lyric/翻译/罗马音）。插件歌曲的直链信息
        // 存在 onlineSongJson（含 pluginId/source/musicInfo），播放页此前只
        // 认 onlineInfoJson 才导致插件歌词拉不到。
        final pluginText = await _fetchPluginLyric(item);
        if (pluginText.trim().isNotEmpty) {
          jsonStr = await parseLyrics(rawLyrics: pluginText);
        } else if (item.source != null && item.onlineInfoJson != null) {
          // (B) 内置 lx 音源：通过 Rust 接口在线抓取指定音源的歌词
          // (kw/kg/tx/wy/mg)。
          final rawResultStr = await fetchLyricFromSource(
            source: item.source!,
            songInfoJson: item.onlineInfoJson!,
          );

          if (rawResultStr != 'null' && rawResultStr.isNotEmpty) {
            String lyricsToParse = '';

            // 提取 LyricResult JSON 对象中的真实歌词正文 (lxlyric > lyric)
            try {
              final lyricObj =
                  jsonDecode(rawResultStr) as Map<String, dynamic>;
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
        }
      } else {
        // 本地曲目：通过数据库及本地资源提取
        final dbPath = await ref.read(dbPathProvider.future);
        jsonStr = await getSongLyricsPayload(dbPath: dbPath, path: item.path);
      }

      if (jsonStr.isNotEmpty && jsonStr != 'null') {
        // 解析移出主线程：JSON 解析 + 边界修正走后台 isolate，避免大歌词
        // 阻塞 UI 线程造成卡顿。
        final parsed = await compute(_parseLyricsJson, jsonStr);
        final lines = await compute(_normalizeBoundaries, parsed);

        if (lines.isNotEmpty && mounted) {
          _cacheLyrics(item.path, lines);
          setState(() {
            _lines = lines;
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

  /// 从在线插件拉取当前播放曲目的歌词正文（LRC/逐字/翻译/罗马音）。
  ///
  /// 播放队列项 `onlineSongJson` 含 `pluginId/source/musicInfo`；非插件来源或
  /// 拉取失败返回空串，调用方据此回退到内置 lx 音源抓取。
  Future<String> _fetchPluginLyric(QueueItem item) async {
    final online = item.onlineSongJson;
    if (online == null || online.isEmpty) return '';
    Map<String, dynamic> parsed;
    try {
      parsed = jsonDecode(online) as Map<String, dynamic>;
    } catch (_) {
      return '';
    }
    final pluginId = parsed['pluginId'] as String?;
    if (pluginId == null || pluginId.isEmpty) return '';
    final sourceKey = parsed['source'] as String? ?? '';
    final musicInfo = parsed['musicInfo'] as Map<String, dynamic>? ?? {};
    try {
      final engine = await ref.read(pluginEngineProvider.future);
      final sources = await engine.store.loadSources();
      final matches = sources.where((s) => s.id == pluginId).toList();
      if (matches.isEmpty) return '';
      final lyric = await engine.getLyric(matches.first, sourceKey, musicInfo);
      if (lyric == null) return '';
      return (lyric['lxlyric'] ??
              lyric['yrc'] ??
              lyric['qrc'] ??
              lyric['eslrc'] ??
              lyric['lyric']) as String? ??
          '';
    } catch (_) {
      return '';
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

  /// 计算当前进度对应的活动行索引（build 与 ticker 共用）。
  int _activeIndexFor(double pos) {
    final curMs = ((pos - _offsetMs / 1000.0) * 1000).toInt();
    int activeIndex = -1;
    for (int i = 0; i < _lines.length; i++) {
      if (_lines[i].timeMs <= curMs) {
        activeIndex = i;
      } else {
        break;
      }
    }
    return activeIndex;
  }

  /// 一次性精确居中：等当前行实测布局后瞬时跳到视口正中（无动画）。
  /// 目标行尚未被测量时按比例粗跳一次拉进视口，随即清除待办交还常规跟随——
  /// 绝不长期锁住。对齐 RwaS LyricPlaybackState 数据驱动模型：活跃行始终由
  /// position 重算、任何锚点变化都驱动一次滚动，不被"上一次是否精确落位"门闩阻塞。
  void _tryPendingCenterJump() {
    if (_userInteracted) return; // 用户正在手动翻看，不打扰
    if (_lines.isEmpty || !_scrollCtrl.hasClients) return;
    final idx = _activeIndexFor(_displayPos);
    final viewport = _scrollCtrl.position.viewportDimension;
    if (viewport <= 0) return;
    final layout = _lineLayouts[idx];
    if (layout == null) {
      // 目标活动行尚未被 LazyList 构造测量——典型于歌曲已播到中段才打开/重开
      // 歌词页，当前行远在视口之外（比例粗跳的错位往往超过 200px 缓存区，该行
      // 仍不会进入 _lineLayouts）。必须在此清除 _pendingCenterJump：否则后续每次
      // _autoScrollToActiveLine 都被这扇门短路，歌词停在顶部、高亮行在屏外，
      // 且"下一句也不跳转"。向 RwaS 看齐：粗跳一次即交还常规跟随路径，
      // 活跃行每推进一格都由 _autoScrollToActiveLine 重新滚动逼近，不再卡死。
      if (idx >= 0 && _lines.length > 1) {
        final maxScroll = _scrollCtrl.position.maxScrollExtent;
        final target = (maxScroll * idx / (_lines.length - 1))
            .clamp(0.0, maxScroll);
        if ((target - _scrollCtrl.offset).abs() >= 1) {
          _scrollCtrl.jumpTo(target); // jumpTo 无动画，避免"先估再动画"两次移动
        }
      }
      _pendingCenterJump = false; // 一次性尽力而为，不长期阻塞跟随
      return;
    }
    _pendingCenterJump = false;
    _lastActiveIndex = idx;
    final target = (layout.$1 + layout.$2 / 2 - viewport / 2)
        .clamp(0.0, _scrollCtrl.position.maxScrollExtent);
    if ((target - _scrollCtrl.offset).abs() >= 1) {
      _scrollCtrl.jumpTo(target);
    }
  }

  void _autoScrollToActiveLine({bool force = false}) {
    if (_lines.isEmpty || !_scrollCtrl.hasClients) return;
    if (_userInteracted && !force) return; // 用户正在手动翻看歌词中，暂不打扰

    // 一次性精确居中优先（seek 的 force 路径直接走动画滚动）
    if (_pendingCenterJump && !force) {
      _tryPendingCenterJump();
      return;
    }

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
    final prevIndex = _lastActiveIndex;
    _lastActiveIndex = activeIndex;

    final maxScroll = _scrollCtrl.position.maxScrollExtent;
    final viewport = _scrollCtrl.position.viewportDimension;

    // 精确居中（弦予样式）：用该行实测布局（内容坐标顶 + 高/2）对齐视口中心；
    // 行尚未构建测量时（如长距离 seek）退回按比例估算。
    double targetOffset;
    final layout = _lineLayouts[activeIndex];
    if (layout != null && viewport > 0) {
      targetOffset = layout.$1 + layout.$2 / 2 - viewport / 2;
    } else {
      targetOffset = maxScroll *
          (activeIndex / (_lines.length > 1 ? (_lines.length - 1) : 1));
    }
    targetOffset = targetOffset.clamp(0.0, maxScroll);

    // RwaS 换行拽动：仅前进自然换行（播放中、非 seek、非用户翻看）触发。
    final isPlaying = ref.read(playerProvider).isPlaying;
    if (force || !isPlaying || _userInteracted || activeIndex <= prevIndex) {
      _cancelPull();
    } else if (layout != null) {
      _beginPull(activeIndex, targetOffset - _scrollCtrl.offset, viewport);
    }

    final current = _scrollCtrl.offset;
    if (!force && (targetOffset - current).abs() < 1) return;

    // RwaS 跟随节奏（LyricPullSpec/LyricFollowEasing）：固定 550ms。
    // 拽动激活时列表滚动与 pull 全局插值同用二次减速曲线（保证被"按住"的行
    // 纹丝不动），否则用 LyricFollowEasing CubicBezier(0.40, 0.10, 0, 1)。
    _scrollCtrl.animateTo(
      targetOffset,
      duration: const Duration(milliseconds: 550),
      curve: _pullActive
          ? Curves.easeOutQuad
          : const Cubic(0.40, 0.10, 0.00, 1.00),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 局部订阅播放进度/播放态驱动歌词推进；页面其余部分（封面/背景/控制）
    // 不随 position 每秒跳动重建（纯滑动不更新）。
    ref.listen(
      playerProvider.select((s) => s.position),
      (_, next) => _onPositionChanged(next),
    );
    ref.listen(
      playerProvider.select((s) => s.isPlaying),
      (prev, next) => _syncTicker(),
    );
    // 歌词样式设置（移植自 MF LyricOperations）：字号档位 / 翻译开关 / 时间偏移。
    // 存到字段供 _onTick → _autoScrollToActiveLine 等非 build 路径使用。
    final settings = ref.watch(settingsProvider).valueOrNull;
    _fontSizeIdx = settings?.lyricFontSize ?? 1;
    _showTranslation = settings?.showLyricsTranslation ?? true;
    _showRomaji = settings?.showLyricsRomaji ?? false;
    _offsetMs = settings?.lyricOffsetMs ?? 0;
    final lyricFontFamily = (settings?.lyricFontName ?? '').isNotEmpty
        ? settings!.lyricFontName
        : null;

    // 横屏（宽≥高×1.05，与壳层判定一致）：歌词字号整体放大。
    final mqSize = MediaQuery.of(context).size;
    final isLandscape = mqSize.width >= mqSize.height * 1.05;
    _fontScale = isLandscape ? 1.18 : 1.0;

    // RwaS 等字号样式：活动行不变号，靠缩放（1.0↔0.92）与亮度区分。
    // 字号继承 RwaS 量级：主行档位 24/28/32/36（RwaS 默认 28sp，范围 24..40），
    // 副行 = 主行 62%（RwaS secondarySize 比例，钳制 15..25）。
    final mainFont = [24.0, 28.0, 32.0, 36.0][_fontSizeIdx] * _fontScale;
    final transFont = (mainFont * 0.62).clamp(15.0, 25.0);
    final romajiFont = transFont;

    // 活动行索引：build 与 ticker 共用同一计算，ticker 据此判断换行才重建。
    final activeIndex = _activeIndexFor(_displayPos);
    _renderActiveIndex = activeIndex;

    Widget content;
    if (_loading) {
      content = const Center(
        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70),
      );
    } else if (_lines.isEmpty) {
      // 歌词页恒定白字（不受主题色控制），与模糊封面暗底适配。
      content = Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.lyrics_outlined,
              size: 40,
              color: Colors.white.withValues(alpha: 0.35),
            ),
            const SizedBox(height: 10),
            Text(
              tr('暂无歌词'),
              style: TextStyle(
                fontSize: 15,
                color: Colors.white.withValues(alpha: 0.5),
              ),
            ),
          ],
        ),
      );
    } else {
      // 头尾空白区 = 半视口 − 半行高：首句/末句也能精确落在视口中心，
      // 不被滚动边界 clamp 顶到上/下缘。行高按当前字号档位估算。
      final typicalH = mainFont * 1.35 +
          (_showRomaji ? romajiFont * 1.2 + 5 : 0) +
          (_showTranslation ? transFont * 1.35 + 6 : 0);
      content = LayoutBuilder(
        builder: (context, constraints) {
          final viewport = constraints.maxHeight;
          // 横竖屏/分屏切换：视口高度变化后滚动偏移不再居中、行高随宽度
          // 换行变化，重新执行一次性精确居中（等新尺寸下实测布局后瞬时跳回）。
          // 行布局缓存按内容坐标记录，但行高会因宽度变化而变，一并清掉重测。
          if (_lastViewportHeight != null &&
              (_lastViewportHeight! - viewport).abs() > 1) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              _lineLayouts.clear();
              _pendingCenterJump = true;
              _tryPendingCenterJump();
            });
          }
          _lastViewportHeight = viewport;
          final blank = viewport / 2 - typicalH / 2;
          final topPad = blank < 20 ? 20.0 : blank;
          final bottomPad = blank < 40 ? 40.0 : blank;
          return NotificationListener<ScrollNotification>(
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
          // 头尾空白区：正在唱的行始终可以居中（见上方 typicalH 注释）。
          // 水平内边距对齐 RwaS lineHorizontalPadding 28dp。
          padding: EdgeInsets.fromLTRB(28, topPad, 28, bottomPad),
          // 缓存视口外约 200px 的行：滚动时只搬运已构建/已测量（onMeasured 回调
          // 已填充布局缓存）的行，拖动选行定位不依赖现建现量。
          scrollCacheExtent: ScrollCacheExtent.pixels(200),
          addAutomaticKeepAlives: false,
          // 每行独立 RepaintBoundary：换行 setState 重建列表时，只有活动行
          // 变化的两行重绘，其余行复用已缓存图层，避免整屏逐帧重绘抽帧。
          addRepaintBoundaries: true,
          itemCount: _lines.length,
          itemBuilder: (context, idx) {
            final line = _lines[idx];
            final isActive = idx == activeIndex;
            final isDragging = idx == _draggingIndex;
            // RwaS 距离衰减（lyricLineVisuals）：近邻 0.42 / 次邻 0.28 / 其余 0.16。
            final dist = (idx - activeIndex).abs();
            final inactiveAlpha = dist == 1
                ? 0.42
                : dist == 2
                    ? 0.28
                    : 0.16;
            // 桌面版 AMLL 模糊规则（PatchedLyricPlayer blurLevel）：除活动行外
            // 全部模糊且常驻不落（一次只显示一行清晰）——下方（未唱）行
            // sigma = 1+dist，上方（已唱）行再 +1（糊得更狠），钳 8；
            // 仅用户手动翻看时归 0（RwaS userScrolling 同款，省光栅化）。
            final passed = idx < activeIndex;
            final blurSigma = (!_userInteracted && !isActive)
                ? math.min(1.0 + dist + (passed ? 1.0 : 0.0), 8.0)
                : 0.0;

            Widget lineChild = Column(
              children: [
                // 罗马音在主行上方（RwaS ComposeLyricLine 排布）
                if (_showRomaji &&
                    line.romaji != null &&
                    line.romaji!.isNotEmpty) ...[
                  Text(
                    line.romaji!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: romajiFont,
                      fontWeight: FontWeight.w500,
                      color: Colors.white.withValues(alpha: 0.34),
                      height: 1.2,
                      fontFamily: lyricFontFamily,
                    ),
                  ),
                  const SizedBox(height: 5),
                ],
                // 逐字歌词渲染 (若包含 words 且当前处于活跃高亮行，走卡拉OK渲染)
                if (isActive && line.words.isNotEmpty)
                  // 活动行卡拉OK独立成图层 + ValueListenableBuilder 局部刷新：
                  // 逐字漫过只重建这一行的染色，不再整页每帧 setState。
                  RepaintBoundary(
                    child: ValueListenableBuilder<double>(
                      valueListenable: _progress,
                      builder: (context, pos, _) {
                        return Wrap(
                          alignment: WrapAlignment.center,
                          children: [
                            for (final w in line.words)
                              _buildKaraokeWordWidget(
                                w,
                                pos - _offsetMs / 1000.0,
                                mainFont,
                                lyricFontFamily,
                              ),
                          ],
                        );
                      },
                    ),
                  )
                else
                  AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeOutCubic,
                    style: TextStyle(
                      // RwaS 等字号：主行恒定字号 w700；全白配色，
                      // 亮度随距离衰减（拖动选中行提亮为纯白）。
                      fontSize: mainFont,
                      fontWeight: FontWeight.w700,
                      color: isDragging
                          ? Colors.white
                          : Colors.white
                              .withValues(alpha: isActive ? 1.0 : inactiveAlpha),
                      height: 1.35,
                      fontFamily: lyricFontFamily,
                    ),
                    child: Text(line.text, textAlign: TextAlign.center),
                  ),
                if (_showTranslation &&
                    line.translation != null &&
                    line.translation!.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    line.translation!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: transFont,
                      fontWeight: FontWeight.w500,
                      color: isDragging
                          ? Colors.white.withValues(alpha: 0.8)
                          : Colors.white
                              .withValues(alpha: isActive ? 0.58 : 0.34),
                      height: 1.35,
                      fontFamily: lyricFontFamily,
                    ),
                  ),
                ],
              ],
            );

            // RwaS 行缩放（lyricLineVisuals spring 0.82/340 近似）：
            // 活动行 1.0，其余 0.92；绘制层变换不影响布局测量。
            lineChild = AnimatedScale(
              scale: isActive ? 1.0 : 0.92,
              duration: const Duration(milliseconds: 320),
              curve: Curves.easeOutCubic,
              child: lineChild,
            );

            // 景深模糊层（桌面版 AMLL：除活动行外全部模糊、一次只显示一行清晰）。
            // 稳态行贴烘焙位图（_blurSnapshots，逐帧高斯模糊归零）；过渡期/
            // 烘焙未就绪行走实时 ImageFiltered（sigma 连续动画，绝不卸载重挂）。
            // 位移层放在模糊层之外：平移与高斯模糊可交换，烘焙内容不含位移。
            if (dist >= 1) {
              final steady = _blurSteady;
              final widthBucket = constraints.maxWidth.isFinite
                  ? constraints.maxWidth.round()
                  : 0;
              final snapKey =
                  _blurSnapshotKey(idx, blurSigma, mainFont, widthBucket);
              // 稳态命中优先精确档；未命中贴近档兜底图（sigma 差 ≤1.5 无感），
              // 都没有才走实时滤镜。
              final snap = steady
                  ? (_blurSnapshots[snapKey] ??
                      _findFallbackSnapshot(
                          idx, blurSigma, mainFont, widthBucket))
                  : null;
              if (snap != null) {
                // 命中：直接贴烘焙位图（布局尺寸与原内容一致）
                lineChild = RawImage(
                  image: snap.image,
                  width: snap.width,
                  height: snap.height,
                  fit: BoxFit.fill,
                );
              } else {
                if (steady) {
                  // 稳态未命中：边界捕获清晰内容（置于滤镜内侧），
                  // post-frame 烘焙一次性施加 blur 后入缓存
                  lineChild = RepaintBoundary(
                    key: _blurBoundaryKeys.putIfAbsent(idx, GlobalKey.new),
                    child: lineChild,
                  );
                  _scheduleBlurCapture(idx, snapKey, blurSigma);
                }
                // 只有刚从清晰退入模糊的旧活动行保留 300ms sigma 过渡
                //（观众可感知的动效）；其余行 sigma 跳变直出，不再逐帧实时
                // 高斯整屏铺开。
                if (idx == _prevActiveIndex) {
                  lineChild = TweenAnimationBuilder<double>(
                    tween: Tween(end: blurSigma.toDouble()),
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeOutCubic,
                    builder: (context, sigma, child) => sigma <= 0.1
                        ? child!
                        : ImageFiltered(
                            imageFilter: ImageFilter.blur(
                                sigmaX: sigma, sigmaY: sigma),
                            child: child,
                          ),
                    child: lineChild,
                  );
                } else {
                  lineChild = blurSigma <= 0.1
                      ? lineChild
                      : ImageFiltered(
                          imageFilter: ImageFilter.blur(
                              sigmaX: blurSigma, sigmaY: blurSigma),
                          child: lineChild,
                        );
                }
              }
            }

            // RwaS 纵向位移（lyricLineVisuals graphicsLayer）：
            // 静态项 = 各行向锚点轻微压缩（±2dp×距离，钳 ±4）；
            // 拽动项 = 前进换行时后续行先按住再逐行弹回（_pullOffsets 逐帧更新）。
            // ListenableBuilder 只重挂 Transform，不重建行内容。
            lineChild = ListenableBuilder(
              listenable: _pullRevision,
              child: lineChild,
              builder: (context, child) {
                final signed = (idx - activeIndex).clamp(-4, 4);
                final dy = signed * -2.0 + (_pullOffsets[idx] ?? 0.0);
                if (dy == 0) return child!;
                return Transform.translate(offset: Offset(0, dy), child: child);
              },
            );

            return _MeasuredLine(
              index: idx,
              onMeasured: _onLineMeasured,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: lineChild,
              ),
            );
          },
        ),
      );
        },
      );
      // 暂停态进入歌词页：逐帧时钟未运行，靠 post-frame 兜底完成一次性精确居中
      if (_pendingCenterJump) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _tryPendingCenterJump();
        });
      }
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
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      _draggingTimeLabel(),
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.white.withValues(alpha: 0.87),
                        fontFeatures: const [FontFeature.tabularFigures()],
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
    showSheetDialog<void>(context, (sheetCtx) {
      final notifier = ref.read(settingsProvider.notifier);
      var current = ref.read(settingsProvider).valueOrNull?.lyricFontSize ?? 1;
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
              Text(
              tr('歌词字号'),
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
              StatefulBuilder(
                builder: (ctx, setSheetState) {
                  return Row(
                    children: [
                      ...List.generate(4, (i) {
                        final labels = [tr('小'), tr('标准'), tr('大'), tr('特大')];
                        return Expanded(
                          child: InkWell(
                            onTap: () {
                              setSheetState(() => current = i);
                              notifier.setLyricFontSize(i);
                            },
                            child: Container(
                              alignment: Alignment.center,
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              margin: const EdgeInsets.only(right: 8),
                              decoration: BoxDecoration(
                                color: current == i
                                    ? const Color(
                                        0xFFEC4141,
                                      ).withValues(alpha: 0.14)
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
                                      : Theme.of(
                                          ctx,
                                        ).colorScheme.onSurfaceVariant,
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
                  Icon(
                    Icons.font_download_outlined,
                    size: 18,
                    color: Theme.of(context).colorScheme.outline,
                  ),
                  const SizedBox(width: 8),
                    Text(
                    tr('自定义歌词字体'),
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  _FontImportAction(sheetCtx: sheetCtx),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                tr('支持 .ttf / .otf 字体文件，导入后立即应用到歌词'),
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.outline,
                ),
              ),
            ],
          ),
        );
    });
  }

  /// 歌词偏移校正面板：粗调滑杆(-500~+500, 10ms) + 细调按钮(1/5/10/100ms)，
  /// 拖蓝/暂停时点按微调可精确定位，满足“偏移步进细化”。
  static void _showOffsetSheet(BuildContext context, WidgetRef ref) {
    showSheetDialog<void>(context, (sheetCtx) {
      final notifier = ref.read(settingsProvider.notifier);
      var value = ref.read(settingsProvider).valueOrNull?.lyricOffsetMs ?? 0;
      void apply(int v, StateSetter setSheetState) {
        setSheetState(() => value = v);
        notifier.setLyricOffsetMs(v);
      }
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                  Text(
                  tr('歌词偏移'),
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
                  TextButton(
                    onPressed: () {
                      notifier.setLyricOffsetMs(0);
                      Navigator.of(sheetCtx).pop();
                    },
                    child:   Text(tr('重置')),
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
                            ? tr('提前 {v}ms', {'v': value})
                            : value < 0
                            ? tr('延后 {v}ms', {'v': -value})
                            : tr('无偏移'),
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
                          _offsetStepChip(
                            ctx,
                            '-100',
                            scheme,
                            () => apply(
                              (value - 100).clamp(-500, 500),
                              setSheetState,
                            ),
                          ),
                          _offsetStepChip(
                            ctx,
                            '-10',
                            scheme,
                            () => apply(
                              (value - 10).clamp(-500, 500),
                              setSheetState,
                            ),
                          ),
                          _offsetStepChip(
                            ctx,
                            '-1',
                            scheme,
                            () => apply(
                              (value - 1).clamp(-500, 500),
                              setSheetState,
                            ),
                          ),
                          _offsetStepChip(
                            ctx,
                            '+1',
                            scheme,
                            () => apply(
                              (value + 1).clamp(-500, 500),
                              setSheetState,
                            ),
                          ),
                          _offsetStepChip(
                            ctx,
                            '+10',
                            scheme,
                            () => apply(
                              (value + 10).clamp(-500, 500),
                              setSheetState,
                            ),
                          ),
                          _offsetStepChip(
                            ctx,
                            '+100',
                            scheme,
                            () => apply(
                              (value + 100).clamp(-500, 500),
                              setSheetState,
                            ),
                          ),
                        ],
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        );
    });
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
    double fontSize,
    String? fontFamily,
  ) {
    final duration = math.max(0.001, word.end - word.start);
    final progress = ((position - word.start) / duration).clamp(0.0, 1.0);

    // RwaS 卡拉OK配色：高亮白 / 未唱白 28%（dimColor），无品牌红。
    const highlightColor = Colors.white;
    final dimColor = Colors.white.withValues(alpha: 0.28);

    final style = TextStyle(
      fontSize: fontSize,
      fontWeight: FontWeight.w700,
      height: 1.35,
      fontFamily: fontFamily,
    );

    if (progress <= 0) {
      return Text(word.text, style: style.copyWith(color: dimColor));
    }

    if (progress >= 1.0) {
      // 已唱完的词带白色辉光（RwaS glowEnabled 的简化对应：已完成词加白晕）。
      return Text(
        word.text,
        style: style.copyWith(
          color: highlightColor,
          shadows: [
            Shadow(
              color: Colors.white.withValues(alpha: 0.35),
              blurRadius: 10,
            ),
          ],
        ),
      );
    }

    // 正在唱当前词：渐变染色漫过 (ShaderMask) + 轻微跳动。
    // 跳动 = 进度驱动的正弦包络：起唱快速上浮并微放大，唱到中段最高，
    // 收尾落回（RwaS KaraokeLyricLine wordLift / AMLL word pop 的简化对应）。
    // 填充前沿之后带 10% 宽度的羽化软边，对应桌面端 AMLL 的 wordFadeWidth 扫字效果。
    final featherEnd = (progress + 0.1).clamp(0.0, 1.0);
    final pop = math.sin(progress * math.pi);
    return Transform.translate(
      offset: Offset(0, -2.5 * pop),
      child: Transform.scale(
        scale: 1.0 + 0.05 * pop,
        child: ShaderMask(
          shaderCallback: (bounds) {
            return LinearGradient(
              colors: [highlightColor, dimColor],
              stops: [progress, featherEnd],
            ).createShader(bounds);
          },
          child: Text(word.text, style: style.copyWith(color: Colors.white)),
        ),
      ),
    );
  }
}

/// 模糊行稳态烘焙位图：清晰内容捕获后一次性施加 blur 的结果。
/// width/height 为逻辑像素（与行内容布局尺寸一致，贴图时保证布局不变）。
class _BlurredLineSnapshot {
  _BlurredLineSnapshot({
    required this.image,
    required this.width,
    required this.height,
  });

  final ui.Image image;
  final double width;
  final double height;

  void dispose() => image.dispose();
}

/// 单个烘焙任务（逐帧队列消费）：目标行、缓存 key、烘焙用的 sigma。
class _BlurCaptureTask {
  _BlurCaptureTask({
    required this.index,
    required this.key,
    required this.sigma,
  });

  final int index;
  final String key;
  final double sigma;
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
class _LyricSettingsRail extends ConsumerStatefulWidget {
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
  ConsumerState<_LyricSettingsRail> createState() => _LyricSettingsRailState();
}

class _LyricSettingsRailState extends ConsumerState<_LyricSettingsRail> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final panelWidth = _expanded ? 46.0 : 40.0;
    // 全局 blur 预算：转场/滚动期间歌词悬浮面板玻璃降级（overlay 档）。
    final budget = ref.watch(blurBudgetProvider(BlurSurfaceType.overlay));
    final sigma = surfaceBlurSigma(
      base: 14,
      budget: budget,
      type: BlurSurfaceType.overlay,
    );
    final panelBg = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.white.withValues(alpha: 0.75);

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
          width: panelWidth,
          decoration: BoxDecoration(
            color: surfaceFillWithBudget(panelBg, budget),
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
                            active:
                                widget.showTranslation && widget.hasTranslation,
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
    final fontName = ref.watch(
      settingsProvider.select((s) => s.valueOrNull?.lyricFontName ?? ''),
    );
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
              showXianYuToast(context, tr('已应用自定义歌词字体'));
            }
          } catch (e) {
            if (context.mounted) {
              showXianYuToast(context, tr('字体导入失败：{e}', {'e': e}));
            }
          }
        },
        icon: const Icon(Icons.file_open_outlined, size: 18),
        label:   Text(tr('选择字体')),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          tr('已应用'),
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
          label:   Text(tr('恢复默认')),
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

    // 队列由非空变空（清空按钮/删掉最后一首）：先关本弹窗，再连带退出其下
    // 的播放详情页。播放页自身的退出监听在本弹窗打开时不触发（非栈顶），
    // 由这里统一负责两层的关闭，避免竞态。
    ref.listen(playerProvider.select((s) => s.queue.isEmpty), (prev, empty) {
      if (prev == false && empty == true && mounted) {
        final nav = Navigator.of(context);
        if (nav.canPop()) nav.pop();
        if (nav.canPop()) nav.pop();
      }
    });

    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 顶部标题栏
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 12, 4),
          child: Row(
            children: [
              Text(
                tr('播放队列'),
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                tr('{n} 首', {'n': queue.length}),
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
              const Spacer(),
              // 清空播放队列（对齐桌面端 PlayQueueSidebar）：停止播放并清掉
              // 全部队列（含无法加载的坏歌）。关闭弹窗与退出播放详情页由
              // 上方「队列变空」监听统一处理。
              IconButton(
                icon: Icon(
                  Icons.delete_outline,
                  size: 20,
                  color: scheme.onSurfaceVariant,
                ),
                tooltip: tr('清空播放队列'),
                onPressed: queue.isEmpty
                    ? null
                    : () async {
                        try {
                          await ref
                              .read(playerProvider.notifier)
                              .clearQueue();
                        } catch (_) {}
                      },
              ),
            ],
          ),
        ),
        if (queue.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 40),
            child: Text(
              tr('队列为空'),
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          )
        else
          Flexible(
            child: ReorderableListView.builder(
              shrinkWrap: true,
              buildDefaultDragHandles: false,
              itemCount: queue.length,
              // 拖动 proxy 处于根 Overlay 下（无 Material 祖先），行内 ListTile 会以
              // debugCheckHasMaterial 报错；补一层透明 Material 提供水波纹上下文。
              proxyDecorator: (child, index, animation) =>
                  Material(type: MaterialType.transparency, child: child),
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
                        ? Icon(
                            Icons.graphic_eq,
                            size: 18,
                            color: const Color(0xFFEC4141),
                          )
                        : Icon(
                            Icons.music_note,
                            size: 18,
                            color: scheme.outline,
                          ),
                    title: Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        color: isCurrent
                            ? const Color(0xFFEC4141)
                            : scheme.onSurface,
                        fontWeight: isCurrent
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                    ),
                    subtitle: Text(
                      item.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: Icon(
                            Icons.drag_handle,
                            size: 18,
                            color: scheme.outline,
                          ),
                          onPressed: null,
                        ),
                        IconButton(
                          icon: Icon(
                            Icons.close,
                            size: 18,
                            color: scheme.outline,
                          ),
                          onPressed: () => ref
                              .read(playerProvider.notifier)
                              .removeFromQueue(index),
                        ),
                      ],
                    ),
                    onTap: () {
                      Navigator.of(context).pop();
                      ref.read(playerProvider.notifier).playQueueItem(index);
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
        child: content,
      ),
    );
  }
}
