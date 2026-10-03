part of 'player_provider.dart';

extension PlayerNotifierAudioChain on PlayerNotifier {
  Future<void> _probeAndRebuild(String reason) async {
    if (_rebuildingPlayer) return;
    try {
      await const MethodChannel('xianyu/diag')
          .invokeMethod<Object>('ping')
          .timeout(const Duration(seconds: 2));
      return; // 主线程有响应，不重建
    } on TimeoutException {
      // 主线程无响应 → 楔死，走重建
    } catch (_) {
      return;
    }
    await _rebuildPlayer(reason);
  }

  Future<void> _rebuildPlayer(String reason) async {
    if (_rebuildingPlayer) return;
    _rebuildingPlayer = true;
    try {
      final old = _player;
      AppLog.warn('play', '[player-rebuild] 重建播放器通道 reason=$reason');
      unawaited(old.dispose().catchError((_) {}).timeout(
            const Duration(seconds: 3),
            onTimeout: () {
              AppLog.warn('play', '[player-rebuild] 旧实例 dispose 挂起，放弃等待');
            },
          ));
      _player = _GatedAudioPlayer();
      _subscribePlayerStreams();
      try {
        await _player.setVolume(_effectiveVolume())
            .timeout(const Duration(seconds: 2));
      } catch (_) {}
    } finally {
      _rebuildingPlayer = false;
    }
  }

  Future<void> _onExclusiveSettingChanged(bool enabled) async {
    final item = state.current;
    if (item == null || item.isOnline || PlayerNotifier._isRemotePath(item.path)) return;
    final pos = state.position;
    final playing = state.isPlaying;
    var target = item.path;
    if (SafChannel.isSafPath(target)) {
      final tmp = await getTemporaryDirectory();
      target = await SafChannel.ensureLocalPlaybackCopy(
          target, p.join(tmp.path, 'saf_playback'));
    }
    if (enabled) {
      if (state.usbExclusive) return;
      final ok =
          await _tryStartExclusive(target, startAtSecs: pos, isPlaying: playing);
      if (ok) {
        try {
          await _player.stop();
        } catch (_) {}
        state = state.copyWith(isPlaying: playing);
        _syncToSystemMediaSession();
      }
    } else {
      if (!state.usbExclusive) return;
      await _stopExclusive();
      final ok =
          await _tryStartDspPipeline(target, startAtSecs: pos, isPlaying: playing);
      if (ok) {
        try {
          await _player.stop();
        } catch (_) {}
        state = state.copyWith(isPlaying: playing);
        _syncToSystemMediaSession();
        return;
      }
      try {
        await _updateRgGain(target);
        await _setLocalSource(target);
        await _player.setVolume(_effectiveVolume());
        await _player.seek(Duration(milliseconds: (pos * 1000).round()));
        if (playing) {
          await _player.play();
        } else {
          await _player.pause();
        }
        state = state.copyWith(isPlaying: playing);
        _syncToSystemMediaSession();
      } catch (e) {
        AppLogger.instance
            .log('exclusive', '关闭 USB 独占后恢复普通播放失败: $e');
        state = state.copyWith(isPlaying: false);
        _syncToSystemMediaSession();
      }
    }
  }

  Future<void> _onOutputDeviceChanged() async {
    if (!state.usbExclusive && !state.dspActive) return;
    final item = state.current;
    if (item == null || item.isOnline || PlayerNotifier._isRemotePath(item.path)) return;
    final pos = state.position;
    final playing = state.isPlaying;
    var target = item.path;
    if (SafChannel.isSafPath(target)) {
      final tmp = await getTemporaryDirectory();
      target = await SafChannel.ensureLocalPlaybackCopy(
          target, p.join(tmp.path, 'saf_playback'));
    }
    final wantExclusive =
        _ref.read(settingsProvider).valueOrNull?.usbExclusiveOutput ?? false;
    await _stopExclusive();
    var ok = false;
    if (wantExclusive) {
      ok = await _tryStartExclusive(target,
          startAtSecs: pos, isPlaying: playing);
    } else {
      ok = await _tryStartDspPipeline(target,
          startAtSecs: pos, isPlaying: playing);
    }
    if (ok) {
      try {
        await _player.stop();
      } catch (_) {}
      state = state.copyWith(isPlaying: playing);
      _syncToSystemMediaSession();
      return;
    }
    try {
      await _updateRgGain(target);
      await _setLocalSource(target);
      await _player.setVolume(_effectiveVolume());
      await _player.seek(Duration(milliseconds: (pos * 1000).round()));
      if (playing) {
        await _player.play();
      } else {
        await _player.pause();
      }
      state = state.copyWith(isPlaying: playing);
      _syncToSystemMediaSession();
    } catch (_) {}
  }

