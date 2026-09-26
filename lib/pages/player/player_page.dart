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
import 'package:shared_preferences/shared_preferences.dart';
import 'package:go_router/go_router.dart';

import 'comment_sheet.dart';
import '../../src/core/db_path.dart';
import '../../src/core/settings.dart';
import '../../src/player/mv_source.dart';
import '../../src/player/mv_provider.dart';
import 'package:video_player/video_player.dart';
import '../../src/download/download_provider.dart';
import '../../src/effects/sound_effect_provider.dart';
import '../../src/auth/auth_provider.dart';
import '../../src/favorites/favorites_provider.dart';
import '../../src/lyrics/floating_lyrics.dart';
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
import '../../src/widgets/auto_hide_chrome.dart';
import '../../src/widgets/cover_image.dart';
import '../../src/widgets/glass_settings.dart';
import '../../src/widgets/modern_dialog.dart';
import '../../src/widgets/predictive_cover_return.dart';
import '../../src/widgets/predictive_dialog_route.dart';
import '../../src/widgets/sheet_dialog.dart';
import '../../src/widgets/source_tag.dart';
import '../../src/i18n/i18n.dart';

final Map<String, List<_LyricLineItem>> _lyricsCache = {};
const int _lyricsCacheMax = 24;

/// 传统布局「封面 ↔ 歌词」的切换时长/曲线。普通状态下由 [PageView] 翻页，
/// 播放 MV 时没有 PageView，靠 MV 画面和歌词页各自的进出场动画对齐同样的时长。
const Duration _mvSwitchDuration = Duration(milliseconds: 260);
const Curve _mvSwitchCurve = Curves.easeOutCubic;

void _cacheLyrics(String path, List<_LyricLineItem> lines) {
  if (path.isEmpty || lines.isEmpty) return;
  _lyricsCache[path] = lines;
  if (_lyricsCache.length > _lyricsCacheMax) {
    _lyricsCache.remove(_lyricsCache.keys.first);
  }
}

/// LyricsRepository 仓储模型（LyricLine）→ 播放页渲染模型
/// （_LyricLineItem）的字段子集映射。在线歌词链路复用仓储取词，
/// 两套模型在此对齐。
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

class _LyricsAdjustDialog extends ConsumerStatefulWidget {
  const _LyricsAdjustDialog({
    required this.hasRomaji,
    required this.showAlign,
  });

  final bool hasRomaji;
  final bool showAlign;

  @override
  ConsumerState<_LyricsAdjustDialog> createState() => _LyricsAdjustDialogState();
}

enum _LyricAdjustPanel { main, font, offset }

class _LyricsAdjustDialogState extends ConsumerState<_LyricsAdjustDialog> {
  _LyricAdjustPanel _panel = _LyricAdjustPanel.main;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final notifier = ref.read(settingsProvider.notifier);
    final align =
        ref.watch(settingsProvider).valueOrNull?.lyricAlignment ?? 'center';
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          switch (_panel) {
            _LyricAdjustPanel.main =>
              _buildMain(context, scheme, align, notifier),
            _LyricAdjustPanel.font => _buildFont(context),
            _LyricAdjustPanel.offset => _buildOffset(context),
          },
        ],
      ),
    );
  }

  Widget _backButton(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(),
      icon: Icon(
        Icons.arrow_back_ios_new_rounded,
        size: 18,
        color: scheme.onSurfaceVariant,
      ),
      onPressed: () => setState(() => _panel = _LyricAdjustPanel.main),
    );
  }

  Widget _buildMain(
    BuildContext context,
    ColorScheme scheme,
    String align,
    SettingsNotifier notifier,
  ) {
    final s = ref.watch(settingsProvider).valueOrNull;
    final showTranslation = s?.showLyricsTranslation ?? true;
    final showRomaji = s?.showLyricsRomaji ?? false;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          tr('歌词调节'),
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(height: 16),
        if (widget.showAlign) ...[
          _TraditionalPlayerLayoutState._buildAlignSegmented(
              context, align, notifier),
          const SizedBox(height: 8),
          const Divider(height: 1),
          const SizedBox(height: 4),
        ],
        _TraditionalPlayerLayoutState._buildLyricMenuAction(
          context,
          icon: Icons.format_size_rounded,
          label: tr('歌词字号'),
          onTap: () => setState(() => _panel = _LyricAdjustPanel.font),
        ),
        _TraditionalPlayerLayoutState._buildLyricMenuSwitch(
          context,
          icon: Icons.translate_rounded,
          label: tr('翻译'),
          value: showTranslation,
          onChanged: (v) => notifier.setShowLyricsTranslation(v),
        ),
        _TraditionalPlayerLayoutState._buildLyricMenuSwitch(
          context,
          icon: Icons.abc_rounded,
          label: tr('罗马音'),
          value: showRomaji,
          enabled: widget.hasRomaji,
          onChanged: (v) => notifier.setShowLyricsRomaji(v),
        ),
        _TraditionalPlayerLayoutState._buildLyricMenuAction(
          context,
          icon: Icons.av_timer_rounded,
          label: tr('时间偏移'),
          onTap: () => setState(() => _panel = _LyricAdjustPanel.offset),
        ),
      ],
    );
  }

  Widget _buildFont(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final notifier = ref.read(settingsProvider.notifier);
    final current = ref.watch(settingsProvider).valueOrNull?.lyricFontSize ?? 1;
    final labels = [tr('小'), tr('标准'), tr('大'), tr('特大')];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _backButton(context),
            const SizedBox(width: 4),
            Text(
              tr('歌词字号'),
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            for (var i = 0; i < labels.length; i++)
              Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => notifier.setLyricFontSize(i),
                  child: Container(
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    margin: const EdgeInsets.only(right: 8),
                    decoration: BoxDecoration(
                      color: current == i
                          ? const Color(0xFFEC4141).withValues(alpha: 0.14)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      labels[i],
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight:
                            current == i ? FontWeight.w700 : FontWeight.w500,
                        color: current == i
                            ? const Color(0xFFEC4141)
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 16),
        const Divider(height: 1),
        const SizedBox(height: 12),
        Row(
          children: [
            Icon(
              Icons.font_download_outlined,
              size: 18,
              color: scheme.outline,
            ),
            const SizedBox(width: 8),
            Text(
              tr('自定义歌词字体'),
              style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
            ),
            const Spacer(),
            _FontImportAction(sheetCtx: context),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          tr('支持 .ttf / .otf 字体文件，导入后立即应用到歌词'),
          style: TextStyle(fontSize: 11, color: scheme.outline),
        ),
      ],
    );
  }

  Widget _buildOffset(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final notifier = ref.read(settingsProvider.notifier);
    final value = ref.watch(settingsProvider).valueOrNull?.lyricOffsetMs ?? 0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _backButton(context),
            Text(
              tr('歌词偏移'),
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
            ),
            TextButton(
              onPressed: () => notifier.setLyricOffsetMs(0),
              child: Text(tr('重置')),
            ),
          ],
        ),
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
        Text(
          tr('蓝牙耳机存在固有延迟，歌词提前时请向"延后"方向调节'),
          style: TextStyle(
            fontSize: 11,
            color: scheme.onSurfaceVariant,
          ),
        ),
        Slider(
          value: value.toDouble(),
          min: -2000,
          max: 2000,
          divisions: 400,
          label: '${value}ms',
          onChanged: (v) => notifier.setLyricOffsetMs(v.round()),
        ),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            '-200', '-100', '-10', '-1', '+1', '+10', '+100', '+200',
          ].map((label) {
            final step = int.parse(label);
            return _LyricsViewState._offsetStepChip(
              context,
              label,
              scheme,
              () => notifier.setLyricOffsetMs((value + step).clamp(-2000, 2000)),
            );
          }).toList(),
        ),
      ],
    );
  }
}

class _PlayerPageState extends ConsumerState<PlayerPage> {
  bool _showLyrics = false;

  /// 传统布局切到「歌词」时上报：歌词页会盖住画面，视频层留着只会从歌词背后
  /// 透出来。为真时 MV 画面滑走并淡出（保持挂载，动画期间还要能看到画面；
  /// 到 opacity 0 后不再绘制）。MV 本身仍在播放，切回「封面」即恢复。
  bool _hideMvVideo = false;

  final GlobalKey _lyricsKey = GlobalKey();

  bool _lyricsViewHasRomaji = false;

  String? _sharePreloadPath;

  bool _chromeVisible = true;
  Timer? _chromeHideTimer;

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

  @override
  Widget build(BuildContext context) {
    final current = ref.watch(playerProvider.select((s) => s.current));
    final notifier = ref.read(playerProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    final mv = ref.watch(mvProvider);

    ref.listen(playerProvider.select((s) => s.current), (prev, next) {
      // 换歌同步 MV 已下沉到 MvNotifier 内部监听：播放页退出后本 widget
      // 的 listen 会一并销毁，挂在页面上会导致页面不在时切歌不同步 MV。
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
    final playerStyle = settings?.playerStyle ?? PlayerStyle.advanced;

    // 只有传统布局会把「歌词」当作盖住画面的整页，需要连视频层一起去掉；
    // 高级布局在 MV 播放时不渲染歌词，别把 MV 藏没了。
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
          Positioned.fill(
            child: _BlurredCoverBackground(
              current: current,
            ),
          ),
          if (mv.ready && mv.controller != null)
            Positioned.fill(
              // 切到歌词页时让 MV 画面滑走并淡出，和歌词页的进场动画同步；
              // 保持挂载是为了动画期间还能看到画面，opacity 到 0 后不会绘制。
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
                        LayoutBuilder(builder: (context, cons) {
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
                        }),
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
          onPointerDown: (_) => _wakeChrome(),
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
                          final err =
                              await ref.read(mvProvider.notifier).toggle(current);
                          if (err != null && mounted) {
                            messenger.showSnackBar(
                              SnackBar(content: Text(tr(err))),
                            );
                          }
                        }
                      : null,
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
                  icon: const Icon(
                    Icons.keyboard_arrow_down,
                    size: 28,
                  ),
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
                  flightShuttleBuilder: (ctx, animation, direction, fromCtx,
                      toCtx) {
                    return PlayerCoverShuttle(
                      animation: animation,
                      songPath: current?.path ?? '',
                      networkUrl: current?.coverUrl,
                      fromRadius: 23,
                      toRadius: 31,
                      borderColor:
                          Colors.white.withValues(alpha: 0.18),
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
                        horizontal: 32, vertical: 8),
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
              child: _GlassControlCard(
                notifier: notifier,
                current: current,
              ),
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
      flexible: mvReady
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
                          flightShuttleBuilder: (ctx, animation, direction,
                                  fromCtx, toCtx) =>
                              PlayerCoverShuttle(
                                animation: animation,
                                songPath: current?.path ?? '',
                                networkUrl: current?.coverUrl,
                                fromRadius: 23,
                                toRadius: 31,
                                borderColor:
                                    Colors.white.withValues(alpha: 0.18),
                                shadow: BoxShadow(
                                  color: scheme
                                      .primary
                                      .withValues(alpha: 0.28),
                                  blurRadius: 36,
                                  spreadRadius: 2,
                                ),
                                gradient: [
                                  scheme.primary,
                                  scheme.primary.withValues(alpha: 0.72),
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
                onLyricAdjust: () => _TraditionalPlayerLayoutState
                    ._showLyricAdjustMenu(
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
  });
  final PlayerNotifier notifier;
  final QueueItem? current;

  final bool chromeVisible;

  final bool mvEnabled;

  final bool mvLoading;

  final bool mvReady;

  /// MV 加载阶段（'resolve'=解析地址 / 'init'=初始化画面）。
  final String mvPhase;

  /// 初始化期间已缓冲秒数。
  final int mvBufferedSec;

  final bool mvSupported;
  final VoidCallback? onToggleMv;

  /// 上报「歌词页是否需要隐藏 MV 视频层」，见 [_hideMvVideo]。
  final ValueChanged<bool>? onHideMvChanged;

  @override
  ConsumerState<_TraditionalPlayerLayout> createState() =>
      _TraditionalPlayerLayoutState();
}

class _TraditionalPlayerLayoutState
    extends ConsumerState<_TraditionalPlayerLayout>
    with SingleTickerProviderStateMixin {
  bool _showLyrics = false;

  bool _wasLandscape = false;

  /// MV 播放时 PageView 会被替换成占位，退出 MV 后 PageView 是重新挂载的
  /// （停在封面页）。用这个标记在退出 MV 的那一帧把页码同步回 [_showLyrics]。
  bool _wasMvReady = false;

  /// 最近一次上报给外层的 [onHideMvChanged] 值。
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
    } catch (_) {
    }
  }

  Future<void> _setCoverLyricAlign(String v) async {
    if (_coverLyricAlign == v) return;
    setState(() => _coverLyricAlign = v);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('player_cover_lyric_align', v);
    } catch (_) {}
  }

  Future<void> _setCoverSizeTier(String v) async {
    if (_coverSizeTier == v) return;
    setState(() => _coverSizeTier = v);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('player_cover_size', v);
    } catch (_) {}
  }

  int _sleepMinutes = 10;

  DateTime? _sleepDeadline;

  Timer? _sleepFire;

  Future<void> _loadSleepMinutes() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(
          () => _sleepMinutes = prefs.getInt('player_sleep_minutes') ?? 10);
    } catch (_) {
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
    showXianYuToast(context, tr('已定时：{n} 分钟后暂停播放', {'n': minutes}),
        duration: const Duration(seconds: 1));
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
      ref.read(playerProvider.notifier).pauseFromSystem();
      showXianYuToast(context, tr('定时时间到，已暂停播放'),
          duration: const Duration(seconds: 2));
    }
  }

