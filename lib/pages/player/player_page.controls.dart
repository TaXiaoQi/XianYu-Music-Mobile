part of 'player_page.dart';

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

class _BlurredCoverBackground extends ConsumerWidget {
  const _BlurredCoverBackground({required this.current});

  final QueueItem? current;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    // 主题包定义了播放页壁纸：整层替换封面模糊背景（静图，含遮罩/缩放参数）
    final themed = ref.watch(themedPageWallpaperProvider);
    if (themed != null) {
      return RepaintBoundary(
        child: CustomBackgroundLayer(background: themed),
      );
    }
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
                onPressed: () => ref.read(favoritesProvider.notifier).toggle(current),
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
                  constraints: const BoxConstraints(minWidth: 40, minHeight: 36),
                  padding: EdgeInsets.zero,
                  icon: themeSlotIcon(
                    ref,
                    'action.download',
                    fallback: Icons.download_outlined,
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

  bool get known => codecLabel.isNotEmpty || sourceRate > 0 || sourceBits != null;

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
  final sel = ref.watch(playerProvider.select((s) => (
        s.usbExclusive,
        s.dspActive,
        s.outSampleRate,
        s.outChannels,
        s.outBitPerfect,
      )));
  var codec = '';
  var rate = 0;
  int? bits;
  if (item != null) {
    if (item.isOnline) {
      final q = (item.onlineQuality ?? '').trim();
      codec = q.isEmpty ? tr('在线') : '${tr('在线')} ${_qualityLabel(q)}';
    } else {
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
          Expanded(child: Center(child: IconButton(iconSize: 28, icon: themeSlotIcon(ref, 'player.queue', fallback: Icons.queue_music, size: 28, color: scheme.onSurfaceVariant), onPressed: () => _showQueueSheet(context, ref)))),
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
              : themeSlotIcon(
                  ref,
                  'action.download',
                  fallback: dlDone
                      ? Icons.check_circle_outline
                      : Icons.download_outlined,
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
          icon: themeSlotIcon(
            ref,
            'action.favorite',
            fallback: isFav ? Icons.favorite : Icons.favorite_border,
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
          icon: themeSlotWidget(
            ref,
            'player.mode',
            size: 28,
            fallback: _PlayModeIcon(mode: playMode, color: idle, size: 28),
          ),
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
          onPressed: mvRequested
              ? null
              : () => playerNavigatorKey.currentState?.push(
                    coverPageRoute<void>(context, (_) => const EffectsPage()),
                  ),
        ),
        IconButton(
          iconSize: 28,
          icon: themeSlotIcon(ref, 'player.queue',
              fallback: Icons.queue_music, size: 28, color: idle),
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
        title:   Text(tr('桌面歌词需要悬浮窗权限')),
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
