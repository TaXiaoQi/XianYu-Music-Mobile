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

  /// 对称双向同步（自动同步/手动上传入口）：先下载云端再做分节 LWW 决策，
  /// 对齐桌面端 uploadSettingsOnly。下载失败必须中止——不能当作「云端无数据」
  /// 把本地全量推上去覆盖云端。
  Future<void> upload() async {
    _lens.item = _lens.item.copyWith(syncing: true, errors: []);
    try {
      final local = _ref.read(settingsProvider).valueOrNull;
      if (local == null) {
        _fail(tr('本地设置尚未加载完成'));
        return;
      }
      final (cloud, cloudAt, cloudSectionTs) =
          await _api.downloadSettingsCrossPlatform();
      if (cloud == null || cloud.isEmpty) {
        // 云端无数据：全量上传并携带分节时间戳账本
        final ts = await buildFullSettingsSectionTs(local);
        await _api.uploadSettings(local, sectionTs: ts);
        await writeSettingsSectionTs(ts);
        _lens.item = _lens.item.copyWith(
          syncing: false,
          lastSummary: tr('已上传偏好设置'),
          lastTime: DateTime.now(),
          errors: [],
        );
        return;
      }
      if (cloudSectionTs == null) {
        // 云端快照未携带分节账本（旧版端上传）：无法判定分节新旧，
        // 维持旧行为以上传为准，并落一份本端账本供后续 LWW
        final ts = await buildFullSettingsSectionTs(local);
        await _api.uploadSettings(local, sectionTs: ts);
        await writeSettingsSectionTs(ts);
        _lens.item = _lens.item.copyWith(
          syncing: false,
          lastSummary: tr('已上传偏好设置'),
          lastTime: DateTime.now(),
          errors: [],
        );
        return;
      }

      // 云端有分节账本：按分节 LWW 合并（云端较新落地本地，本地较新上传云端）。
      // 云端账本缺失的分节回落到整包 uploaded_at（旧版端上传的快照）
      final cloudAtMs = cloudAt?.millisecondsSinceEpoch ?? 0;
      final localTs = await readSettingsSectionTs();
      final m = normalizeCloudSettingsMap(cloud);
      final cloudWon = <String, dynamic>{};
      final localWon = <String>[];
      final mergedTs = <String, int>{};
      for (final entry in settingsToSyncMap(local).entries) {
        final cts = cloudSectionTs[entry.key] ?? cloudAtMs;
        final lts = localTs[entry.key] ?? 0;
        if (cts > lts && m[entry.key] != null) {
          cloudWon[entry.key] = m[entry.key];
          mergedTs[entry.key] = cts;
        } else {
          mergedTs[entry.key] = lts;
          if (lts > cts) localWon.add(entry.key);
        }
      }
      if (cloudWon.isEmpty &&
          localWon.isEmpty &&
          !areSettingsEqual(local, cloud)) {
        // 时间戳持平但内容有差异（多见于账本刚启用）：以本端为准整体上传
        // 并全部重新打点，避免永久停滞
        final now = DateTime.now().millisecondsSinceEpoch;
        for (final key in mergedTs.keys) {
          mergedTs[key] = now;
        }
        localWon.addAll(mergedTs.keys);
      }

      // 云端较新分节先落地本地（applySyncedSettings 对缺失字段回落本地值）
      if (cloudWon.isNotEmpty) {
        await _ref
            .read(settingsProvider.notifier)
            .saveAll(applySyncedSettings(local, cloudWon));
      }
      // 账本全量对齐（云端较新分节记云端时刻，其余保持本地时刻）
      await writeSettingsSectionTs(mergedTs);

      var uploaded = false;
      if (localWon.isNotEmpty) {
        // 上传合并后的设置（含云端已落地部分），账本随载荷上云
        final merged = _ref.read(settingsProvider).valueOrNull ?? local;
        await _api.uploadSettings(merged, sectionTs: mergedTs);
        uploaded = true;
      }
      _lens.item = _lens.item.copyWith(
        syncing: false,
        lastSummary: uploaded && cloudWon.isNotEmpty
            ? tr('设置已双向合并同步')
            : uploaded
                ? tr('已上传偏好设置')
                : cloudWon.isNotEmpty
                    ? tr('设置已从云端更新')
                    : tr('本地与云端设置一致，无需同步'),
        lastTime: DateTime.now(),
        errors: [],
      );
    } catch (e) {
      AppLog.warn('sync', '设置上传失败: $e');
      _fail(e is AuthException ? e.message : tr('上传失败: {e}', {'e': e}));
    }
  }

  Future<void> download() async {
    _lens.item = _lens.item.copyWith(syncing: true, errors: []);
    try {
      final (cloud, cloudAt, cloudSectionTs) =
          await _api.downloadSettingsCrossPlatform();
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
      // 全量落地：全部分节记云端时刻（账本缺失回落整包 uploaded_at），
      // 避免下次自动同步把云端内容又推回去
      final cloudAtMs = cloudAt?.millisecondsSinceEpoch ?? 0;
      await writeSettingsSectionTs({
        for (final key in settingsToSyncMap(local).keys)
          key: cloudSectionTs?[key] ?? cloudAtMs,
      });
      _lens.item = _lens.item.copyWith(
        syncing: false,
        lastSummary: tr('已应用云端设置'),
        lastTime: DateTime.now(),
        errors: [],
      );
    } catch (e) {
      AppLog.warn('sync', '设置下载失败: $e');
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
      final (cloud, cloudTime, cloudSectionTs) =
          await _api.downloadSettingsCrossPlatform();
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
        diffLabels: diffSyncedSettingsLabels(local, cloud),
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
            // 保留本地 = 本端成为全部分节的最新持有者，先对齐账本再上传
            final ts = await buildFullSettingsSectionTs(local);
            await writeSettingsSectionTs(ts);
            await _api.uploadSettings(local, sectionTs: ts);
          } catch (e) {
            errors.add(tr('设置上传失败: {e}', {'e': e}));
          }
        }
      } else {
        try {
          final merged = applySyncedSettings(local, cloud);
          await _ref.read(settingsProvider.notifier).saveAll(merged);
          // 全量落地：全部分节记云端时刻，避免下次自动同步把云端内容又推回去
          final cloudAtMs = cloudTime?.millisecondsSinceEpoch ?? 0;
          await writeSettingsSectionTs({
            for (final key in settingsToSyncMap(local).keys)
              key: cloudSectionTs?[key] ?? cloudAtMs,
          });
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
      AppLog.warn('sync', '设置同步失败: $e');
      _fail(e is AuthException ? e.message : tr('同步失败: {e}', {'e': e}));
    }
  }
}

/// 对比本地与云端设置，返回不一致项的中文名列表（用于冲突弹窗展示具体冲突）。
/// 与 [areSettingsEqual] 同规则：云端缺失的字段不算冲突。
List<String> diffSyncedSettingsLabels(
    AppSettings local, Map<String, dynamic> cloud) {
  const labels = {
    'volume': '音量',
    'playMode': '播放模式',
    'keepScreenOn': '屏幕常亮',
    'themeMode': '主题模式',
    'accentColor': '主题色',
    'showQualityBadges': '音质标识',
    'onlineDefaultQuality': '在线默认音质',
    'libraryMinDurationSeconds': '曲库最短时长',
    'showLyricsTranslation': '歌词翻译',
    'enableWordEffect': '逐字歌词效果',
    'downloadQuality': '下载音质',
    'downloadLyrics': '下载歌词',
    'organizeRule': '整理规则',
  };
  final localMap = settingsToSyncMap(local);
  final m = normalizeCloudSettingsMap(cloud);
  final out = <String>[];
  for (final e in localMap.entries) {
    final cv = m[e.key];
    if (cv == null || cv == e.value) continue;
    out.add(labels[e.key] ?? e.key);
  }
  return out;
}
