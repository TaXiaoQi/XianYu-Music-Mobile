part of 'player_provider.dart';

extension PlayerNotifierSourceSwitch on PlayerNotifier {
  Future<ResolvedMediaUrl?> _tryLxResolve(
      String songInfoJson, List<String> candidates) async {
    try {
      return await _tryLxResolveInner(songInfoJson, candidates)
          .timeout(const Duration(seconds: 45));
    } catch (_) {
      return null;
    }
  }

  Future<ResolvedMediaUrl?> _tryLxResolveInner(
      String songInfoJson, List<String> candidates) async {
    final engine = await _ref.read(pluginEngineProvider.future);
    final songInfo = jsonDecode(songInfoJson) as Map<String, dynamic>;
    for (final quality in candidates) {
      try {
        final resolved = await engine.resolveLxUrl(songInfo, quality);
        if (resolved == null) continue;
        final url = resolved['url'] as String?;
        if (PlayerNotifier._isPlayableUrl(url)) {
          return ResolvedMediaUrl(
            url: url!,
            quality: quality,
            headers: resolved['headers'] as Map<String, String>?,
          );
        }
      } catch (e) {
        AppLog.debug('player', '音源候选解析失败: $e');
      }
    }
    return null;
  }

  Future<ResolvedMediaUrl?> _resolveOnlineUrl(QueueItem item) async {
    final infoJson = item.onlineInfoJson;
    if (infoJson == null) return null;
    final s = _ref.read(settingsProvider).valueOrNull;
    final preferred = _sessionQualityOverride ??
        s?.onlineDefaultQuality ??
        '320k';
    final fb = s?.onlineQualityFallbackBehavior ?? 'lower';
    return _tryLxResolve(infoJson, PlayerNotifier._qualityCandidates(preferred, fb));
  }

