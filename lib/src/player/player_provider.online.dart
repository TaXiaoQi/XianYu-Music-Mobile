part of 'player_provider.dart';

extension PlayerNotifierOnline on PlayerNotifier {
  Future<void> _playRemote(QueueItem item) async {
    final service = RemoteLibraryService(_ref);

    if (PlayerNotifier._isDsdPath(item.path)) {
      final s = _ref.read(settingsProvider).valueOrNull;
      if (!(s?.usbExclusiveOutput ?? false) ||
          !(s?.dsdNativePassthrough ?? false)) {
        throw StateError(
            tr('远程 DSD 需开启「USB 独占输出」与「DSD 原生直通」'));
      }
      try {
        await _player.stop();
      } catch (e) {
        AppLog.warn('player', '播放器停止失败: $e');
      }
      await service.precacheRemote(item.path);
      final plan = await service.playbackSource(item.path);
      if (!plan.isCached) {
        throw StateError(tr('远程 DSD 缓存失败'));
      }
      final ok = await _tryStartExclusive(plan.cachedPath!,
          startAtSecs: 0, isPlaying: true);
      if (!ok) {
        throw StateError(tr('USB 独占输出启动失败，无法播放 DSD'));
      }
      return;
    }

    if (PlayerNotifier._isTranscodePath(item.path)) {
      final result = await service.transcodeToWav(item.path);
      try {
        await _player.stop();
      } catch (e) {
        AppLog.warn('player', '播放器停止失败: $e');
      }
      await _player.setFilePath(result.path);
      await _updateRgGain(result.path);
      await _player.setVolume(_effectiveVolume());
      await _player.play();
      return;
    }

    final plan = await service.playbackSource(item.path);
    try {
      await _player.stop();
    } catch (e) {
      AppLog.warn('player', '播放器停止失败: $e');
    }
    if (plan.isCached) {
      await _player.setFilePath(plan.cachedPath!);
      await _updateRgGain(plan.cachedPath);
    } else {
      if (!RegExp(r'^https?://').hasMatch(plan.url)) {
        throw StateError(tr('远程源配置缺失或已失效'));
      }
      await _player.setUrl(plan.url, headers: plan.headers);
      _rgGain = 1.0;
    }
    await _player.setVolume(_effectiveVolume());
    await _player.play();
  }

  void _precacheNextCover() {
    final n = state.queue.length;
    if (n == 0 || state.playMode == 1) return;
    final curIdx = state.queueIndex;
    final List<int> targets;
    if (state.playMode == 2) {
      if (_shuffleFuture.isEmpty) return;
      targets = <int>[];
      for (var k = 1; k <= 3 && k <= _shuffleFuture.length; k++) {
        final i = state.queue
            .indexWhere((q) => q.path == _shuffleFuture[_shuffleFuture.length - k]);
        if (i >= 0 && i != curIdx) targets.add(i);
      }
    } else {
      final start = curIdx < 0 ? 0 : curIdx;
      targets = <int>[
        for (var k = 1; k <= 3; k++)
          if ((start + k) % n != curIdx) (start + k) % n,
      ];
    }
    if (targets.isEmpty) return;
    final items = [for (final i in targets) state.queue[i]];
    unawaited(Future(() async {
      try {
        final dbPath = await _ref.read(dbPathProvider.future);
        final cacheRoot = await _ref.read(coverCacheRootProvider.future);
        for (final item in items) {
          await CoverImage.prewarm(
            songPath: item.path,
            networkUrl: item.coverUrl,
            dbPath: dbPath,
            cacheRoot: cacheRoot,
          );
        }
      } catch (e) {
        AppLog.debug('player', '封面预缓存失败: $e');
      }
    }));
  }

  void _maybePrecacheNextRemote(double pos) {
    final cur = state.current;
    if (cur == null || cur.isOnline || !PlayerNotifier._isRemotePath(cur.path)) return;
    final dur = state.duration;
    if (dur <= 0 || pos < dur * 0.6) return;
    if (state.playMode == 1) return;

    int next;
    if (state.playMode == 2) {
      if (_shuffleFuture.isEmpty) return;
      final path = _shuffleFuture.last;
      final i = state.queue.indexWhere((q) => q.path == path);
      if (i < 0) return;
      next = i;
    } else {
      final n = state.queue.length;
      if (n == 0) return;
      next = state.queueIndex < 0 ? 0 : (state.queueIndex + 1) % n;
    }
    final nextItem = state.queue[next];
    if (nextItem.isOnline || !PlayerNotifier._isRemotePath(nextItem.path)) return;
    if (_lastPrecachedRemotePath == nextItem.path) return;
    _lastPrecachedRemotePath = nextItem.path;
    final service = RemoteLibraryService(_ref);
    unawaited(Future(() async {
      try {
        await service.precacheRemote(nextItem.path);
        AppLog.info('play', '已预缓存下一首远程歌曲: ${nextItem.path}');
      } catch (e) {
        AppLog.warn('play', '预缓存下一首失败: $e');
      }
    }));
  }

