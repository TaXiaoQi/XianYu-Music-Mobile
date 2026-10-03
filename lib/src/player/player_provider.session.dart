part of 'player_provider.dart';

extension PlayerNotifierSession on PlayerNotifier {
  void _syncToSystemMediaSession() {
    final cur = state.current;
    if (cur != null) {
      var item = cur;
      if (!cur.isOnline && cur.coverUrl?.isNotEmpty != true) {
        final hd = coverMaterializer.hdCoverCache[cur.path];
        if (hd != null && hd.isNotEmpty && File(hd).existsSync()) {
          // 内嵌原图（高清）：锁屏/通知放大展示不糊。
          item = cur.copyWith(coverPath: hd);
        } else {
          final cp = cur.coverPath;
          final coverPathLive = cp != null &&
              cp.isNotEmpty &&
              !cp.startsWith('http') &&
              File(cp).existsSync();
          if (!coverPathLive) {
            final cached = coverMaterializer.notifCoverCache[cur.path];
            if (cached != null && cached.isNotEmpty) {
              item = cur.copyWith(coverPath: cached);
            }
          }
          // 缩略图先行占位，同时异步提取内嵌原图，完成后重推。
          unawaited(_materializeLocalHdCover(cur));
        }
      }
      audioHandler?.syncMediaItem(item, state.duration);
      if (state.queue.isNotEmpty) {
        audioHandler?.syncQueue(state.queue, coverMaterializer.notifCoverCache);
      }
      audioHandler?.syncPlaybackState(
        isPlaying: state.isPlaying,
        positionSecs: state.position,
        durationSecs: state.duration,
        isFavorite: _ref.read(favoritesProvider).contains(cur.path),
        playMode: state.playMode,
        queueIndex: state.queueIndex,
      );
    }
  }

  Future<void> _resolveNotificationCover(QueueItem item) async {
    if (item.isOnline) return;
    if (item.coverUrl?.isNotEmpty == true) return;
    final cp = item.coverPath;
    if (cp != null && cp.isNotEmpty && !cp.startsWith('http')) {
      if (File(cp).existsSync()) return;
      AppLog.info('media_cover', 'coverPath 失效，走缩略图兜底: $cp');
    }
    final pending = coverMaterializer.notifCoverPending[item.path];
    if (pending != null) {
      await pending;
      return;
    }
    final fut = _resolveNotificationCoverInner(item);
    coverMaterializer.notifCoverPending[item.path] = fut;
    try {
      await fut;
    } finally {
      coverMaterializer.notifCoverPending.remove(item.path);
    }
  }

  /// 提取本地歌内嵌原图（getSongCover，带 Rust 侧缓存/负缓存/信号量），
  /// 完成后若仍是当前曲目则重推媒体会话，通知/锁屏展示高清封面。
  Future<void> _materializeLocalHdCover(QueueItem item) async {
    if (coverMaterializer.hdCoverPending.contains(item.path)) return;
    if (coverMaterializer.hdCoverCache.containsKey(item.path)) return;
    coverMaterializer.hdCoverPending.add(item.path);
    try {
      final dbPath = await _ref.read(dbPathProvider.future);
      final cacheRoot = await _ref.read(coverCacheRootProvider.future);
      final p = await getSongCover(
        dbPath: dbPath,
        cacheRoot: cacheRoot,
        path: item.path,
      );
      if (p.isEmpty) return;
      coverMaterializer.hdCoverCache[item.path] = p;
      if (state.current?.path == item.path) {
        _syncToSystemMediaSession();
      }
    } catch (_) {
      // 提取失败保持缩略图占位，下次播放重新尝试。
    } finally {
      coverMaterializer.hdCoverPending.remove(item.path);
    }
  }

  List<QueueItem> peekUpcomingItems(int count) {
    final n = state.queue.length;
    if (n == 0 || count <= 0 || state.playMode == 1) return const [];
    if (state.playMode == 2) {
      if (_shuffleFuture.isEmpty) return const [];
      final i = state.queue.indexWhere((q) => q.path == _shuffleFuture.last);
      return i >= 0 ? [state.queue[i]] : const [];
    }
    final start = state.queueIndex < 0 ? 0 : state.queueIndex + 1;
    final take = count < n ? count : n;
    return List.generate(
      take,
      (k) => state.queue[(start + k) % n],
      growable: false,
    );
  }

