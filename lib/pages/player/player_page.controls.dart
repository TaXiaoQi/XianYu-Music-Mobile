part of 'player_page.dart';

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
        (s) => performancePriority(s.valueOrNull ?? const AppSettings()),
      ),
    );
    final playerLiquid =
        (ref.watch(
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
          ? Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: Text(tr('暂无播放'))),
            )
          : landscape
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                RepaintBoundary(
                  child: _ProgressBar(notifier: notifier, showTime: false),
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
                RepaintBoundary(child: _ProgressBar(notifier: notifier)),
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
        ? wallpaperGlassFill(context, ref)
        : (isDark
              ? Colors.white.withValues(alpha: 0.08)
              : Colors.white.withValues(alpha: 0.6));

    final sigma = wallpaperGlassActive(ref)
        ? navSurfaceBlurSigma(ref)
        : surfaceBlurSigma(
            base: 15,
            budget: budget,
            type: BlurSurfaceType.drawerOrSheet,
          );
    // 静态帧：转场/动画帧不重绘玻璃层，防 saveLayer 内重采样闪黑
    return RepaintBoundary(
      child: ClipRRect(
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
    final chain = _resolveAudioChain(ref, current);
    final isFav = ref.watch(favoritesProvider).contains(current.path);
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
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 4,
                    ),
                    child: Text(
                      mvQualityShown
                          ? mvQuality
                          : _qualityLabel(currentQuality),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.5,
                        color:
                            (mvQualityShown ||
                                (currentQuality != null &&
                                    isLosslessQuality(currentQuality)))
                            ? scheme.primary
                            : const Color(0xFFEC4141).withValues(alpha: 0.9),
                      ),
                    ),
                  ),
                ),
              if (chain.known) ...[
                const SizedBox(width: 6),
                _AudioFormatBadge(chain: chain, dense: true),
              ],
              const SizedBox(width: 4),
              InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: mvRequested
                    ? null
                    : () => _toggleFloatingLyrics(context, ref, lyricsEnabled),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 4,
                  ),
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
                icon: themeSlotIcon(
                  ref,
                  'action.favorite',
                  fallback: isFav ? Icons.favorite : Icons.favorite_border,
                  size: 22,
                  color: isFav
                      ? const Color(0xFFEC4141)
                      : Colors.white.withValues(alpha: 0.85),
                ),
                tooltip: tr('收藏'),
                onPressed: () =>
                    ref.read(favoritesProvider.notifier).toggle(current),
              ),
              IconButton(
                constraints: const BoxConstraints(minWidth: 40, minHeight: 36),
                padding: EdgeInsets.zero,
                icon: themeSlotIcon(
                  ref,
                  'action.share',
                  fallback: Icons.ios_share,
                  size: 22,
                  color: Colors.white.withValues(alpha: 0.85),
                ),
                tooltip: tr('分享歌曲'),
                onPressed: () => _shareCurrent(context, ref, current),
              ),
              if (current.isOnline)
                IconButton(
                  constraints: const BoxConstraints(
                    minWidth: 40,
                    minHeight: 36,
                  ),
                  padding: EdgeInsets.zero,
                  icon: themeSlotIcon(
                    ref,
                    'action.download',
                    fallback: Icons.download_outlined,
                    size: 22,
                    color: Colors.white.withValues(alpha: 0.85),
                  ),
                  tooltip: tr('下载歌曲'),
                  onPressed: () =>
                      _showDownloadQualitySheet(context, ref, current),
                ),
              if (current.isOnline)
                IconButton(
                  constraints: const BoxConstraints(
                    minWidth: 40,
                    minHeight: 36,
                  ),
                  padding: EdgeInsets.zero,
                  icon: themeSlotIcon(
                    ref,
                    'player.comment',
                    fallback: Icons.mode_comment_outlined,
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
  BuildContext context,
  WidgetRef ref,
  QueueItem current,
) async {
  await showSongShareSheet(context, ref: ref, song: current);
}

void _showQualitySheet(BuildContext context, WidgetRef ref) {
  final mv = ref.read(mvProvider);
  if (mv.requested) {
    showSheetDialog<void>(context, (_) => const _MvQualitySheet());
    return;
  }
  final notifier = ref.read(playerProvider.notifier);
  showSheetDialog<void>(context, (_) => _QualitySheet(notifier: notifier));
}

void _showDownloadQualitySheet(
  BuildContext context,
  WidgetRef ref,
  QueueItem song,
) {
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

String _fmtKhz(int rate) {
  final k = rate % 1000 == 0
      ? '${rate ~/ 1000}'
      : (rate / 1000).toStringAsFixed(1);
  return '${k}kHz';
}


/// 当前播放链路的音频格式快照：源文件格式 + Rust 管线实际输出格式。
///
/// 源格式取自曲库扫描结果（`sample_rate`/`bit_depth`/`codec`），输出格式取自
/// AAudio 流的真实参数，所以能判断出「有没有被重采样」以及是否 bit-perfect。

class _AudioChain {
  const _AudioChain({
    required this.codecLabel,
    required this.sourceRate,
    required this.sourceBits,
    required this.outRate,
    required this.outChannels,
    required this.bitPerfect,
    required this.exclusive,
    required this.dspActive,
  });

  final String codecLabel;
  final int sourceRate;
  final int? sourceBits;
  final int outRate;
  final int outChannels;
  final bool bitPerfect;
  final bool exclusive;
  final bool dspActive;

  bool get known =>
      codecLabel.isNotEmpty || sourceRate > 0 || sourceBits != null;

  /// 是否走 Rust 管线（USB 独占或共享 DSP），否则是系统播放器。
  bool get rustEngine => exclusive || dspActive;

  /// 输出采样率与源不一致即发生重采样。
  bool get resampled =>
      rustEngine && outRate > 0 && sourceRate > 0 && outRate != sourceRate;

  /// 源格式短标签：`FLAC 24bit/96kHz`、`MP3 44.1kHz`、`在线 320K`
  String get sourceLabel {
    final parts = <String>[];
    if (codecLabel.isNotEmpty) parts.add(codecLabel);
    if (sourceRate > 0 && sourceBits != null) {
      parts.add('${sourceBits}bit/${_fmtKhz(sourceRate)}');
    } else if (sourceRate > 0) {
      parts.add(_fmtKhz(sourceRate));
    } else if (sourceBits != null) {
      parts.add('${sourceBits}bit');
    }
    return parts.join(' ');
  }

  /// 输出格式短标签：`96kHz 立体声`
  String get outLabel {
    if (outRate <= 0) return '';
    final ch = switch (outChannels) {
      1 => ' 单声道',
      2 => ' 立体声',
      _ => '',
    };
    return '${_fmtKhz(outRate)}$ch';
  }

  /// 状态短标签：`直出` / `重采样` / `独占输出` / `音效引擎` / `系统混音`
  String get statusLabel {
    if (!rustEngine) return tr('系统混音');
    if (bitPerfect) return tr('直出');
    if (resampled) return tr('重采样');
    return exclusive ? tr('独占输出') : tr('音效引擎');
  }

  /// 徽标上的单行摘要。
  String get badge => rustEngine
      ? [sourceLabel, statusLabel].where((e) => e.isNotEmpty).join(' · ')
      : sourceLabel;
}

/// 组装当前音频链路快照。只在曲目或输出参数变化时触发重建，
/// 不被 250ms 的进度轮询带着刷。
_AudioChain _resolveAudioChain(WidgetRef ref, QueueItem? item) {
  final sel = ref.watch(
    playerProvider.select(
      (s) => (
        s.usbExclusive,
        s.dspActive,
        s.outSampleRate,
        s.outChannels,
        s.outBitPerfect,
      ),
    ),
  );
  var codec = '';
  var rate = 0;
  int? bits;
  if (item != null) {
    if (!item.isOnline) {
      final song = ref.watch(songByPathProvider.select((m) => m[item.path]));
      if (song != null) {
        codec = (song.codec ?? song.format).toUpperCase().trim();
        rate = song.sampleRate;
        bits = song.bitDepth;
      } else {
        // 不在曲库里的本地/远程文件：退到扩展名，至少能显示容器类型
        final dot = item.path.lastIndexOf('.');
        if (dot > 0 && dot < item.path.length - 1) {
          codec = item.path.substring(dot + 1).toUpperCase();
        }
      }
    }
  }
  return _AudioChain(
    codecLabel: codec,
    sourceRate: rate,
    sourceBits: bits,
    outRate: sel.$3,
    outChannels: sel.$4,
    bitPerfect: sel.$5,
    exclusive: sel.$1,
    dspActive: sel.$2,
  );
}


/// 紧凑的音频格式徽标：`FLAC 24bit/96kHz · 直出`。

class _AudioFormatBadge extends StatelessWidget {
  const _AudioFormatBadge({required this.chain, this.dense = false});

  final _AudioChain chain;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    if (!chain.known || chain.badge.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final color = chain.bitPerfect
        ? scheme.primary
        : chain.resampled
        ? Colors.white.withValues(alpha: 0.62)
        : Colors.white.withValues(alpha: 0.80);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 7 : 9,
        vertical: dense ? 2 : 3,
      ),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        chain.badge,
        style: TextStyle(
          fontSize: dense ? 10 : 11,
          fontWeight: FontWeight.w600,
          color: color,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}


/// 音质弹层里的「当前音频」只读区块：源 / 输出 / 引擎。

class _AudioChainPanel extends StatelessWidget {
  const _AudioChainPanel({required this.chain});

  final _AudioChain chain;

  @override
  Widget build(BuildContext context) {
    if (!chain.known) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final engine = chain.exclusive
        ? (chain.bitPerfect ? tr('USB 独占 · bit-perfect 直出') : tr('USB 独占输出'))
        : chain.dspActive
        ? tr('Rust DSP 共享管线')
        : tr('系统播放器（未走音效引擎）');
    final rows = <(String, String)>[
      (tr('源格式'), chain.sourceLabel.isEmpty ? tr('未知') : chain.sourceLabel),
      if (chain.rustEngine)
        (
          tr('输出'),
          chain.outLabel.isEmpty
              ? tr('未知')
              : '${chain.outLabel} · ${chain.statusLabel}',
        ),
      (tr('引擎'), engine),
    ];
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 4, 20, 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.22)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.graphic_eq, size: 15, color: scheme.primary),
              const SizedBox(width: 6),
              Text(
                tr('当前音频'),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: scheme.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final (label, value) in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 56,
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      value,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface,
                      ),
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
  String preferred,
  List<String> available,
  String behavior,
) {
  if (available.isEmpty || available.contains(preferred)) return preferred;
  int rank(String q) {
    final i = kQualityLadder.indexOf(q);
    return i < 0 ? kQualityLadder.length : i;
  }

  final prefRank = rank(preferred);
  final sorted = [...available]..sort((a, b) => rank(a).compareTo(rank(b)));
  if (behavior == 'higher') {
    return sorted.firstWhere(
      (q) => rank(q) > prefRank,
      orElse: () => sorted.last,
    );
  }
  return sorted.reversed.firstWhere(
    (q) => rank(q) < prefRank,
    orElse: () => sorted.first,
  );
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
    final mvCtrl = ref.watch(
      mvProvider.select(
        (s) => (s.audioTakenOver && s.ready) ? s.controller : null,
      ),
    );
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
                    fontSize: 11,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                Text(
                  hasDuration ? _fmt(dur) : '--:--',
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant,
                  ),
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
          Expanded(
            child: Center(
              child: IconButton(
                iconSize: 28,
                icon: themeSlotWidget(
                  ref,
                  'player.mode',
                  size: 28,
                  fallback: _PlayModeIcon(
                    mode: playMode,
                    color: scheme.onSurfaceVariant,
                    size: 28,
                  ),
                ),
                onPressed: notifier.cyclePlayMode,
              ),
            ),
          ),
          Expanded(
            child: Center(
              child: IconButton(
                iconSize: 28,
                icon: const Icon(Icons.skip_previous),
                onPressed: notifier.previous,
              ),
            ),
          ),
          Expanded(
            child: Center(
              child: Container(
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
              ),
            ),
          ),
          Expanded(
            child: Center(
              child: IconButton(
                iconSize: 28,
                icon: const Icon(Icons.skip_next),
                onPressed: notifier.next,
              ),
            ),
          ),
          Expanded(
            child: Center(
              child: IconButton(
                iconSize: 28,
                icon: themeSlotIcon(
                  ref,
                  'player.queue',
                  fallback: Icons.queue_music,
                  size: 28,
                  color: scheme.onSurfaceVariant,
                ),
                onPressed: () => _showQueueSheet(context, ref),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showQueueSheet(BuildContext context, WidgetRef ref) {
    showSheetDialog<void>(
      context,
      (_) => _QueueSheet(player: ref.read(playerProvider)),
    );
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
        Offset((size.width - tp.width) / 2, (size.height - tp.height) / 2),
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
        title: Text(tr('桌面歌词需要悬浮窗权限')),
        content: Text(tr('开启后歌词窗可显示在其他应用上层。需要前往系统设置授予「显示在其他应用上层」权限。')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('取消')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('去授权')),
          ),
        ],
      ),
    );
    if (go == true) {
      // 不立即切换开关：跳系统设置，回前台后由控制器复检权限，
      // 授权成功才开启；被拦截则保持关闭
      await ref
          .read(floatingLyricsControllerProvider)
          .requestEnableViaSettings();
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
      final translation = rawTrans != null ? _cleanLyricText(rawTrans) : null;

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
              words.add(_LyricWordItem(text: wText, start: wStart, end: wEnd));
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
  bool shouldRepaint(covariant _DislikeStrokePainter old) => old.color != color;
}
