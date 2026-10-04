part of 'player_provider.dart';

extension PlayerNotifierQuality on PlayerNotifier {
  Future<void> _prewarmOnlineSizes(QueueItem item) async {
    // 真实体积探测关闭时零预热：起播仅解析当前档，弹层打开再按需补
    if (!(_ref.read(settingsProvider).valueOrNull?.showRealQualitySizes ??
        false)) {
      return;
    }
    final json = item.onlineSongJson ?? item.onlineInfoJson;
    if (json == null || json.isEmpty) return;
    String key;
    try {
      final songJson = jsonDecode(json) as Map<String, dynamic>;
      key = _songProbeKey(songJson, item);
    } catch (_) {
      return;
    }
    if (!_prewarmKeys.add(key)) return;
    if (_prewarmKeys.length > 16) _prewarmKeys.remove(_prewarmKeys.first);
    try {
      final songJson = jsonDecode(json) as Map<String, dynamic>;
      final probe = onlineQualityProbeRegistry.ensure(
          key, _buildResolveCallback(songJson, item));
      final declared = await _declaredQualities(songJson);
      final targets = declared.isNotEmpty
          ? kQualityLadder.reversed.where(declared.contains).toList()
          : kQualityLadder.reversed
              .where((q) => isLosslessQuality(q) || q == '320k' || q == '128k')
              .toList();
      await Future.wait(targets.map(probe.probe).toList())
          .timeout(const Duration(seconds: 30));
      await qualitySizes();
    } catch (_) {
      _prewarmKeys.remove(key);
    }
  }

  String _shortResolveReason(String raw) {
    if (raw.contains('熔断')) return '音源熔断中，稍后自动重试';
    if (raw.contains('鉴权') || raw.contains('卡密') || raw.contains('不支持')) {
      return '音源鉴权失败';
    }
    if (raw.contains('超时') || raw.toLowerCase().contains('timeout')) {
      return '音源请求超时';
    }
    if (raw.contains('rate') || raw.contains('限') || raw.contains('429')) {
      return '音源请求被限流';
    }
    final s = raw.trim();
    return s.length > 24 ? '${s.substring(0, 24)}…' : s;
  }

  String _songProbeKey(Map<String, dynamic> songJson, QueueItem item) {
    final pid = songJson['pluginId'];
    final src = songJson['source'];
    final mid = songJson['songmid'] ?? songJson['id'];
    if (pid != null) {
      return 'plugin:$pid:${mid ?? songJson['title'] ?? item.title}';
    }
    return 'lx:$src:${mid ?? item.title}';
  }

  Future<List<String>> _declaredQualities(Map<String, dynamic> songJson) async {
    final out = <String>{};
    final pid = songJson['pluginId'];
    if (pid is String && pid.isNotEmpty) {
      final musicInfo = songJson['musicInfo'];
      if (musicInfo is Map) {
        final types = musicInfo['_types'];
        if (types is Map) {
          for (final k in types.keys) {
            final norm = PluginEngine.normalizeQualityKey(k);
            if (norm != null) out.add(norm);
          }
        }
      }
      if (out.isEmpty) {
        try {
          final engine = _ref.read(pluginEngineProvider).valueOrNull;
          final meta = engine?.metadataOf(pid);
          final raw = meta?['supportedQualities'];
          AppLog.debug('quality', '[quality] declared pid=$pid meta=${meta == null ? 'null' : 'ok'} '
              'supportedQualities=$raw');
          if (raw is List) {
            for (final dq in raw) {
              final norm = PluginEngine.normalizeQualityKey(dq);
              if (norm != null) out.add(norm);
            }
          }
        } catch (_) {
          // 读取失败按默认值处理
        }
      }
      if (out.isEmpty) {
        out.addAll(const {'128k', '320k', 'flac'});
      }
    } else {
      final types = songJson['_types'];
      if (types is Map) {
        for (final k in types.keys) {
          final norm = PluginEngine.normalizeQualityKey(k);
          if (norm != null) out.add(norm);
        }
      }
    }
    final result = kQualityLadder.where(out.contains).toList();
    AppLog.debug('quality', '[quality] _declaredQualities pid=$pid result=$result');
    return result;
  }

  Future<ResolvedMediaUrl?> Function(String) _buildResolveCallback(
      Map<String, dynamic> songJson, QueueItem item) {
    final hasPlugin = songJson.containsKey('pluginId');
    return (String q) async {
      if (hasPlugin) {
        final u = await _resolvePluginUrl(songJson, q, itemPath: item.path);
        if (u != null && PlayerNotifier._isPlayableUrl(u.url)) return u;
        final musicInfo =
            songJson['musicInfo'] as Map<String, dynamic>? ?? {};
        final fallbackInfo = <String, dynamic>{
          if ((songJson['source'] as String?)?.isNotEmpty ?? false)
            'source': songJson['source'],
          ...musicInfo,
        };
        final lx = await _lxResolveQuality(jsonEncode(fallbackInfo), q);
        if (lx != null) return lx;
        return null;
      }
      return _lxResolveQuality(jsonEncode(songJson), q);
    };
  }