  Future<void> _persistSleepMinutes() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('player_sleep_minutes', _sleepMinutes);
    } catch (_) {}
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
    // 播放 MV 时 PageView 不在树里（flexible 被替换成占位），此时控制器没有
    // 关联的滚动视图，animateToPage 会抛异常并中断整个方法，表现就是顶栏的
    // 「歌词」按钮点了没反应。所以只在真的有附着视图时才翻页。
    if (_pageController.hasClients) {
      _pageController.animateToPage(
        i,
        duration: _mvSwitchDuration,
        curve: _mvSwitchCurve,
      );
    }
    if (_showLyrics != (i == 1)) setState(() => _showLyrics = i == 1);
    // 这里同步上报，避免歌词页先叠在视频上再抽掉视频层、闪一帧画面。
    _notifyHideMv(ref.read(mvProvider).ready &&
        _showLyrics &&
        !ref.read(isLandscapeProvider));
  }

  /// 通知外层是否要把 MV 视频层整个去掉。
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
      // 退出 MV 后 PageView 才重新挂载并停在封面页，若之前在看歌词要把页码同步回来。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            _pageController.hasClients &&
            _pageController.page != 1) {
          _pageController.jumpToPage(1);
        }
      });
    }
    if (mvReady && !_wasMvReady && _showLyrics) {
      // 播放 MV 时顶栏不再有「封面/歌词」切换（整屏就是 MV 画面），
      // 歌词若还开着就没有回画面的入口了，所以进入 MV 直接回到画面。
      _showLyrics = false;
    }
    _wasMvReady = mvReady;
    // 兜底同步：[_showLyrics] 也会在 build 里被改（例如横屏转回竖屏时重置），
    // 那种路径走不到 [_switchPage]，所以这里再核对一次，只能延迟到帧末上报。
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

  /// 歌词页内容。MV 播放时 [PageView] 不在树中，同一份内容会作为叠在 MV 上的
  /// 歌词层复用，保证顶栏的「歌词」按钮在两种状态下都能切到歌词。
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
      top: [
        _buildTopBar(context),
      ],
      flexible: mvReady
          // MV 播放时没有 PageView 可翻，歌词页和 MV 画面各自做进出场动画，
          // 方向和翻页一致：歌词从右侧进来，MV 画面往左退掉。
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
      flexible: mvReady
          ? const SizedBox.shrink()
          : Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: 24),
              child: _buildCoverSection(context, showLyricPreview: false),
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
                  onTap: () {},
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
      (_) => _LyricsAdjustDialog(
        hasRomaji: hasRomaji,
        showAlign: showAlign,
      ),
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
                        fontWeight:
                            align == value ? FontWeight.w700 : FontWeight.w500,
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
            Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: scheme.outline,
            ),
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
                  // 整屏都是 MV 画面，封面/歌词切换没有意义，顶栏只留歌名。
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
            icon: const Icon(
              Icons.ios_share,
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

  Widget _buildCoverSection(BuildContext context,
      {bool showLyricPreview = true}) {
    final isPlaying = ref.watch(playerProvider.select((s) => s.isPlaying));
    return LayoutBuilder(
      builder: (context, cons) {
        final coverTierScale = switch (_coverSizeTier) {
          'medium' => 0.85,
          'small' => 0.70,
          _ => 1.0,
        };
        final coverSize = math.min(
          cons.maxWidth * (showLyricPreview ? 0.85 : 0.92),
          cons.maxHeight * (showLyricPreview ? 0.6 : 0.88),
        ) * coverTierScale;
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
    final isFav = c != null &&
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
        {
          'ciyuanxi_id': ciyuanxiId,
          'song_name': c.title,
          'singer': c.artist,
        },
      );
    } catch (_) {
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
      settingsProvider.select((s) => s.valueOrNull?.floatingLyricsEnabled ?? false),
    );
    final mvRequested = ref.watch(mvProvider.select((s) => s.requested));
    final mvQuality = ref.watch(
      mvProvider.select((s) => s.source?.videoQuality),
    );
    final mvQualityShown =
        mvRequested && mvQuality != null && mvQuality.isNotEmpty;
    final dlActive = current != null &&
        dl.tasks.any((t) =>
            t.songPath == current.path &&
            (t.status == DownloadStatus.waiting ||
                t.status == DownloadStatus.downloading));
    final dlDone = current != null &&
        (isLocal ||
            dl.history.any((h) => h.songPath == current.path));
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Expanded(child: Center(child: _actionItem(
            context,
            icon: Icons.graphic_eq,
            tooltip: tr('音效'),
            active: !bypass && _hasPlayerEffects(sfx),
            // MV 的音轨不走音效引擎，控制不了它，MV 开启时入口置灰不可点。
            enabled: !mvRequested,
            onTap: () => context.push('/effects'),
          ))),
          Expanded(child: Center(child: _qualityActionItem(
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
              _showDownloadQualitySheet(context, ref, current);
            },
          ))),
          Expanded(child: Center(child: _actionItem(
            context,
            icon: Icons.chat_bubble_outline,
            iconWidget: _MessageCircleIcon(
              size: 24,
              color: current != null && current.isOnline
                  ? Colors.white.withValues(alpha: 0.85)
                  : Colors.white.withValues(alpha: 0.32),
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
          ))),
          Expanded(child: Center(child: _lyricsActionItem(context, lyricsEnabled))),
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
      icon: Icon(
        Icons.more_horiz,
        size: 24,
        color: Colors.white.withValues(alpha: 0.85),
      ),
      onPressed: () => _showCoverMoreSheet(context, lyricsEnabled),
    );
  }

  Future<void> _showCoverMoreSheet(
      BuildContext context, bool lyricsEnabled) async {
    final c = widget.current;
    if (c == null) return;
    await showSheetDialog<void>(
      context,
      (ctx) {
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
                      fontSize: 15, fontWeight: FontWeight.w700),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Text(
                  c.artist.isEmpty ? tr('未知歌手') : c.artist,
                  style: TextStyle(
                      fontSize: 12, color: scheme.onSurfaceVariant),
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
                              strokeWidth: 2.2, color: scheme.primary),
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
                          ? tr('MV 加载中（已缓冲 {sec} 秒）',
                              {'sec': widget.mvBufferedSec})
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
                leading:
                    Icon(Icons.playlist_add, color: scheme.primary, size: 22),
                title: Text(tr('添加到歌单')),
                onTap: () {
                  Navigator.pop(ctx);
                  showAddToPlaylistSheet(
                      ctx, ref, [importedSongFromQueueItem(c)]);
                },
              ),
              ListTile(
                // MV 开启时画面就是 MV，桌面歌词没有意义，整行禁用。
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
                          : scheme.onSurfaceVariant),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _toggleFloatingLyrics(ctx, ref, lyricsEnabled);
                },
              ),
            ],
          ),
        );
      },
    );
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
          Text(label,
              style:
                  TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
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
          : Icon(
              dlDone ? Icons.check_circle_outline : Icons.download_outlined,
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
        // 只约束最小点击热区（36×36），宽度交给文字自行撑开：
        // 音质缩写长度不一（HQ/SQ/HRA/AT+ 与 MV 画质 480P/720P/1080P），
        // 原先写死 width:36 会让 480P 这类 4~5 字符在 16px 字号下折行成两行。
        child: Container(
          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          padding: const EdgeInsets.symmetric(horizontal: 2),
          alignment: Alignment.center,
          decoration: const BoxDecoration(shape: BoxShape.circle),
          child: Text(
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

class _LyricPreview extends ConsumerStatefulWidget {
  const _LyricPreview({required this.current, this.align = 'left'});
  final QueueItem? current;

  final String align;

  @override
  ConsumerState<_LyricPreview> createState() => _LyricPreviewState();
}

class _LyricPreviewState extends ConsumerState<_LyricPreview>
    with TickerProviderStateMixin {
  static const double _kLineH = 23.0;

  List<_LyricLineItem> _lines = const [];
  bool _loading = false;

  // 逐字渲染需要逐帧播放位置：与主歌词页同一套「锚点+Stopwatch」模拟，
  // 播放中每帧插值推进 _progress，seek/暂停由 provider 流重置锚点。
  final ValueNotifier<double> _progress = ValueNotifier<double>(0);
  double _anchorPos = 0;
  final Stopwatch _anchorWatch = Stopwatch();
  Ticker? _ticker;

  @override
  void initState() {
    super.initState();
    _anchorPos = ref.read(playerProvider).position;
    _progress.value = _anchorPos;
    _ticker = createTicker(_onPreviewTick);
    _syncPreviewTicker();
    _load();
  }

  void _onPreviewTick(Duration _) {
    final next = _anchorPos + _anchorWatch.elapsedMilliseconds / 1000.0;
    if ((next - _progress.value).abs() < 0.002) return;
    _progress.value = next;
  }

  void _onPreviewPositionChanged(double next) {
    _anchorPos = next;
    _anchorWatch.reset();
    _progress.value = next;
    _syncPreviewTicker();
  }

  void _syncPreviewTicker() {
    final isPlaying = ref.read(playerProvider).isPlaying;
    if (isPlaying && !(_ticker?.isActive ?? false)) {
      _anchorWatch
        ..reset()
        ..start();
      _ticker!.start();
    } else if (!isPlaying && (_ticker?.isActive ?? false)) {
      _ticker!.stop();
      _anchorWatch.stop();
      _progress.value = _anchorPos;
    }
  }

  @override
  void didUpdateWidget(_LyricPreview old) {
    super.didUpdateWidget(old);
    if (old.current?.path != widget.current?.path) {
      _lines = const [];
      _loading = false;
      _anchorPos = ref.read(playerProvider).position;
      _progress.value = _anchorPos;
      _syncPreviewTicker();
      _load();
    }
  }

  @override
  void dispose() {
    _ticker?.dispose();
    _progress.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final item = widget.current;
    final path = item?.path ?? '';
    if (path.isEmpty || _loading || _lines.isNotEmpty) return;
    final cached = _lyricsCache[path];
    if (cached != null && cached.isNotEmpty) {
      if (mounted) setState(() => _lines = cached);
      return;
    }
    _loading = true;
    try {
      if (item!.isOnline) {
        // 在线歌曲与主歌词页同源：统一走 LyricsRepository（含密文解密）。
        final lines =
            _lyricLinesToViewItems(await ref.read(lyricsRepositoryProvider).fetchLyrics(item));
        if (lines.isNotEmpty) _cacheLyrics(path, lines);
        if (!mounted) return;
        setState(() => _lines = lines);
      } else {
        final dbPath = await ref.read(dbPathProvider.future);
        final jsonStr =
            await getSongLyricsPayload(dbPath: dbPath, path: item.path);
        final parsed = (jsonStr.isNotEmpty && jsonStr != 'null')
            ? await compute(_parseLyricsJson, jsonStr)
            : const <_LyricLineItem>[];
        final lines = await compute(_normalizeBoundaries, parsed);
        if (lines.isNotEmpty) _cacheLyrics(path, lines);
        if (!mounted) return;
        setState(() => _lines = lines);
      }
    } catch (_) {
      if (mounted) setState(() => _lines = const []);
    } finally {
      _loading = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(
      playerProvider.select((s) => s.position),
      (_, next) => _onPreviewPositionChanged(next),
    );
    ref.listen(
      playerProvider.select((s) => s.isPlaying),
      (_, _) => _syncPreviewTicker(),
    );
    if (_lines.isEmpty) return const SizedBox.shrink();
    final posMs = (ref.watch(playerProvider.select((s) => s.position)) * 1000);
    var active = 0;
    for (var i = 0; i < _lines.length; i++) {
      if (_lines[i].timeMs <= posMs) {
        active = i;
      } else {
        break;
      }
    }
    return ClipRect(
      child: SizedBox(
        width: double.infinity,
        height: 3 * _kLineH,
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: null, end: active.toDouble()),
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          builder: (context, cur, _) {
            final activeLine = cur.round().clamp(0, _lines.length - 1);
            final rows = <Widget>[];
            for (var i = (cur - 2).floor(); i <= (cur + 2).ceil(); i++) {
              if (i < 0 || i >= _lines.length) continue;
              final y = (i - cur) * _kLineH + _kLineH;
              if (y > 3 * _kLineH || y + _kLineH < 0) continue;
              final isActive = i == activeLine;
              final line = _lines[i];
              final align = switch (widget.align) {
                'center' => Alignment.center,
                'right' => Alignment.centerRight,
                _ => Alignment.centerLeft,
              };
              // 当前行带逐字时间轴（YRC/QRC 等）时按卡拉OK渲染，
              // 超宽单行整体缩放（FittedBox）保持一行不溢出。
              Widget lineChild;
              if (isActive && line.words.isNotEmpty) {
                lineChild = RepaintBoundary(
                  child: ValueListenableBuilder<double>(
                    valueListenable: _progress,
                    builder: (context, posSec, _) {
                      return Align(
                        alignment: align,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              for (final w in line.words)
                                _buildKaraokeWord(w, posSec, 14, null),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                );
              } else {
                lineChild = Text(
                  line.text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: switch (widget.align) {
                    'center' => TextAlign.center,
                    'right' => TextAlign.right,
                    _ => TextAlign.left,
                  },
                  style: TextStyle(
                    color: isActive
                        ? Colors.white
                        : Colors.white.withValues(alpha: 0.5),
                    fontSize: isActive ? 14 : 12.5,
                    height: 1.2,
                  ),
                );
              }
              rows.add(
                Positioned(
                  top: y,
                  left: 0,
                  right: 0,
                  child: lineChild,
                ),
              );
            }
            return ClipRect(
              clipBehavior: Clip.hardEdge,
              child: Stack(children: rows),
            );
          },
        ),
      ),
    );
  }
}

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
  static const _speed = 42.0;

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

class _AnimatedPlayerCover extends ConsumerStatefulWidget {
  const _AnimatedPlayerCover({
    required this.current,
    required this.builder,
    this.role = 'cover',
  });

  final QueueItem? current;

  final Widget Function(BuildContext, QueueItem?) builder;

  final String role;

  @override
  ConsumerState<_AnimatedPlayerCover> createState() =>
      _AnimatedPlayerCoverState();
}

class _SwitchCoverRecord {
  QueueItem? item;
  int index = -1;
  DateTime? at;
}

const Duration _switchCoverGrace = Duration(seconds: 5);
final Map<String, _SwitchCoverRecord> _switchCoverRecords = {};

_SwitchCoverRecord _switchCoverRecordOf(String role) =>
    _switchCoverRecords.putIfAbsent(role, () => _SwitchCoverRecord());

class _AnimatedPlayerCoverState extends ConsumerState<_AnimatedPlayerCover>
    with SingleTickerProviderStateMixin {
  AnimationController? _ctrlC;

  AnimationController get _ctrl => _ctrlC ??= AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );

  QueueItem? _base;

  String? _shownPath;

  int _lastIndex = -1;

  bool _animating = false;

  int _dir = 1;

  late final _SwitchCoverRecord _record = _switchCoverRecordOf(widget.role);

  @override
  void initState() {
    super.initState();
    _shownPath = widget.current?.path;
    _maybeStartFromPrevious();
  }

  @override
  void didUpdateWidget(_AnimatedPlayerCover old) {
    super.didUpdateWidget(old);
    _onTrackChange(widget.current, old.current);
  }

  void _onTrackChange(QueueItem? next, QueueItem? prev) {
    if (next == null || next.path == _shownPath) return;
    final idx = ref.read(playerProvider).queueIndex;
    _dir = (_lastIndex < 0 || idx >= _lastIndex) ? 1 : -1;
    _lastIndex = idx;
    _shownPath = next.path;
    final base = (prev != null && prev.path != next.path)
        ? prev
        : _record.item;
    if (base == null || base.path == next.path) return;
    setState(() {
      _base = base;
      _animating = true;
    });
    _commitSwitch(next);
    _runForward();
  }

  void _maybeStartFromPrevious() {
    final cur = widget.current;
    if (cur == null) return;
    _lastIndex = ref.read(playerProvider).queueIndex;
    if (_record.item?.path == cur.path) {
      _commitSwitch(cur);
      return;
    }
    final prevItem = _record.item;
    final at = _record.at;
    final recent = at != null &&
        DateTime.now().difference(at) < _switchCoverGrace;
    if (prevItem != null && recent && prevItem.path != cur.path) {
      _dir = _record.index < 0 || _lastIndex >= _record.index ? 1 : -1;
      _base = prevItem;
      _animating = true;
      _runForward();
    }
    _commitSwitch(cur);
  }

  void _runForward() {
    _ctrl
      ..stop()
      ..value = 0;
    _ctrl.forward().whenComplete(() {
      if (!mounted) return;
      setState(() {
        _animating = false;
        _base = null;
      });
    });
  }

  void _commitSwitch(QueueItem item) {
    _record
      ..item = item
      ..index = ref.read(playerProvider).queueIndex
      ..at = DateTime.now();
  }

  @override
  Widget build(BuildContext context) {
    final cur = widget.current;
    if (cur == null) {
      _ctrl.stop();
      _ctrl.value = 1;
      return widget.builder(context, null);
    }
    if (!_animating || _base == null) return widget.builder(context, cur);
    return Stack(
      fit: StackFit.passthrough,
      children: [
        widget.builder(context, _base),
        AnimatedBuilder(
          animation: _ctrl,
          child: widget.builder(context, cur),
          builder: (context, child) => ClipRect(
            child: FractionalTranslation(
              translation: Offset(
                _dir * (1 - Curves.easeOutCubic.transform(_ctrl.value)),
                0,
              ),
              child: child,
            ),
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _ctrlC?.dispose();
    super.dispose();
  }
}

class _TraditionalCover extends StatelessWidget {
  const _TraditionalCover({
    required this.size,
    required this.current,
    required this.eq,
    required this.flash,
    required this.playing,
    this.onTap,
  });
  final double size;
  final QueueItem? current;
  final AnimationController eq;
  final bool flash;
  final bool playing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return _AnimatedPlayerCover(
      current: current,
      builder: (context, cur) => _buildCover(context, cur),
    );
  }

  Widget _buildCover(BuildContext context, QueueItem? cur) {
    final scheme = Theme.of(context).colorScheme;
    final cover = Container(
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
            if (cur == null)
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
                songPath: cur.path,
                networkUrl: cur.coverUrl,
                thumbPath: cur.coverPath,
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

    if (onTap == null) return cover;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: cover,
    );
  }
}

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

    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          Container(color: Color.lerp(scheme.surface, Colors.black, 0.6)),
          _AnimatedPlayerCover(
            current: current,
            role: 'bg',
            builder: (context, cur) => _blurCoverLayer(context, cur, scheme),
          ),
          const _DecoratedGradient(
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [
                Color(0x0F000000),
                Color(0x00000000),
                Color(0x0F000000),
              ],
            ),
          ),
          const _DecoratedGradient(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color(0x08000000),
                Color(0x00000000),
                Color(0x38000000),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _blurCoverLayer(BuildContext context, QueueItem? item, ColorScheme scheme) {
    if (item == null) {
      return Container(color: Color.lerp(scheme.surface, Colors.black, 0.6));
    }
    final size = MediaQuery.of(context).size;
    const downscale = 8.0;
    final smallW = size.width / downscale;
    final smallH = size.height / downscale;
    const sigma = 50.0 / downscale;
    const toneMatrix = <double>[
      1.2039, -0.2717, -0.0274, 0, -0.08,
      -0.0809, 1.0131, -0.0274, 0, -0.08,
      -0.0809, -0.2717, 1.2575, 0, -0.08,
      0, 0, 0, 1, 0,
    ];
    final coverChild = CoverImage(
      songPath: item.path,
      networkUrl: item.coverUrl,
      width: smallW,
      height: smallH,
      radius: 0,
      gradient: [
        scheme.primary,
        scheme.primary.withValues(alpha: 0.72),
      ],
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
    );

    final inner = ImageFiltered(
      imageFilter: ImageFilter.blur(
        sigmaX: sigma,
        sigmaY: sigma,
        tileMode: TileMode.decal,
      ),
      child: ColorFiltered(
        colorFilter: const ColorFilter.matrix(toneMatrix),
        child: coverChild,
      ),
    );

    return FittedBox(
      fit: BoxFit.cover,
      child: SizedBox(
        width: smallW,
        height: smallH,
        child: inner,
      ),
    );
  }
}

class _DecoratedGradient extends StatelessWidget {
  const _DecoratedGradient({required this.gradient});

  final Gradient gradient;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(gradient: gradient),
    );
  }
}

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
      ],
    );
  }

  Widget _blob(Color color, double size) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      gradient: RadialGradient(colors: [color, color.withValues(alpha: 0)]),
    ),
  );
}

