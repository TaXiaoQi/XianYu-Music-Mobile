part of 'player_page.dart';

class _MessageCircleIcon extends StatelessWidget {
  const _MessageCircleIcon({this.size = 24, this.color});

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
            PressableScale(child: GestureDetector(
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
            )),
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
      // cloud:// 曲目 isOnline 恒为 false（仅插件/直链源为 true），
      // 必须显式加入，否则网盘曲目永远走本地 DB 分支拿不到内嵌歌词
      if (item!.isOnline || item.path.startsWith('cloud://')) {
        final lines = _lyricLinesToViewItems(
          await ref.read(lyricsRepositoryProvider).fetchLyrics(item),
        );
        if (lines.isNotEmpty) _cacheLyrics(path, lines);
        if (!mounted) return;
        setState(() => _lines = lines);
        // 云盘曲目：内嵌歌词可能晚到（慢 CDN 首探 2 分钟级），插件搜索
        // 结果先显示；预探完成命中内嵌时再覆盖刷新（桌面同款行为）。
        if (item.path.startsWith('cloud://')) {
          unawaited(() async {
            final meta = await ref
                .read(cloudHeadMetaProvider.notifier)
                .waitFor(item.path, timeout: const Duration(minutes: 3));
            final raw = meta?.lyricsRaw;
            if (!mounted || raw == null || raw.trim().isEmpty) return;
            final emb = await compute(
              _parseLyricsJson,
              await parseLyrics(rawLyrics: raw),
            );
            if (!mounted || emb.isEmpty || path != widget.current?.path) return;
            _cacheLyrics(path, emb);
            setState(() => _lines = emb);
          }());
        }
      } else {
        final dbPath = await ref.read(dbPathProvider.future);
        final jsonStr = await getSongLyricsPayload(
          dbPath: dbPath,
          path: item.path,
        );
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
              rows.add(Positioned(top: y, left: 0, right: 0, child: lineChild));
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
  // 滚完一轮停留：停稳再开下一轮，避免无限连滚观感奇怪
  static const _pause = Duration(milliseconds: 1200);
  bool _pausing = false;
  Timer? _pauseTimer;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this)
      ..addListener(() {
        setState(() {});
        if (_controller.status == AnimationStatus.completed && !_pausing) {
          _pausing = true;
          _pauseTimer?.cancel();
          _pauseTimer = Timer(_pause, () {
            if (!mounted) return;
            _pausing = false;
            _controller.forward(from: 0);
          });
        }
      });
    _measure();
  }

  @override
  void didUpdateWidget(covariant _Marquee old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text || old.style != widget.style) {
      _pauseTimer?.cancel();
      _pausing = false;
      _controller.value = 0;
      _measure();
    }
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
    _pauseTimer?.cancel();
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
          _controller.duration = Duration(
            milliseconds: (seconds * 1000).round(),
          );
        }
        if (!_pausing && !_controller.isAnimating) {
          _controller.forward(from: _controller.value >= 1 ? 0 : null);
        }
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
                  left: dx,
                  top: 0,
                  child: Text(
                    widget.text,
                    maxLines: 1,
                    softWrap: false,
                    style: widget.style,
                  ),
                ),
                Positioned(
                  left: dx + _textWidth + _gap,
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
    final base = (prev != null && prev.path != next.path) ? prev : _record.item;
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
    final recent =
        at != null && DateTime.now().difference(at) < _switchCoverGrace;
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

class _TraditionalCover extends ConsumerWidget {
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
  Widget build(BuildContext context, WidgetRef ref) {
    return _AnimatedPlayerCover(
      current: current,
      // ref 经闭包传入（封面动画 builder 逐帧调 _buildCover）
      builder: (context, cur) => _buildCover(context, cur, ref),
    );
  }

  Widget _buildCover(BuildContext context, QueueItem? cur, WidgetRef ref) {
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
                // 云盘曲目：预探命中的内嵌封面优先（响应式，探测完成即刷新）
                thumbPath: cur.path.startsWith('cloud://')
                    ? (ref.watch(cloudHeadMetaProvider)[cur.path]?.coverPath ??
                        cur.coverPath)
                    : cur.coverPath,
                width: size,
                height: size,
                radius: 23,
                highQuality: true,
                cacheWidth: CoverImage.fullCoverDecodePx(),
                gradient: [
                  scheme.primary,
                  scheme.primary.withValues(alpha: 0.72),
                ],
              ),
            if (flash && playing)
              Positioned(left: 0, right: 0, bottom: 0, child: _EqStrip(eq: eq)),
          ],
        ),
      ),
    );

    if (onTap == null) return cover;
    return PressableScale(child: GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: cover,
    ));
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
          colors: [Colors.transparent, Colors.black.withValues(alpha: 0.45)],
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
                  height:
                      12 +
                      14 *
                          (0.5 + 0.5 * math.sin(t * 2 * math.pi * 2 + i * 0.8)),
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

/// 沉浸式封面：竖屏播放页顶部大幅清晰封面。
///
/// 与桌面端一致的「大图铺满 + 向下渐变」观感：封面自身透明度沿纵向递减
/// （dstIn 遮罩），自然过渡到下方的封面模糊底图，不做二次调色以避免偏色。
/// 顶部另叠一层轻微压暗，保证顶栏图标与标题在浅色封面上依旧可读。
class _ImmersiveCoverBackdrop extends StatelessWidget {
  const _ImmersiveCoverBackdrop({required this.current, required this.height});

  final QueueItem? current;
  final double height;

