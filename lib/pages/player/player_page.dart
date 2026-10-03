import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../effects/effects_page.dart';
import '../../src/navigation/routes.dart'
    show playerNavigatorKey, coverPageRoute;
import 'comment_sheet.dart';
import '../../src/core/application_logger.dart';
import '../../src/core/db_path.dart';
import '../../src/core/settings.dart';
import '../../src/theme/theme_icon.dart';
import '../../src/player/mv_source.dart';
import '../../src/player/mv_provider.dart';
import 'package:video_player/video_player.dart';
import '../../src/download/download_provider.dart';
import '../../src/effects/sound_effect_provider.dart';
import '../../src/auth/auth_provider.dart';
import '../../src/favorites/favorites_provider.dart';
import '../../src/lyrics/floating_lyrics.dart';
import '../../src/library/library_provider.dart';
import '../../src/lyrics/lyric_font.dart';
import '../../src/lyrics/lyric_model.dart';
import '../../src/lyrics/lyrics_repository.dart';
import '../../src/player/online_quality_probe.dart';
import '../../src/player/player_provider.dart';
import '../../src/rust/api.dart';
import '../../src/responsive/landscape.dart';
import '../../src/navigation/shell.dart' show isLandscapeProvider;
import '../../src/share/share_service.dart';
import '../../src/share/share_sheet.dart';
import '../../src/widgets/app_toast.dart';
import '../../src/widgets/add_to_playlist_sheet.dart';
import '../../src/widgets/bilipai_glass.dart';
import '../../src/widgets/blur_budget.dart';
import '../../src/widgets/committed_slider.dart';
import '../../src/widgets/cover_hero.dart';
import '../../src/widgets/flying_cover.dart';
import '../../src/widgets/auto_hide_chrome.dart';
import '../../src/widgets/cover_image.dart';
import '../../src/widgets/custom_background.dart' show CustomBackgroundLayer;
import '../../src/theme/page_wallpaper.dart' show themedPageWallpaperProvider;
import '../../src/widgets/glass_settings.dart';
import '../../src/widgets/modern_dialog.dart';
import '../../src/widgets/predictive_cover_return.dart';
import '../../src/widgets/predictive_dialog_route.dart';
import '../../src/widgets/sheet_dialog.dart';
import '../../src/widgets/source_tag.dart';
import '../../src/i18n/i18n.dart';
import 'dart:async';

part 'player_page.lyrics.adjust.dart';
part 'player_page.lyrics.view.dart';
part 'player_page.lyrics.rail.dart';
part 'player_page.sheets.dart';
part 'player_page.controls.dart';
part 'player_page.controls.cover.dart';
part 'player_page.controls.landscape.dart';

final Map<String, List<_LyricLineItem>> _lyricsCache = {};
const int _lyricsCacheMax = 24;

const Duration _mvSwitchDuration = Duration(milliseconds: 260);
const Curve _mvSwitchCurve = Curves.easeOutCubic;

void _cacheLyrics(String path, List<_LyricLineItem> lines) {
  if (path.isEmpty || lines.isEmpty) return;
  _lyricsCache[path] = lines;
  if (_lyricsCache.length > _lyricsCacheMax) {
    _lyricsCache.remove(_lyricsCache.keys.first);
  }
}

List<_LyricLineItem> _lyricLinesToViewItems(List<LyricLine> lines) {
  return [
    for (final l in lines)
      _LyricLineItem(
        timeMs: l.timeMs,
        endTimeMs: l.endTimeMs,
        text: l.text,
        translation: l.translation,
        romaji: l.romaji,
        words: [
          for (final w in l.words)
            _LyricWordItem(text: w.text, start: w.start, end: w.end),
        ],
      ),
  ];
}

bool _hasPlayerEffects(SoundEffectSettings sfx) {
  return sfx.bassBoostEnabled ||
      sfx.trebleEnabled ||
      sfx.distortionEnabled ||
      sfx.delayEnabled ||
      sfx.flangerEnabled ||
      sfx.phaserEnabled ||
      sfx.compressorEnabled ||
      sfx.noiseGateEnabled ||
      sfx.limiterEnabled ||
      sfx.exciterEnabled ||
      sfx.subBassEnabled ||
      sfx.loFiEnabled ||
      sfx.stereoWidenEnabled ||
      sfx.vibratoEnabled ||
      sfx.tremoloEnabled ||
      sfx.vocalRemoval ||
      sfx.reverbKind != 'none' ||
      sfx.spatialMode != 'none' ||
      sfx.audioBoost != 0 ||
      sfx.eqGains.any((g) => g != 0);
}

class PlayerPage extends ConsumerStatefulWidget {
  const PlayerPage({super.key});

