import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/account_api.dart';
import '../auth/auth_provider.dart';
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

  /// 按上传配置同步歌单/收藏/插件/设置。
  ///
  /// 以客户端为主，仅上传（覆盖式同步，保证服务器保存的是客户端当前状态，
  /// 含新增内容）。首次登录时已通过 syncOnLoginSuccess 做了一次全量一致性同步，
  /// 此后自动同步不再下载、不再弹冲突窗。
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
      // 空列表保护：本地收藏为空时跳过上传，避免覆盖云端收藏。
      await notifier.syncFavoritesUpload();
    }
    // 累计听歌统计同步（保证线上累计时长持续上传、离线数据回归时合并）。
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
