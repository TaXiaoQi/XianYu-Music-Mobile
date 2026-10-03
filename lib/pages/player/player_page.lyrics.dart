part of 'player_page.dart';

class _LyricsAdjustDialog extends ConsumerStatefulWidget {
  const _LyricsAdjustDialog({required this.hasRomaji, required this.showAlign});

  final bool hasRomaji;
  final bool showAlign;

  @override
  ConsumerState<_LyricsAdjustDialog> createState() =>
      _LyricsAdjustDialogState();
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
            _LyricAdjustPanel.main => _buildMain(
              context,
              scheme,
              align,
              notifier,
            ),
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
            context,
            align,
            notifier,
          ),
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
                        fontWeight: current == i
                            ? FontWeight.w700
                            : FontWeight.w500,
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
            Icon(Icons.font_download_outlined, size: 18, color: scheme.outline),
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
          style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
        ),
        Text(
          tr('蓝牙耳机存在固有延迟，歌词提前时请向"延后"方向调节'),
          style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
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
          children: ['-200', '-100', '-10', '-1', '+1', '+10', '+100', '+200']
              .map((label) {
                final step = int.parse(label);
                return _LyricsViewState._offsetStepChip(
                  context,
                  label,
                  scheme,
                  () => notifier.setLyricOffsetMs(
                    (value + step).clamp(-2000, 2000),
                  ),
                );
              })
              .toList(),
        ),
      ],
    );
  }
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

  // ---- RwaS 换行拽动 ----
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

  // ==================== 模糊行静态烘焙缓存 ====================

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
    int index,
    double sigma,
    double mainFont,
    int widthBucket,
  ) {
    return '${widget.current?.path}|$index|s${sigma.toStringAsFixed(1)}'
        '|f${mainFont.toStringAsFixed(1)}|w$widthBucket'
        '|t${_showTranslation ? 1 : 0}|r${_showRomaji ? 1 : 0}'
        '|a${_align.index}';
  }

  _BlurredLineSnapshot? _findFallbackSnapshot(
    int index,
    double sigma,
    double mainFont,
    int widthBucket,
  ) {
    final pathPrefix = '${widget.current?.path}|$index|';
    final tail =
        '|f${mainFont.toStringAsFixed(1)}|w$widthBucket'
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
      _BlurCaptureTask(index: index, key: key, sigma: sigma),
    );
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
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _pumpBlurCaptures(),
          );
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
    final dpr = MediaQuery.of(
      context,
    ).devicePixelRatio.clamp(1.0, 2.0).toDouble();
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
        ..imageFilter = ImageFilter.blur(
          sigmaX: task.sigma,
          sigmaY: task.sigma,
        ),
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
    final onlineJsonChanged =
        oldWidget.current?.onlineSongJson != widget.current?.onlineSongJson;
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

  // ==================== RwaS 换行拽动 ====================

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
        offset = (contribution - _pullDistance * itemE).clamp(
          0.0,
          double.infinity,
        );
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

  // ==================== 拖动选行播放 ====================

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
        _lastActiveIndex = -1;
        _renderActiveIndex = -1;
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
        final repoLines = await ref
            .read(lyricsRepositoryProvider)
            .fetchLyrics(item);
        final viewLines = _lyricLinesToViewItems(repoLines);
        if (viewLines.isNotEmpty && mounted) {
          _cacheLyrics(item.path, viewLines);
          setState(() {
            _lines = viewLines;
            _loading = false;
          });
          _reportRomaji();
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
        final target = (maxScroll * idx / (_lines.length - 1)).clamp(
          0.0,
          maxScroll,
        );
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
    final target = (layout.$1 + layout.$2 / 2 - viewport / 2).clamp(
      0.0,
      _scrollCtrl.position.maxScrollExtent,
    );
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
      targetOffset =
          maxScroll *
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
      final typicalH =
          mainFont * 1.35 +
          (_showRomaji ? romajiFont * 1.2 + 5 : 0) +
          (_showTranslation ? transFont * 1.35 + 6 : 0);
      content = LayoutBuilder(
        builder: (context, constraints) {
          final viewport = constraints.maxHeight;
          if (_lastViewportHeight != null &&
              (_lastViewportHeight! - viewport).abs() > 1) {
            final widthChanged =
                _lastViewportWidth != null &&
                (_lastViewportWidth! - constraints.maxWidth).abs() > 1;
            _viewportChangeDebounce?.cancel();
            _viewportChangeDebounce = Timer(
              const Duration(milliseconds: 350),
              () {
                if (!mounted) return;
                if (widthChanged) _lineLayouts.clear();
                _pendingCenterJump = true;
                _pendingCenterFallback?.cancel();
                _tryPendingCenterJump();
              },
            );
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
                              : Colors.white.withValues(
                                  alpha: isActive ? 1.0 : inactiveAlpha,
                                ),
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
                              : Colors.white.withValues(
                                  alpha: isActive ? 0.58 : 0.34,
                                ),
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
                  final snapKey = _blurSnapshotKey(
                    idx,
                    blurSigma,
                    mainFont,
                    widthBucket,
                  );
                  final snap = steady
                      ? (_blurSnapshots[snapKey] ??
                            _findFallbackSnapshot(
                              idx,
                              blurSigma,
                              mainFont,
                              widthBucket,
                            ))
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
                                  sigmaX: sigma,
                                  sigmaY: sigma,
                                ),
                                child: child,
                              ),
                        child: lineChild,
                      );
                    } else {
                      lineChild = blurSigma <= 0.1
                          ? lineChild
                          : ImageFiltered(
                              imageFilter: ImageFilter.blur(
                                sigmaX: blurSigma,
                                sigmaY: blurSigma,
                              ),
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
                    return Transform.translate(
                      offset: Offset(0, dy),
                      child: child,
                    );
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
                  style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
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
                  child: Text(tr('重置')),
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
          Shadow(color: Colors.white.withValues(alpha: 0.35), blurRadius: 10),
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

    // 静态帧：转场/动画帧不重绘玻璃层，防 saveLayer 内重采样闪黑
    return RepaintBoundary(
      child: ClipRRect(
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
                                  widget.showTranslation &&
                                  widget.hasTranslation,
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
        label: Text(tr('选择字体')),
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
          label: Text(tr('恢复默认')),
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