class _BigCover extends StatelessWidget {
  const _BigCover({required this.current, this.size});

  final QueueItem? current;

  final double? size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _AnimatedPlayerCover(
      current: current,
      builder: (context, cur) {
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
            child: cur == null
                ? _placeholder(scheme, coverSize)
                : CoverImage(
                    songPath: cur.path,
                    networkUrl: cur.coverUrl,
                    thumbPath: cur.coverPath,
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
      },
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

class _GlassControlCard extends ConsumerWidget {
  const _GlassControlCard({
    required this.notifier,
    required this.current,
    this.landscape = false,
    this.onLyricAdjust,
  });
  final PlayerNotifier notifier;
  final QueueItem? current;
  final bool landscape;

  final VoidCallback? onLyricAdjust;

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
    final frosted = ref.watch(
      settingsProvider.select((s) => s.valueOrNull?.frostedGlass ?? false),
    );
    final budget = ref.watch(blurBudgetProvider(BlurSurfaceType.drawerOrSheet));
    final error = ref.watch(playerProvider.select((s) => s.error));

    final content = Padding(
      padding: landscape
          ? const EdgeInsets.fromLTRB(8, 10, 8, 12)
          : const EdgeInsets.fromLTRB(20, 10, 20, 14),
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
                    showTime: false,
                  ),
                ),
                const SizedBox(height: 4),
                _LandscapeControlsRow(
                  notifier: notifier,
                  current: current,
                  onLyricAdjust: onLyricAdjust,
                ),
              ],
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _TitleRow(current: current!),
                if (error != null) ...[
                  const SizedBox(height: 6),
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
                const SizedBox(height: 4),
                RepaintBoundary(
                  child: _ProgressBar(notifier: notifier),
                ),
                const SizedBox(height: 2),
                _Controls(notifier: notifier),
              ],
            ),
    );

    if (lowPerf || (!frosted && !playerLiquid)) {
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
        backgroundColor: bilipaiSurfaceTint(context, ref, quality),
        specular: bilipaiSpecularOf(quality),
        edgeAmount: bilipaiEdgeOf(quality),
        saturation: bilipaiSaturationOf(quality),
        child: content,
      );
    }

    final glassColor = wallpaperGlassActive(ref)
        ? wallpaperNavGlassFill(context)
        : (isDark
            ? Colors.white.withValues(alpha: 0.08)
            : Colors.white.withValues(alpha: 0.6));

    final sigma = wallpaperGlassActive(ref)
        ? kNavSurfaceBlurSigma
        : surfaceBlurSigma(
            base: 15,
            budget: budget,
            type: BlurSurfaceType.drawerOrSheet,
          );
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
    final mvRequested = ref.watch(mvProvider.select((s) => s.requested));
    final mvQuality = ref.watch(
      mvProvider.select((s) => s.source?.videoQuality),
    );
    final mvQualityShown = mvRequested && mvQuality != null && mvQuality.isNotEmpty;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      current.title.isEmpty ? tr('未知曲目') : current.title,
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
                      current.artist.isEmpty ? tr('未知歌手') : current.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.white.withValues(alpha: 0.72),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (current.isOnline)
                InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => _showQualitySheet(context, ref),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                    child: Text(
                      mvQualityShown ? mvQuality : _qualityLabel(currentQuality),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.5,
                        color: (mvQualityShown ||
                                (currentQuality != null &&
                                    isLosslessQuality(currentQuality)))
                            ? scheme.primary
                            : const Color(0xFFEC4141).withValues(alpha: 0.9),
                      ),
                    ),
                  ),
                ),
              const SizedBox(width: 4),
              InkWell(
                borderRadius: BorderRadius.circular(10),
                // MV 开启时画面就是 MV，桌面歌词没有意义，这里置灰不可点。
                onTap: mvRequested
                    ? null
                    : () => _toggleFloatingLyrics(context, ref, lyricsEnabled),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  child: Container(
                    width: 24,
                    height: 24,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: !mvRequested && lyricsEnabled
                          ? scheme.primary.withValues(alpha: 0.14)
                          : Colors.transparent,
                    ),
                    child: Text(
                      tr('词'),
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: mvRequested
                            ? Colors.white.withValues(alpha: 0.32)
                            : lyricsEnabled
                                ? scheme.primary
                                : Colors.white.withValues(alpha: 0.72),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              IconButton(
                constraints: const BoxConstraints(minWidth: 40, minHeight: 36),
                padding: EdgeInsets.zero,
                icon: Icon(
                  isFav ? Icons.favorite : Icons.favorite_border,
                  size: 22,
                  color: isFav
                      ? const Color(0xFFEC4141)
                      : Colors.white.withValues(alpha: 0.85),
                ),
                tooltip: tr('收藏'),
                onPressed: () => ref.read(favoritesProvider.notifier).toggle(current),
              ),
              IconButton(
                constraints: const BoxConstraints(minWidth: 40, minHeight: 36),
                padding: EdgeInsets.zero,
                icon: Icon(
                  Icons.ios_share,
                  size: 22,
                  color: Colors.white.withValues(alpha: 0.85),
                ),
                tooltip: tr('分享歌曲'),
                onPressed: () => _shareCurrent(context, ref, current),
              ),
              if (current.isOnline)
                IconButton(
                  constraints: const BoxConstraints(minWidth: 40, minHeight: 36),
                  padding: EdgeInsets.zero,
                  icon: Icon(
                    Icons.download_outlined,
                    size: 22,
                    color: Colors.white.withValues(alpha: 0.85),
                  ),
                  tooltip: tr('下载歌曲'),
                  onPressed: () => _showDownloadQualitySheet(context, ref, current),
                ),
              if (current.isOnline)
                IconButton(
                  constraints: const BoxConstraints(minWidth: 40, minHeight: 36),
                  padding: EdgeInsets.zero,
                  icon: Icon(
                    Icons.mode_comment_outlined,
                    size: 22,
                    color: Colors.white.withValues(alpha: 0.85),
                  ),
                  tooltip: tr('评论'),
                  onPressed: () => showSheetDialog<void>(
                    context,
                    (_) => CommentSheet(songJson: current.onlineSongJson),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

Future<void> _shareCurrent(
    BuildContext context, WidgetRef ref, QueueItem current) async {
  await showSongShareSheet(context, ref: ref, song: current);
}

void _showQualitySheet(BuildContext context, WidgetRef ref) {
  final mv = ref.read(mvProvider);
  if (mv.requested) {
    showSheetDialog<void>(context, (_) => const _MvQualitySheet());
    return;
  }
  final notifier = ref.read(playerProvider.notifier);
  showSheetDialog<void>(
  context,
  (_) => _QualitySheet(notifier: notifier),
);
}

void _showDownloadQualitySheet(
    BuildContext context, WidgetRef ref, QueueItem song) {
  final notifier = ref.read(playerProvider.notifier);
  final mv = ref.read(mvProvider);
  if (mv.requested && mv.ready && mv.source != null) {
    showSheetDialog<void>(context, (_) => _MvDownloadSheet(song: song));
    return;
  }
  showSheetDialog<void>(
  context,
  (_) => _DownloadQualitySheet(notifier: notifier, song: song),
);
}

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

String _compactSize(int bytes) {
  final mb = bytes / 1024 / 1024;
  if (mb >= 1024) return '${(mb / 1024).toStringAsFixed(1)}G';
  if (mb >= 1) return '${mb.toStringAsFixed(1)}M';
  final kb = bytes / 1024;
  if (kb >= 1) return '${kb.round()}K';
  return '${bytes}B';
}

String _qualitySizeSuffix(String q, Map<String, QualitySizeInfo> sizes) {
  final info = sizes[q];
  if (info == null) return '';
  return ' · ${_compactSize(info.bytes)}';
}

String _nearestAvailable(
    String preferred, List<String> available, String behavior) {
  if (available.isEmpty || available.contains(preferred)) return preferred;
  int rank(String q) {
    final i = kQualityLadder.indexOf(q);
    return i < 0 ? kQualityLadder.length : i;
  }

  final prefRank = rank(preferred);
  final sorted = [...available]..sort((a, b) => rank(a).compareTo(rank(b)));
  if (behavior == 'higher') {
    return sorted
        .firstWhere((q) => rank(q) > prefRank, orElse: () => sorted.last);
  }
  return sorted.reversed
      .firstWhere((q) => rank(q) < prefRank, orElse: () => sorted.first);
}

mixin _QualitySheetProbeState<W extends ConsumerStatefulWidget>
    on ConsumerState<W> {
  Future<List<String>>? _future;
  Map<String, QualitySizeInfo> _sizes = const {};

  Future<List<String>> loadQualityOptions();

  PlayerNotifier get sheetNotifier;

  @override
  void initState() {
    super.initState();
    _future = loadQualityOptions();
    _loadSizes();
  }

  Future<void> _loadSizes() async {
    await _future;
    for (var i = 0; i < 20; i++) {
      if (!mounted) return;
      final sizes = await sheetNotifier.qualitySizes();
      if (!mounted) return;
      if (sizes.isNotEmpty) setState(() => _sizes = sizes);
      final probing =
          ref.read(playerProvider.select((s) => s.qualityMenuProbing));
      if (!probing && (sizes.isNotEmpty || i > 0)) return;
      await Future.delayed(const Duration(milliseconds: 600));
    }
  }

  /// 探测收尾后仍无体积的档位视为假音质（声明了但解析不出直链、
  /// 元数据也无体积），从列表剔除，对齐桌面端规则。
  /// 体积尚未就绪（_sizes 为空）时不过滤，避免误伤本地/未探测场景。
  List<String> dropFakeQualities(List<String> shown, Set<String> keep) {
    final sizes = _sizes;
    if (sizes.isEmpty) return shown;
    return shown
        .where((q) => sizes.containsKey(q) || keep.contains(q))
        .toList(growable: false);
  }
}

class _QualitySheet extends ConsumerStatefulWidget {
  const _QualitySheet({required this.notifier});

  final PlayerNotifier notifier;

  @override
  ConsumerState<_QualitySheet> createState() => _QualitySheetState();
}

class _QualitySheetState extends ConsumerState<_QualitySheet>
    with _QualitySheetProbeState<_QualitySheet> {
  @override
  PlayerNotifier get sheetNotifier => widget.notifier;

  @override
  Future<List<String>> loadQualityOptions() => widget.notifier.qualityOptions();

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
                final fallbackOpts = ref.watch(
                  playerProvider.select((s) => s.availableQualities),
                );
                final cur = ref.watch(
                  playerProvider.select((s) => s.currentQuality),
                );
                final base = opts.isNotEmpty ? opts : fallbackOpts;
                final combined = <String>{...base};
                if (cur != null && cur.isNotEmpty) combined.add(cur);
                final shown =
                    kQualityLadder.reversed.where(combined.contains).toList();
                // 探测收尾后仍无体积的档位视为假音质剔除（对齐桌面端），
                // 探测中或体积结果未就绪时不过滤
                final probing = ref.watch(
                  playerProvider.select((s) => s.qualityMenuProbing),
                );
                final sizes = _sizes;
                final visible = probing || sizes.isEmpty
                    ? shown
                    : dropFakeQualities(
                        shown, {if (cur != null && cur.isNotEmpty) cur});
                if (visible.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 48),
                    child: Center(child: Text(tr('暂无可切换音质'))),
                  );
                }
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final q in visible) ...[
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
                                  // 先关弹窗再后台切换：切换含网络解析与
                                  // 起播，耗时可能长达数秒，不能让弹窗
                                  // 挂着等结果
                                  final overlay = Overlay.of(
                                    ctx,
                                    rootOverlay: true,
                                  );
                                  Navigator.of(ctx).pop();
                                  final ok = await widget.notifier
                                      .switchQuality(
                                    q,
                                  );
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
            ),
          ],
        ),
      ),
    );
  }
}

