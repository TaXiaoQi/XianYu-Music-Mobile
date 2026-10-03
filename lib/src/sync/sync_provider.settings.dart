part of 'sync_provider.dart';

/// 设置同步服务：由 [SyncNotifier] 装配，状态经 [SyncDomainLens] 读写；
/// 冲突解决流程中的歌单/插件同步经注入的服务实例编排。
class SettingsSyncService {
  SettingsSyncService(
    this._ref,
    this._lens, {
    required this.uploadConfig,
    required this.playlists,
    required this.plugins,
  });

  final Ref _ref;
  final SyncDomainLens _lens;
  final UploadConfig Function() uploadConfig;
  final PlaylistSyncService playlists;
  final PluginsSyncService plugins;

  AccountApi get _api => _ref.read(accountApiProvider);

  // ==================== 设置同步 ====================

  Future<void> upload() async {
    _lens.item = _lens.item.copyWith(syncing: true, errors: []);
    try {
      final settings = _ref.read(settingsProvider).valueOrNull;
      if (settings == null) {
        _fail(tr('本地设置尚未加载完成'));
        return;
      }
      await _api.uploadSettings(settings);
      _lens.item = _lens.item.copyWith(
        syncing: false,
        lastSummary: tr('已上传偏好设置'),
        lastTime: DateTime.now(),
        errors: [],
      );
    } catch (e) {
      AppLogger.instance.log('sync', '设置上传失败: $e');
      _fail(e is AuthException ? e.message : tr('上传失败: {e}', {'e': e}));
    }
  }

  Future<void> download() async {
    _lens.item = _lens.item.copyWith(syncing: true, errors: []);
    try {
      final cloud = await _api.downloadSettings();
      if (cloud == null || cloud.isEmpty) {
        _lens.item = _lens.item.copyWith(
          syncing: false,
          lastSummary: tr('云端暂无设置'),
          lastTime: DateTime.now(),
        );
        return;
      }
      final local = _ref.read(settingsProvider).valueOrNull;
      if (local == null) {
        _fail(tr('本地设置尚未加载完成'));
        return;
      }
      final merged = applySyncedSettings(local, cloud);
      await _ref.read(settingsProvider.notifier).saveAll(merged);
      _lens.item = _lens.item.copyWith(
        syncing: false,
        lastSummary: tr('已应用云端设置'),
        lastTime: DateTime.now(),
        errors: [],
      );
    } catch (e) {
      AppLogger.instance.log('sync', '设置下载失败: $e');
      _fail(e is AuthException ? e.message : tr('下载失败: {e}', {'e': e}));
    }
  }

  void _fail(String err) {
    _lens.item = _lens.item.copyWith(
      syncing: false,
      errors: [err],
    );
  }

  Future<void> sync(BuildContext context) async {
    _lens.item = _lens.item.copyWith(syncing: true, errors: []);
    try {
      final local = _ref.read(settingsProvider).valueOrNull;
      if (local == null) {
        _fail(tr('本地设置尚未加载完成'));
        return;
      }
      final meta = await _api.downloadSettingsCrossPlatform();
      final cloud = meta.settings;
      final cloudTime = meta.uploadedAt;
      final upload = uploadConfig();

      if (cloud == null || cloud.isEmpty) {
        if (upload.settings) {
          await _api.uploadSettings(local);
          _lens.item = _lens.item.copyWith(
            syncing: false,
            lastSummary: tr('已上传偏好设置'),
            lastTime: DateTime.now(),
            errors: [],
          );
        } else {
          _lens.item = _lens.item.copyWith(
            syncing: false,
            lastSummary: tr('云端暂无设置'),
            lastTime: DateTime.now(),
            errors: [],
          );
        }
        return;
      }

      if (areSettingsEqual(local, cloud)) {
        _lens.item = _lens.item.copyWith(
          syncing: false,
          lastSummary: tr('本地与云端设置一致，无需同步'),
          lastTime: DateTime.now(),
          errors: [],
        );
        return;
      }

      if (!context.mounted) return;
      final choices = await showSettingsConflictDialog(
        context: context,
        localTime: DateTime.now(),
        cloudTime: cloudTime ?? DateTime.now(),
      );
      if (choices == null) {
        _lens.item = _lens.item.copyWith(
          syncing: false,
          lastSummary: tr('已取消设置同步'),
          lastTime: DateTime.now(),
          errors: [],
        );
        return;
      }

      final errors = <String>[];

      // --- 设置 ---
      if (choices.settings == SyncDirection.local) {
        if (upload.settings) {
          try {
            await _api.uploadSettings(local);
          } catch (e) {
            errors.add(tr('设置上传失败: {e}', {'e': e}));
          }
        }
      } else {
        try {
          final merged = applySyncedSettings(local, cloud);
          await _ref.read(settingsProvider.notifier).saveAll(merged);
        } catch (e) {
          errors.add(tr('设置下载失败: {e}', {'e': e}));
        }
      }

      // --- 歌单 ---
      if (choices.playlists == SyncDirection.local) {
        if (upload.playlists) {
          await playlists.upload();
        }
      } else {
        await playlists.download();
      }

      // --- 插件 ---
      if (choices.plugins == SyncDirection.local) {
        if (upload.plugins) {
          await plugins.upload();
        }
      } else {
        await plugins.download();
      }

      _lens.item = _lens.item.copyWith(
        syncing: false,
        lastSummary: errors.isEmpty ? tr('同步完成') : '同步完成（${errors.length} 个错误）',
        lastTime: DateTime.now(),
        errors: errors,
      );
    } catch (e) {
      AppLogger.instance.log('sync', '设置同步失败: $e');
      _fail(e is AuthException ? e.message : tr('同步失败: {e}', {'e': e}));
    }
  }
}