  Future<String?> _preloadRemote(QueueItem item) async {
    try {
      final service = RemoteLibraryService(_ref);
      final plan = await service.playbackSource(item.path);
      if (plan.isCached) {
        await _player.setFilePath(plan.cachedPath!);
        return plan.cachedPath;
      }
    } catch (e) {
      AppLog.debug('player', '远程歌曲预加载失败: $e');
    }
    return null;
  }

  String precacheProbeKey(Map<String, dynamic> songJson, QueueItem item) =>
      _songProbeKey(songJson, item);

  SongQualityProbe precacheProbeEnsure(
    Map<String, dynamic> songJson,
    QueueItem item,
    String key,
  ) =>
      onlineQualityProbeRegistry.ensure(
        key,
        _buildResolveCallback(songJson, item),
      );

  List<String> precacheCandidates(String preferred, String fallback) =>
      PlayerNotifier._qualityCandidates(preferred, fallback);

  void _triggerOnlinePrecache(QueueItem item) {
    try {
      if (!item.isOnline) return;
      final s = _ref.read(settingsProvider).valueOrNull;
      final preferred = _sessionQualityOverride ??
          s?.onlineDefaultQuality ??
          item.onlineQuality ??
          '320k';
      final fb = s?.onlineQualityFallbackBehavior ?? 'lower';
      OnlinePrecache.instance.schedule(
        ref: _ref,
        notifier: this,
        queue: state.queue,
        queueIndex: state.queueIndex,
        playMode: state.playMode,
        currentPath: state.current?.path ?? item.path,
        preferred: preferred,
        fallback: fb,
      );
    } catch (e) {
      AppLog.debug('player', '在线预缓存调度失败: $e');
    }
  }

  Future<void> _startOnlineUrl(
    String url, {
    Map<String, String>? headers,
    required QueueItem item,
    String? ekey,
    String? cek,
    double startAtSecs = 0,
    bool isPlaying = true,
    bool castPlayback = false,
  }) async {
    final clean = sanitizeMediaUrl(url);
    if (clean.isEmpty) throw StateError(tr('无效的播放链接'));
    final h = await withBilibiliStreamCookie(
          clean,
          normalizeMediaRequestHeaders(clean, headers),
          dataDir: _ref.read(appDataDirProvider.future),
        ) ??
        <String, String>{};
    if (ekey != null && ekey.isNotEmpty) {
      await _startEncryptedFile(clean, h, item, ekey,
          startAtSecs: startAtSecs, isPlaying: isPlaying);
      return;
    }
    if (cek != null && cek.isNotEmpty) {
      await _startEncryptedFile(clean, h, item, cek,
          isCenc: true, startAtSecs: startAtSecs, isPlaying: isPlaying);
      return;
    }
    LastAudioSource.recordUrl(clean, h);
    await AudioProxyServer.instance.ensureStarted();
    AudioHeadCache.instance.registerHeaders(clean, h);
    final proxyUrl = AudioProxyServer.instance.proxyUrlFor(clean);
    if (proxyUrl != null) {
      try {
        await _player.stop();
      } catch (e) {
        AppLog.warn('player', '播放器停止失败: $e');
      }
      final ok = await _tryStartDspPipeline(proxyUrl,
          streamCacheUrl: clean,
          streamCacheHeaders: h,
          startAtSecs: startAtSecs, isPlaying: isPlaying, castPlayback: castPlayback);
      if (ok) {
        _triggerOnlinePrecache(item);
        return;
      }
    }
    final playUrl = AudioProxyServer.instance.playUrlFor(clean);
    final setUrlAt = DateTime.now();
    try {
      await _player.setUrl(playUrl,
              headers: h,
              initialPosition: startAtSecs > 0
                  ? Duration(milliseconds: (startAtSecs * 1000).round())
                  : null)
          .timeout(const Duration(seconds: 10));
      AppLog.debug('play',
          '[startOnlineUrl] setUrl 完成 ${DateTime.now().difference(setUrlAt).inMilliseconds}ms '
          'proc=${_player.processingState} url=$playUrl');
    } on TimeoutException {
      AppLog.warn('play',
          '[startOnlineUrl] 起播超时(10s) proc=${_player.processingState} '
          'buffered=${_player.bufferedPosition.inMilliseconds}ms '
          'dur=${_player.duration?.inMilliseconds}ms url=$clean');
      unawaited(diagProbeUrl(clean, h));
      await dumpPlayerThreads();
      unawaited(_player
          .stop()
          .then((_) => AppLog.info('play', '[startOnlineUrl] 超时后 stop 成功'))
          .catchError((_) {})
          .timeout(const Duration(seconds: 2), onTimeout: () {
        AppLog.warn('play', '[startOnlineUrl] 超时后 stop 也挂起（控制通道被占）');
      }));
      unawaited(_probeAndRebuild('[startOnlineUrl] 起播超时'));
      throw _StartOnlineTimeoutException(tr('音源起播超时，已跳过'));
    } on PlatformException catch (e) {
      AppLog.error('play', '[startOnlineUrl] 平台通道异常 code=${e.code}');
      unawaited(_probeAndRebuild('平台通道异常 ${e.code}'));
      throw StateError(tr('播放器通道异常'));
    }
    final declaredMs = item.durationMs;
    final actualMs = _player.duration?.inMilliseconds ?? 0;
    if (declaredMs >= 30000 && actualMs > 0 && actualMs < 5000) {
      AppLog.warn('play', '[startOnlineUrl] 直链实际时长异常 '
          'declared=${declaredMs}ms actual=${actualMs}ms url=$clean');
      throw StateError(tr('直链已失效（返回内容与歌曲不符）'));
    }
    await _player.setVolume(_effectiveVolume());
    if (castPlayback) {
      // ExoPlayer 速度跨曲目残留（仅音效设置变更时会被重写），
      // 被投播放强制回原速
      try {
        await _player.setSpeed(1.0);
        await _player.setPitch(1.0);
      } catch (e) {
        AppLog.warn('player', '播放器速度重置失败: $e');
      }
    }
    if (isPlaying) {
      await _player.play();
    }
    _triggerOnlinePrecache(item);
  }

