import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/account_api.dart';
import '../auth/auth_provider.dart';
import '../core/settings.dart';
import 'sync_provider.dart';

/// 自动同步调度器：每分钟 tick，到点后检查服务器负载并执行同步。
///
/// 与桌面端 autoSync.ts 对齐：
/// - 服务器繁忙时按 suggestedDelaySeconds 延后，超过 maxDelayMinutes 上限则放弃本轮
/// - 同步内容为歌单/收藏/插件/设置（按 UploadConfig 开关），对齐桌面端 performAutoSync
/// - 配置统一存放在 syncProvider（账号页/同步页开关均写入同一份）
class AutoSyncService {
  AutoSyncService(this._ref);
  final Ref _ref;

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

  /// 按上传配置同步歌单/收藏/插件/设置（对齐桌面端 performAutoSync）。
  Future<void> _syncAll() async {
    final upload = _ref.read(syncProvider).uploadConfig;
    final notifier = _ref.read(syncProvider.notifier);
    if (upload.playlists) {
      await notifier.syncPlaylistsUpload();
      await notifier.syncPlaylistsDownload();
    }
    if (upload.plugins) {
      await notifier.syncPluginsUpload();
      await notifier.syncPluginsDownload();
    }
    if (upload.favorites) {
      // 先下载再上传：换包名/重装后本地收藏为空，先拉取云端收藏再上传，
      // 避免空列表覆盖云端（syncFavoritesUpload 另有空列表保护兜底）。
      await notifier.syncFavoritesDownload();
      await notifier.syncFavoritesUpload();
    }
    if (upload.settings) {
      await _syncSettings();
    }
  }

  /// 设置同步：下载云端 → 合并 → 上传（无冲突弹窗，适合后台自动同步）。
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
