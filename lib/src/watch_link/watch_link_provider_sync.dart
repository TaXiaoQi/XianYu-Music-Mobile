part of 'watch_link_provider.dart';

extension WatchLinkControllerSync on WatchLinkController {
  void _pushState() {
    if ((!_connected && !_cloudWatchOnline) || !_transferActive) return;
    final st = _container.read(playerProvider);
    final item = st.current;
    _lastPlaying = st.isPlaying;
    _lastMode = linkPlayModeFromInt(st.playMode);
    _lastLiked = _likedOf(item);
    _send(LinkMessage.state(
      isPlaying: st.isPlaying,
      playMode: _lastMode,
      liked: _lastLiked,
      volume: _volumeOf(),
      mvPhase: _mvPhaseText(),
    ));
  }

  // ---- MV 加载进度同步 ----

  String? _mvPhaseText() {
    final mv = _container.read(mvProvider);
    if (!mv.requested || mv.ready) return null;
    switch (mv.phase) {
      case 'resolve':
        return 'MV 加载中（解析地址）';
      case 'init':
        return mv.bufferedSec > 0
            ? 'MV 加载中（已缓冲 ${mv.bufferedSec} 秒）'
            : 'MV 加载中（准备画面）';
      default:
        return mv.loading ? 'MV 加载中' : null;
    }
  }

  void _pushMvPhaseDebounced() {
    _mvPushTimer?.cancel();
    _mvPushTimer = Timer(const Duration(milliseconds: 300), _pushMvState);
  }

  void _pushMvState() {
    if (!_connected && !_cloudWatchOnline) return;
    final st = _container.read(playerProvider);
    _send(LinkMessage.state(
      isPlaying: st.isPlaying,
      playMode: _lastMode,
      liked: _lastLiked,
      volume: _volumeOf(),
      mvPhase: _mvPhaseText(),
    ));
  }

  // ---- 音效同步 ----

  void _pushEffectsDebounced() {
    _fxPushTimer?.cancel();
    _fxPushTimer = Timer(const Duration(milliseconds: 120), _sendEffects);
  }

  void _sendEffects() {
    if (!_connected && !_cloudWatchOnline) return;
    final s = _container.read(soundEffectProvider).settings;
    _send(LinkMessage.effects(fx: s.toJson()));
  }

  void _onFxCommand(LinkMessage msg) {
    final arg = msg.payload['arg'];
    if (arg is! Map) return;
    try {
      final s = SoundEffectSettings.fromJson(
        Map<String, dynamic>.from(arg),
      );
      _container.read(soundEffectProvider.notifier).set(s);
    } catch (_) {}
  }

  void _pushSnapshot({bool cloud = false}) {
    if ((!_connected && !_cloudWatchOnline) || !_snapshotAllowed()) return;
    final st = _container.read(playerProvider);
    final item = st.current;
    _songKey = item == null
        ? null
        : '${item.path}|${item.title}|${item.artist}|${item.durationMs}';
    _lastPlaying = st.isPlaying;
    _lastMode = linkPlayModeFromInt(st.playMode);
    _lastLiked = _likedOf(item);
    _send(LinkMessage.nowPlaying(
      id: item?.path ?? '',
      title: item?.title ?? '',
      artist: item?.artist ?? '',
      album: item?.album ?? '',
      cover: _coverOf(item),
      duration: st.duration,
      daily: item?.fromDailyRecommend ?? false,
    ), cloud: cloud);
    _maybePushCoverData(item, cloud: cloud);
    _send(LinkMessage.state(
      isPlaying: st.isPlaying,
      playMode: _lastMode,
      liked: _lastLiked,
      volume: _volumeOf(),
      mvPhase: _mvPhaseText(),
    ), cloud: cloud);
    _lastPosPush = DateTime.now();
    _send(LinkMessage.position(pos: st.position, duration: st.duration),
        cloud: cloud);
    _lyricSentSongId = null;
    _maybePushLyric(cloud: cloud);
    _maybePrecacheNext(cloud: cloud);
  }

  bool _snapshotAllowed() {
    final s = _container.read(settingsProvider).valueOrNull;
    final mode = s?.watchLinkTransferMode ?? 'ask';
    if (mode == 'remember') return s?.watchLinkAutoTransfer == true;
    return _transferActive || _dayGrantOf(s) == true;
  }

  void _maybeAskOnHandshake() {
    final st = _container.read(playerProvider);
    if (!st.isPlaying) return;
    final s = _container.read(settingsProvider).valueOrNull;
    if ((s?.watchLinkTransferMode ?? 'ask') != 'ask') return;
    if (!_needsAsk(s)) return;
    _askTransfer();
  }

  Future<void> _maybePushLyric({bool cloud = false}) async {
    if ((!_connected && !_cloudWatchOnline) || !_transferActive) return;
    final item = _container.read(playerProvider).current;
    final id = item?.path ?? '';
    if (item == null || id.isEmpty || id == _lyricSentSongId) return;
    _lyricSentSongId = id;
    try {
      final payload =
          await _container.read(lyricsRepositoryProvider).fetchPayloadJson(item);
      if (payload.isEmpty || payload == 'null') return;
      if ((!_connected && !_cloudWatchOnline) || !_transferActive) return;
      _send(LinkMessage.lyric(id: id, payload: payload), cloud: cloud);
    } catch (_) {}
  }