  Future<ResolvedMediaUrl?> _lxResolveQuality(
      String songInfoJson, String quality) async {
    try {
      final engine = await _ref.read(pluginEngineProvider.future);
      final songInfo = jsonDecode(songInfoJson) as Map<String, dynamic>;
      final resolved = await engine
          .resolveLxUrl(songInfo, quality)
          .timeout(const Duration(seconds: 8));
      final url = resolved?['url'] as String?;
      if (!PlayerNotifier._isPlayableUrl(url)) {
        AppLog.warn('lx', '[lxResolve] 插件 $quality 无结果/非法直链: $url');
        return null;
      }
      AppLog.info('lx', '[lxResolve] 插件 $quality 命中');
      return ResolvedMediaUrl(
        url: url!,
        headers: resolved?['headers'] as Map<String, String>?,
      );
    } catch (e) {
      AppLog.error('lx', '[lxResolve] 插件 $quality 异常: $e');
      return null;
    }
  }

  void _refreshQualityMenuState(SongQualityProbe probe) {
    state = state.copyWith(
      availableQualities: probe.availableQualities,
      qualityMenuProbing: probe.probing,
    );
  }

  Future<bool> switchQuality(String quality) async {
    final item = state.current;
    if (item == null || !item.isOnline) return false;
    final json = item.onlineSongJson ?? item.onlineInfoJson;
    if (json == null || json.isEmpty) return false;
    if (quality == state.currentQuality) return true;
    final prevOverride = _sessionQualityOverride;
    _sessionQualityOverride = quality;
    try {
      await _prewarmQuality(item, quality);
      final resumePos = state.position;
      await _playAt(
        state.queueIndex,
        startAtSecs: resumePos,
        continueStatsSession: true,
        skipOnFailure: false,
      );
      if (state.current?.path != item.path) return false;
      final picked = state.currentQuality;
      if (picked != null && picked.isNotEmpty) {
        final updated = (state.current ?? item).copyWithQuality(picked);
        state = state.copyWith(
          current: updated,
          queue: state.queue
              .map((e) => e.path == item.path ? updated : e)
              .toList(),
        );
      }
      return true;
    } catch (_) {
      _sessionQualityOverride = prevOverride;
      return false;
    }
  }

  Future<void> _prewarmQuality(QueueItem item, String quality) async {
    final json = item.onlineSongJson;
    if (json == null || json.isEmpty) return;
    QualityProbeResult? resolved;
    try {
      final songJson = jsonDecode(json) as Map<String, dynamic>;
      final key = _songProbeKey(songJson, item);
      final probe = onlineQualityProbeRegistry.ensure(
          key, _buildResolveCallback(songJson, item));
      resolved = await probe
          .probe(quality)
          .timeout(const Duration(seconds: 20), onTimeout: () => null);
    } catch (e) {
      AppLog.debug('player', '音质预热失败: $e');
    }
    final res = resolved;
    if (res == null || res.url.isEmpty || res.ekey != null || res.cek != null) {
      return;
    }
    try {
      final clean = sanitizeMediaUrl(res.url);
      if (clean.isEmpty || !clean.startsWith('http')) return;
      final h = await withBilibiliStreamCookie(
            clean,
            normalizeMediaRequestHeaders(clean, res.headers),
            dataDir: _ref.read(appDataDirProvider.future),
          ) ??
          const <String, String>{};
      AudioHeadCache.instance.registerHeaders(clean, h);
      await AudioProxyServer.instance.ensureStarted();
      unawaited(streamCacheBeginUrlDownload(
          url: clean, headers: jsonEncode(h)));
    } catch (e) {
      AppLog.debug('player', '流缓存预热失败: $e');
    }
  }

  Future<List<String>> qualityOptions() =>
      _probeQualityOptions(forDownload: false);

  Future<List<String>> downloadQualityOptions() =>
      _probeQualityOptions(forDownload: true);

