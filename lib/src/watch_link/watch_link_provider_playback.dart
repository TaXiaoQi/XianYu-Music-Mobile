part of 'watch_link_provider.dart';

extension WatchLinkControllerPlayback on WatchLinkController {
  // ---- 状态推送 ----

  void _onPlayback(PlaybackState st) {
    if (st.isPlaying && !_lastSeenPlaying) _maybeAutoWakeWatch();
    _lastSeenPlaying = st.isPlaying;
    if (!_connected && !_cloudWatchOnline) return;
    final item = st.current;
    final key = item == null
        ? null
        : '${item.path}|${item.title}|${item.artist}|${item.durationMs}';
    final wasPlaying = _lastPlaying;
    final isPlaying = st.isPlaying;
    final prevKey = _songKey;
    _lastPlaying = isPlaying;
    _songKey = key;

    if (isPlaying && !wasPlaying) {
      if (_transferActive) {
        _pushSnapshot();
      } else {
        _onPlaybackStart();
      }
      return;
    }
    if (!isPlaying && wasPlaying && _transferActive) {
      _pushState();
      if (key != prevKey && item != null) {
        _pushNowPlayingBlock(st, item);
      }
      _transferActive = false;
      _sessionDenied = false;
      return;
    }
    if (!_transferActive) return;

    if (key != prevKey) {
      if (item != null) _pushNowPlayingBlock(st, item);
      return;
    }
    final mode = linkPlayModeFromInt(st.playMode);
    if (isPlaying != wasPlaying ||
        mode != _lastMode ||
        _likedOf(item) != _lastLiked) {
      _lastMode = mode;
      _lastLiked = _likedOf(item);
      _pushState();
    }
    if (isPlaying) {
      final now = DateTime.now();
      if (now.difference(_lastPosPush) >= const Duration(milliseconds: 900)) {
        _lastPosPush = now;
        _send(LinkMessage.position(pos: st.position, duration: st.duration));
      }
    }
  }

  Future<void> _maybeAutoWakeWatch() async {
    if (_wakeInFlight) return;
    final s = _container.read(settingsProvider).valueOrNull;
    if (s?.watchLinkageEnabled != true) {
      AppLog.info('watch_link', '起播自动唤起跳过: 联动开关未开启');
      return;
    }
    if (_connected || _cloudWatchOnline) {
      AppLog.debug('watch_link', '起播自动唤起跳过: 腕上端已在线');
      return;
    }
    final now = DateTime.now();
    if (now.difference(_lastWakeAttempt) < WatchLinkController._wakeRetryGap) {
      AppLog.debug('watch_link', '起播自动唤起跳过: 冷却中');
      return;
    }
    _lastWakeAttempt = now;
    _wakeInFlight = true;
    try {
      final r = await _channel.wearWake();
      if (r.ok) {
        AppLog.info('watch_link',
            '起播自动唤起: ok=true code=${r.code} ${r.message}');
      } else {
        AppLog.warn('watch_link',
            '起播自动唤起失败: code=${r.code} ${r.message}');
      }
      if (r.ok && r.code == 201) {
        final ctx = appNavigatorKey.currentContext;
        if (ctx != null && ctx.mounted) {
          showXianYuToast(ctx, tr('已拉起腕上端'),
              duration: const Duration(seconds: 2));
        }
      }
    } finally {
      _wakeInFlight = false;
    }
  }

  void _pushNowPlayingBlock(PlaybackState st, QueueItem item) {
    _send(LinkMessage.nowPlaying(
      id: item.path,
      title: item.title,
      artist: item.artist,
      album: item.album,
      cover: _coverOf(item),
      duration: st.duration,
      daily: item.fromDailyRecommend,
    ));
    _maybePushCoverData(item);
    _send(LinkMessage.state(
      isPlaying: st.isPlaying,
      playMode: _lastMode,
      liked: _lastLiked,
      volume: _volumeOf(),
      mvPhase: _mvPhaseText(),
    ));
    _lastPosPush = DateTime.now();
    _send(LinkMessage.position(pos: st.position, duration: st.duration));
    _maybePushLyric();
    _maybePrecacheNext();
  }

  void _onPlaybackStart() {
    final s = _container.read(settingsProvider).valueOrNull;
    final mode = s?.watchLinkTransferMode ?? 'ask';
    if (mode == 'remember') {
      if (s?.watchLinkAutoTransfer == true) {
        _transferActive = true;
        _pushSnapshot();
      }
      return;
    }
    switch (_dayGrantOf(s)) {
      case true:
        _transferActive = true;
        _pushSnapshot();
      case false:
        break;
      case null:
        if (_needsAsk(s)) _askTransfer();
    }
  }

  String _today() {
    final n = DateTime.now();
    return '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
  }

  bool? _dayGrantOf(AppSettings? s) {
    if (s == null || s.watchLinkAskDate != _today()) return null;
    return s.watchLinkAskGranted;
  }

  bool _needsAsk(AppSettings? s) =>
      !_transferActive && !_sessionDenied && _dayGrantOf(s) == null;

  Future<void> _playGate() async {
    if (!_connected && !_cloudWatchOnline) return;
    final s = _container.read(settingsProvider).valueOrNull;
    if ((s?.watchLinkTransferMode ?? 'ask') != 'ask') return;
    if (!_needsAsk(s)) return;
    await _askTransfer();
  }

  Future<void> _askTransfer() async {
    if (_askInFlight != null) return _askInFlight;
    final context = appNavigatorKey.currentContext;
    if (context == null || !context.mounted) return;
    final task = _doAskTransfer();
    _askInFlight = task;
    try {
      await task;
    } finally {
      _askInFlight = null;
    }
  }

  Future<void> _doAskTransfer() async {
    final context = appNavigatorKey.currentContext;
    if (context == null || !context.mounted) return;
    final result = await showTransferConfirmDialog(
      context,
      watchName: _connectedName.isNotEmpty ? _connectedName : _cloudWatchName,
    );
    switch (result) {
      case 'device':
        await _container
            .read(settingsProvider.notifier)
            .setWatchLinkTransferRemembered(autoTransfer: true);
        _transferActive = true;
        _pushSnapshot();
      case 'once':
        _transferActive = true;
        _pushSnapshot();
      case 'never':
        await _container
            .read(settingsProvider.notifier)
            .setWatchLinkAskChoice(date: _today(), granted: false);
      default:
        _sessionDenied = true;
    }
  }

}