  // ---- 接下来五首批量预载 ----

  void _maybePrecacheNext({bool cloud = false}) {
    if ((!_connected && !_cloudWatchOnline) || !_snapshotAllowed()) return;
    final upcoming =
        _container.read(playerProvider.notifier).peekUpcomingItems(5);
    if (upcoming.isEmpty) return;
    final todo = upcoming
        .where((e) => !_precachedPaths.contains(e.path))
        .toList(growable: false);
    if (todo.isEmpty) return;
    if (_precachedPaths.length > 64) _precachedPaths.clear();
    Future.delayed(const Duration(seconds: 3), () async {
      for (final next in todo) {
        if ((!_connected && !_cloudWatchOnline) || !_snapshotAllowed()) return;
        if (_precachedPaths.contains(next.path)) continue;
        _precachedPaths.add(next.path);
        if (_container.read(playerProvider).current?.path == next.path) {
          continue;
        }
        String? coverData;
        try {
          final bytes = await _nextCoverBytes(next);
          if (bytes != null && bytes.isNotEmpty) {
            coverData = await compute(_encodeLinkCoverBytes, bytes);
          }
        } catch (_) {}
        String? lyricPayload;
        try {
          final payload = await _container
              .read(lyricsRepositoryProvider)
              .fetchPayloadJson(next);
          if (payload.isNotEmpty && payload != 'null') lyricPayload = payload;
        } catch (_) {}
        if ((!_connected && !_cloudWatchOnline) || !_snapshotAllowed()) return;
        if (coverData == null && lyricPayload == null) continue;
        _send(LinkMessage.precache(
          id: next.path,
          coverData: coverData,
          lyricPayload: lyricPayload,
        ), cloud: cloud, low: true);
        await Future.delayed(const Duration(milliseconds: 800));
      }
    });
  }

  Future<Uint8List?> _nextCoverBytes(QueueItem item) async {
    final url = item.coverUrl;
    if (url != null && url.isNotEmpty && !url.startsWith('lx://')) {
      return CoverProxy.cached(url) ?? await CoverProxy.fetch(url);
    }
    final path = await _container
        .read(playerProvider.notifier)
        .resolveLinkCoverPath(item);
    if (path == null || path.isEmpty) return null;
    final f = File(path);
    if (!await f.exists()) return null;
    return f.readAsBytes();
  }

  bool _likedOf(QueueItem? item) {
    if (item == null) return false;
    try {
      return _container.read(favoritesProvider).contains(item.path);
    } catch (_) {
      return false;
    }
  }

  double _volumeOf() => _container.read(volumeProvider);

  String? _coverOf(QueueItem? item) {
    if (item == null) return null;
    final path = item.coverPath;
    if (path != null &&
        path.isNotEmpty &&
        !path.startsWith('http') &&
        !path.startsWith('lx://')) {
      return path;
    }
    return null;
  }

  Future<void> _maybePushCoverData(QueueItem? item, {bool cloud = false}) async {
    if (item == null) return;
    final url = item.coverUrl;
    if (url != null && url.isNotEmpty) {
      if (url.startsWith('lx://')) return;
      final cached = _coverDataCache[url];
      if (cached != null) {
        _sendCoverData(item, cached, cloud: cloud);
        return;
      }
      try {
        final bytes = await _nextCoverBytes(item);
        if (bytes == null || bytes.isEmpty) return;
        final data = await compute(_encodeLinkCoverBytes, bytes);
        if (data == null || data.isEmpty) return;
        if (_coverDataCache.length > 16) _coverDataCache.clear();
        _coverDataCache[url] = data;
        _sendCoverData(item, data, cloud: cloud);
      } catch (_) {}
      return;
    }
    var path = item.coverPath;
    final live = path != null &&
        path.isNotEmpty &&
        !path.startsWith('http') &&
        !path.startsWith('lx://') &&
        File(path).existsSync();
    if (!live) {
      final resolved = await _container
          .read(playerProvider.notifier)
          .resolveLinkCoverPath(item);
      if (resolved == null) return;
      path = resolved;
      item = item.copyWith(coverPath: resolved);
    }
    final cached = _coverDataCache[path];
    if (cached != null) {
      _sendCoverData(item, cached, cloud: cloud);
      return;
    }
    final target = item;
    final coverPath = path;
    compute(_encodeLinkCoverData, coverPath).then((data) {
      if (data == null || data.isEmpty) return;
      if (_coverDataCache.length > 16) _coverDataCache.clear();
      _coverDataCache[coverPath] = data;
      _sendCoverData(target, data, cloud: cloud);
    }).catchError((_) {});
  }

  void _sendCoverData(QueueItem item, String data, {bool cloud = false}) {
    if ((!_connected && !_cloudWatchOnline) || !_snapshotAllowed()) return;
    final st = _container.read(playerProvider);
    if (st.current?.path != item.path) return;
    _send(LinkMessage.nowPlaying(
      id: item.path,
      title: item.title,
      artist: item.artist,
      album: item.album,
      cover: _coverOf(item),
      coverData: data,
      duration: st.duration,
      daily: item.fromDailyRecommend,
    ), cloud: cloud);
  }

}
