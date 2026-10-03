part of 'player_page.dart';

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
      final probing = ref.read(
        playerProvider.select((s) => s.qualityMenuProbing),
      );
      if (!probing && (sizes.isNotEmpty || i > 0)) return;
      await Future.delayed(const Duration(milliseconds: 600));
    }
  }

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
            _AudioChainPanel(
              chain: _resolveAudioChain(
                ref,
                ref.watch(playerProvider.select((s) => s.current)),
              ),
            ),
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
                final shown = kQualityLadder.reversed
                    .where(combined.contains)
                    .toList();
                // 探测中或体积结果未就绪时不过滤
                final probing = ref.watch(
                  playerProvider.select((s) => s.qualityMenuProbing),
                );
                final sizes = _sizes;
                final visible = probing || sizes.isEmpty
                    ? shown
                    : dropFakeQualities(shown, {
                        if (cur != null && cur.isNotEmpty) cur,
                      });
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
                                  // 挂着等结果
                                  final overlay = Overlay.of(
                                    ctx,
                                    rootOverlay: true,
                                  );
                                  Navigator.of(ctx).pop();
                                  final ok = await widget.notifier
                                      .switchQuality(q);
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
      final source = await mvNotifier.resolveDownloadSource(widget.song, q.key);
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
      showXianYuToastByOverlay(overlay, tr('MV 下载失败：{e}', {'e': e.toString()}));
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
                child: Center(child: Text(tr('暂无可下载画质'))),
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
                        onTap: _downloading
                            ? () {}
                            : () => _download(context, q),
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

class _DownloadQualitySheetState extends ConsumerState<_DownloadQualitySheet>
    with _QualitySheetProbeState<_DownloadQualitySheet> {
  @override
  PlayerNotifier get sheetNotifier => widget.notifier;

  @override
  Future<List<String>> loadQualityOptions() =>
      widget.notifier.downloadQualityOptions();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final playingPath = ref.watch(
      playerProvider.select((s) => s.current?.path),
    );
    final cur = ref.watch(playerProvider.select((s) => s.currentQuality));
    final settings = ref.watch(settingsProvider.select((s) => s.valueOrNull));
    final isPlayingSong =
        widget.song.path.isNotEmpty &&
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
                final probing = ref.watch(
                  playerProvider.select((s) => s.qualityMenuProbing),
                );
                final shown = probing || _sizes.isEmpty || !isPlayingSong
                    ? probed
                    : dropFakeQualities(probed, {cur});
                final sizes = _sizes;
                final defaultQ = _nearestAvailable(
                  initial,
                  shown,
                  fallbackBehavior,
                );
                final options = shown.isNotEmpty ? shown : const <String>[''];
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
                          isSelected: shown.isEmpty ? true : q == defaultQ,
                          onTap: () async {
                            final overlay = Overlay.of(ctx, rootOverlay: true);
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
                                'quality': _qualityLabel(q.isEmpty ? null : q),
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

void _seekAudioWithMv(WidgetRef ref, PlayerNotifier notifier, double secs) {
  notifier.seek(secs);
  ref.read(mvProvider.notifier).alignToAudioSeconds(secs);
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
                          await ref.read(playerProvider.notifier).clearQueue();
                        } catch (e) {
                          AppLog.warn('ui', '清空播放队列失败: $e');
                        }
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
                      left: 16,
                      top: 0,
                      right: 12,
                      bottom: 0,
                    ),
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
              Text(
                tr('定时播放'),
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
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
                  child: Text(
                    tr('取消'),
                    style: TextStyle(fontSize: 12, color: scheme.primary),
                  ),
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
