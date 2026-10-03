part of 'player_provider.dart';

extension PlayerNotifierCast on PlayerNotifier {
  // ---------------- DLNA 投屏支持 ----------------

  Future<void> pauseLocalEngine() async {
    _flushPlayStats();
    try {
      await _stopExclusive();
    } catch (e) {
      AppLog.warn('player', '停止独占失败: $e');
    }
    try {
      await _player.pause();
    } catch (e) {
      AppLog.warn('player', '暂停播放器失败: $e');
    }
    state = state.copyWith(isPlaying: false);
    _syncToSystemMediaSession();
  }

  void syncCastPosition(double pos, double dur, bool playing) {
    if (state.current == null) return;
    state = state.copyWith(
      position: pos < 0 ? 0 : pos,
      duration: dur > 0.5 ? dur : null,
      isPlaying: playing,
    );
  }

  Future<void> playExternalUri({
    required String uri,
    required String title,
    String artist = '',
    String album = '',
    int durationMs = 0,
    String coverUrl = '',
    String lyricUrl = '',
  }) async {
    await _stopExclusive();
    _playEpoch++;
    _flushPlayStats();
    _currentPlayCountRecorded = false;
    _accumulatedTime = 0;
    _restoredOnlinePending = null;
    _restoredLocalPending = null;
    if (_activeProbeKey != null) {
      onlineQualityProbeRegistry.invalidate(_activeProbeKey!);
      _activeProbeKey = null;
    }
    final item = QueueItem(
      path: uri,
      title: title.isEmpty ? tr('DLNA 投放') : title,
      artist: artist,
      album: album,
      durationMs: durationMs,
      coverUrl: coverUrl.isEmpty ? null : coverUrl,
      lyricUrl: lyricUrl.isEmpty ? null : lyricUrl,
    );
    state = state.copyWith(
      queue: [item],
      queueIndex: 0,
      current: item,
      isPlaying: false,
      position: 0,
      duration: durationMs / 1000.0,
      resolving: false,
      error: null,
    );
    _syncToSystemMediaSession();
    try {
      // 被投播放按 DLNA 语义强制原速：DSP 管线与 ExoPlayer 均不吃
      // 本机音效里的变速/变调设置，否则桌面端原速音频会被加速播放
      await _startOnlineUrl(uri, item: item, castPlayback: true);
      state = state.copyWith(isPlaying: true);
      _trackStartTime = DateTime.now();
      _syncToSystemMediaSession();
    } catch (e) {
      state = state.copyWith(
        isPlaying: false,
        error: tr('播放失败：{e}', {'e': e.toString()}),
      );
      _showPlaybackToast(tr('DLNA 投放播放失败'));
      _syncToSystemMediaSession();
    }
  }

  Future<CastMediaResolution?> resolveForCast(QueueItem item) async {
    if (item.isOnline) {
      final json = item.onlineSongJson;
      if (json != null && json.isNotEmpty) {
        final songJson = jsonDecode(json) as Map<String, dynamic>;
        final s0 = _ref.read(settingsProvider).valueOrNull;
        final fb0 = s0?.onlineQualityFallbackBehavior ?? 'lower';
        final preferred = _sessionQualityOverride ??
            s0?.onlineDefaultQuality ??
            item.onlineQuality ??
            '320k';
        final candidates = PlayerNotifier._qualityCandidates(preferred, fb0);
        final key = _songProbeKey(songJson, item);
        final probe = onlineQualityProbeRegistry.ensure(
            key, _buildResolveCallback(songJson, item));
        _activeProbeKey = key;
        final start = await probe
            .startBest(preferred, candidates)
            .timeout(const Duration(seconds: 45), onTimeout: () => null);
        if (start == null) return null;
        final clean = sanitizeMediaUrl(start.url);
        if (clean.isEmpty) return null;
        return CastMediaResolution(
          url: clean,
          headers: await withBilibiliStreamCookie(
                clean,
                normalizeMediaRequestHeaders(clean, start.headers),
                dataDir: _ref.read(appDataDirProvider.future),
              ) ??
              const {},
          isRemote: true,
        );
      }
      final url = await _resolveOnlineUrl(item);
      if (url == null) return null;
      final clean = sanitizeMediaUrl(url.url);
      if (clean.isEmpty) return null;
      return CastMediaResolution(
        url: clean,
        headers: await withBilibiliStreamCookie(
              clean,
              normalizeMediaRequestHeaders(clean, url.headers),
              dataDir: _ref.read(appDataDirProvider.future),
            ) ??
            const {},
        isRemote: true,
      );
    }
    if (PlayerNotifier._isRemotePath(item.path)) {
      final plan = await RemoteLibraryService(_ref).playbackSource(item.path);
      if (plan.isCached) {
        return CastMediaResolution(
            url: plan.cachedPath!, headers: const {}, isRemote: false);
      }
      if (plan.url.isEmpty) return null;
      return CastMediaResolution(
        url: plan.url,
        headers: plan.headers ?? const {},
        isRemote: true,
      );
    }
    var target = item.path;
    if (SafChannel.isSafPath(target)) {
      final tmp = await getTemporaryDirectory();
      target = await SafChannel.ensureLocalPlaybackCopy(
          target, p.join(tmp.path, 'saf_playback'));
    }
    if (!File(target).existsSync()) return null;
    return CastMediaResolution(url: target, headers: const {}, isRemote: false);
  }

  Future<void> _castFollowPlay(
    QueueItem item,
    int epoch, {
    double startAtSecs = 0,
  }) async {
    state = state.copyWith(resolving: item.isOnline);
    final media = await resolveForCast(item);
    if (epoch != _playEpoch) return;
    if (media == null) throw StateError(tr('无法获取播放链接'));
    try {
      await _player.stop();
    } catch (e) {
      AppLog.warn('player', '播放器停止失败: $e');
    }
    await _ref.read(dlnaCastProvider.notifier).castMedia(
          title: item.title,
          artist: item.artist,
          album: item.album,
          url: media.url,
          isRemote: media.isRemote,
          headers: media.headers,
          durationMs: item.durationMs,
          coverUrl: item.coverUrl,
          startAtSecs: startAtSecs,
        );
    if (epoch != _playEpoch) return;
    state = state.copyWith(isPlaying: true, resolving: false);
  }
}

class CastMediaResolution {
  final String url;
  final Map<String, String> headers;

  final bool isRemote;
  const CastMediaResolution({
    required this.url,
    required this.headers,
    required this.isRemote,
  });
}
