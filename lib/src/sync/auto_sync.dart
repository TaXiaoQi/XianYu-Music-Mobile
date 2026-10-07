import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/account_api.dart';
import '../auth/auth_provider.dart';
import 'sync_provider.dart';
import 'sync_trigger.dart';

class AutoSyncService {
  AutoSyncService(this._ref);
  final Ref _ref;

  Timer? _timer;
  Timer? _debounceTimer;
  final Set<String> _dirty = {};
  bool _syncing = false;
  int _delayedCount = 0;
  int _nextSyncAt = 0;

  AccountApi get _api => _ref.read(accountApiProvider);

  void start() {
    _timer ??= Timer.periodic(const Duration(seconds: 60), (_) => _tick());
    SyncTrigger.register(_onDirty);
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    SyncTrigger.register(null);
  }

  Future<AutoSyncConfig> getConfig() async =>
      _ref.read(syncProvider).autoSyncConfig;

  Future<void> setConfig(AutoSyncConfig config) async {
    await _ref.read(syncProvider.notifier).updateAutoSyncConfig(config);
    _delayedCount = 0;
    _nextSyncAt = 0;
  }

  Future<void> _tick() async {
    if (_syncing) return;
    final config = await getConfig();
    if (!config.enabled) return;
    final auth = _ref.read(authProvider);
    if (!auth.isLoggedIn) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_nextSyncAt > 0 && now < _nextSyncAt) return;
    if (_nextSyncAt == 0) {
      _nextSyncAt = now + _intervalMs(config);
      return;
    }
    await _attemptSync(config);
  }

  int _intervalMs(AutoSyncConfig config) {
    final seconds = config.syncIntervalSeconds <= 0
        ? 60
        : config.syncIntervalSeconds;
    return seconds * 1000;
  }

  // ==================== 数据变更驱动（对齐桌面端） ====================

  // 业务域（歌单/收藏/插件）数据修改后触发；8 秒防抖合并连续变更
  void _onDirty(Set<String> domains) {
    _dirty.addAll(domains);
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(seconds: 8), _flushDirty);
  }

  Future<void> _flushDirty() async {
    if (_dirty.isEmpty) return;
    if (_syncing) {
      // 同步进行中：稍后重试，期间新变更继续并入 _dirty
      _debounceTimer?.cancel();
      _debounceTimer = Timer(const Duration(seconds: 15), _flushDirty);
      return;
    }
    final config = await getConfig();
    if (!config.enabled) {
      _dirty.clear();
      return;
    }
    final auth = _ref.read(authProvider);
    if (!auth.isLoggedIn) return;
    final domains = Set<String>.from(_dirty);
    _dirty.clear();
    _syncing = true;
    try {
      final load = await _api.getServerLoad();
      if (load != null && load.busy) {
        // 服务器繁忙：还回待同步域，交给定时轮询兜底
        _dirty.addAll(domains);
        return;
      }
      await _syncDomains(domains);
      _delayedCount = 0;
      _nextSyncAt =
          DateTime.now().millisecondsSinceEpoch + _intervalMs(config);
    } catch (_) {
      // 失败还回待同步域，定时轮询兜底重试
      _dirty.addAll(domains);
    } finally {
      _syncing = false;
    }
  }

  Future<void> _syncDomains(Set<String> domains) async {
    final upload = _ref.read(syncProvider).uploadConfig;
    final notifier = _ref.read(syncProvider.notifier);
    if (domains.contains(SyncTrigger.playlists) && upload.playlists) {
      await notifier.syncPlaylistsUpload();
    }
    if (domains.contains(SyncTrigger.plugins) && upload.plugins) {
      await notifier.syncPluginsUpload();
    }
    if (domains.contains(SyncTrigger.favorites) && upload.favorites) {
      await notifier.syncFavoritesUpload();
    }
  }

  Future<void> _attemptSync(AutoSyncConfig config) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final intervalMinutes =
        (config.syncIntervalSeconds <= 0 ? 60 : config.syncIntervalSeconds) ~/ 60;
    final maxIntervalMinutes = intervalMinutes < 1 ? 1 : intervalMinutes;
    if (_delayedCount * maxIntervalMinutes >= config.maxDelayMinutes) {
      _delayedCount = 0;
      _nextSyncAt = now + _intervalMs(config);
      return;
    }
    final load = await _api.getServerLoad();
    if (load != null && load.busy) {
      _delayedCount++;
      final delay = load.suggestedDelaySeconds <= 0
          ? 60
          : load.suggestedDelaySeconds;
      _nextSyncAt = now + delay * 1000;
      return;
    }
    _syncing = true;
    try {
      await _syncAll();
      _delayedCount = 0;
      _nextSyncAt = now + _intervalMs(config);
    } catch (_) {
      _nextSyncAt = now + _intervalMs(config);
    } finally {
      _syncing = false;
    }
  }

  Future<void> _syncAll() async {
    final upload = _ref.read(syncProvider).uploadConfig;
    final notifier = _ref.read(syncProvider.notifier);
    if (upload.playlists) {
      await notifier.syncPlaylistsUpload();
    }
    if (upload.plugins) {
      await notifier.syncPluginsUpload();
    }
    if (upload.favorites) {
      await notifier.syncFavoritesUpload();
    }
    await notifier.syncListenStats();
    if (upload.settings) {
      await notifier.syncSettingsUpload();
    }
  }
}

final autoSyncProvider = Provider<AutoSyncService>((ref) {
  final service = AutoSyncService(ref);
  ref.onDispose(service.dispose);
  return service;
});