  Future<bool> _tryStartExclusive(
    String path, {
    required double startAtSecs,
    required bool isPlaying,
  }) async {
    if (!path.startsWith('http')) {
      LastAudioSource.recordFilePath(path);
    }
    try {
      final sfx = _ref.read(soundEffectProvider).settings;
      final settings = _ref.read(settingsProvider).valueOrNull;
      final bitPerfect = settings?.bitPerfectOutput ?? false;
      final dsd = settings?.dsdNativePassthrough ?? false;
      await startUsbExclusivePlayback(
        path: path,
        deviceId: settings?.usbExclusiveDeviceId ?? -1,
        volume: _mvAudioOverride ? 0.0 : _ref.read(volumeProvider),
        startTimeSecs: startAtSecs,
        isPlaying: isPlaying,
        volumeBalanceGain: bitPerfect ? 1.0 : _effectiveBalanceGain(),
        equalizerSettingsJson: bitPerfect ? '' : jsonEncode(sfx.toEqualizerRustJson()),
        soundEffectSettingsJson: bitPerfect ? '' : jsonEncode(sfx.toRustJson()),
        bitPerfect: bitPerfect,
        dsdNativePassthrough: dsd,
        sharedMode: false,
        // 跳过静音：独占直出时也走解码器外层包装，直出照样能剪静音
        skipSilenceEnabled: settings?.skipSilenceEnabled ?? false,
        skipSilenceThresholdDb: settings?.skipSilenceThresholdDb ?? -45.0,
        skipSilenceKeepMs: settings?.skipSilenceKeepMs ?? 500,
      );
      state = state.copyWith(usbExclusive: true, isPlaying: isPlaying);
      _startExclusivePolling();
      _syncToSystemMediaSession();
      return true;
    } catch (e) {
      state = state.copyWith(usbExclusive: false);
      AppLogger.instance.log('exclusive', 'USB 独占输出启动失败，回退普通播放: $e');
      return false;
    }
  }

  Future<bool> _tryStartDspPipeline(
    String path, {
    required double startAtSecs,
    required bool isPlaying,
    String? streamCacheUrl,
    Map<String, String>? streamCacheHeaders,
    bool castPlayback = false,
  }) async {
    if (DateTime.now().isBefore(_dspFailUntil)) {
      AppLog.warn('play', '[dsp] 跳过接管: 失败冷却中(至 $_dspFailUntil)');
      return false;
    }
    if (_dspSkipNextStart) {
      _dspSkipNextStart = false;
      AppLog.warn('play', '[dsp] 跳过接管: skipNextStart 标志(管线曾异常退出)');
      return false;
    }
    if (!path.startsWith('http')) {
      LastAudioSource.recordFilePath(path);
    }
    try {
      var sfx = _ref.read(soundEffectProvider).settings;
      if (castPlayback) {
        // 被投播放按 DLNA 语义强制原速原调，其余音效（EQ/混响等）保持
        sfx = sfx.copyWith(playbackRate: 100.0, pitchShift: 100.0);
      }
      final settings = _ref.read(settingsProvider).valueOrNull;
      final deviceName = await startUsbExclusivePlayback(
        path: path,
        deviceId: settings?.usbExclusiveDeviceId ?? -1,
        volume: _mvAudioOverride ? 0.0 : _ref.read(volumeProvider),
        startTimeSecs: startAtSecs,
        isPlaying: isPlaying,
        volumeBalanceGain: _effectiveBalanceGain(),
        equalizerSettingsJson: jsonEncode(sfx.toEqualizerRustJson()),
        soundEffectSettingsJson: jsonEncode(sfx.toRustJson()),
        bitPerfect: false,
        dsdNativePassthrough: false,
        sharedMode: true,
        streamCacheUrl: streamCacheUrl,
        streamCacheHeaders: streamCacheHeaders == null
            ? null
            : jsonEncode(streamCacheHeaders),
        skipSilenceEnabled: settings?.skipSilenceEnabled ?? false,
        skipSilenceThresholdDb: settings?.skipSilenceThresholdDb ?? -45.0,
        skipSilenceKeepMs: settings?.skipSilenceKeepMs ?? 500,
      );
      state = state.copyWith(usbExclusive: false, dspActive: true, isPlaying: isPlaying);
      _startExclusivePolling();
      _syncToSystemMediaSession();
      AppLog.info('play', '[dsp] 共享管线接管成功: $deviceName');
      return true;
    } catch (e) {
      state = state.copyWith(dspActive: false);
      _dspFailUntil = DateTime.now().add(const Duration(seconds: 60));
      AppLog.warn('play', '[dsp] 启动失败(60s冷却后重试) 回退ExoPlayer: $e');
      return false;
    }
  }