  Future<String?> resolveLinkCoverPath(QueueItem item) async {
    if (item.isOnline || item.coverUrl?.isNotEmpty == true) return null;
    try {
      await _resolveNotificationCover(item);
    } catch (_) {
      return null;
    }
    final p = coverMaterializer.notifCoverCache[item.path];
    if (p == null || p.isEmpty) return null;
    return File(p).existsSync() ? p : null;
  }

  Future<String> _resolveNotificationCoverInner(QueueItem item) async {
    if (coverMaterializer.notifCoverCache.containsKey(item.path)) {
      return coverMaterializer.notifCoverCache[item.path] ?? '';
    }
    coverMaterializer.notifCoverCache[item.path] = '';
    try {
      final dbPath = await _ref.read(dbPathProvider.future);
      final cacheRoot = await _ref.read(coverCacheRootProvider.future);
      var p = await getSongCoverThumbnail(
        dbPath: dbPath,
        cacheRoot: cacheRoot,
        path: item.path,
      );
      if (p.isEmpty && SafChannel.isSafPath(item.path)) {
        final healed =
            await SafChannel.extractCoverToCache(item.path, cacheRoot);
        if (healed.isNotEmpty) {
          p = await getSongCoverThumbnail(
            dbPath: dbPath,
            cacheRoot: cacheRoot,
            path: item.path,
          );
        }
      }
      coverMaterializer.notifCoverCache[item.path] = p;
      if (p.isNotEmpty && state.current?.path == item.path) {
        _syncToSystemMediaSession();
      } else if (p.isEmpty) {
        AppLog.info('media_cover', '缩略图兜底为空: ${item.path}');
      }
      return p;
    } catch (e) {
      AppLog.info('media_cover', '缩略图兜底异常: $e');
      return '';
    }
  }

  void _preloadQueueCovers() {
    final targets = <QueueItem>{};
    for (var k = 1; k <= 6 && state.queueIndex + k < state.queue.length; k++) {
      targets.add(state.queue[state.queueIndex + k]);
    }
    if (state.playMode == 2 && state.queue.length > 1) {
      for (var i = 0; i < 3; i++) {
        final idx = _rand.nextInt(state.queue.length);
        if (idx != state.queueIndex) targets.add(state.queue[idx]);
      }
    }
    for (final item in targets) {
      if (!coverMaterializer.preloadedCovers.add(item.path)) continue;
      if (coverMaterializer.preloadedCovers.length > 64) {
        coverMaterializer.preloadedCovers.remove(coverMaterializer.preloadedCovers.first);
      }
      Future(() => _preloadOneCover(item));
    }
  }

  Future<void> _preloadOneCover(QueueItem item) async {
    try {
      if (item.isOnline) {
        final url = item.coverUrl;
        if (url != null && url.isNotEmpty && CoverProxy.needsProxy(url)) {
          await CoverProxy.fetch(url);
        }
        return;
      }
      if (item.coverUrl?.isNotEmpty == true) return;
      final dbPath = await _ref.read(dbPathProvider.future);
      final cacheRoot = await _ref.read(coverCacheRootProvider.future);
      await getSongCoverThumbnail(
        dbPath: dbPath,
        cacheRoot: cacheRoot,
        path: item.path,
      );
    } catch (e) {
      AppLog.debug('player', '封面预加载失败: $e');
    }
  }