  @override
  ConsumerState<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends ConsumerState<PlayerPage> {
  bool _showLyrics = false;

  bool _hideMvVideo = false;

  final GlobalKey _lyricsKey = GlobalKey();

  bool _lyricsViewHasRomaji = false;

  String? _sharePreloadPath;

  bool _chromeVisible = true;
  Timer? _chromeHideTimer;

  /// 本次按下的瞬间 chrome 是否可见：区分"点击唤起"与"点击收起"——
  /// down 阶段 _wakeChrome 先把 chrome 唤起，若收起判断只看当前状态，
  /// 同一次点击的 up 阶段会立刻把它再藏回去（唤起失效）
  bool _chromeVisibleAtPointerDown = true;

  void _wakeChrome() {
    _chromeHideTimer?.cancel();
    _chromeHideTimer = null;
    final needRestore = !_chromeVisible;
    if (ref.read(isLandscapeProvider)) _armChromeHide();
    if (needRestore && mounted) setState(() => _chromeVisible = true);
  }

  void _armChromeHide() {
    _chromeHideTimer?.cancel();
    _chromeHideTimer = Timer(const Duration(milliseconds: 3500), () {
      _chromeHideTimer = null;
      if (!mounted || !ref.read(isLandscapeProvider)) return;
      if (_chromeVisible) setState(() => _chromeVisible = false);
    });
  }

  /// 横屏点击收起顶栏/底栏：点击内容区空白处（非 chrome 控件）立即收起。
  /// 呼出由外层 Listener onPointerDown 兜底；按下瞬间已隐藏的点击
  /// 属于"唤起"，不能再走收起分支
  void _onContentAreaTap() {
    final s = ref.read(settingsProvider).valueOrNull;
    if (!(s?.landscapeTapToHideChrome ?? true)) return;
    if (!ref.read(isLandscapeProvider)) return;
    if (!_chromeVisibleAtPointerDown) return;
    _chromeHideTimer?.cancel();
    _chromeHideTimer = null;
    setState(() => _chromeVisible = false);
  }

  @override
  Widget build(BuildContext context) {
    final current = ref.watch(playerProvider.select((s) => s.current));
    final notifier = ref.read(playerProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    final mv = ref.watch(mvProvider);

    ref.listen(playerProvider.select((s) => s.current), (prev, next) {
      if (prev != null && next == null && mounted) {
        if (ModalRoute.of(context)?.isCurrent == true) {
          final nav = Navigator.of(context);
          if (nav.canPop()) nav.pop();
        }
      }
    });

    if (current != null && _sharePreloadPath != current.path) {
      _sharePreloadPath = current.path;
      final toPreload = current;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(shareServiceProvider).preload(toPreload);
      });
    }

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
    final playerStyle = settings?.playerStyle ?? PlayerStyle.traditional;

    final hideMvVideo = _hideMvVideo && playerStyle == PlayerStyle.traditional;

    final autoHideChrome = settings?.landscapeAutoHideChrome ?? true;
    final landscapeNow = ref.watch(isLandscapeProvider);
    if (!landscapeNow || !autoHideChrome) {
      _chromeHideTimer?.cancel();
      _chromeHideTimer = null;
      if (!_chromeVisible) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_chromeVisible) setState(() => _chromeVisible = true);
        });
      }
    } else if (_chromeVisible && _chromeHideTimer == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _armChromeHide();
      });
    }

    return Theme(
      data: Theme.of(context).copyWith(
        brightness: Brightness.dark,
        colorScheme: bgScheme,
        iconTheme: Theme.of(context).iconTheme.copyWith(color: Colors.white),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: ColoredBox(
              color: Color.lerp(scheme.surface, Colors.black, 0.6)!,
            ),
          ),
          Positioned.fill(child: _BlurredCoverBackground(current: current)),
          if (mv.ready && mv.controller != null)
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedSlide(
                  offset: hideMvVideo ? const Offset(-0.08, 0) : Offset.zero,
                  duration: _mvSwitchDuration,
                  curve: _mvSwitchCurve,
                  child: AnimatedOpacity(
                    opacity: hideMvVideo ? 0 : 1,
                    duration: _mvSwitchDuration,
                    curve: _mvSwitchCurve,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        LayoutBuilder(
                          builder: (context, cons) {
                            final ar = mv.controller!.value.aspectRatio;
                            final w = cons.maxWidth;
                            final h = cons.maxHeight;
                            final vw = w >= h * ar ? h * ar : w;
                            final vh = w >= h * ar ? h : w / ar;
                            return Align(
                              child: SizedBox(
                                width: vw,
                                height: vh,
                                child: VideoPlayer(mv.controller!),
                              ),
                            );
                          },
                        ),
                        Container(color: const Color(0x66000000)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          _DragDismissSheet(
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (_) {
                _chromeVisibleAtPointerDown = _chromeVisible;
                _wakeChrome();
              },
              child: playerStyle == PlayerStyle.traditional
                  ? _TraditionalPlayerLayout(
                      notifier: notifier,
                      current: current,
                      chromeVisible: _chromeVisible,
                      mvEnabled: mv.requested,
                      mvLoading: mv.loading,
                      mvReady: mv.ready,
                      mvPhase: mv.phase,
                      mvBufferedSec: mv.bufferedSec,
                      mvSupported: mvSupports(current),
                      onHideMvChanged: (hide) {
                        if (_hideMvVideo != hide) {
                          setState(() => _hideMvVideo = hide);
                        }
                      },
                      onToggleMv: current != null
                          ? () async {
                              final messenger = ScaffoldMessenger.of(context);
                              final err = await ref
                                  .read(mvProvider.notifier)
                                  .toggle(current);
                              if (err != null && mounted) {
                                messenger.showSnackBar(
                                  SnackBar(content: Text(tr(err))),
                                );
                              }
                            }
                          : null,
                      onContentAreaTap: _onContentAreaTap,
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
          ),
        ],
      ),
    );
  }

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
    final mvReady = ref.watch(mvProvider.select((s) => s.ready));
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
    return LandscapeGate.sequential(
      portrait: _PlayerShell(
        current: current,
        top: [
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
                    mvReady
                        ? (current?.title ?? tr('正在播放'))
                        : (_showLyrics ? tr('歌词') : tr('正在播放')),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Colors.white.withValues(alpha: 0.9),
                    ),
                  ),
                ),
                const SizedBox(width: 48),
              ],
            ),
          ),
          if (!_showLyrics && !mvReady) const SizedBox(height: 12),
          if (!_showLyrics && !mvReady)
            GestureDetector(
              onTap: () {
                setState(() => _showLyrics = true);
              },
              child: Center(
                child: Hero(
                  tag: 'player-cover',
                  flightShuttleBuilder:
                      (ctx, animation, direction, fromCtx, toCtx) {
                        return PlayerCoverShuttle(
                          animation: animation,
                          songPath: current?.path ?? '',
                          networkUrl: current?.coverUrl,
                          fromRadius: 23,
                          toRadius: 31,
                          borderColor: Colors.white.withValues(alpha: 0.18),
                          shadow: BoxShadow(
                            color: scheme.primary.withValues(alpha: 0.28),
                            blurRadius: 36,
                            spreadRadius: 2,
                          ),
                          gradient: [
                            scheme.primary,
                            scheme.primary.withValues(alpha: 0.72),
                          ],
                        );
                      },
                  child: FlyingCoverAnchor(
                    child: CoverReturnSource(
                      songPath: current?.path,
                      networkUrl: current?.coverUrl,
                      child: _BigCover(
                        current: current,
                        size: MediaQuery.of(context).size.width * 0.64,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
        flexible: mvReady
            ? const SizedBox.shrink()
            : _showLyrics
            ? ClipRect(
                child: RepaintBoundary(
                  child: _LyricsView(
                    key: _lyricsKey,
                    current: current,
                    visible: _showLyrics,
                    onTap: () {
                      setState(() => _showLyrics = false);
                    },
                    onRomajiAvailable: (has) {
                      if (_lyricsViewHasRomaji != has) {
                        setState(() => _lyricsViewHasRomaji = has);
                      }
                    },
                  ),
                ),
              )
            : Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 32,
                  vertical: 8,
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: _LyricPreview(current: current),
                ),
              ),
        bottom: [
          if (_showLyrics && !mvReady) const SizedBox(height: 8),
          RepaintBoundary(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
              child: _GlassControlCard(notifier: notifier, current: current),
            ),
          ),
        ],
        overlay: _showLyrics && !mvReady
            ? Positioned(
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
              )
            : null,
      ),
      landscape: landscapeBody,
    );
  }

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
    final mvReady = ref.watch(mvProvider.select((s) => s.ready));
    return _PlayerShell(
      current: current,
      isLandscape: true,
      top: [
        AutoHideChrome(
          visible: _chromeVisible,
          alignment: Alignment.topCenter,
          child: Padding(
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
                const SizedBox(width: 44),
              ],
            ),
          ),
        ),
      ],
      flexible: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _onContentAreaTap,
        child: mvReady
            ? const SizedBox.shrink()
            : Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 12, 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(left: 20),
                        child: LayoutBuilder(
                          builder: (context, cons) {
                            final side = cons.maxWidth;
                            final coverSize = side * 0.9 < cons.maxHeight * 0.8
                                ? side * 0.9
                                : cons.maxHeight * 0.8;
                            return Center(
                              child: GestureDetector(
                                onTap: () =>
                                    setState(() => _showLyrics = !_showLyrics),
                                child: Hero(
                                  tag: 'player-cover',
                                  flightShuttleBuilder:
                                      (
                                        ctx,
                                        animation,
                                        direction,
                                        fromCtx,
                                        toCtx,
                                      ) => PlayerCoverShuttle(
                                        animation: animation,
                                        songPath: current?.path ?? '',
                                        networkUrl: current?.coverUrl,
                                        fromRadius: 23,
                                        toRadius: 31,
                                        borderColor: Colors.white.withValues(
                                          alpha: 0.18,
                                        ),
                                        shadow: BoxShadow(
                                          color: scheme.primary.withValues(
                                            alpha: 0.28,
                                          ),
                                          blurRadius: 36,
                                          spreadRadius: 2,
                                        ),
                                        gradient: [
                                          scheme.primary,
                                          scheme.primary.withValues(
                                            alpha: 0.72,
                                          ),
                                        ],
                                      ),
                                  child: FlyingCoverAnchor(
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
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(right: 22),
                        child: ClipRect(
                          child: RepaintBoundary(
                            child: _LyricsView(
                              key: _lyricsKey,
                              current: current,
                              visible: _showLyrics,
                              onTap: () =>
                                  setState(() => _showLyrics = !_showLyrics),
                              onRomajiAvailable: (has) {
                                if (_lyricsViewHasRomaji != has) {
                                  setState(() => _lyricsViewHasRomaji = has);
                                }
                              },
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
      ),
      bottom: [
        RepaintBoundary(
          child: AutoHideChrome(
            visible: _chromeVisible,
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: _GlassControlCard(
                notifier: notifier,
                current: current,
                landscape: true,
                onLyricAdjust: () =>
                    _TraditionalPlayerLayoutState._showLyricAdjustMenu(
                      context,
                      ref,
                      hasRomaji: hasRomaji,
                    ),
              ),
            ),
          ),
        ),
      ],
      overlay: null,
    );
  }

  @override
  void dispose() {
    super.dispose();
  }
}

class _PlayerShell extends StatelessWidget {
  const _PlayerShell({
    this.current,
    this.isLandscape = false,
    this.top = _noSlots,
    required this.flexible,
    this.bottom = _noSlots,
    this.overlay,
  });

  static const List<Widget> _noSlots = [];

  final QueueItem? current;

  final bool isLandscape;

  final List<Widget> top;

  final Widget flexible;

  final List<Widget> bottom;

  final Widget? overlay;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        top: true,
        bottom: true,
        left: !isLandscape,
        right: !isLandscape,
        child: _body(),
      ),
    );
  }

  Widget _body() {
    return Stack(
      children: [
        Column(
          children: [
            ...top,
            Expanded(child: flexible),
            ...bottom,
          ],
        ),
        ?overlay,
      ],
    );
  }
}

class _TraditionalPlayerLayout extends ConsumerStatefulWidget {
  const _TraditionalPlayerLayout({
    required this.notifier,
    required this.current,
    this.chromeVisible = true,
    this.mvEnabled = false,
    this.mvLoading = false,
    this.mvReady = false,
    this.mvPhase = '',
    this.mvBufferedSec = 0,
    this.mvSupported = false,
    this.onToggleMv,
    this.onHideMvChanged,
    this.onContentAreaTap,
  });
  final PlayerNotifier notifier;
  final QueueItem? current;

  final bool chromeVisible;

  final bool mvEnabled;

  final bool mvLoading;

  final bool mvReady;

  final String mvPhase;

  final int mvBufferedSec;

  final bool mvSupported;
  final VoidCallback? onToggleMv;

  final ValueChanged<bool>? onHideMvChanged;

  /// 横屏点击收起顶栏/底栏：内容区空白处点击回调（null=关闭）
  final VoidCallback? onContentAreaTap;

  @override
  ConsumerState<_TraditionalPlayerLayout> createState() =>
      _TraditionalPlayerLayoutState();
}

class _TraditionalPlayerLayoutState
    extends ConsumerState<_TraditionalPlayerLayout>
    with SingleTickerProviderStateMixin {
  bool _showLyrics = false;

  bool _wasLandscape = false;

  bool _wasMvReady = false;

  bool? _reportedHideMv;

  bool _lyricsViewHasRomaji = false;

  final GlobalKey _lyricsKey = GlobalKey();

  String _coverLyricAlign = 'left';

  String _coverSizeTier = 'large';

  Future<void> _loadCoverAppearancePrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _coverLyricAlign =
            prefs.getString('player_cover_lyric_align') ?? 'left';
        _coverSizeTier = prefs.getString('player_cover_size') ?? 'large';
      });
    } catch (e) {
      AppLog.warn('ui', '读取封面偏好设置失败: $e');
    }
  }

  Future<void> _setCoverLyricAlign(String v) async {
    if (_coverLyricAlign == v) return;
    setState(() => _coverLyricAlign = v);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('player_cover_lyric_align', v);
    } catch (e) {
      AppLog.warn('ui', '保存封面歌词对齐设置失败: $e');
    }
  }

  Future<void> _setCoverSizeTier(String v) async {
    if (_coverSizeTier == v) return;
    setState(() => _coverSizeTier = v);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('player_cover_size', v);
    } catch (e) {
      AppLog.warn('ui', '保存封面尺寸设置失败: $e');
    }
  }

  int _sleepMinutes = 10;

  DateTime? _sleepDeadline;

  Timer? _sleepFire;

  Future<void> _loadSleepMinutes() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(
        () => _sleepMinutes = prefs.getInt('player_sleep_minutes') ?? 10,
      );
    } catch (e) {
      AppLog.warn('ui', '读取定时暂停设置失败: $e');
    }
  }

  void _startSleepTimer(int minutes) {
    _sleepFire?.cancel();
    setState(() {
      _sleepMinutes = minutes;
      _sleepDeadline = DateTime.now().add(Duration(minutes: minutes));
    });
    _sleepFire = Timer(Duration(minutes: minutes), _onSleepTimeout);
    _persistSleepMinutes();
    showXianYuToast(
      context,
      tr('已定时：{n} 分钟后暂停播放', {'n': minutes}),
      duration: const Duration(seconds: 1),
    );
  }

  void _cancelSleepTimer() {
    _sleepFire?.cancel();
    _sleepFire = null;
    if (_sleepDeadline == null) return;
    setState(() => _sleepDeadline = null);
  }

  void _onSleepTimeout() {
    _sleepFire = null;
    if (!mounted) return;
    setState(() => _sleepDeadline = null);
    if (ref.read(playerProvider).isPlaying) {
      ref.read(playerProvider.notifier).pauseFromSystem(origin: 'sleepTimer');
      showXianYuToast(
        context,
        tr('定时时间到，已暂停播放'),
        duration: const Duration(seconds: 2),
      );
    }
  }

  Future<void> _persistSleepMinutes() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('player_sleep_minutes', _sleepMinutes);
    } catch (e) {
      AppLog.warn('ui', '保存定时暂停设置失败: $e');
    }
  }

  late final PageController _pageController;

  final bool _flashOn = false;

  late final AnimationController _eq;

  @override
  void initState() {
    super.initState();
    _loadCoverAppearancePrefs();
    _loadSleepMinutes();
    _eq = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _pageController = PageController(initialPage: 0);
  }

  @override
  void dispose() {
    _eq.dispose();
    _sleepFire?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  void _switchPage(int i) {
    if (_pageController.hasClients) {
      _pageController.animateToPage(
        i,
        duration: _mvSwitchDuration,
        curve: _mvSwitchCurve,
      );
    }
    if (_showLyrics != (i == 1)) setState(() => _showLyrics = i == 1);
    _notifyHideMv(
      ref.read(mvProvider).ready &&
          _showLyrics &&
          !ref.read(isLandscapeProvider),
    );
  }

  void _notifyHideMv(bool hide) {
    if (_reportedHideMv == hide) return;
    _reportedHideMv = hide;
    widget.onHideMvChanged?.call(hide);
  }

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
    final isPlaying = ref.watch(playerProvider.select((s) => s.isPlaying));
    _syncEq(isPlaying);
    final isLandscape = ref.watch(isLandscapeProvider);
    final mvReady = ref.watch(mvProvider.select((s) => s.ready));
    if (!isLandscape && _wasLandscape) {
      _wasLandscape = false;
      if (_showLyrics) {
        _showLyrics = false;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _pageController.jumpToPage(0);
        });
      }
    } else {
      _wasLandscape = isLandscape;
    }
    if (!mvReady && _wasMvReady && !isLandscape && _showLyrics) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            _pageController.hasClients &&
            _pageController.page != 1) {
          _pageController.jumpToPage(1);
        }
      });
    }
    if (mvReady && !_wasMvReady && _showLyrics) {
      _showLyrics = false;
    }
    _wasMvReady = mvReady;
    final hideMv = mvReady && _showLyrics && !isLandscape;
    if (_reportedHideMv != hideMv) {
      _reportedHideMv = hideMv;
      final onHideMvChanged = widget.onHideMvChanged;
      if (onHideMvChanged != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) onHideMvChanged(hideMv);
        });
      }
    }
    return LandscapeGate.sequential(
      portrait: _buildTraditionalPortrait(context, current),
      landscape: _buildTraditionalLandscape(context, current),
    );
  }

  Widget _buildLyricsPage(QueueItem? current) {
    return ClipRect(
      child: RepaintBoundary(
        child: _LyricsView(
          key: _lyricsKey,
          current: current,
          visible: _showLyrics,
          onTap: () {},
          onRomajiAvailable: (has) {
            if (_lyricsViewHasRomaji != has) {
              setState(() => _lyricsViewHasRomaji = has);
            }
          },
        ),
      ),
    );
  }

  Widget _buildTraditionalPortrait(BuildContext context, QueueItem? current) {
    final mvReady = ref.watch(mvProvider.select((s) => s.ready));
    return _PlayerShell(
      current: current,
      top: [_buildTopBar(context)],
      flexible: mvReady
          ? AnimatedSlide(
              offset: _showLyrics ? Offset.zero : const Offset(0.08, 0),
              duration: _mvSwitchDuration,
              curve: _mvSwitchCurve,
              child: AnimatedOpacity(
                opacity: _showLyrics ? 1 : 0,
                duration: _mvSwitchDuration,
                curve: _mvSwitchCurve,
                child: IgnorePointer(
                  ignoring: !_showLyrics,
                  child: _buildLyricsPage(current),
                ),
              ),
            )
          : Stack(
              fit: StackFit.expand,
              children: [
                PageView.builder(
                  controller: _pageController,
                  itemCount: 2,
                  allowImplicitScrolling: true,
                  onPageChanged: (i) {
                    if (_showLyrics != (i == 1)) {
                      setState(() => _showLyrics = i == 1);
                    }
                  },
                  itemBuilder: (context, i) {
                    if (i == 0) {
                      return _KeepAliveWrap(child: _buildCoverSection(context));
                    }
                    return _KeepAliveWrap(child: _buildLyricsPage(current));
                  },
                ),
              ],
            ),
      bottom: [
        _buildActionsRow(context),
        const SizedBox(height: 4),
        RepaintBoundary(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 22),
            child: _ProgressBar(notifier: widget.notifier),
          ),
        ),
        _Controls(notifier: widget.notifier),
        const SizedBox(height: 32),
      ],
      overlay: null,
    );
  }

  Widget _buildTraditionalLandscape(BuildContext context, QueueItem? current) {
    final mvReady = ref.watch(mvProvider.select((s) => s.ready));
    return _PlayerShell(
      current: current,
      isLandscape: true,
      top: [
        AutoHideChrome(
          visible: widget.chromeVisible,
          alignment: Alignment.topCenter,
          child: _buildTopBar(context, landscape: true),
        ),
      ],
      flexible: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: widget.onContentAreaTap,
        child: mvReady
            ? const SizedBox.shrink()
            : Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(left: 24),
                      child: _buildCoverSection(
                        context,
                        showLyricPreview: false,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(left: 12, right: 56),
                      child: ClipRect(
                        child: RepaintBoundary(
                          child: _LyricsView(
                            key: _lyricsKey,
                            current: current,
                            visible: true,
                            onTap: widget.onContentAreaTap ?? () {},
                            onRomajiAvailable: (hasRomaji) {
                              if (_lyricsViewHasRomaji != hasRomaji) {
                                setState(
                                  () => _lyricsViewHasRomaji = hasRomaji,
                                );
                              }
                            },
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
      ),
      bottom: [
        AutoHideChrome(
          visible: widget.chromeVisible,
          alignment: Alignment.bottomCenter,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RepaintBoundary(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 22),
                  child: _ProgressBar(
                    notifier: widget.notifier,
                    showTime: false,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              _LandscapeControlsRow(
                notifier: widget.notifier,
                current: current,
                onLyricAdjust: () => _showLyricAdjustMenu(
                  context,
                  ref,
                  hasRomaji: _lyricsViewHasRomaji,
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ],
      overlay: null,
    );
  }

  static void _showLyricAdjustMenu(
    BuildContext context,
    WidgetRef ref, {
    required bool hasRomaji,
    bool showAlign = true,
  }) {
    showSheetDialog<void>(
      context,
      (_) => _LyricsAdjustDialog(hasRomaji: hasRomaji, showAlign: showAlign),
    );
  }

  static Widget _buildAlignSegmented(
    BuildContext ctx,
    String align,
    SettingsNotifier notifier,
  ) {
    final scheme = Theme.of(ctx).colorScheme;
    const labels = [('left', '左'), ('center', '中'), ('right', '右')];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          tr('歌词对齐'),
          style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            for (final (value, label) in labels)
              Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () {
                    notifier.setLyricAlignment(value);
                  },
                  child: Container(
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    margin: const EdgeInsets.only(right: 8),
                    decoration: BoxDecoration(
                      color: align == value
                          ? const Color(0xFFEC4141).withValues(alpha: 0.14)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: align == value
                            ? FontWeight.w700
                            : FontWeight.w500,
                        color: align == value
                            ? const Color(0xFFEC4141)
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }

  static Widget _buildLyricMenuAction(
    BuildContext ctx, {
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    final scheme = Theme.of(ctx).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 12),
        child: Row(
          children: [
            Icon(icon, size: 20, color: scheme.onSurfaceVariant),
            const SizedBox(width: 12),
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
            ),
            const Spacer(),
            Icon(Icons.chevron_right_rounded, size: 20, color: scheme.outline),
          ],
        ),
      ),
    );
  }

  static Widget _buildLyricMenuSwitch(
    BuildContext ctx, {
    required IconData icon,
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
    bool enabled = true,
  }) {
    final scheme = Theme.of(ctx).colorScheme;
    return InkWell(
      onTap: enabled ? () => onChanged(!value) : null,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        child: Row(
          children: [
            Icon(
              icon,
              size: 20,
              color: enabled ? scheme.onSurfaceVariant : scheme.outline,
            ),
            const SizedBox(width: 12),
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: enabled ? scheme.onSurface : scheme.outline,
              ),
            ),
            const Spacer(),
            Switch.adaptive(
              value: value,
              onChanged: enabled ? onChanged : null,
              activeThumbColor: const Color(0xFFEC4141),
            ),
          ],
        ),
      ),
    );
  }

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
                  : widget.mvReady
                  ? Text(
                      widget.current?.title ?? tr('正在播放'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Colors.white.withValues(alpha: 0.9),
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
            icon: themeSlotIcon(
              ref,
              'action.share',
              fallback: Icons.ios_share,
              size: 20,
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

  Widget _buildCoverSection(
    BuildContext context, {
    bool showLyricPreview = true,
  }) {
    final isPlaying = ref.watch(playerProvider.select((s) => s.isPlaying));
    return LayoutBuilder(
      builder: (context, cons) {
        final coverTierScale = switch (_coverSizeTier) {
          'medium' => 0.85,
          'small' => 0.70,
          _ => 1.0,
        };
        final coverSize =
            math.min(
              cons.maxWidth * (showLyricPreview ? 0.85 : 0.92),
              cons.maxHeight * (showLyricPreview ? 0.6 : 0.88),
            ) *
            coverTierScale;
        final hInset = (cons.maxWidth - coverSize) / 2;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            showLyricPreview
                ? const SizedBox(height: 14)
                : const Expanded(child: SizedBox.shrink()),
            Center(
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
                child: FlyingCoverAnchor(
                  child: CoverReturnSource(
                    songPath: widget.current?.path,
                    networkUrl: widget.current?.coverUrl,
                    child: _TraditionalCover(
                      size: coverSize,
                      current: widget.current,
                      eq: _eq,
                      flash: _flashOn,
                      playing: isPlaying,
                      onTap: () => _switchPage(1),
                    ),
                  ),
                ),
              ),
            ),
            if (showLyricPreview) ...[
              const SizedBox(height: 30),
              _buildCaption(context, inset: hInset),
            ],
            Expanded(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: hInset),
                child: Align(
                  alignment: switch (_coverLyricAlign) {
                    'center' => Alignment.center,
                    'right' => Alignment.centerRight,
                    _ => Alignment.centerLeft,
                  },
                  child: showLyricPreview
                      ? _LyricPreview(
                          current: widget.current,
                          align: _coverLyricAlign,
                        )
                      : const SizedBox.shrink(),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildCaption(BuildContext context, {required double inset}) {
    final c = widget.current;
    final chain = _resolveAudioChain(ref, c);
    final isFav =
        c != null &&
        ref.watch(favoritesProvider.select((s) => s.contains(c.path)));
    final fromDaily = c?.fromDailyRecommend ?? false;
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
                if (chain.known) ...[
                  const SizedBox(height: 7),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: _AudioFormatBadge(chain: chain, dense: true),
                  ),
                ],
              ],
            ),
          ),
          if (fromDaily)
            InkWell(
              borderRadius: BorderRadius.circular(22),
              onTap: () => _reportDailyDislike(context, c),
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: SizedBox(
                  width: 28,
                  height: 28,
                  child: CustomPaint(
                    painter: _DislikeStrokePainter(
                      color: Colors.white.withValues(alpha: 0.9),
                    ),
                    child: Icon(
                      Icons.favorite_border,
                      size: 26,
                      color: Colors.white.withValues(alpha: 0.9),
                    ),
                  ),
                ),
              ),
            ),
          if (fromDaily) const SizedBox(width: 8),
          InkWell(
            borderRadius: BorderRadius.circular(22),
            onTap: () {
              if (c != null) {
                ref.read(favoritesProvider.notifier).toggle(c);
              }
            },
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: themeSlotIcon(
                ref,
                'action.favorite',
                fallback: isFav ? Icons.favorite : Icons.favorite_border,
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

  Future<void> _reportDailyDislike(BuildContext context, QueueItem? c) async {
    if (c == null) return;
    final ciyuanxiId = ref.read(authProvider).user?.ciyuanxiId?.trim() ?? '';
    if (ciyuanxiId.isEmpty) {
      showXianYuToast(context, tr('请先登录后使用每日推荐'));
      return;
    }
    try {
      await ref.read(authProvider.notifier).requestAction(
        'report_daily_dislike',
        {'ciyuanxi_id': ciyuanxiId, 'song_name': c.title, 'singer': c.artist},
      );
    } catch (e) {
      AppLog.warn('ui', '上报不喜欢的歌曲失败: $e');
    }
    if (!context.mounted) return;
    showXianYuToast(context, tr('已减少此类推荐'));
    await ref.read(playerProvider.notifier).next();
  }

  Widget _buildActionsRow(BuildContext context) {
    final sfx = ref.watch(soundEffectProvider).settings;
    final bypass = sfx.bypass;
    final current = widget.current;
    final dl = ref.watch(downloadProvider);
    final isLocal = current != null && !current.isOnline;
    final currentQuality = ref.watch(
      playerProvider.select((s) => s.currentQuality),
    );
    final lyricsEnabled = ref.watch(
      settingsProvider.select(
        (s) => s.valueOrNull?.floatingLyricsEnabled ?? false,
      ),
    );
    final mvRequested = ref.watch(mvProvider.select((s) => s.requested));
    final mvQuality = ref.watch(
      mvProvider.select((s) => s.source?.videoQuality),
    );
    final mvQualityShown =
        mvRequested && mvQuality != null && mvQuality.isNotEmpty;
    final dlActive =
        current != null &&
        dl.tasks.any(
          (t) =>
              t.songPath == current.path &&
              (t.status == DownloadStatus.waiting ||
                  t.status == DownloadStatus.downloading),
        );
    final dlDone =
        current != null &&
        (isLocal || dl.history.any((h) => h.songPath == current.path));
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Expanded(
            child: Center(
              child: _actionItem(
                context,
                icon: Icons.graphic_eq,
                tooltip: tr('音效'),
                active: !bypass && _hasPlayerEffects(sfx),
                enabled: !mvRequested,
                onTap: () => playerNavigatorKey.currentState?.push(
                  coverPageRoute<void>(context, (_) => const EffectsPage()),
                ),
              ),
            ),
          ),
          Expanded(
            child: Center(
              child: _qualityActionItem(
                context,
                quality: mvQualityShown ? mvQuality : currentQuality,
                onTap: () {
                  final c = current;
                  if (c == null) return;
                  if (c.isOnline) {
                    _showQualitySheet(context, ref);
                  } else {
                    showXianYuToast(context, tr('本地音乐以原音质播放'));
                  }
                },
              ),
            ),
          ),
          Expanded(
            child: Center(
              child: _downloadActionItem(
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
                  _showDownloadQualitySheet(context, ref, current);
                },
              ),
            ),
          ),
          Expanded(
            child: Center(
              child: _actionItem(
                context,
                icon: Icons.chat_bubble_outline,
                iconWidget: themeSlotWidget(
                  ref,
                  'player.comment',
                  size: 24,
                  fallback: _MessageCircleIcon(
                    size: 24,
                    color: current != null && current.isOnline
                        ? Colors.white.withValues(alpha: 0.85)
                        : Colors.white.withValues(alpha: 0.32),
                  ),
                ),
                tooltip: tr('评论'),
                enabled: current != null && current.isOnline,
                onTap: () {
                  final c = current;
                  if (c == null) return;
                  showSheetDialog<void>(
                    context,
                    (_) => CommentSheet(songJson: c.onlineSongJson!),
                  );
                },
              ),
            ),
          ),
          Expanded(
            child: Center(child: _lyricsActionItem(context, lyricsEnabled)),
          ),
        ],
      ),
    );
  }

  Widget _lyricsActionItem(BuildContext context, bool lyricsEnabled) {
    if (_showLyrics) {
      return IconButton(
        iconSize: 28,
        tooltip: tr('歌词调节'),
        icon: Icon(
          Icons.tune_rounded,
          size: 22,
          color: Colors.white.withValues(alpha: 0.9),
        ),
        onPressed: () => _showLyricAdjustMenu(
          context,
          ref,
          hasRomaji: _lyricsViewHasRomaji,
          showAlign: true,
        ),
      );
    }
    return IconButton(
      iconSize: 28,
      tooltip: tr('更多'),
      icon: themeSlotIcon(
        ref,
        'action.more',
        fallback: Icons.more_horiz,
        size: 24,
        color: Colors.white.withValues(alpha: 0.85),
      ),
      onPressed: () => _showCoverMoreSheet(context, lyricsEnabled),
    );
  }

  Future<void> _showCoverMoreSheet(
    BuildContext context,
    bool lyricsEnabled,
  ) async {
    final c = widget.current;
    if (c == null) return;
    await showSheetDialog<void>(context, (ctx) {
      final scheme = Theme.of(ctx).colorScheme;
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Text(
                c.title,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Text(
                c.artist.isEmpty ? tr('未知歌手') : c.artist,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            StatefulBuilder(
              builder: (ctx, setSheetState) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _sheetSegmentRow(
                    ctx,
                    label: tr('迷你歌词对齐'),
                    current: _coverLyricAlign,
                    options: [
                      (value: 'left', label: tr('左对齐')),
                      (value: 'center', label: tr('居中')),
                      (value: 'right', label: tr('右对齐')),
                    ],
                    onSelected: (v) {
                      setSheetState(() {});
                      _setCoverLyricAlign(v);
                    },
                  ),
                  _sheetSegmentRow(
                    ctx,
                    label: tr('封面大小'),
                    current: _coverSizeTier,
                    options: [
                      (value: 'large', label: tr('大')),
                      (value: 'medium', label: tr('中')),
                      (value: 'small', label: tr('小')),
                    ],
                    onSelected: (v) {
                      setSheetState(() {});
                      _setCoverSizeTier(v);
                    },
                  ),
                ],
              ),
            ),
            _SleepTimerRow(
              initialMinutes: _sleepMinutes,
              deadlineGetter: () => _sleepDeadline,
              onCommit: _startSleepTimer,
              onCancel: _cancelSleepTimer,
            ),
            if (widget.mvSupported && widget.onToggleMv != null)
              ListTile(
                leading: widget.mvLoading
                    ? SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.2,
                          color: scheme.primary,
                        ),
                      )
                    : Icon(
                        widget.mvEnabled
                            ? Icons.movie
                            : Icons.movie_creation_outlined,
                        color: widget.mvEnabled
                            ? scheme.primary
                            : scheme.onSurfaceVariant,
                        size: 22,
                      ),
                title: Text(() {
                  if (!widget.mvLoading) {
                    return widget.mvEnabled ? tr('关闭 MV') : tr('开启 MV');
                  }
                  if (widget.mvPhase == 'init') {
                    return widget.mvBufferedSec > 0
                        ? tr('MV 加载中（已缓冲 {sec} 秒）', {
                            'sec': widget.mvBufferedSec,
                          })
                        : tr('MV 加载中（准备画面）');
                  }
                  return tr('MV 加载中（解析地址）');
                }()),
                onTap: widget.mvLoading
                    ? null
                    : () {
                        Navigator.pop(ctx);
                        widget.onToggleMv?.call();
                      },
              ),
            ListTile(
              leading: Icon(
                Icons.playlist_add,
                color: scheme.primary,
                size: 22,
              ),
              title: Text(tr('添加到歌单')),
              onTap: () {
                Navigator.pop(ctx);
                showAddToPlaylistSheet(ctx, ref, [
                  importedSongFromQueueItem(c),
                ]);
              },
            ),
            ListTile(
              enabled: !widget.mvEnabled,
              leading: Icon(
                Icons.closed_caption_outlined,
                color: widget.mvEnabled
                    ? scheme.outline
                    : (lyricsEnabled
                          ? scheme.primary
                          : scheme.onSurfaceVariant),
                size: 22,
              ),
              title: Text(tr('桌面歌词')),
              trailing: Text(
                lyricsEnabled ? tr('已开启') : tr('已关闭'),
                style: TextStyle(
                  fontSize: 12,
                  color: widget.mvEnabled
                      ? scheme.outline
                      : scheme.onSurfaceVariant,
                ),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _toggleFloatingLyrics(ctx, ref, lyricsEnabled);
              },
            ),
          ],
        ),
      );
    });
  }

  Widget _sheetSegmentRow(
    BuildContext ctx, {
    required String label,
    required String current,
    required List<({String value, String label})> options,
    required ValueChanged<String> onSelected,
  }) {
    final scheme = Theme.of(ctx).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              for (var i = 0; i < options.length; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                Expanded(
                  child: _SheetSegmentButton(
                    label: options[i].label,
                    selected: current == options[i].value,
                    onTap: () => onSelected(options[i].value),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

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
          : themeSlotIcon(
              ref,
              'action.download',
              fallback: dlDone
                  ? Icons.check_circle_outline
                  : Icons.download_outlined,
              color: dlDone
                  ? const Color(0xFF07C160)
                  : Colors.white.withValues(alpha: 0.85),
            ),
      onPressed: onTap,
    );
  }

  Widget _qualityActionItem(
    BuildContext context, {
    required String? quality,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tr('音质'),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          padding: const EdgeInsets.symmetric(horizontal: 2),
          alignment: Alignment.center,
          decoration: const BoxDecoration(shape: BoxShape.circle),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _qualityAbbr(quality),
                maxLines: 1,
                softWrap: false,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: Colors.white.withValues(alpha: 0.85),
                ),
              ),
              // 主题提供倍速/音效图时才出现；未启用主题时是零尺寸，观感不变。
              themeSlotWidget(
                ref,
                'player.speed',
                size: 18,
                color: Colors.white.withValues(alpha: 0.85),
                fallback: const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      ),
    );
  }

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
      icon:
          iconWidget ??
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
