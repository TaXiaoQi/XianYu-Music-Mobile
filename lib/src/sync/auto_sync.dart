import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth/account_api.dart';
import '../auth/auth_provider.dart';
import '../core/settings.dart';

/// 自动同步配置（持久化）。
class AutoSyncConfig {
  final bool enabled;
  final int syncIntervalSeconds;
  final int maxDelayMinutes;
  const AutoSyncConfig({
    this.enabled = false,
    this.syncIntervalSeconds = 3600,
    this.maxDelayMinutes = 30,
  });

  AutoSyncConfig copyWith({
    bool? enabled,
    int? syncIntervalSeconds,
    int? maxDelayMinutes,
  }) =>
      AutoSyncConfig(
        enabled: enabled ?? this.enabled,
        syncIntervalSeconds: syncIntervalSeconds ?? this.syncIntervalSeconds,
        maxDelayMinutes: maxDelayMinutes ?? this.maxDelayMinutes,
      );
}

/// 自动同步调度器：每分钟 tick，到点后检查服务器负载并执行设置同步。
///
/// 与桌面端 autoSync.ts 对齐：
/// - 服务器繁忙时按 suggestedDelaySeconds 延后，超过 maxDelayMinutes 上限则放弃本轮
/// - 同步内容为设置（下载云端 → 合并 → 上传）
class AutoSyncService {
  AutoSyncService(this._ref);
  final Ref _ref;

  static const _enabledKey = 'auto_sync_enabled';
  static const _intervalKey = 'auto_sync_interval';
  static const _maxDelayKey = 'auto_sync_max_delay';

  Timer? _timer;
  bool _syncing = false;
  int _delayedCount = 0;
  int _nextSyncAt = 0;

  AccountApi get _api => _ref.read(accountApiProvider);

  /// 启动调度器（应用启动后调用）。
  void start() {
    _timer ??= Timer.periodic(const Duration(seconds: 60), (_) => _tick());
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }

  Future<AutoSyncConfig> getConfig() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return AutoSyncConfig(
        enabled: prefs.getBool(_enabledKey) ?? false,
        syncIntervalSeconds: prefs.getInt(_intervalKey) ?? 3600,
        maxDelayMinutes: prefs.getInt(_maxDelayKey) ?? 30,
      );
    } catch (_) {
      return const AutoSyncConfig();
    }
  }

  Future<void> setConfig(AutoSyncConfig config) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await Future.wait([
        prefs.setBool(_enabledKey, config.enabled),
        prefs.setInt(_intervalKey, config.syncIntervalSeconds),
        prefs.setInt(_maxDelayKey, config.maxDelayMinutes),
      ]);
    } catch (_) {}
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
      await _syncSettings();
      _delayedCount = 0;
      _nextSyncAt = now + _intervalMs(config);
    } catch (_) {
      _nextSyncAt = now + _intervalMs(config);
    } finally {
      _syncing = false;
    }
  }

  /// 设置同步：下载云端 → 合并 → 上传。
  Future<void> _syncSettings() async {
    final settings = _ref.read(settingsProvider).valueOrNull;
    if (settings == null) return;
    final cloud = await _api.downloadSettings();
    if (cloud != null && cloud.isNotEmpty) {
      final merged = applySyncedSettings(settings, cloud);
      await _ref.read(settingsProvider.notifier).saveAll(merged);
    }
    final latest = _ref.read(settingsProvider).valueOrNull ?? settings;
    await _api.uploadSettings(latest);
  }
}

final autoSyncProvider = Provider<AutoSyncService>((ref) {
  final service = AutoSyncService(ref);
  ref.onDispose(service.dispose);
  return service;
});
