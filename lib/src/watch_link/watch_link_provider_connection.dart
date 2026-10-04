part of 'watch_link_provider.dart';

extension WatchLinkControllerConnection on WatchLinkController {
  // ---- 开关与权限 ----

  void _applyLinkSettings(AppSettings s) {
    _applyEnabled(s.watchLinkageEnabled);
    _applyCloud(
      PlatformCaps.isAndroid &&
          s.watchLinkageEnabled &&
          s.watchLinkCloudEnabled,
    );
  }

  Future<void> _applyEnabled(bool enabled) async {
    if (!enabled) {
      await _channel.stop();
      _running = false;
      return;
    }
    if (_running) return;
    if (!await _channel.hasPermission()) return;
    await _channel.start();
    _running = true;
  }

  void _onPermission(bool granted) {
    if (!granted || _running) return;
    final s = _container.read(settingsProvider).valueOrNull;
    if (s?.watchLinkageEnabled != true) return;
    _channel.start().then((_) => _running = true);
  }

  // ---- 云端兜底通道（P4） ----

  Future<void> _applyCloud(bool desired) async {
    if (!desired) {
      _cloudRunning = false;
      _cloudWatchOnline = false;
      _container.read(watchLinkCloudOnlineProvider.notifier).state = false;
      _cloudReconnect?.cancel();
      await _cloud.close();
      return;
    }
    if (_cloudRunning) return;
    _cloudRunning = true;
    final key = await _ensureCloudKey();
    if (_cloudRunning && key.isNotEmpty) _connectCloud();
  }

  Future<String> _ensureCloudKey() async {
    final s = _container.read(settingsProvider).valueOrNull;
    final existing = s?.watchLinkCloudKey ?? '';
    if (existing.isNotEmpty) return existing;
    final rnd = Random.secure();
    final key = List.generate(32, (_) => rnd.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    await _container.read(settingsProvider.notifier).setWatchLinkCloudKey(key);
    return key;
  }

  void _connectCloud() {
    _cloudReconnect?.cancel();
    _cloudWatchOnline = false;
    _container.read(watchLinkCloudOnlineProvider.notifier).state = false;
    _cloud.connect(url: kWatchCloudRelayUrl, key: _cloudKeyOf());
  }

  String _cloudKeyOf() =>
      _container.read(settingsProvider).valueOrNull?.watchLinkCloudKey ?? '';

  void _onCloudRaw(Uint8List bytes) {
    for (final msg in _cloudDecoder.feed(bytes)) {
      _onMessage(msg, fromCloud: true);
    }
  }

  void _onCloudEvent(CloudLinkEvent evt) {
    switch (evt.kind) {
      case CloudLinkEvent.ready:
        _cloudWatchOnline = true;
        _container.read(watchLinkCloudOnlineProvider.notifier).state = true;
        _cloudBackoff = const Duration(seconds: 5);
      case CloudLinkEvent.peerLost:
        _cloudWatchOnline = false;
        _container.read(watchLinkCloudOnlineProvider.notifier).state = false;
      case CloudLinkEvent.replaced:
      case CloudLinkEvent.closed:
        _cloudWatchOnline = false;
        _container.read(watchLinkCloudOnlineProvider.notifier).state = false;
        if (_cloudRunning) {
          _cloudReconnect?.cancel();
          _cloudReconnect = Timer(_cloudBackoff, () {
            _cloudBackoff = _cloudBackoff * 2 > const Duration(seconds: 15)
                ? const Duration(seconds: 15)
                : _cloudBackoff * 2;
            _connectCloud();
          });
        }
    }
  }

  // ---- 连接事件 ----

  void _onConnection(WatchLinkConnection evt) {
    _connected = evt.connected;
    _connectedName = evt.name;
    _container.read(watchLinkConnectedNameProvider.notifier).state = evt.name;
    _songKey = null;
    _precachedPaths.clear();
    _decoder = FrameDecoder();
    _resetAuth();
    _resetTxPump();
  }

  void _resetTxPump() {
    _txGen++;
    _txDraining = false;
    _txQueue.clear();
    _txLowQueue.clear();
  }

  // ---- 设备管理（设置页） ----

  Future<bool> hasLinkPermission() => _channel.hasPermission();

  Future<void> requestLinkPermission() => _channel.requestPermission();

  Future<List<WatchBondedDevice>> loadPairedDevices() =>
      _channel.pairedDevices();

  Future<bool> connectToWatch(String address) async {
    if (_connected) return true;
    if (!await _channel.hasPermission()) {
      await _channel.requestPermission();
      return false;
    }
    _channel.connect(address);
    return true;
  }

  Future<void> disconnectWatch() async {
    await _channel.disconnect();
    if (_cloudRunning) {
      _cloudReconnect?.cancel();
      await _cloud.close();
      _cloudReconnect = Timer(const Duration(seconds: 3), _connectCloud);
    }
  }

  // ---- Wear Engine ----

  Future<bool> hasWearEngine() => _channel.hasWearEngine();

  Future<void> installHealth() => _channel.installHealth();

  Future<WearAuthResult> wearAuthorize() => _channel.wearAuthorize();

  Future<List<WearEngineDevice>> wearDevices() => _channel.wearDevices();

  Future<String> wearPing() async {
    final r = await _channel.wearWake();
    return r.message.isEmpty
        ? (r.ok ? tr('已拉起腕上端') : tr('唤醒失败'))
        : r.message;
  }

}