  /// 在线歌曲起播失败后（日推/歌单导入/收藏等快照类歌曲均适用），
  /// 不依赖入库时的插件快照换源，而是用「歌名+歌手」实时重搜当前
  /// 可用插件，用新结果解析播放。
  Future<bool> _reSearchOnlineSource(QueueItem item) async {
    final songKey = '${item.title}|${item.artist}';
    if (_onlineReSearchDone.contains(songKey)) return false;
    if (item.title.trim().isEmpty) return false;
    if (state.current?.path != item.path) return false;
    _onlineReSearchDone.add(songKey);
    if (_onlineReSearchDone.length > 64) {
      _onlineReSearchDone.remove(_onlineReSearchDone.first);
    }

    var failedPluginId = '';
    final failedJson = item.onlineSongJson;
    if (failedJson != null && failedJson.isNotEmpty) {
      try {
        failedPluginId =
            ((jsonDecode(failedJson) as Map<String, dynamic>)['pluginId']
                    as String?) ??
                '';
      } catch (_) {
        // 解析失败按默认值处理
      }
    }

    AppLog.info('autoswitch', '重搜换源: ${item.title}');
    try {
      final engine = await _ref.read(pluginEngineProvider.future);
      final sources = (await engine.store.loadSources())
          .where((s) => s.id != failedPluginId)
          .toList();
      final playable = <PluginSource>[];
      for (final s in sources) {
        if (await engine.canPlayMusic(s)) playable.add(s);
      }
      if (playable.isEmpty) return false;

      final keyword = item.artist.trim().isEmpty
          ? item.title.trim()
          : '${item.title.trim()} ${item.artist.trim()}';
      final normTitle = PlayerNotifier._normSongText(item.title);
      final normArtist = PlayerNotifier._normSongText(PlayerNotifier._firstArtistOf(item.artist));

      Future<List<PluginSearchResult>> searchOne(PluginSource plugin) async {
        try {
          if (plugin.format.isMfCompatible) {
            return await PluginCatalogService(engine, [plugin])
                .searchMusic(plugin, keyword, limit: 10)
                .timeout(const Duration(seconds: 8));
          }
          for (final key
              in (plugin.sources.isEmpty ? const ['default'] : plugin.sources)) {
            try {
              final r = await engine
                  .searchInPlugin(plugin, key, keyword, limit: 10)
                  .timeout(const Duration(seconds: 8));
              if (r.isNotEmpty) return r;
            } catch (e) {
              AppLog.debug('player', '插件子源搜索失败: $e');
            }
          }
        } catch (e) {
          AppLog.debug('player', '插件搜索失败: $e');
        }
        return const [];
      }

      final searchResults = await Future.wait(
          [for (final p in playable) searchOne(p)]);

      final candidates = <(PluginSource, PluginSearchResult)>[];
      for (var i = 0; i < playable.length; i++) {
        for (final r in searchResults[i]) {
          if (PlayerNotifier._normSongText(r.name) != normTitle) continue;
          final ra = PlayerNotifier._normSongText(PlayerNotifier._firstArtistOf(r.singer));
          if (ra.isEmpty ||
              normArtist.isEmpty ||
              !(ra.contains(normArtist) || normArtist.contains(ra))) {
            continue;
          }
          candidates.add((playable[i], r));
          break;
        }
        if (candidates.length >= 4) break;
      }

      final settings = _ref.read(settingsProvider).valueOrNull;
      final preferred = _sessionQualityOverride ??
          settings?.onlineDefaultQuality ??
          item.onlineQuality ??
          '320k';
      final fb = settings?.onlineQualityFallbackBehavior ?? 'lower';
      final qualityChain = PlayerNotifier._qualityCandidates(preferred, fb);

      for (final (plugin, r) in candidates) {
        final song = r.toJson();
        final isMf = plugin.format.isMfCompatible;
        final cover = resolveSongCoverUrl(song) ?? r.img;
        final newItem = isMf
            ? QueueItem(
                path: 'plugin://${plugin.id}/${r.songmid}',
                title: r.name,
                artist: r.singer,
                album: r.albumName,
                durationMs: PlayerNotifier._intervalStrToMs(r.interval),
                coverUrl: cover,
                onlineSongJson: jsonEncode({
                  'pluginId': plugin.id,
                  'format': plugin.format.value,
                  'musicInfo': song,
                }),
                onlineQuality: preferred,
              )
            : QueueItem(
                path: 'lx://${r.source}/${r.songmid}',
                title: r.name,
                artist: r.singer,
                album: r.albumName,
                durationMs: PlayerNotifier._intervalStrToMs(r.interval),
                coverUrl: cover,
                onlineSongJson: jsonEncode({
                  'pluginId': plugin.id,
                  'format': plugin.format.value,
                  'source': r.source,
                  'musicInfo': song,
                }),
                onlineQuality: preferred,
                source: r.source,
                onlineInfoJson: jsonEncode(song),
              );

        ResolvedMediaUrl? url;
        try {
          if (isMf) {
            url = await engine
                .getMusicFreeUrl(plugin, song,
                    preferred: preferred, fallback: fb)
                .timeout(const Duration(seconds: 10));
          } else {
            url = await _tryLxResolve(jsonEncode(song), qualityChain);
          }
        } catch (e) {
          AppLog.debug('player', '换源候选解析失败: $e');
        }
        if (url == null || !PlayerNotifier._isPlayableUrl(url.url)) continue;
        if (state.current?.path != item.path) return false;

        final idx = state.queueIndex;
        final queue = [...state.queue];
        if (idx >= 0 && idx < queue.length) queue[idx] = newItem;
        state = state.copyWith(
          queue: queue,
          current: newItem,
          isPlaying: false,
          resolving: true,
          position: 0,
          duration: newItem.durationMs / 1000.0,
          error: null,
        );
        _syncToSystemMediaSession();
        try {
          state = state.copyWith(resolving: false);
          await _startOnlineUrl(url.url,
              headers: url.headers, item: newItem, ekey: url.ekey, cek: url.cek);
        } catch (_) {
          continue;
        }
        _skipDepth = 0;
        state = state.copyWith(resolving: false, error: null);
        statsReporter.resetCounters();
        statsReporter.recordRecentPlay(newItem);
        statsReporter.recordHistory(newItem);
        statsReporter.reportBehavior(newItem, 'play', 0);
        statsReporter.noteTrackStart();
        _syncToSystemMediaSession();
        AppLog.info('autoswitch', '重搜换源命中: ${plugin.name}');
        _showPlaybackToast(
            tr('已切换到 {source} 音源', {'source': plugin.name}));
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _autoSwitchSource(QueueItem item, {bool force = false}) async {
    final settings = _ref.read(settingsProvider).valueOrNull;
    final now = DateTime.now();
    if (_lastAutoSwitchAt != null &&
        _lastAutoSwitchPath == item.path &&
        now.difference(_lastAutoSwitchAt!) < const Duration(milliseconds: 800)) {
      return false;
    }
    _lastAutoSwitchAt = now;
    _lastAutoSwitchPath = item.path;
    if ((settings?.onlineFailureBehavior ?? 'pause') != 'autoswitch' &&
        !force) {
      return false;
    }

    final infoJson = item.onlineInfoJson ?? item.onlineSongJson;
    if (infoJson == null || infoJson.isEmpty) return false;
    var info = <String, dynamic>{};
    try {
      info = jsonDecode(infoJson) as Map<String, dynamic>;
    } catch (_) {
      return false;
    }

    final key = '${item.title}|${item.artist}';
    if (_switchCtxKey != key) {
      _switchCtxKey = key;
      _failedSources.clear();
    }
    if (item.title.trim().isEmpty) return false;
    AppLog.info('autoswitch', '起播失败自动换源: ${item.title}');

    if (await _switchViaSiblingPlatform(item)) return true;

    final curSource = (info['source'] as String?) ?? item.source;
    var curKey = (curSource == null || curSource.isEmpty) ? '' : curSource;
    if (curKey.isEmpty) {
      final mj = info['musicInfo'];
      var label = mj is Map<String, dynamic>
          ? (mj['platform'] ?? mj['source'])?.toString() ?? ''
          : '';
      if (label.isEmpty) {
        try {
          final sj = jsonDecode(item.onlineSongJson ?? '') as Map<String, dynamic>?;
          final sm = sj?['musicInfo'];
          if (sm is Map<String, dynamic>) {
            label = (sm['platform'] ?? sm['source'])?.toString() ?? '';
          }
          if (label.trim().isEmpty) {
            final pid = sj?['pluginId'] as String?;
            if (pid != null && pid.isNotEmpty) {
              final engine = await _ref.read(pluginEngineProvider.future);
              label = await _platformLabelFromPluginMeta(engine, pid);
              if (label.isNotEmpty) {
                AppLog.info('autoswitch',
                    'musicInfo 无平台标签，回退插件元数据: $label');
              }
            }
          }
        } catch (_) {
          // 解析失败按默认值处理
        }
      }
      curKey = lxSourceKeyForPlatform(label);
    }
    if (curKey.isEmpty) {
      AppLog.warn('autoswitch', '无法识别平台标签，放弃落雪换源: ${item.title}');
      return false;
    }
    _failedSources.add(curKey);

    final fb = settings?.onlineQualityFallbackBehavior ?? 'lower';
    final preferred = settings?.onlineDefaultQuality ?? '320k';
    final sourceLabels = {for (final s in kOnlineSources) s.id: s.label};

    while (true) {
      final String rawJson;
      try {
        rawJson = await findAlternativeLxSource(
          songName: item.title,
          songArtist: item.artist,
          songDuration: item.durationMs / 1000.0,
          failedSourcesJson: jsonEncode(_failedSources.toList()),
        );
      } catch (_) {
        break;
      }
      if (rawJson.isEmpty || rawJson == 'null') break;
      final Map<String, dynamic> raw;
      try {
        raw = jsonDecode(rawJson) as Map<String, dynamic>;
      } catch (_) {
        break;
      }
      final newItem = OnlineTrack.fromJson(raw).toQueueItem();
      final srcId = newItem.source;
      final infoJson = newItem.onlineInfoJson;
      if (srcId == null ||
          srcId.isEmpty ||
          _failedSources.contains(srcId) ||
          infoJson == null ||
          infoJson.isEmpty) {
        break;
      }
      final url = await _tryLxResolve(
        infoJson,
        PlayerNotifier._qualityCandidates(preferred, fb),
      );
      if (url == null) {
        AppLog.warn('autoswitch', '落雪换源候选解析失败: $srcId');
        _failedSources.add(srcId);
        continue;
      }
      final idx = state.queueIndex;
      final queue = [...state.queue];
      if (idx >= 0 && idx < queue.length) queue[idx] = newItem;
      state = state.copyWith(
        queue: queue,
        current: newItem,
        isPlaying: false,
        resolving: true,
        position: 0,
        duration: newItem.durationMs / 1000.0,
        error: null,
      );
      _syncToSystemMediaSession();
      try {
        state = state.copyWith(resolving: false);
        await _startOnlineUrl(url.url,
            headers: url.headers, item: newItem, ekey: url.ekey, cek: url.cek);
      } catch (_) {
        _failedSources.add(srcId);
        continue;
      }
      _skipDepth = 0;
      state = state.copyWith(resolving: false, error: null);
      statsReporter.resetCounters();
      statsReporter.recordRecentPlay(newItem);
      statsReporter.recordHistory(newItem);
      statsReporter.reportBehavior(newItem, 'play', 0);
      statsReporter.noteTrackStart();
      _syncToSystemMediaSession();
      AppLog.info('autoswitch', '落雪换源命中: $srcId');
      _showPlaybackToast(
          tr('已自动切换到 {source} 音源', {'source': sourceLabels[srcId] ?? srcId}));
      return true;
    }
    return false;
  }

  Future<bool> _switchViaSiblingPlatform(QueueItem item) async {
    ResolvedMediaUrl? hit;
    Map<String, dynamic>? healedJson;
    try {
      final json = item.onlineSongJson;
      if (json == null || json.isEmpty) return false;
      final songJson = jsonDecode(json) as Map<String, dynamic>;
      final pluginId = songJson['pluginId'] as String?;
      final format = songJson['format'] as String? ?? 'lx';
      final sourceKey = songJson['source'] as String? ?? '';
      final musicInfo = songJson['musicInfo'] as Map<String, dynamic>? ?? {};
      if (pluginId == null || pluginId.isEmpty) return false;
      if (state.current?.path != item.path) return false;

      final engine = await _ref.read(pluginEngineProvider.future);
      final preferred =
          _ref.read(settingsProvider).valueOrNull?.onlineDefaultQuality ??
              '320k';

      var labelOverride = _songPlatformLabel(format, sourceKey, musicInfo);
      if (labelOverride.trim().isEmpty) {
        labelOverride = await _platformLabelFromPluginMeta(engine, pluginId);
        if (labelOverride.isNotEmpty) {
          AppLog.info('autoswitch',
              'musicInfo 无平台标签，回退插件元数据: $labelOverride');
        }
      }
      final override = labelOverride.trim().isEmpty ? null : labelOverride;

      hit = await _resolveViaSiblingPlugin(
        failedId: pluginId,
        format: format,
        sourceKey: sourceKey,
        musicInfo: musicInfo,
        quality: preferred,
        itemPath: item.path,
        engine: engine,
        platformLabelOverride: override,
      );

      if (hit == null) {
        final sources = await engine.store.loadSources();
        final healed = await _crossFormatHeal(
            pluginId, format, sourceKey, musicInfo, sources, engine,
            platformLabelOverride: override);
        if (healed != null) {
          final (plugin, newJson) = healed;
          final newFormat = newJson['format'] as String? ?? format;
          final newSourceKey = newJson['source'] as String? ?? sourceKey;
          final newMusicInfo =
              newJson['musicInfo'] as Map<String, dynamic>? ?? musicInfo;
          if (isMfFormatValue(newFormat)) {
            hit = await engine.getMusicFreeUrl(
              plugin,
              newMusicInfo,
              preferred: preferred,
              fallback: 'pause',
            );
          } else {
            final r = await engine.getMusicUrl(
                plugin, newSourceKey, newMusicInfo, preferred);
            final url = r?['url'] as String?;
            hit = (r != null && PlayerNotifier._isPlayableUrl(url))
                ? ResolvedMediaUrl(
                    url: url!,
                    headers: r['headers'] is Map
                        ? (r['headers'] as Map).cast<String, String>()
                        : null,
                    quality: preferred,
                  )
                : null;
          }
          if (hit != null) healedJson = newJson;
        }
      }
      if (hit == null) return false;

      if (healedJson != null) {
        _applyCrossFormatHealToState(
          itemPath: item.path,
          pluginId: healedJson['pluginId'] as String? ?? pluginId,
          newOnlineSongJson: jsonEncode(healedJson),
          newSource: healedJson['source'] as String? ?? sourceKey,
          newOnlineInfoJson:
              jsonEncode(healedJson['musicInfo'] ?? musicInfo),
        );
      }

      state = state.copyWith(
        isPlaying: false,
        resolving: false,
        position: 0,
        error: null,
      );
      _skipDepth = 0;
      await _startOnlineUrl(hit.url,
          headers: hit.headers, item: item, ekey: hit.ekey, cek: hit.cek);
      state = state.copyWith(resolving: false, error: null);
      statsReporter.resetCounters();
      statsReporter.recordRecentPlay(item);
      statsReporter.recordHistory(item);
      statsReporter.reportBehavior(item, 'play', 0);
      statsReporter.noteTrackStart();
      _syncToSystemMediaSession();
      _showPlaybackToast(tr('播放失败，已自动切换音源重播'));
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<ResolvedMediaUrl?> _resolvePluginUrl(
      Map<String, dynamic> songJson, String quality,
      {String itemPath = ''}) async {
    try {
      final pluginId = songJson['pluginId'] as String?;
      var sourceKey = songJson['source'] as String? ?? '';
      var musicInfo = songJson['musicInfo'] as Map<String, dynamic>? ?? {};
      var format = songJson['format'] as String? ?? 'lx';
      if (pluginId == null || pluginId.isEmpty) return null;

      final engine = await _ref.read(pluginEngineProvider.future);
      final sources = await engine.store.loadSources();
      final staleUrl = musicInfo['url'];
      if (staleUrl is String && staleUrl.startsWith('http')) {
        musicInfo.remove('url');
      }
      var source = sources.where((s) => s.id == pluginId).toList();
      var labelOverride = _songPlatformLabel(format, sourceKey, musicInfo);
      if (labelOverride.trim().isEmpty) {
        labelOverride = await _platformLabelFromPluginMeta(engine, pluginId);
      }
      final override = labelOverride.trim().isEmpty ? null : labelOverride;
      if (source.isEmpty) {
        final healed = _findHealedPlugin(sources, format, sourceKey, musicInfo,
            platformLabelOverride: override);
        if (healed == null) {
          final healedCross = await _crossFormatHeal(
              pluginId, format, sourceKey, musicInfo, sources, engine,
              platformLabelOverride: override);
          if (healedCross == null) {
            return null;
          }
          source = [healedCross.$1];
          final newFormat = healedCross.$2['format'] as String? ?? format;
          final newSource = healedCross.$2['source'] as String? ?? sourceKey;
          final newMusicInfo = healedCross.$2['musicInfo'] as Map<String, dynamic>? ?? musicInfo;
          format = newFormat;
          sourceKey = newSource;
          musicInfo = newMusicInfo;
          final newOnlineSongJson = jsonEncode(healedCross.$2);
          final newOnlineInfoJson = jsonEncode(newMusicInfo);
          _applyCrossFormatHealToState(
            itemPath: itemPath,
            pluginId: healedCross.$1.id,
            newOnlineSongJson: newOnlineSongJson,
            newSource: newSource,
            newOnlineInfoJson: newOnlineInfoJson,
          );
        } else {
          source = [healed];
        }
      }

      ResolvedMediaUrl? resolved;
      if (isMfFormatValue(format)) {
        resolved = await engine
            .getMusicFreeUrl(
              source.first,
              musicInfo,
              preferred: quality,
              fallback: 'pause',
            )
            .timeout(const Duration(seconds: 8));
      } else {
        final result = await engine
            .getMusicUrl(source.first, sourceKey, musicInfo, quality)
            .timeout(const Duration(seconds: 8));
        final url = result?['url'] as String?;
        if (result != null && PlayerNotifier._isPlayableUrl(url)) {
          final h = result['headers'];
          final reportedRaw = result['type'];
          final reportedQuality = reportedRaw is String
              ? PluginEngine.normalizeQualityKey(reportedRaw)
              : null;
          resolved = ResolvedMediaUrl(
            url: url!,
            headers: h is Map ? h.cast<String, String>() : null,
            quality: reportedQuality ?? quality,
          );
        } else {
        }
      }
      if (resolved != null) return resolved;
      return null;
    } catch (e) {
      return null;
    }
  }

  String _songPlatformLabel(
    String format,
    String sourceKey,
    Map<String, dynamic> musicInfo,
  ) {
    if (format == 'lx') return sourceKey;
    final v = musicInfo['platform'] ?? musicInfo['source'] ?? sourceKey;
    return v?.toString() ?? '';
  }

  Future<String> _platformLabelFromPluginMeta(
    PluginEngine engine,
    String pluginId,
  ) async {
    try {
      final sources = await engine.store.loadSources();
      final src = sources.where((s) => s.id == pluginId).toList();
      if (src.isEmpty) return '';
      final meta = await engine.ensureLoaded(src.first);
      for (final k in const ['platform', 'pluginName', 'name']) {
        final v = meta?[k]?.toString() ?? '';
        if (v.trim().isNotEmpty) return v.trim();
      }
      return '';
    } catch (_) {
      return '';
    }
  }

  Future<ResolvedMediaUrl?> _resolveViaSiblingPlugin({
    required String failedId,
    required String format,
    required String sourceKey,
    required Map<String, dynamic> musicInfo,
    required String quality,
    required String itemPath,
    required PluginEngine engine,
    String? platformLabelOverride,
  }) async {
    try {
      final pluginFormat = PluginFormat.fromValue(format);
      var platformLabel = _songPlatformLabel(format, sourceKey, musicInfo);
      if (platformLabel.trim().isEmpty &&
          platformLabelOverride != null &&
          platformLabelOverride.trim().isNotEmpty) {
        platformLabel = platformLabelOverride;
      }
      final sources = await engine.store.loadSources();
      final candidates = listEnabledPluginsForPlatform(
        platformLabel: platformLabel,
        installedPlugins: sources,
        format: pluginFormat,
        excludeId: failedId,
      ).take(3).toList();
      AppLog.info('autoswitch',
          '兄弟插件换源 label=$platformLabel failedId=$failedId candidates=${candidates.length}');
      for (final plugin in candidates) {
        final ResolvedMediaUrl? hit;
        if (plugin.format.isMfCompatible) {
          hit = await engine
              .getMusicFreeUrl(
                plugin,
                musicInfo,
                preferred: quality,
                fallback: 'pause',
              )
              .timeout(const Duration(seconds: 8));
        } else {
          final lxKey = lxSourceKeyForPlatform(platformLabel);
          final lxSupported =
              plugin.sources.isEmpty || plugin.sources.contains(lxKey);
          if (lxKey.isEmpty || !lxSupported) {
            continue;
          }
          final result = await engine
              .getMusicUrl(plugin, lxKey, musicInfo, quality)
              .timeout(const Duration(seconds: 8));
          final url = result?['url'] as String?;
          hit = (result != null && PlayerNotifier._isPlayableUrl(url))
              ? ResolvedMediaUrl(
                  url: url!,
                  headers: result['headers'] is Map
                      ? (result['headers'] as Map).cast<String, String>()
                      : null,
                  quality: quality,
                )
              : null;
        }
        if (hit == null) {
          continue;
        }
        return hit;
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  PluginSource? _findHealedPlugin(
    List<PluginSource> sources,
    String format,
    String sourceKey,
    Map<String, dynamic> musicInfo, {
    String? platformLabelOverride,
  }) {
    final pluginFormat = PluginFormat.fromValue(format);
    var platform = _songPlatformLabel(format, sourceKey, musicInfo);
    if (platform.trim().isEmpty &&
        platformLabelOverride != null &&
        platformLabelOverride.trim().isNotEmpty) {
      platform = platformLabelOverride;
    }
    if (platform.trim().isEmpty) return null;
    return findPluginForPlatform(
      platformLabel: platform,
      installedPlugins: sources,
      format: pluginFormat,
    );
  }

  Future<(PluginSource, Map<String, dynamic>)?> _crossFormatHeal(
    String pluginId,
    String format,
    String sourceKey,
    Map<String, dynamic> musicInfo,
    List<PluginSource> sources,
    PluginEngine engine, {
    String? platformLabelOverride,
  }) async {
    final pluginFormat = PluginFormat.fromValue(format);
    var platformLabel = _songPlatformLabel(format, sourceKey, musicInfo);
    if (platformLabel.trim().isEmpty &&
        platformLabelOverride != null &&
        platformLabelOverride.trim().isNotEmpty) {
      platformLabel = platformLabelOverride;
    }
    if (platformLabel.trim().isEmpty) return null;

    final title = (musicInfo['name'] ?? musicInfo['title'] ?? '').toString().trim();
    final artist = (musicInfo['singer'] ?? musicInfo['artist'] ?? '').toString().trim();
    if (title.isEmpty) return null;

    final cacheKey = '$pluginId|$title|$artist';
    final cached = _crossFormatHealCache[cacheKey];
    if (cached != null) {
      final cachedSource = sources.where((s) => s.id == cached['pluginId']).toList();
      if (cachedSource.isNotEmpty) return (cachedSource.first, cached);
      _crossFormatHealCache.remove(cacheKey);
    }

    final cross = findPluginForPlatform(
      platformLabel: platformLabel,
      installedPlugins: sources,
      format: pluginFormat,
      allowCrossFormat: true,
    );
    if (cross == null) return null;
    if (cross.format == pluginFormat) return null;

    final keyword = artist.isEmpty ? title : '$title $artist';
    try {
      final PluginSearchResult? match;
      if (cross.format.isMfCompatible) {
        final catalog = PluginCatalogService(engine, sources);
        final results = await catalog.searchMusic(cross, keyword, limit: 10);
        match = _pickBestSearchMatch(results, title, artist);
      } else {
        final lxKey = _lxSourceKeyForPlatform(platformLabel, cross);
        final results = await engine.searchInPlugin(cross, lxKey, keyword, limit: 10);
        match = _pickBestSearchMatch(results, title, artist);
      }
      if (match == null) return null;

      final newSongJson = cross.format.isMfCompatible
          ? {
              'pluginId': cross.id,
              'format': cross.format.value,
              'musicInfo': match.toJson(),
            }
          : {
              'pluginId': cross.id,
              'format': 'lx',
              'source': match.source,
              'musicInfo': match.toJson(),
            };
      _crossFormatHealCache[cacheKey] = newSongJson;
      if (_crossFormatHealCache.length > 64) {
        _crossFormatHealCache.remove(_crossFormatHealCache.keys.first);
      }
      return (cross, newSongJson);
    } catch (e) {
      return null;
    }
  }

  void _applyCrossFormatHealToState({
    required String itemPath,
    required String pluginId,
    required String newOnlineSongJson,
    required String newSource,
    required String newOnlineInfoJson,
  }) {
    final cur = state.current;
    if (cur != null && cur.path == itemPath) {
      final curOnline = cur.onlineSongJson;
      if (curOnline != null && curOnline.contains('"pluginId":"$pluginId"')) {
        return;
      }
    }
    final updated = cur?.path == itemPath
        ? cur!.copyWithOnlineSource(
            onlineSongJson: newOnlineSongJson,
            source: newSource,
            onlineInfoJson: newOnlineInfoJson,
          )
        : cur;
    final queue = state.queue.map((q) {
      if (q.path != itemPath) return q;
      return q.copyWithOnlineSource(
        onlineSongJson: newOnlineSongJson,
        source: newSource,
        onlineInfoJson: newOnlineInfoJson,
      );
    }).toList();
    state = state.copyWith(current: updated, queue: queue);
  }

  PluginSearchResult? _pickBestSearchMatch(
    List<PluginSearchResult> results,
    String title,
    String artist,
  ) {
    if (results.isEmpty) return null;
    for (final r in results) {
      if (PlayerNotifier._matchOnlineTitle(title, r.name)) return r;
    }
    return results.first;
  }

  String _lxSourceKeyForPlatform(String platformLabel, PluginSource plugin) {
    final lxKey = lxSourceKeyForPlatform(platformLabel);
    for (final s in plugin.sources) {
      if (s == lxKey) return s;
    }
    return lxKey.isNotEmpty ? lxKey : (plugin.sources.isNotEmpty ? plugin.sources.first : 'default');
  }
}