class _MvQualitySheet extends ConsumerStatefulWidget {
  const _MvQualitySheet();

  @override
  ConsumerState<_MvQualitySheet> createState() => _MvQualitySheetState();
}

class _MvQualitySheetState extends ConsumerState<_MvQualitySheet> {
  @override
  Widget build(BuildContext context) {
    final mv = ref.watch(mvProvider);
    final source = mv.source;
    final qualities = source?.availableVideoQualities ?? const <MvQuality>[];
    final cur = (source?.videoQuality ?? '').toUpperCase();
    final size = MediaQuery.of(context).size;
    final landscape = size.width > size.height;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: landscape ? size.height * 0.85 : size.height * 0.7,
        maxWidth: landscape ? 560 : double.infinity,
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
                tr('MV 画质'),
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.2,
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (qualities.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 48),
                child: Center(
                  child: Text(mv.loading ? tr('MV 加载中…') : tr('暂无可切换画质')),
                ),
              )
            else if (landscape)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (final q in qualities)
                      _qualityPill(
                        context,
                        label: _mvQualityTileLabel(q),
                        selected: q.key.toUpperCase() == cur,
                        onTap: q.key.toUpperCase() == cur
                            ? null
                            : () => _switch(q),
                      ),
                  ],
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final q in qualities) ...[
                      ModernOptionTile<String>(
                        option: ModernChoiceOption(
                          label: _mvQualityTileLabel(q),
                          value: q.key,
                        ),
                        isSelected: q.key.toUpperCase() == cur,
                        onTap: q.key.toUpperCase() == cur
                            ? () {}
                            : () => _switch(q),
                      ),
                      const SizedBox(height: 6),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _qualityPill(
    BuildContext context, {
    required String label,
    required bool selected,
    required VoidCallback? onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected
          ? scheme.primary.withValues(alpha: 0.16)
          : scheme.surfaceContainerHighest,
      shape: StadiumBorder(
        side: BorderSide(
          color: selected ? scheme.primary : scheme.outlineVariant,
          width: selected ? 1.4 : 1,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        customBorder: const StadiumBorder(),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              color: selected ? scheme.primary : scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _switch(MvQuality q) async {
    final err = await ref.read(mvProvider.notifier).setQuality(q.key);
    if (!mounted) return;
    final overlay = Overlay.of(context, rootOverlay: true);
    Navigator.of(context).pop();
    showXianYuToastByOverlay(overlay, err ?? tr('画质已切换为${q.label}'));
  }
}

class _MvDownloadSheet extends ConsumerStatefulWidget {
  const _MvDownloadSheet({required this.song});

  final QueueItem song;

  @override
  ConsumerState<_MvDownloadSheet> createState() => _MvDownloadSheetState();
}

class _MvDownloadSheetState extends ConsumerState<_MvDownloadSheet> {
  bool _downloading = false;

  Future<void> _download(BuildContext ctx, MvQuality q) async {
    if (_downloading) return;
    setState(() => _downloading = true);
    final overlay = Overlay.of(ctx, rootOverlay: true);
    final mvNotifier = ref.read(mvProvider.notifier);
    final dlNotifier = ref.read(downloadProvider.notifier);
    if (!await dlNotifier.requireDownloadDir(ctx)) {
      if (mounted) setState(() => _downloading = false);
      return;
    }
    if (!ctx.mounted) return;
    Navigator.of(ctx).pop();
    _runDownload(overlay, mvNotifier, dlNotifier, q);
  }

  Future<void> _runDownload(
    OverlayState overlay,
    MvNotifier mvNotifier,
    DownloadManager dlNotifier,
    MvQuality q,
  ) async {
    final quality = q.key.toUpperCase();
    try {
      final source = await mvNotifier.resolveDownloadSource(
        widget.song,
        q.key,
      );
      if (source == null || source.url.isEmpty) {
        throw StateError(tr('此歌曲无 MV 或画质不支持'));
      }
      await dlNotifier.downloadMvVideo(
        item: widget.song,
        source: source,
        qualityKey: quality,
      );
      showXianYuToastByOverlay(
        overlay,
        tr('MV 已下载（{quality}），保存到下载目录', {'quality': quality}),
      );
    } catch (e) {
      showXianYuToastByOverlay(
        overlay,
        tr('MV 下载失败：{e}', {'e': e.toString()}),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final mv = ref.watch(mvProvider);
    final qualities = mv.source?.availableVideoQualities ?? const <MvQuality>[];
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
                tr('下载 MV'),
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.2,
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (qualities.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 48),
                child: Center(
                  child: Text(tr('暂无可下载画质')),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final q in qualities) ...[
                      ModernOptionTile<String>(
                        option: ModernChoiceOption(
                          label: _mvQualityTileLabel(q),
                          value: q.key,
                        ),
                        isSelected: false,
                        onTap: _downloading ? () {} : () => _download(context, q),
                      ),
                      const SizedBox(height: 6),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

String _mvQualityTileLabel(MvQuality q) {
  final label = q.label.isNotEmpty ? q.label : q.key;
  if (q.size != null && q.size! > 0) return '$label · ${_compactSize(q.size!)}';
  if (q.bitrate != null && q.bitrate! > 0) {
    return '$label · ${(q.bitrate! / 1000).round()}K';
  }
  return label;
}

class _DownloadQualitySheet extends ConsumerStatefulWidget {
  const _DownloadQualitySheet({required this.notifier, required this.song});

  final PlayerNotifier notifier;
  final QueueItem song;

  @override
  ConsumerState<_DownloadQualitySheet> createState() =>
      _DownloadQualitySheetState();
}

class _DownloadQualitySheetState
    extends ConsumerState<_DownloadQualitySheet>
    with _QualitySheetProbeState<_DownloadQualitySheet> {
  @override
  PlayerNotifier get sheetNotifier => widget.notifier;

  @override
  Future<List<String>> loadQualityOptions() =>
      widget.notifier.downloadQualityOptions();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final playingPath =
        ref.watch(playerProvider.select((s) => s.current?.path));
    final cur = ref.watch(playerProvider.select((s) => s.currentQuality));
    final settings = ref.watch(settingsProvider.select((s) => s.valueOrNull));
    final isPlayingSong = widget.song.path.isNotEmpty &&
        widget.song.path == playingPath &&
        cur != null &&
        cur.isNotEmpty;
    final String initial;
    final settingQuality = settings?.downloadQuality;
    if (settingQuality != null && settingQuality.isNotEmpty) {
      initial = settingQuality;
    } else if (isPlayingSong) {
      initial = cur;
    } else {
      initial = '320k';
    }
    final fallbackBehavior =
        settings?.downloadQualityFallbackBehavior ?? 'lower';
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
                final fallbackOpts = ref.watch(
                  playerProvider.select((s) => s.availableQualities),
                );
                final probed = opts.isNotEmpty ? opts : fallbackOpts;
                // 体积探测基于当前播放歌曲，仅在下载对象就是播放歌曲时
                // 剔除假音质（对齐桌面端）；探测中或体积未就绪时不过滤
                final probing = ref.watch(
                  playerProvider.select((s) => s.qualityMenuProbing),
                );
                final shown = probing || _sizes.isEmpty || !isPlayingSong
                    ? probed
                    : dropFakeQualities(probed, {cur});
                final sizes = _sizes;
                final defaultQ =
                    _nearestAvailable(initial, shown, fallbackBehavior);
                    final options = shown.isNotEmpty
                        ? shown
                        : const <String>[''];
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (shown.isEmpty)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: Text(
                                tr('未能探测到可用音质，将以默认音质下载'),
                                style: TextStyle(
                                  fontSize: 12,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          for (final q in options) ...[
                            ModernOptionTile<String>(
                              option: ModernChoiceOption(
                                label: shown.isEmpty
                                    ? '${_qualityLabel(initial)} · ${tr('默认')}'
                                    : '${_qualityLabel(q)}${_qualitySizeSuffix(q, sizes)}',
                                value: shown.isEmpty ? '' : q,
                              ),
                              isSelected:
                                  shown.isEmpty ? true : q == defaultQ,
                              onTap: () async {
                                final overlay =
                                    Overlay.of(ctx, rootOverlay: true);
                                if (!await ref
                                    .read(downloadProvider.notifier)
                                    .requireDownloadDir(ctx)) {
                                  return;
                                }
                                if (!ctx.mounted) return;
                                Navigator.of(ctx).pop();
                                ref
                                    .read(downloadProvider.notifier)
                                    .download(
                                  widget.song,
                                  quality: q.isEmpty ? null : q,
                                );
                                showXianYuToastByOverlay(
                                  overlay,
                                  tr('开始下载：{title}（{quality}），请留意通知查看下载进度', {
                                    'title': widget.song.title,
                                    'quality': _qualityLabel(
                                        q.isEmpty ? null : q),
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
            ),
          ],
        ),
      ),
    );
  }
}

/// 音频跳转 + 让 MV 同步跟随。
///
/// MV 的自动同步（[MvNotifier._syncTimeline]）对所有 seek 都施加 5 秒冷却，
/// 冷却期内只做 ±8% 变速微调、不发 seek——用户主动跳转若落进该窗口就完全不动，
/// 表现为「拖了进度条 MV 自己放自己的」。所以用户侧跳转必须显式告知 MV。
void _seekAudioWithMv(WidgetRef ref, PlayerNotifier notifier, double secs) {
  notifier.seek(secs);
  ref.read(mvProvider.notifier).alignToAudioSeconds(secs);
}

class _ProgressBar extends ConsumerWidget {
  const _ProgressBar({required this.notifier, this.showTime = true});
  final PlayerNotifier notifier;

  final bool showTime;

  String _fmt(double s) {
    final m = s ~/ 60;
    final sec = (s % 60).floor();
    return '${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    // 音频被 MV 接管后，进度条整体切到 MV 时间轴：位置、总时长、拖动
    // 都以 MV 为准，所见即所听。
    final mvCtrl = ref.watch(mvProvider
        .select((s) => (s.audioTakenOver && s.ready) ? s.controller : null));
    if (mvCtrl != null && mvCtrl.value.isInitialized) {
      return ListenableBuilder(
        listenable: mvCtrl,
        builder: (context, _) {
          final v = mvCtrl.value;
          return _bar(
            context,
            scheme,
            position: v.position.inMilliseconds / 1000.0,
            dur: v.duration.inMilliseconds / 1000.0,
            onCommit: (secs) =>
                ref.read(mvProvider.notifier).seekToMvSeconds(secs),
          );
        },
      );
    }
    final position = ref.watch(playerProvider.select((s) => s.position));
    final dur = ref.watch(playerProvider.select((s) => s.duration));
    return _bar(
      context,
      scheme,
      position: position,
      dur: dur,
      onCommit: (v) => _seekAudioWithMv(ref, notifier, v),
    );
  }

  Widget _bar(
    BuildContext context,
    ColorScheme scheme, {
    required double position,
    required double dur,
    required void Function(double secs) onCommit,
  }) {
    // 时长未知时（还没起播、或恢复的会话里没带时长）不能拿 1.0 顶替 max，
    // 否则 position 会被 clamp 到满格、右侧显示 00:01，看着就像进度条坏了。
    // 这里和底部时间行的做法一致：位置照实显示，总时长用 --:--。
    final hasDuration = dur > 0;
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
            value: hasDuration ? position.clamp(0, dur) : 0.0,
            min: 0,
            max: hasDuration ? dur : 1.0,
            enabled: hasDuration,
            onCommit: hasDuration ? onCommit : null,
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
                  hasDuration ? _fmt(dur) : '--:--',
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
    final playMode = ref.watch(playerProvider.select((s) => s.playMode));
    final resolving = ref.watch(playerProvider.select((s) => s.resolving));
    final isPlaying = ref.watch(playerProvider.select((s) => s.isPlaying));
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
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

  void _showQueueSheet(BuildContext context, WidgetRef ref) {
    showSheetDialog<void>(
        context, (_) => _QueueSheet(player: ref.read(playerProvider)));
  }
}

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

class _LandscapeControlsRow extends ConsumerWidget {
  const _LandscapeControlsRow({
    required this.notifier,
    required this.current,
    this.onLyricAdjust,
  });

  final PlayerNotifier notifier;
  final QueueItem? current;

  final VoidCallback? onLyricAdjust;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final accent = scheme.primary;
    final item = current;
    final sfx = ref.watch(soundEffectProvider).settings;
    final bypass = sfx.bypass;
    final dl = ref.watch(downloadProvider);
    final isLocal = item != null && !item.isOnline;
    final currentQuality = ref.watch(
      playerProvider.select((s) => s.currentQuality),
    );
    final lyricsEnabled = ref.watch(
      settingsProvider.select(
          (s) => s.valueOrNull?.floatingLyricsEnabled ?? false),
    );
    final mvRequested = ref.watch(mvProvider.select((s) => s.requested));
    final mvQuality = ref.watch(
      mvProvider.select((s) => s.source?.videoQuality),
    );
    final mvQualityShown =
        mvRequested && mvQuality != null && mvQuality.isNotEmpty;
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
    final idle = Colors.white.withValues(alpha: 0.85);
    final position = ref.watch(playerProvider.select((s) => s.position));
    final dur = ref.watch(playerProvider.select((s) => s.duration));
    String fmtTime(double s) {
      final m = s ~/ 60;
      final sec = (s % 60).floor();
      return '${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
    }

    final leftCluster = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
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
        IconButton(
          iconSize: 28,
          tooltip: tr('桌面歌词'),
          icon: Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: !mvRequested && lyricsEnabled
                  ? accent.withValues(alpha: 0.14)
                  : Colors.transparent,
            ),
            child: Text(
              tr('词'),
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.bold,
                color: mvRequested
                    ? Colors.white.withValues(alpha: 0.32)
                    : lyricsEnabled
                        ? accent
                        : idle,
              ),
            ),
          ),
          // MV 开启时画面就是 MV，桌面歌词没有意义，置灰不可点。
          onPressed: mvRequested
              ? null
              : () => _toggleFloatingLyrics(context, ref, lyricsEnabled),
        ),
      ],
    );

    final rightCluster = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
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
            // 同 _qualityActionItem：只约束最小热区，宽度交给文字撑开，
            // 避免 480P/720P/1080P 等较长画质标签在 36px 内折行。
            child: Container(
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              padding: const EdgeInsets.symmetric(horizontal: 2),
              alignment: Alignment.center,
              decoration: const BoxDecoration(shape: BoxShape.circle),
              child: Text(
                mvQualityShown ? mvQuality : _qualityAbbr(currentQuality),
                maxLines: 1,
                softWrap: false,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: idle,
                ),
              ),
            ),
          ),
        ),
        IconButton(
          iconSize: 28,
          tooltip: tr('音效'),
          icon: Icon(
            Icons.graphic_eq,
            color: mvRequested
                ? Colors.white.withValues(alpha: 0.32)
                : (!bypass && _hasPlayerEffects(sfx) ? accent : idle),
          ),
          // MV 的音轨不走音效引擎，控制不了它，MV 开启时置灰不可点。
          onPressed: mvRequested ? null : () => context.push('/effects'),
        ),
        IconButton(
          iconSize: 28,
          icon: Icon(Icons.queue_music, color: idle),
          onPressed: () => showSheetDialog<void>(
            context,
            (_) => _QueueSheet(player: ref.read(playerProvider)),
          ),
        ),
        if (onLyricAdjust != null)
          IconButton(
            iconSize: 28,
            tooltip: tr('歌词调节'),
            icon: Icon(
              Icons.tune_rounded,
              size: 22,
              color: Colors.white.withValues(alpha: 0.9),
            ),
            onPressed: onLyricAdjust,
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

String _cleanLyricText(String raw) {
  if (raw.isEmpty) return '';

  String text = raw;

  text = text.replaceAll(
    RegExp(
      r'\[(ar|ti|al|by|offset|kuwo|kugou|hash|sign|qq|total|language|types):[^\]]*\]',
      caseSensitive: false,
    ),
    '',
  );

  text = text.replaceAll(RegExp(r'\(\d+,\d+(?:,\d+)?\)'), '');

  text = text.replaceAll(RegExp(r'\[\d+,\d+\]'), '');

  text = text.replaceAll(RegExp(r'<[^>]*>'), '');

  return text.trim();
}

/// 逐字文本清理：与 [_cleanLyricText] 类似但不 trim，
/// 单词首尾的空格是英语逐字歌词的单词间隔，trim 掉会导致单词连在一起。
String _cleanLyricWordText(String raw) {
  if (raw.isEmpty) return '';

  String text = raw.replaceAll('\u200b', '').replaceAll('\u2063', '');

  text = text.replaceAll(RegExp(r'\(\d+,\d+(?:,\d+)?\)'), '');

  text = text.replaceAll(RegExp(r'\[\d+,\d+\]'), '');

  text = text.replaceAll(RegExp(r'<[^>]*>'), '');

  return text;
}

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

      final words = <_LyricWordItem>[];
      final rawWords = item['words'] as List?;
      if (rawWords != null && rawWords.isNotEmpty) {
        for (final w in rawWords) {
          if (w is Map<String, dynamic>) {
            final wText = _cleanLyricWordText((w['text'] as String?) ?? '');
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

class _LyricLineItem {
  final int timeMs;

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

class _KeepAliveWrap extends StatefulWidget {
  const _KeepAliveWrap({required this.child});

  final Widget child;

  @override
  State<_KeepAliveWrap> createState() => _KeepAliveWrapState();
}

class _KeepAliveWrapState extends State<_KeepAliveWrap>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

class _LyricsView extends ConsumerStatefulWidget {
  const _LyricsView({
    super.key,
    required this.current,
    required this.visible,
    required this.onTap,
    required this.onRomajiAvailable,
  });

  final QueueItem? current;
  final bool visible;
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

  bool _userInteracted = false;

  Timer? _recenterTimer;
  int _lastActiveIndex = -1;

  double _fontScale = 1.0;

  // ---- RwaS 换行拽动（LyricPullEngine 移植）----
  bool _pullActive = false;
  int _pullAnchor = -1;
  double _pullDistance = 0;
  int _pullDelayMs = 50;
  final Stopwatch _pullWatch = Stopwatch();
  final Map<int, double> _pullOffsets = {};

  final ValueNotifier<int> _pullRevision = ValueNotifier<int>(0);

  int? _draggingIndex;
  Timer? _draggingIndexTimer;

  final Map<int, (double, double)> _lineLayouts = {};

  int _fontSizeIdx = 1;
  bool _showTranslation = true;
  bool _showRomaji = false;
  int _offsetMs = 0;

  TextAlign _align = TextAlign.center;

  bool _hasRomaji = false;

  late final Ticker _ticker;
  final Stopwatch _anchorWatch = Stopwatch();

  double _anchorPos = 0;

  double _displayPos = 0;

  final ValueNotifier<double> _progress = ValueNotifier<double>(0);

  int _renderActiveIndex = -1;

  bool _pendingCenterJump = true;

  Timer? _pendingCenterFallback;

  double? _lastViewportHeight;

  double? _lastViewportWidth;

  Timer? _viewportChangeDebounce;

  // ==================== 模糊行静态烘焙缓存（稳态省逐帧高斯模糊） ====================

  int _blurSteadyAtMs = 0;
  Timer? _blurSteadyTimer;

  final Map<String, _BlurredLineSnapshot> _blurSnapshots = {};

  int _prevActiveIndex = -1;
  static const int _blurSnapshotCap = 20;

  final Set<String> _blurCapturing = {};

  final Map<int, GlobalKey> _blurBoundaryKeys = {};

  bool get _blurSteady =>
      !_userInteracted &&
      DateTime.now().millisecondsSinceEpoch >= _blurSteadyAtMs;

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
        '|t${_showTranslation ? 1 : 0}|r${_showRomaji ? 1 : 0}'
        '|a${_align.index}';
  }

  _BlurredLineSnapshot? _findFallbackSnapshot(
      int index, double sigma, double mainFont, int widthBucket) {
    final pathPrefix = '${widget.current?.path}|$index|';
    final tail = '|f${mainFont.toStringAsFixed(1)}|w$widthBucket'
        '|t${_showTranslation ? 1 : 0}|r${_showRomaji ? 1 : 0}'
        '|a${_align.index}';
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

  final List<_BlurCaptureTask> _blurCaptureQueue = [];
  bool _blurCapturePumping = false;

  void _scheduleBlurCapture(int index, String key, double sigma) {
    if (_blurCapturing.contains(key)) return;
    _blurCapturing.add(key);
    _blurCaptureQueue.add(
        _BlurCaptureTask(index: index, key: key, sigma: sigma));
    _pumpBlurCaptures();
  }

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

  Future<void> _captureBlurLine(_BlurCaptureTask task) async {
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
    final ui.Image raw;
    try {
      raw = await boundary.toImage(pixelRatio: dpr);
    } catch (_) {
      return;
    }
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
    final pathChanged = oldWidget.current?.path != widget.current?.path;
    final onlineJsonChanged = oldWidget.current?.onlineSongJson !=
        widget.current?.onlineSongJson;
    if (pathChanged || onlineJsonChanged) {
      final p = ref.read(playerProvider).position;
      _anchorPos = p;
      _displayPos = p;
      _progress.value = p;
      _lastActiveIndex = -1;
      _renderActiveIndex = -1;
      _pendingCenterJump = true;
      _pendingCenterFallback?.cancel();
      _clearBlurSnapshots();
      _enterBlurTransition();
      _draggingIndexTimer?.cancel();
      _draggingIndex = null;
      _lineLayouts.clear();
      _syncTicker();
      _fetchLyrics();
    } else if (!oldWidget.visible && widget.visible) {
      _pendingCenterJump = true;
      _pendingCenterFallback?.cancel();
      _syncTicker();
    }
  }

  // ==================== RwaS 换行拽动（LyricPullEngine 移植） ====================

  static double _pullEase(double p) {
    p = p.clamp(0.0, 1.0);
    return 1.0 - (1.0 - p) * (1.0 - p);
  }

  void _beginPull(int anchor, double distancePx, double viewport) {
    if (distancePx <= 1 || viewport <= 0) {
      _cancelPull();
      return;
    }
    _pullActive = true;
    _pullAnchor = anchor;
    _pullDistance = distancePx;
    _pullOffsets.clear();
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

  void _advancePull() {
    if (!_pullActive) return;
    const durationMs = 550;
    final t = _pullWatch.elapsedMilliseconds;
    final globalE = _pullEase(t / durationMs);
    final contribution = _pullDistance * globalE;
    var changed = _pullOffsets.isNotEmpty;
    var previous = 0.0;
    for (var i = _pullAnchor + 1; i <= _pullAnchor + 16; i++) {
      if (i >= _lines.length) break;
      final startMs = _pullDelayMs * (i - _pullAnchor);
      double offset;
      if (t < startMs) {
        offset = contribution;
      } else {
        final itemE = _pullEase((t - startMs) / durationMs);
        offset = (contribution - _pullDistance * itemE).clamp(0.0, double.infinity);
      }
      final clamped = math.max(offset, previous);
      previous = clamped;
      if (_pullOffsets[i] != clamped) {
        _pullOffsets[i] = clamped;
        changed = true;
      }
    }
    if (t >= durationMs + _pullDelayMs * 16) {
      _pullActive = false;
      _pullOffsets.clear();
      changed = true;
    }
    if (changed) _pullRevision.value++;
  }

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
      _displayPos = next;
      _progress.value = next;
    }
    _syncTicker();
    _autoScrollToActiveLine();
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
    _pendingCenterFallback?.cancel();
    _viewportChangeDebounce?.cancel();
    _clearBlurSnapshots();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _onTick(Duration _) {
    _advancePull();
    final next = _anchorPos + _anchorWatch.elapsedMilliseconds / 1000.0;
    if ((next - _displayPos).abs() < 0.002) return;
    _displayPos = next;
    _progress.value = next;
    _autoScrollToActiveLine();
    final idx = _activeIndexFor(_displayPos);
    if (idx != _renderActiveIndex) {
      _prevActiveIndex = _renderActiveIndex;
      _renderActiveIndex = idx;
      if (mounted) setState(() {});
    }
  }

  void _syncTicker() {
    final st = ref.read(playerProvider);
    final shouldRun = st.isPlaying && widget.visible;
    if (shouldRun && !_ticker.isActive) {
      _anchorPos = st.position;
      _displayPos = _anchorPos;
      _progress.value = _anchorPos;
      _pendingCenterJump = true;
      _pendingCenterFallback?.cancel();
      _anchorWatch
        ..reset()
        ..start();
      _ticker.start();
    } else if (!shouldRun && _ticker.isActive) {
      _ticker.stop();
      _anchorWatch.stop();
      if (!st.isPlaying) {
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
      _enterBlurTransition();
      _autoScrollToActiveLine(force: true);
    }
  }

  // ==================== 拖动选行播放（移植自 MusicFree） ====================

  void _onLineMeasured(int index, double viewportDy, double height) {
    if (!mounted) return;
    _lineLayouts[index] = (viewportDy + _scrollCtrl.offset, height);
    if (_pendingCenterJump &&
        !_userInteracted &&
        index == _activeIndexFor(_displayPos)) {
      _tryPendingCenterJump();
    }
  }

  void _updateDraggingIndex() {
    if (!_scrollCtrl.hasClients || _lines.isEmpty) return;

    final offset = _scrollCtrl.offset;
    final viewport = _scrollCtrl.position.viewportDimension;
    final center = offset + viewport / 2;

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
      _draggingIndexTimer?.cancel();
      _draggingIndexTimer = Timer(const Duration(seconds: 2), () {
        if (mounted && _draggingIndex != null) {
          setState(() => _draggingIndex = null);
        }
      });
    }
  }

  void _seekToDraggingLine() {
    final idx = _draggingIndex;
    if (idx == null || idx < 0 || idx >= _lines.length) return;

    _seekAudioWithMv(
      ref,
      ref.read(playerProvider.notifier),
      _lines[idx].timeMs / 1000.0,
    );

    _draggingIndexTimer?.cancel();
    setState(() {
      _draggingIndex = null;
      _userInteracted = false;
    });
    _autoScrollToActiveLine(force: true);
  }

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

    final cached = _lyricsCache[item.path];
    if (cached != null && cached.isNotEmpty) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadedPath = item.path;
          _lines = cached;
        });
        _reportRomaji();
        // 歌词就绪后强制校准：等待期间旧歌词残留可能已推进 _lastActiveIndex，
        // 与新歌词当前行恰好相等时普通去重会跳过定位，首屏停旧行、慢一句才追上
        _lastActiveIndex = -1;
        _renderActiveIndex = -1;
        // 保留居中待跳标记：此时新布局可能尚未生成，force 先按估算定位，
        // 下一帧布局就绪后 _tryPendingCenterJump 再精确居中
        _pendingCenterJump = true;
        _autoScrollToActiveLine(force: true);
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
        // 在线歌曲统一走 LyricsRepository：含插件密文 QRC/e-lrc 解密、
        // 翻译解密、原生兜底与 payload 缓存。此前播放页独立取词对密文
        // 直接判空，Baka 系 QQ 插件密文歌词显示「暂无歌词」。
        final repoLines = await ref.read(lyricsRepositoryProvider).fetchLyrics(item);
        final viewLines = _lyricLinesToViewItems(repoLines);
        if (viewLines.isNotEmpty && mounted) {
          _cacheLyrics(item.path, viewLines);
          setState(() {
            _lines = viewLines;
            _loading = false;
          });
          _reportRomaji();
          // 歌词就绪后强制校准（同缓存分支）：异步加载期间 _lastActiveIndex
          // 可能已在旧歌词上推进，需立即按当前播放位置定位到正在唱的行
          _lastActiveIndex = -1;
          _renderActiveIndex = -1;
          _pendingCenterJump = true;
          _autoScrollToActiveLine(force: true);
          return;
        }
      } else {
        final dbPath = await ref.read(dbPathProvider.future);
        jsonStr = await getSongLyricsPayload(dbPath: dbPath, path: item.path);
      }

      if (jsonStr.isNotEmpty && jsonStr != 'null') {
        final parsed = await compute(_parseLyricsJson, jsonStr);
        final lines = await compute(_normalizeBoundaries, parsed);

        if (lines.isNotEmpty && mounted) {
          _cacheLyrics(item.path, lines);
          setState(() {
            _lines = lines;
            _loading = false;
          });
          _reportRomaji();
          // 歌词就绪后强制校准（同缓存分支）：异步加载期间 _lastActiveIndex
          // 可能已在旧歌词上推进，需立即按当前播放位置定位到正在唱的行
          _lastActiveIndex = -1;
          _renderActiveIndex = -1;
          _pendingCenterJump = true;
          _autoScrollToActiveLine(force: true);
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

  void _reportRomaji() {
    final has = _lines.any((l) => l.romaji != null && l.romaji!.isNotEmpty);
    if (has != _hasRomaji) {
      _hasRomaji = has;
      widget.onRomajiAvailable(has);
    }
  }

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

  void _tryPendingCenterJump() {
    if (_userInteracted) return;
    if (_lines.isEmpty || !_scrollCtrl.hasClients) return;
    final idx = _activeIndexFor(_displayPos);
    final viewport = _scrollCtrl.position.viewportDimension;
    if (viewport <= 0) return;
    final layout = _lineLayouts[idx];
    if (layout == null) {
      if (idx >= 0 && _lines.length > 1) {
        final maxScroll = _scrollCtrl.position.maxScrollExtent;
        final target = (maxScroll * idx / (_lines.length - 1))
            .clamp(0.0, maxScroll);
        if ((target - _scrollCtrl.offset).abs() >= 1) {
          _scrollCtrl.jumpTo(target);
        }
      }
      _pendingCenterFallback?.cancel();
      _pendingCenterFallback = Timer(const Duration(milliseconds: 500), () {
        if (mounted) {
          _pendingCenterJump = false;
          _pendingCenterFallback = null;
        }
      });
      return;
    }
    _pendingCenterJump = false;
    _pendingCenterFallback?.cancel();
    _pendingCenterFallback = null;
    _lastActiveIndex = idx;
    final target = (layout.$1 + layout.$2 / 2 - viewport / 2)
        .clamp(0.0, _scrollCtrl.position.maxScrollExtent);
    if ((target - _scrollCtrl.offset).abs() >= 1) {
      _scrollCtrl.jumpTo(target);
    }
  }

  void _autoScrollToActiveLine({bool force = false}) {
    if (_lines.isEmpty || !_scrollCtrl.hasClients) return;
    if (_userInteracted && !force) return;

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

    double targetOffset;
    final layout = _lineLayouts[activeIndex];
    if (layout != null && viewport > 0) {
      targetOffset = layout.$1 + layout.$2 / 2 - viewport / 2;
    } else {
      targetOffset = maxScroll *
          (activeIndex / (_lines.length > 1 ? (_lines.length - 1) : 1));
    }
    targetOffset = targetOffset.clamp(0.0, maxScroll);

    final isPlaying = ref.read(playerProvider).isPlaying;
    if (force || !isPlaying || _userInteracted || activeIndex <= prevIndex) {
      _cancelPull();
    } else if (layout != null) {
      _beginPull(activeIndex, targetOffset - _scrollCtrl.offset, viewport);
    }

    final current = _scrollCtrl.offset;
    if (!force && (targetOffset - current).abs() < 1) return;

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
    ref.listen(
      playerProvider.select((s) => s.position),
      (_, next) => _onPositionChanged(next),
    );
    ref.listen(
      playerProvider.select((s) => s.isPlaying),
      (prev, next) => _syncTicker(),
    );
    final settings = ref.watch(settingsProvider).valueOrNull;
    final newFontSizeIdx = settings?.lyricFontSize ?? 1;
    final newShowTranslation = settings?.showLyricsTranslation ?? true;
    final newShowRomaji = settings?.showLyricsRomaji ?? false;
    _offsetMs = settings?.lyricOffsetMs ?? 0;
    final newAlign = switch (settings?.lyricAlignment) {
      'left' => TextAlign.left,
      'right' => TextAlign.right,
      _ => TextAlign.center,
    };
    if (newFontSizeIdx != _fontSizeIdx ||
        newShowTranslation != _showTranslation ||
        newShowRomaji != _showRomaji ||
        newAlign != _align) {
      _lineLayouts.clear();
      _clearBlurSnapshots();
      _pendingCenterJump = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _tryPendingCenterJump();
      });
    }
    _fontSizeIdx = newFontSizeIdx;
    _showTranslation = newShowTranslation;
    _showRomaji = newShowRomaji;
    _align = newAlign;
    final lyricFontFamily = (settings?.lyricFontName ?? '').isNotEmpty
        ? settings!.lyricFontName
        : null;

    final mqSize = MediaQuery.of(context).size;
    final isLandscape = mqSize.width >= mqSize.height * 1.05;
    _fontScale = isLandscape ? 1.18 : 1.0;

    final mainFont = [24.0, 28.0, 32.0, 36.0][_fontSizeIdx] * _fontScale;
    final transFont = (mainFont * 0.62).clamp(15.0, 25.0);
    final romajiFont = transFont;

    final activeIndex = _activeIndexFor(_displayPos);
    _renderActiveIndex = activeIndex;

    Widget content;
    if (_loading) {
      content = const Center(
        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70),
      );
    } else if (_lines.isEmpty) {
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
      final typicalH = mainFont * 1.35 +
          (_showRomaji ? romajiFont * 1.2 + 5 : 0) +
          (_showTranslation ? transFont * 1.35 + 6 : 0);
      content = LayoutBuilder(
        builder: (context, constraints) {
          final viewport = constraints.maxHeight;
          if (_lastViewportHeight != null &&
              (_lastViewportHeight! - viewport).abs() > 1) {
            final widthChanged = _lastViewportWidth != null &&
                (_lastViewportWidth! - constraints.maxWidth).abs() > 1;
            _viewportChangeDebounce?.cancel();
            _viewportChangeDebounce = Timer(
                const Duration(milliseconds: 350), () {
              if (!mounted) return;
              if (widthChanged) _lineLayouts.clear();
              _pendingCenterJump = true;
              _pendingCenterFallback?.cancel();
              _tryPendingCenterJump();
            });
          }
          _lastViewportHeight = viewport;
          _lastViewportWidth = constraints.maxWidth;
          final blank = viewport / 2 - typicalH / 2;
          final topPad = blank < 20 ? 20.0 : blank;
          final bottomPad = blank < 40 ? 40.0 : blank;
          return NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification is UserScrollNotification) {
            _onUserScrollStart();
            _scheduleAutoRecenter();
          } else if (notification is ScrollUpdateNotification) {
            if (_userInteracted) _updateDraggingIndex();
          }
          return false;
        },
        child: ListView.builder(
          controller: _scrollCtrl,
          padding: EdgeInsets.fromLTRB(28, topPad, 28, bottomPad),
          scrollCacheExtent: ScrollCacheExtent.pixels(200),
          addAutomaticKeepAlives: false,
          addRepaintBoundaries: true,
          itemCount: _lines.length,
          itemBuilder: (context, idx) {
            final line = _lines[idx];
            final isActive = idx == activeIndex;
            final isDragging = idx == _draggingIndex;
            final dist = (idx - activeIndex).abs();
            final inactiveAlpha = dist == 1
                ? 0.42
                : dist == 2
                    ? 0.28
                    : 0.16;
            final passed = idx < activeIndex;
            final blurSigma = (!_userInteracted && !isActive)
                ? math.min(1.0 + dist + (passed ? 1.0 : 0.0), 8.0)
                : 0.0;

            Widget lineChild = Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_showRomaji &&
                    line.romaji != null &&
                    line.romaji!.isNotEmpty) ...[
                  Text(
                    line.romaji!,
                    textAlign: _align,
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
                if (isActive && line.words.isNotEmpty)
                  RepaintBoundary(
                    child: ValueListenableBuilder<double>(
                      valueListenable: _progress,
                      builder: (context, pos, _) {
                        return Wrap(
                          alignment: switch (_align) {
                            TextAlign.left => WrapAlignment.start,
                            TextAlign.right => WrapAlignment.end,
                            _ => WrapAlignment.center,
                          },
                          children: [
                            for (final w in line.words)
                              _buildKaraokeWord(
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
                      fontSize: mainFont,
                      fontWeight: FontWeight.w700,
                      color: isDragging
                          ? Colors.white
                          : Colors.white
                              .withValues(alpha: isActive ? 1.0 : inactiveAlpha),
                      height: 1.35,
                      fontFamily: lyricFontFamily,
                    ),
                    child: Text(line.text, textAlign: _align),
                  ),
                if (_showTranslation &&
                    line.translation != null &&
                    line.translation!.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    line.translation!,
                    textAlign: _align,
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

            lineChild = AnimatedScale(
              scale: isActive ? 1.0 : 0.92,
              duration: const Duration(milliseconds: 320),
              curve: Curves.easeOutCubic,
              child: lineChild,
            );

            if (dist >= 1) {
              final steady = _blurSteady;
              final widthBucket = constraints.maxWidth.isFinite
                  ? constraints.maxWidth.round()
                  : 0;
              final snapKey =
                  _blurSnapshotKey(idx, blurSigma, mainFont, widthBucket);
              final snap = steady
                  ? (_blurSnapshots[snapKey] ??
                      _findFallbackSnapshot(
                          idx, blurSigma, mainFont, widthBucket))
                  : null;
              if (snap != null) {
                lineChild = RawImage(
                  image: snap.image,
                  width: snap.width,
                  height: snap.height,
                  fit: BoxFit.fill,
                );
              } else {
                if (steady) {
                  lineChild = RepaintBoundary(
                    key: _blurBoundaryKeys.putIfAbsent(idx, GlobalKey.new),
                    child: lineChild,
                  );
                  _scheduleBlurCapture(idx, snapKey, blurSigma);
                }
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

          if (_draggingIndex != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
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
                  Expanded(
                    child: Container(
                      height: 1,
                      color: Colors.white.withValues(alpha: 0.35),
                    ),
                  ),
                  const SizedBox(width: 10),
                  _DraggingPlayButton(onPressed: _seekToDraggingLine),
                ],
              ),
            ),
        ],
      ),
    );
  }

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
                      Slider(
                        value: value.toDouble(),
                        min: -500,
                        max: 500,
                        divisions: 100,
                        label: '${value}ms',
                        onChanged: (v) => apply(v.round(), setSheetState),
                      ),
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
}

/// 卡拉OK逐字渲染：word.start/end（秒）区间内按进度渐变着色，
/// 当前字有轻微上浮+放大动效。主歌词页与封面页预览小歌词共用。
Widget _buildKaraokeWord(
  _LyricWordItem word,
  double position,
  double fontSize,
  String? fontFamily,
) {
  final duration = math.max(0.001, word.end - word.start);
  final progress = ((position - word.start) / duration).clamp(0.0, 1.0);

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

                          _RailIconButton(
                            icon: Icons.format_size_rounded,
                            active: widget.fontSizeIdx != 1,
                            onTap: widget.onFontSize,
                          ),

                          _RailIconButton(
                            icon: Icons.translate_rounded,
                            active:
                                widget.showTranslation && widget.hasTranslation,
                            disabled: !widget.hasTranslation,
                            onTap: widget.onToggleTranslation,
                          ),

                          _RailIconButton(
                            icon: Icons.abc_rounded,
                            active: widget.showRomaji && widget.hasRomaji,
                            disabled: !widget.hasRomaji,
                            onTap: widget.onToggleRomaji,
                          ),

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
                    contentPadding: const EdgeInsets.only(
                        left: 16, top: 0, right: 12, bottom: 0),
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
                        SourceTag(
                          path: item.path,
                          isOnline: item.isOnline,
                          source: item.source,
                          onlineSongJson: item.onlineSongJson,
                        ),
                        const SizedBox(width: 4),
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

class _SheetSegmentButton extends StatelessWidget {
  const _SheetSegmentButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected
          ? scheme.primary.withValues(alpha: 0.14)
          : scheme.onSurface.withValues(alpha: 0.05),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: SizedBox(
          height: 34,
          child: Center(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: selected ? scheme.primary : scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _formatSleepRemaining(Duration d) {
  String two(int v) => v.toString().padLeft(2, '0');
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = d.inSeconds % 60;
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}

class _SleepTimerRow extends StatefulWidget {
  const _SleepTimerRow({
    required this.initialMinutes,
    required this.deadlineGetter,
    required this.onCommit,
    required this.onCancel,
  });

  final int initialMinutes;

  final DateTime? Function() deadlineGetter;

  final ValueChanged<int> onCommit;

  final VoidCallback onCancel;

  @override
  State<_SleepTimerRow> createState() => _SleepTimerRowState();
}

class _SleepTimerRowState extends State<_SleepTimerRow> {
  late int _value = widget.initialMinutes;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final deadline = widget.deadlineGetter();
    final active = deadline != null;
    final remaining = deadline?.difference(DateTime.now());
    final status = active
        ? (remaining == null || remaining.isNegative
            ? tr('即将暂停…')
            : tr('剩余 {t}', {'t': _formatSleepRemaining(remaining)}))
        : tr('{n} 分钟', {'n': _value});
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(tr('定时播放'),
                  style: TextStyle(
                      fontSize: 12, color: scheme.onSurfaceVariant)),
              const Spacer(),
              Text(
                status,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                  color: active ? scheme.primary : scheme.onSurfaceVariant,
                ),
              ),
              if (active)
                TextButton(
                  onPressed: () {
                    widget.onCancel();
                    setState(() {});
                  },
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 32),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(tr('取消'),
                      style:
                          TextStyle(fontSize: 12, color: scheme.primary)),
                ),
            ],
          ),
          CommittedSlider(
            value: _value.toDouble(),
            min: 1,
            max: 120,
            onChangeLive: (v) =>
                setState(() => _value = v.round().clamp(1, 120)),
            onCommit: (v) {
              widget.onCommit(v.round().clamp(1, 120));
              setState(() {});
            },
          ),
        ],
      ),
    );
  }
}

class _DislikeStrokePainter extends CustomPainter {
  final Color color;
  const _DislikeStrokePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(size.width * 0.14, size.height * 0.14),
      Offset(size.width * 0.86, size.height * 0.86),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _DislikeStrokePainter old) =>
      old.color != color;
}