  Future<void> _startEncryptedFile(
    String url,
    Map<String, String>? headers,
    QueueItem item,
    String key, {
    bool isCenc = false,
    double startAtSecs = 0,
    bool isPlaying = true,
  }) async {
    try {
      await _player.stop();
    } catch (e) {
      AppLog.warn('player', '播放器停止失败: $e');
    }
    final plainPath =
        await _decryptUrlToTemp(url, headers, key, isCenc: isCenc);
    await _player.setFilePath(plainPath);
    if (startAtSecs > 0) {
      try {
        await _player
                .seek(Duration(milliseconds: (startAtSecs * 1000).round()));
          } catch (e) {
            AppLog.warn('player', '恢复播放进度失败: $e');
          }
    }
    await _player.setVolume(_effectiveVolume());
    if (isPlaying) {
      await _player.play();
    }
    _triggerOnlinePrecache(item);
  }

  Future<String> _decryptUrlToTemp(
    String url,
    Map<String, String>? headers,
    String key, {
    bool isCenc = false,
  }) async {
    final cached = _decryptPathCache[url];
    if (cached != null) {
      final f = File(cached);
      if (f.existsSync() && f.lengthSync() > 0) return cached;
    }
    final dir = Directory(p.join((await getTemporaryDirectory()).path,
        'xianyu_decrypt'));
    if (!dir.existsSync()) await dir.create(recursive: true);
    final list = dir
        .listSync(followLinks: false)
        .whereType<File>()
        .toList()
      ..sort((a, b) => a.statSync().modified.compareTo(b.statSync().modified));
    for (var i = 0; i < list.length - PlayerNotifier._decryptCacheMax + 1; i++) {
      try {
        list[i].deleteSync();
      } catch (e) {
        AppLog.debug('player', '解密缓存清理失败: $e');
      }
    }
    final dest = p.join(dir.path,
        'dec_${sha256.convert(utf8.encode(url)).toString().substring(0, 24)}.tmp');
    if (File(dest).existsSync()) {
      try {
        final f = File(dest);
        if (f.lengthSync() > 0) {
          _decryptPathCache[url] = dest;
          return dest;
        }
        f.deleteSync();
      } catch (e) {
        AppLog.debug('player', '解密缓存校验失败: $e');
      }
    }
    final plainPath = await downloadOnlineSong(
      url: url,
      destPath: dest,
      ekey: isCenc ? null : key,
      cek: isCenc ? key : null,
      headersJson: jsonEncode(headers ?? <String, String>{}),
    );
    _decryptPathCache[url] = plainPath;
    if (_decryptPathCache.length > PlayerNotifier._decryptCacheMax) {
      final key0 = _decryptPathCache.keys.first;
      _decryptPathCache.remove(key0);
    }
    return plainPath;
  }
}