  Future<Map<String, QualitySizeInfo>> qualitySizes() async {
    final item = state.current;
    final json = item?.onlineSongJson ?? item?.onlineInfoJson;
    if (item == null || json == null || json.isEmpty) return const {};
    try {
      final songJson = jsonDecode(json) as Map<String, dynamic>;
      final key = _songProbeKey(songJson, item);
      final probe = onlineQualityProbeRegistry.peek(key);
      if (probe == null) return const {};

      final shown = state.availableQualities;
      if (shown.isNotEmpty) {
        final have = {
          for (final r in probe.resolved) r.requested ?? r.quality
        };
        final missing = shown.where((q) => !have.contains(q)).toList();
        if (missing.isNotEmpty) {
          await Future.wait(missing.map(probe.probe))
              .timeout(const Duration(seconds: 20),
                  onTimeout: () => <QualityProbeResult?>[]);
        }
      }

      final entries = probe.resolved;
      if (entries.isEmpty) return const {};
      final metaSizes = _metadataQualitySizes(songJson);
      final out = <String, QualitySizeInfo>{};
      final keys = <String>[
        ...shown,
        for (final r in entries)
          if (r.requested != null && !shown.contains(r.requested!))
            r.requested!,
      ];
      // 真实体积探测关闭时跳过 Range 请求，仅元数据自报值兜底
      final realSizes =
          _ref.read(settingsProvider).valueOrNull?.showRealQualitySizes ??
          false;
      for (final q in keys) {
        final entry = _entryForShown(entries, q);
        if (entry != null) {
          final cached = _qualitySizeByUrl[entry.url];
          if (cached != null) {
            out[q] = QualitySizeInfo(url: entry.url, bytes: cached);
            continue;
          }
          if (!realSizes) {
            final meta = metaSizes[q];
            if (meta != null) {
              out[q] = QualitySizeInfo(url: entry.url, bytes: meta);
            }
            continue;
          }
          try {
            final raw = await probeUrlSize(url: entry.url);
            final info = jsonDecode(raw);
            final size = info is Map<String, dynamic> ? info['size'] : null;
            if (size is num && size > 0) {
              if (_qualitySizeByUrl.length > 200) _qualitySizeByUrl.clear();
              _qualitySizeByUrl[entry.url] = size.toInt();
              out[q] = QualitySizeInfo(url: entry.url, bytes: size.toInt());
              continue;
            }
          } catch (e) {
            AppLog.debug('player', '音质体积探测失败: $e');
          }
        }
        final meta = metaSizes[q];
        if (meta != null) {
          out[q] = QualitySizeInfo(url: entry?.url ?? '', bytes: meta);
        }
      }
      return out;
    } catch (e) {
      AppLog.debug('quality', '[quality] 体积探测失败: $e');
      return const {};
    }
  }

  QualityProbeResult? _entryForShown(
      List<QualityProbeResult> entries, String q) {
    for (final r in entries) {
      if (r.requested == q) return r;
    }
    for (final r in entries) {
      if (r.quality == q) return r;
    }
    return null;
  }

  Map<String, int> _metadataQualitySizes(Map<String, dynamic> songJson) {
    final out = <String, int>{};
    void scan(dynamic raw) {
      if (raw is! Map) return;
      final m = raw.cast<String, dynamic>();
      for (final entry in m.entries) {
        final norm = PluginEngine.normalizeQualityKey(entry.key);
        if (norm == null || out.containsKey(norm)) continue;
        final v = entry.value;
        final size = v is Map ? v['size'] : null;
        final bytes = PlayerNotifier._parseQualitySize(size);
        if (bytes != null) out[norm] = bytes;
      }
    }

    final musicInfo = songJson['musicInfo'];
    if (musicInfo is Map) {
      final info = musicInfo.cast<String, dynamic>();
      final rawData = info['rawData'];
      if (rawData is Map) {
        scan(rawData.cast<String, dynamic>()['qualities']);
      }
      scan(info['qualities']);
      scan(info['_types']);
      scan(info['lx_types']);
    }
    scan(songJson['qualities']);
    scan(songJson['_types']);
    scan(songJson['lx_types']);
    return out;
  }

