part of 'player_page.dart';

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
        (s) => s.valueOrNull?.floatingLyricsEnabled ?? false,
      ),
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
    final dlActive =
        item != null &&
        dl.tasks.any(
          (t) =>
              t.songPath == item.path &&
              (t.status == DownloadStatus.waiting ||
                  t.status == DownloadStatus.downloading),
        );
    final dlDone =
        item != null &&
        (isLocal || dl.history.any((h) => h.songPath == item.path));
    final isFav =
        item != null &&
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
            '${fmtTime(position)} / ${dur <= 0 ? '--:--' : fmtTime(dur)}'
                .trimRight(),
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
          icon: themeSlotIcon(
            ref,
            'player.queue',
            fallback: Icons.queue_music,
            size: 28,
            color: idle,
          ),
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