  Future<void> _restoreSession() async {
    try {
      String jsonStr = '';
      try {
        final dbPath = await _ref.read(dbPathProvider.future);
        jsonStr = await loadPlaybackSession(dbPath: dbPath);
      } catch (e) {
        AppLogger.instance.log('session', '读取数据库播放会话失败: $e');
      }

      if (jsonStr.isEmpty || jsonStr == 'null') {
        AppLog.info('session', 'restore skip: empty session');
        return;
      }

      final Map<String, dynamic> data = jsonDecode(jsonStr);
      final String curPath = data['currentSongPath'] as String? ?? '';
      final List rawQueue = data['playQueuePaths'] as List? ?? [];
      final Map rawMeta = data['queueSongMeta'] as Map? ?? {};
      final int mode = (data['playMode'] as num?)?.toInt() ?? 0;
      final double pos = (data['currentPositionSecs'] as num?)?.toDouble() ?? 0;
      final bool wasPlaying = data['isPlaying'] as bool? ?? false;

      if (rawQueue.isEmpty || curPath.isEmpty) {
        AppLog.info('session',
            'restore skip: queue=${rawQueue.length} curPath=$curPath');
        return;
      }

      final List<QueueItem> queue = [];
      for (final p in rawQueue) {
        final pathStr = p as String;
        final meta = rawMeta[pathStr] as Map<String, dynamic>?;
        if (meta != null) {
          queue.add(QueueItem(
            path: pathStr,
            title: meta['title'] as String? ?? _titleFromPath(pathStr),
            artist: meta['artist'] as String? ?? '',
            album: meta['album'] as String? ?? '',
            durationMs: (meta['durationMs'] as num?)?.toInt() ?? 0,
            coverUrl: meta['coverUrl'] as String?,
            coverPath: meta['coverPath'] as String?,
            source: meta['source'] as String?,
            onlineSongJson: meta['onlineSongJson'] as String?,
            onlineQuality: meta['onlineQuality'] as String?,
            onlineInfoJson: meta['onlineInfoJson'] as String?,
            fromDailyRecommend: meta['fromDailyRecommend'] as bool? ?? false,
          ));
        } else {
          queue.add(QueueItem(
            path: pathStr,
            title: _titleFromPath(pathStr),
            artist: '',
            album: '',
          ));
        }
      }

      final curIdx = queue.indexWhere((q) => q.path == curPath);
      final currentItem = curIdx >= 0 ? queue[curIdx] : queue.first;

      state = PlaybackState(
        queue: queue,
        queueIndex: curIdx >= 0 ? curIdx : 0,
        current: currentItem,
        isPlaying: false,
        position: pos,
        duration: currentItem.durationMs / 1000.0,
        playMode: mode,
      );

      if (!currentItem.isOnline && currentItem.coverUrl?.isNotEmpty != true) {
        try {
          await _resolveNotificationCover(currentItem);
        } catch (e) {
          AppLog.debug('player', '恢复封面解析失败: $e');
        }
      }
      _syncToSystemMediaSession();

      final vol = _ref.read(settingsProvider).valueOrNull?.volume ?? 1.0;
      await _player.setVolume(vol);

      if (!currentItem.isOnline) {
        if (PlayerNotifier._isRemotePath(currentItem.path)) {
          final cached = await _preloadRemote(currentItem);
          await _updateRgGain(cached);
          await seek(pos);
          await _player.setVolume(_effectiveVolume());
          if (wasPlaying) unawaited(_player.play());
        } else if (SafChannel.isSafPath(currentItem.path)) {
          _restoredLocalPending = pos;
          if (wasPlaying) {
            unawaited(Future.delayed(const Duration(milliseconds: 800), () {
              final idx = state.queueIndex;
              if (idx >= 0 && idx < state.queue.length) {
                _playAt(idx, startAtSecs: pos);
              }
            }));
          }
        } else {
          await _updateRgGain(currentItem.path);
          final useExclusive =
              _ref.read(settingsProvider).valueOrNull?.usbExclusiveOutput ?? false;
          var restored = false;
          if (useExclusive) {
            restored = await _tryStartExclusive(currentItem.path,
                startAtSecs: pos, isPlaying: wasPlaying);
          }
          if (!restored) {
            var path = currentItem.path;
            final isHttpSource =
                path.startsWith('http://') || path.startsWith('https://');
            if (PlayerNotifier._isTranscodePath(path) && !isHttpSource) {
              try {
                path =
                    (await RemoteLibraryService(_ref).transcodeToWav(path)).path;
                await _updateRgGain(path);
              } catch (e) {
                AppLogger.instance.log('session', '转码预载失败: $e');
              }
            }
            if (!isHttpSource) {
              restored = await _tryStartDspPipeline(path,
                  startAtSecs: pos, isPlaying: wasPlaying);
            }
            if (!restored) {
              try {
                await _setLocalSource(path);
                await seek(pos);
                if (wasPlaying) unawaited(_player.play());
              } catch (e) {
                AppLogger.instance.log('session', '本地曲目预加载失败: $e');
              }
              await _player.setVolume(_effectiveVolume());
            }
          }
        }
      } else {
        _restoredOnlinePending = pos;
        if (wasPlaying) {
          _restoredOnlinePending = null;
          unawaited(Future.delayed(const Duration(milliseconds: 800), () {
            final idx = state.queueIndex;
            if (idx >= 0 && idx < state.queue.length) {
              _playAt(idx, startAtSecs: pos, skipOnFailure: false)
                  .catchError((Object e) {
              });
            }
          }));
        }
      }
      AppLog.info('session',
          'restored queue=${queue.length} cur="${currentItem.title}" '
          'pos=${pos.toStringAsFixed(1)} '
          'dur=${state.duration.toStringAsFixed(1)} '
          'online=${currentItem.isOnline}');
    } catch (e) {
      AppLogger.instance.log('session', '恢复播放会话异常: $e');
    }
  }