  Future<List<String>> _probeQualityOptions(
      {required bool forDownload}) async {
    await Future<void>.delayed(Duration.zero);
    final item = state.current;
    final json = item?.onlineSongJson ?? item?.onlineInfoJson;
    AppLog.debug('quality', '[quality] _probeQualityOptions item=${item?.title} '
        'onlineSongJson=${item?.onlineSongJson?.isNotEmpty ?? false} '
        'onlineInfoJson=${item?.onlineInfoJson?.isNotEmpty ?? false}');
    if (json == null || json.isEmpty) return const [];
    try {
      final songJson = jsonDecode(json) as Map<String, dynamic>;
      final key = _songProbeKey(songJson, item!);
      final probe = onlineQualityProbeRegistry
          .ensure(key, _buildResolveCallback(songJson, item));
      _activeProbeKey = key;
      state = state.copyWith(qualityMenuProbing: true);

      final declared = await _declaredQualities(songJson);
      if (declared.isNotEmpty) {
        final base = kQualityLadder.reversed.where(declared.contains).toList();
        AppLog.debug('quality', '[quality] declared non-empty base=$base');
        state = state.copyWith(
          availableQualities: base,
          qualityMenuProbing: true,
        );
        unawaited(_probeInBackground(probe, declared, base));
        return base;
      }

      final targets = kQualityLadder.reversed
          .where((q) => isLosslessQuality(q) || q == '320k' || q == '128k')
          .toList();
      AppLog.debug('quality', '[quality] declared empty, probing targets=$targets');
      await Future.wait(targets.map(probe.probe).toList());

      final opts = <String>{...probe.availableQualities};
      if (state.currentQuality != null) opts.add(state.currentQuality!);
      final ordered =
          kQualityLadder.reversed.where(opts.contains).toList();
      AppLog.info('quality', '[quality] probe done opts=$ordered');
      if (ordered.isEmpty) probe.markFailed();
      state = state.copyWith(
        availableQualities: ordered,
        qualityMenuProbing: false,
      );
      return ordered;
    } catch (e) {
      AppLog.error('quality', '[quality] _probeQualityOptions error: $e');
      state = state.copyWith(qualityMenuProbing: false);
      return state.availableQualities;
    }
  }

  Future<void> _probeInBackground(
    SongQualityProbe probe,
    List<String> targets,
    List<String> base,
  ) async {
    try {
      if (await _tryBakaTrustProbe(probe, targets, base)) {
        state = state.copyWith(
          availableQualities: probe.availableQualities,
          qualityMenuProbing: false,
        );
        return;
      }

      if (await _currentIsPluginSong()) {
        final groups = <String, List<String>>{};
        for (final q in targets) {
          groups
              .putIfAbsent(PluginEngine.qualityKeyToMfQuality(q), () => [])
              .add(q);
        }
        await Future.wait(groups.values.map((grp) async {
          final rep = grp.reduce((a, b) =>
              kQualityLadder.indexOf(a) > kQualityLadder.indexOf(b) ? a : b);
          try {
            final res =
                await probe.probe(rep).timeout(const Duration(seconds: 15));
            if (res != null && res.url.isNotEmpty) {
              probe.trustDeclared(grp);
            }
          } catch (e) {
            AppLog.debug('player', '音质探测失败: $e');
          }
        }));
      } else {
        await Future.wait(targets.map(probe.probe).toList())
            .timeout(const Duration(seconds: 30));
      }

      final opts = <String>{...probe.availableQualities};
      if (state.currentQuality != null) opts.add(state.currentQuality!);
      if (opts.isEmpty) opts.addAll(base);
      final ordered =
          kQualityLadder.reversed.where(opts.contains).toList();
      if (ordered.isEmpty) probe.markFailed();
      state = state.copyWith(
        availableQualities: ordered,
        qualityMenuProbing: false,
      );
    } catch (_) {
      state = state.copyWith(qualityMenuProbing: false);
    }
  }

  Future<bool> _currentIsPluginSong() async {
    final item = state.current;
    final json = item?.onlineSongJson ?? item?.onlineInfoJson;
    if (item == null || json == null || json.isEmpty) return false;
    try {
      final songJson = jsonDecode(json) as Map<String, dynamic>;
      final pid = songJson['pluginId'] as String?;
      return pid != null && pid.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _tryBakaTrustProbe(
    SongQualityProbe probe,
    List<String> targets,
    List<String> base,
  ) async {
    if (targets.isEmpty || base.isEmpty) return false;
    final item = state.current;
    final json = item?.onlineSongJson ?? item?.onlineInfoJson;
    if (item == null || json == null || json.isEmpty) return false;
    final String? pluginId;
    try {
      final songJson = jsonDecode(json) as Map<String, dynamic>;
      pluginId = songJson['pluginId'] as String?;
    } catch (_) {
      return false;
    }
    if (pluginId == null || pluginId.isEmpty) return false;
    final engine = _ref.read(pluginEngineProvider).valueOrNull;
    if (engine == null || !engine.isBakaPlugin(pluginId)) return false;

    final top = targets.reduce((a, b) =>
        kQualityLadder.indexOf(a) > kQualityLadder.indexOf(b) ? a : b);
    final res = await probe.probe(top).timeout(const Duration(seconds: 10));
    if (res == null || res.url.isEmpty) return false;
    if (res.quality != top) {
      AppLog.info('quality', '[quality] Baka 最高档 $top 实际返回 ${res.quality}，回退逐档实测');
      return false;
    }
    probe.trustDeclared(base);
    final ordered = probe.availableQualities;
    AppLog.info('quality', '[quality] Baka 信任模式命中，声明档全量可用 $ordered');
    return true;
  }
}