  Future<void> _stopExclusive() async {
    _stopExclusivePolling();
    try {
      await stopUsbExclusivePlayback();
    } catch (_) {}
    // 管线没了，预排的下一首与过渡计数一并作废
    _gaplessNextIndex = -1;
    _gaplessNextPath = null;
    _lastTransitionSeq = 0;
    if (state.usbExclusive ||
        state.dspActive ||
        state.outSampleRate != 0 ||
        state.outChannels != 0 ||
        state.outBitPerfect) {
      state = state.copyWith(
        usbExclusive: false,
        dspActive: false,
        // 回退到 ExoPlayer 后输出参数不再来自 AAudio，清掉避免显示过期格式
        outSampleRate: 0,
        outChannels: 0,
        outBitPerfect: false,
      );
    }
  }

  void _startExclusivePolling() {
    _stopExclusivePolling();
    // 新会话的管线侧配置是默认值：把交叉时长补上（默认关 → 0）
    final s = _ref.read(settingsProvider).valueOrNull;
    _pushCrossfade(s?.crossfadeEnabled ?? false, s?.crossfadeSeconds ?? 5);
    _exclusiveTimer = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => _pollExclusive(),
    );
  }

  void _stopExclusivePolling() {
    _exclusiveTimer?.cancel();
    _exclusiveTimer = null;
  }

  /// 下发曲间交叉淡入淡出时长（未接管时忽略；关闭 = 0）。
  void _pushCrossfade(bool enabled, int seconds) {
    if (!state.usbExclusive && !state.dspActive) return;
    try {
      setUsbExclusiveCrossfade(ms: enabled ? (seconds * 1000) : 0);
    } catch (_) {}
  }

  /// 下发跳过静音参数到 Rust 管线（未接管时忽略）。
  void _pushSkipSilence(bool enabled, double thresholdDb, int keepMs) {
    if (!state.usbExclusive && !state.dspActive) return;
    try {
      setUsbExclusiveSkipSilence(
        enabled: enabled,
        thresholdDb: thresholdDb,
        keepMs: keepMs,
      );
    } catch (_) {}
  }

  Future<void> _pollExclusive() async {
    if (!state.usbExclusive && !state.dspActive) return;
    try {
      final pos = await getUsbExclusivePositionSecs();
      state = state.copyWith(position: pos);
      _syncToSystemMediaSession();
      _persistPositionDebounced();
      _maybePrecacheNextRemote(pos);
      final infoStr = await getUsbExclusiveDeviceInfo();
      final info = jsonDecode(infoStr) as Map<String, dynamic>;
      final engineDur = (info['durationSecs'] as num?)?.toDouble() ?? 0.0;
      if (engineDur > 0) {
        state = state.copyWith(duration: engineDur);
      }
      // 输出格式（AAudio 流实际参数）：质量指示要显示「源 → 输出」，
      // 只有拿到真实输出采样率才能判断有没有重采样。
      final outRate = (info['sampleRate'] as num?)?.toInt() ?? 0;
      final outCh = (info['channels'] as num?)?.toInt() ?? 0;
      final outBp = info['bitPerfect'] == true;
      if (state.outSampleRate != outRate ||
          state.outChannels != outCh ||
          state.outBitPerfect != outBp) {
        state = state.copyWith(
          outSampleRate: outRate,
          outChannels: outCh,
          outBitPerfect: outBp,
        );
      }
      // 管线关键事件（seek / 预排就绪 / 无缝拼接 / 交叉时长 / 跳过静音切换）：
      // Rust 侧「取出即清空」，所以只有真发生事件时才非空，不会刷屏。
      // 作用是让这几项在真机上可从日志核对，而不是只能靠耳朵判断。
      final diag = await takeUsbExclusivePipelineDiag();
      if (diag.isNotEmpty) {
        AppLog.info('play', '[dsp-diag] $diag');
      }
      final dur = state.duration;
      // 无缝拼接已发生：Rust 侧已经接上下一首，这里只把队列/UI 推进过去，
      // 绝不能重启管线（重启就又出缝了）。
      final tseq = (info['transitionSeq'] as num?)?.toInt() ?? 0;
      if (tseq != _lastTransitionSeq) {
        _lastTransitionSeq = tseq;
        await _onGaplessTransition();
        return;
      }
      if (info['active'] != true) {
        final lastErr = (info['lastError'] as String?)?.trim() ?? '';
        AppLog.warn('play',
            '[dsp] 轮询发现 active=false pos=${pos.toStringAsFixed(1)} lastError=$lastErr');
        if (dur > 0 && pos >= dur - 0.3) {
          await _onExclusiveTrackEnd();
        } else {
          await _onExclusiveDisconnect();
        }
        return;
      }
      if (dur > 0 && pos >= dur - 0.3) {
        await _onExclusiveTrackEnd();
        return;
      }
      // 快播完了就把下一首预排给 Rust（本地/直链才预排）
      _maybeQueueGaplessNext();
    } catch (_) {}
  }

  Future<void> _onExclusiveDisconnect() async {
    final cur = state.current;
    _flushPlayStats();
    AppLog.warn('play',
        '[dsp] 管线提前退出(active=false) 自动重播回退 cur=${cur?.title}');
    if (cur != null) statsReporter.reportBehavior(cur, 'usb_disconnect', 0);
    await _stopExclusive();
    _dspSkipNextStart = true;
    if (cur == null) return;
    await _playAt(state.queueIndex);
  }

  Future<void> _onExclusiveTrackEnd() async {
    final ended = state.current;
    if (ended != null) statsReporter.reportBehavior(ended, 'complete', 0);
    _flushPlayStats();
    await _stopExclusive();
    if (state.playMode == 1) {
      await _playAt(state.queueIndex);
      return;
    }
    final next = _pickNextIndex();
    if (next < 0) {
      state = state.copyWith(isPlaying: false, position: 0);
      _syncToSystemMediaSession();
      return;
    }
    await _playAt(next);
  }

  /// 剩余不多时把「下一首」预排给 Rust：播完直接接上，不重启管线。
  ///
  /// 只预排本地文件；在线源需要 Dart 先解析直链并预热流缓存（后续再做），
  /// 这里不下发，让它走普通切歌，不会更差。
  void _maybeQueueGaplessNext() {
    if (!state.usbExclusive && !state.dspActive) return;
    final gapless =
        _ref.read(settingsProvider).valueOrNull?.gaplessEnabled ?? true;
    if (!gapless) return;
    if (_gaplessNextIndex >= 0) return; // 已预排
    final dur = state.duration;
    if (dur <= 0) return;
    if (dur - state.position > 15) return; // 还早，等下一轮轮询再看
    final queue = state.queue;
    if (queue.isEmpty) return;
    final int next;
    if (state.playMode == 1) {
      next = state.queueIndex; // 单曲循环：无缝重来
    } else {
      // 注意：随机模式下这里会消费一次随机队列，所以结果必须缓存下来，
      // 过渡时直接用它，不能再算一次。
      next = _pickNextIndex();
    }
    if (next < 0 || next >= queue.length) return;
    final item = queue[next];
    if (item.isOnline || PlayerNotifier._isRemotePath(item.path)) return;
    if (item.path.startsWith('http')) return; // 直链留给后续（需预热流缓存）
    _gaplessNextIndex = next;
    _gaplessNextPath = item.path;
    try {
      setUsbExclusiveNext(path: item.path);
      AppLog.info('play',
          '[gapless] 预排下一首 index=$next path=$_gaplessNextPath');
    } catch (e) {
      _gaplessNextIndex = -1;
      _gaplessNextPath = null;
      AppLog.warn('play', '[gapless] 预排下发失败: $e');
    }
  }

  /// Rust 侧已无缝接上下一首：只推进 Dart 状态，不碰管线（一碰就又出缝）。
  Future<void> _onGaplessTransition() async {
    final queue = state.queue;
    final target = _gaplessNextIndex;
    _gaplessNextIndex = -1;
    _gaplessNextPath = null;
    if (target < 0 || target >= queue.length) {
      // 没预排却收到过渡（理论上不会发生）：按曲终兜底，避免状态停在旧曲
      AppLog.warn('play', '[gapless] 过渡回调缺少预排下标，按曲终兜底');
      await _onExclusiveTrackEnd();
      return;
    }
    final ended = state.current;
    if (ended != null) statsReporter.reportBehavior(ended, 'complete', 0);
    _flushPlayStats();
    final item = queue[target];
    _currentPlayCountRecorded = false;
    _accumulatedTime = 0;
    AppLog.info('play', '[gapless] 已无缝接上 index=$target title=${item.title}');
    state = state.copyWith(
      queueIndex: target,
      current: item,
      position: 0,
      duration: item.durationMs / 1000.0,
      isPlaying: true,
      error: null,
    );
    statsReporter.reportBehavior(item, 'play', 0);
    statsReporter.recordRecentPlay(item);
    statsReporter.recordHistory(item);
    _trackStartTime = DateTime.now();
    _syncToSystemMediaSession();
    unawaited(Future(() => _preloadQueueCovers()));
  }

  void _syncExclusiveEffects(SoundEffectSettings s) {
    if (!state.usbExclusive && !state.dspActive) return;
    _sfxSyncTimer?.cancel();
    _sfxSyncTimer = Timer(const Duration(milliseconds: 50), () async {
      try {
        await setUsbExclusiveEqualizer(
            settingsJson: jsonEncode(s.toEqualizerRustJson()));
        await setUsbExclusiveSoundEffect(
            settingsJson: jsonEncode(s.toRustJson()));
      } catch (_) {}
    });
  }

  Future<void> _applyEffectSpeedPitch(SoundEffectSettings s) async {
    if (state.usbExclusive || state.dspActive) return;
    try {
      final rate = s.playbackRate.clamp(50.0, 200.0) / 100.0;
      await _player.setSpeed(rate);
      if (s.preservesPitch) {
        await _player.setPitch(1.0);
      } else {
        final pitch = s.pitchShift.clamp(50.0, 200.0) / 100.0;
        await _player.setPitch(pitch);
      }
    } catch (_) {
    }
  }

  Future<void> setMvAudioOverride(bool value) async {
    if (_mvAudioOverride == value) return;
    _mvAudioOverride = value;
    if (!value) _mvSongGain = 1.0;
    await _player.setVolume(_effectiveVolume());
    if (state.usbExclusive || state.dspActive) {
      try {
        await setUsbExclusiveVolume(
            volume: _ref.read(volumeProvider) * _mvSongGain);
      } catch (_) {}
    }
  }

  Future<void> setMvSongGain(double gain) async {
    _mvSongGain = gain.clamp(0.0, 1.0);
    await _player.setVolume(_effectiveVolume());
    if (state.usbExclusive || state.dspActive) {
      try {
        await setUsbExclusiveVolume(
            volume: _ref.read(volumeProvider) * _mvSongGain);
      } catch (_) {}
    }
  }

  double _effectiveVolume() =>
      (_ref.read(volumeProvider) *
              _effectiveBalanceGain() *
              (_mvAudioOverride ? _mvSongGain : 1.0) *
              _sleepFade)
          .clamp(0.0, 4.0);

  double _effectiveBalanceGain() {
    final s = _ref.read(settingsProvider).valueOrNull;
    return (s?.volumeBalanceEnabled ?? false) ? _rgGain : 1.0;
  }

  Future<Duration?> _setLocalSource(String path) async {
    var target = path;
    if (target.startsWith('http://') || target.startsWith('https://')) {
      return _player.setUrl(target);
    }
    if (path.startsWith('content://')) {
      final tmp = await getTemporaryDirectory();
      target = await SafChannel.ensureLocalPlaybackCopy(
          path, p.join(tmp.path, 'saf_playback'));
    }
    if (target.startsWith('content://')) {
      return _player.setUrl(target);
    }
    return _player.setFilePath(target);
  }

  Future<void> _updateRgGain(String? path) async {
    final s = _ref.read(settingsProvider).valueOrNull;
    if (s?.volumeBalanceEnabled != true ||
        path == null ||
        path.isEmpty ||
        path.startsWith('http')) {
      _rgGain = 1.0;
      return;
    }
    try {
      _rgGain = await loudnessPlaybackGainForFile(
        filePath: path,
        gainOffsetDb: s?.volumeBalanceGainOffsetDb ?? 0,
        preventClipping: s?.volumeBalancePreventClipping ?? true,
      );
    } catch (_) {
      _rgGain = 1.0;
    }
  }

  Future<void> _onVolumeBalanceSettingChanged() async {
    final item = state.current;
    if (item == null) return;
    if (item.isOnline) {
      _rgGain = 1.0;
    } else if (PlayerNotifier._isRemotePath(item.path)) {
      try {
        final plan = await RemoteLibraryService(_ref).playbackSource(item.path);
        await _updateRgGain(plan.isCached ? plan.cachedPath : null);
      } catch (_) {
        _rgGain = 1.0;
      }
    } else {
      await _updateRgGain(item.path);
    }
    if (state.usbExclusive || state.dspActive) {
      try {
        await setUsbExclusiveVolumeBalanceGain(gain: _effectiveBalanceGain());
      } catch (_) {}
    } else if (!item.isOnline && !state.dspActive) {
      try {
        await _player.setVolume(_effectiveVolume());
      } catch (_) {}
    }
  }
}