  @override
  Widget build(BuildContext context) {
    final item = current;
    return SizedBox(
      height: height,
      child: LayoutBuilder(
        builder: (context, cons) {
          final w = cons.maxWidth;
          final h = cons.maxHeight;
          return Stack(
            fit: StackFit.expand,
            children: [
              if (item != null)
                ShaderMask(
                  blendMode: BlendMode.dstIn,
                  shaderCallback: (rect) => const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.white, Colors.white, Colors.transparent],
                    stops: [0.0, 0.52, 1.0],
                  ).createShader(rect),
                  child: _AnimatedPlayerCover(
                    current: item,
                    role: 'immersive',
                    builder: (context, cur) => cur == null
                        ? const SizedBox.shrink()
                        : Hero(
                            tag: 'player-cover',
                            flightShuttleBuilder:
                                (ctx, animation, direction, fromCtx, toCtx) {
                                  final scheme = Theme.of(context).colorScheme;
                                  return PlayerCoverShuttle(
                                    animation: animation,
                                    songPath: cur.path,
                                    networkUrl: cur.coverUrl,
                                    fromRadius: 23,
                                    // 沉浸式封面为全宽直角图，飞行收尾圆角 0
                                    toRadius: 0,
                                    borderColor: Colors.white.withValues(
                                      alpha: 0.14,
                                    ),
                                    shadow: BoxShadow(
                                      color: Colors.black.withValues(
                                        alpha: 0.35,
                                      ),
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
                              // 沉浸式真封面即页面背景层（不可藏）：飞行
                              // 目标取锚点整块矩形，飞行期间背景保持可见
                              // （hideOnFly=false）；圆角 0 对齐全宽直角图；
                              // rectMorph 让副本飞行全程宽高形变到整块矩
                              // 形，落地即与真封面同位同形，淡出完成嵌入
                              hideOnFly: false,
                              targetRadius: 0,
                              rectMorph: true,
                              child: CoverReturnSource(
                                songPath: cur.path,
                                networkUrl: cur.coverUrl,
                                radiusHint: 0,
                                child: ValueListenableBuilder<bool>(
                                  valueListenable:
                                      FlyingCover.instance.targetHidden,
                                  builder: (context, hidden, _) =>
                                      AnimatedOpacity(
                                    // 正向飞行在途：封面图让位给飞行副本，
                                    // 上半屏露出页面级专辑取色底（与下半
                                    // 部分同源同色）；落地恢复淡入，与副本
                                    // 展开淡出同步——副本「嵌入」背景，全程
                                    // 单一封面。预测性返回同理由
                                    // CoverReturnSource 的 returning 隐藏
                                    // 真图，只留返回副本 + 取色底
                                    opacity: hidden ? 0 : 1,
                                    duration: hidden
                                        ? Duration.zero
                                        : const Duration(milliseconds: 300),
                                    curve: Curves.easeOut,
                                    child: CoverImage(
                                      songPath: cur.path,
                                      networkUrl: cur.coverUrl,
                                      width: w,
                                      height: h,
                                      radius: 0,
                                      highQuality: true,
                                      cacheWidth:
                                          CoverImage.fullCoverDecodePx(),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                  ),
                ),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0x66000000), Color(0x00000000)],
                    stops: [0.0, 0.32],
                  ),
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
    // 主题包定义了播放页壁纸：外层路由作用域（PageWallpaperScope）已垫
    // 不透明底 + 同图同参壁纸层，这里再垫会双层叠加（不透明度翻倍），
    // 本层退透明让外层壁纸透出即可
    final themed = ref.watch(themedPageWallpaperProvider);
    if (themed != null) {
      return const SizedBox.shrink();
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
              colors: [Color(0x0F000000), Color(0x00000000), Color(0x0F000000)],
            ),
          ),
          const _DecoratedGradient(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0x08000000), Color(0x00000000), Color(0x38000000)],
            ),
          ),
        ],
      ),
    );
  }

  Widget _blurCoverLayer(
    BuildContext context,
    QueueItem? item,
    ColorScheme scheme,
  ) {
    if (item == null) {
      return Container(color: Color.lerp(scheme.surface, Colors.black, 0.6));
    }
    final size = MediaQuery.of(context).size;
    const downscale = 8.0;
    final smallW = size.width / downscale;
    final smallH = size.height / downscale;
    const sigma = 50.0 / downscale;
    const toneMatrix = <double>[
      1.2039,
      -0.2717,
      -0.0274,
      0,
      -0.08,
      -0.0809,
      1.0131,
      -0.0274,
      0,
      -0.08,
      -0.0809,
      -0.2717,
      1.2575,
      0,
      -0.08,
      0,
      0,
      0,
      1,
      0,
    ];
    final coverChild = CoverImage(
      songPath: item.path,
      networkUrl: item.coverUrl,
      width: smallW,
      height: smallH,
      radius: 0,
      gradient: [scheme.primary, scheme.primary.withValues(alpha: 0.72)],
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
      child: SizedBox(width: smallW, height: smallH, child: inner),
    );
  }
}

class _DecoratedGradient extends StatelessWidget {
  const _DecoratedGradient({required this.gradient});

  final Gradient gradient;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(decoration: BoxDecoration(gradient: gradient));
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
                : Consumer(
                    builder: (context, ref, _) => CoverImage(
                      songPath: cur.path,
                      networkUrl: cur.coverUrl,
                      // 云盘曲目：预探命中的内嵌封面优先（响应式，探测完成即刷新）
                      thumbPath: cur.path.startsWith('cloud://')
                          ? (ref.watch(
                                  cloudHeadMetaProvider)[cur.path]?.coverPath ??
                              cur.coverPath)
                          : cur.coverPath,
                      width: coverSize,
                      height: coverSize,
                      radius: 31,
                      highQuality: true,
                      cacheWidth: CoverImage.fullCoverDecodePx(),
                      gradient: [
                        scheme.primary,
                        scheme.primary.withValues(alpha: 0.72),
                      ],
                    ),
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