  String _titleFromPath(String p) {
    final name = p.split(RegExp(r'[\\/]')).last;
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  void _persistPositionDebounced() {
    final current = state.current;
    if (current == null) return;
    final now = DateTime.now();
    if (now.difference(_lastPosPersist).inSeconds < 5) return;
    _lastPosPersist = now;
    final pos = state.position;
    final isPlaying = state.isPlaying;
    Future(() async {
      try {
        final dbPath = await _ref.read(dbPathProvider.future);
        await updatePlaybackPosition(
          dbPath: dbPath,
          positionSecs: pos,
          isPlaying: isPlaying,
        );
      } catch (e) {
        AppLog.warn('session', 'position save failed: $e');
      }
    });
  }

  Future<void> _ensureNotificationPermission() async {
    if (_notifPermissionAsked) return;
    _notifPermissionAsked = true;
    if (!Platform.isAndroid) return;
    try {
      final status = await Permission.notification.status;
      if (!status.isGranted) await Permission.notification.request();
    } catch (e) {
      AppLog.warn('player', '通知权限检查失败: $e');
    }
  }

  Future<void> _persistSession() async {
    try {
      final dbPath = await _ref.read(dbPathProvider.future);
      final settings = _ref.read(settingsProvider).valueOrNull;
      final item = state.current;
      if (item == null || state.queue.isEmpty) {
        await savePlaybackSession(
          dbPath: dbPath,
          sessionJson: jsonEncode({
            'currentSongPath': '',
            'playQueuePaths': <String>[],
            'sourceSongPaths': <String>[],
            'playMode': 0,
            'volume': (settings?.volume ?? 1.0) * 100.0,
            'currentPositionSecs': 0.0,
            'isPlaying': false,
            'sessionQualityOverride': null,
            'queueSongMeta': <String, dynamic>{},
            'updatedAt': DateTime.now().millisecondsSinceEpoch,
          }),
        );
        return;
      }

      final Map<String, dynamic> queueSongMeta = {};
      for (final q in state.queue) {
        queueSongMeta[q.path] = {
          'path': q.path,
          'title': q.title,
          'artist': q.artist,
          'album': q.album,
          'durationMs': q.durationMs,
          'coverUrl': q.coverUrl,
          'coverPath': q.coverPath,
          'source': q.source,
          'onlineSongJson': q.onlineSongJson,
          'onlineQuality': q.onlineQuality,
          'onlineInfoJson': q.onlineInfoJson,
        };
      }

      final sessionJson = jsonEncode({
        'currentSongPath': item.path,
        'playQueuePaths': state.queue.map((q) => q.path).toList(),
        'sourceSongPaths': state.queue.map((q) => q.path).toList(),
        'playMode': state.playMode,
        'volume': (settings?.volume ?? 1.0) * 100.0,
        'currentPositionSecs': state.position,
        'isPlaying': state.isPlaying,
        'sessionQualityOverride': null,
        'queueSongMeta': queueSongMeta,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      });
      await savePlaybackSession(dbPath: dbPath, sessionJson: sessionJson);
    } catch (e) {
      AppLogger.instance.log('session', '播放会话保存失败: $e');
    }
  }
}
