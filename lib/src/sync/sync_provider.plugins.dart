part of 'sync_provider.dart';

/// 插件同步服务：由 [SyncNotifier] 装配，状态经 [SyncDomainLens] 读写。
class PluginsSyncService {
  PluginsSyncService(this._ref, this._lens);

  final Ref _ref;
  final SyncDomainLens _lens;

  AccountApi get _api => _ref.read(accountApiProvider);

  Future<String> _dataDir() => _ref.read(appDataDirProvider.future);

  Future<void> upload() async {
    _lens.item = _lens.item.copyWith(syncing: true, errors: []);
    try {
      var sources = _ref.read(pluginManagerProvider).sources;
      if (sources.isEmpty) {
        await _ref.read(pluginManagerProvider.notifier).refresh();
        sources = _ref.read(pluginManagerProvider).sources;
      }
      final uploadSkip = await PluginSyncState.uploadSkipIds();
      final targets =
          sources.where((p) => !uploadSkip.contains(p.id)).toList();
      final subs = _ref
          .read(pluginSubscriptionsProvider)
          .map((s) => s.toJson())
          .toList();
      if (targets.isEmpty) {
        if (subs.isNotEmpty) {
          try {
            await _api.uploadPlugin({},
                isFirst: true, subscriptions: subs);
            _lens.item = _lens.item.copyWith(
              syncing: false,
              lastSummary: tr('已上传 {n} 个订阅链接', {'n': subs.length}),
              lastTime: DateTime.now(),
            );
          } catch (e) {
            _fail(e is AuthException ? e.message : tr('订阅上传失败: {e}', {'e': e}));
          }
        } else {
          _lens.item = _lens.item.copyWith(
            syncing: false,
            lastSummary: tr('本地暂无可上传的插件'),
            lastTime: DateTime.now(),
          );
        }
        await PluginSyncState.setSyncedIds(const <String>[]);
        return;
      }
      final dir = await _dataDir();
      final errors = <String>[];
      var uploaded = 0;
      final uploadedIds = <String>[];
      for (var i = 0; i < targets.length; i++) {
        final p = targets[i];
        final scriptPath = '$dir/plugins/${p.id}.js';
        try {
          final script = await rust.readPluginFile(path: scriptPath);
          if (script.trim().isEmpty) {
            errors.add(tr('插件 "{name}" 脚本读取失败，已跳过', {'name': p.name}));
            continue;
          }
          final plugin = <String, dynamic>{
            'id': p.id,
            'name': p.name,
            'version': p.version,
            'author': p.author,
            'description': p.description,
            'enabled': p.enabled,
            'sources': p.sources,
            'filePath': scriptPath,
            'sourceUrl': p.sourceUrl,
            'script': SyncNotifier._encodeRevBase64(script),
            'scriptEncoded': true,
          };
          final ciyuanxiId = _api.ciyuanxiId;
          if (ciyuanxiId != null && ciyuanxiId.isNotEmpty) {
            final userVars =
                await _ref.read(pluginUserVarValuesProvider.notifier).valuesOf(p.id);
            if (userVars.isNotEmpty) {
              final block = PluginUserVarCrypto.encrypt(ciyuanxiId, userVars);
              if (block != null) plugin['userVariablesEncrypted'] = block;
            }
          }
          await _api.uploadPlugin(plugin, isFirst: i == 0, subscriptions: subs);
          uploaded++;
          uploadedIds.add(p.id);
        } catch (e) {
          AppLogger.instance.log('sync', '插件 ${p.name} 上传失败: $e');
          errors.add(tr('插件 "{name}" 上传失败', {'name': p.name}));
        }
      }
      await PluginSyncState.setSyncedIds(uploadedIds);
      _lens.item = _lens.item.copyWith(
        syncing: false,
        lastSummary: uploaded > 0
            ? tr('已上传 {n} 个插件{subs}', {'n': uploaded, 'subs': subs.isNotEmpty ? tr('、{n} 个订阅', {'n': subs.length}) : ''})
            : tr('没有插件被上传'),
        lastTime: DateTime.now(),
        errors: errors,
      );
    } catch (e) {
      AppLogger.instance.log('sync', '插件上传失败: $e');
      _fail(e is AuthException ? e.message : tr('上传失败: {e}', {'e': e}));
    }
  }

  Future<void> download() async {
    _lens.item = _lens.item.copyWith(syncing: true, errors: []);
    try {
      final snapshot = await _api.downloadPluginSnapshot();

      final cloudSubs = ((snapshot['subscriptions'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
      var mergedSubs = 0;
      if (cloudSubs.isNotEmpty) {
        mergedSubs = await _ref
            .read(pluginSubscriptionsProvider.notifier)
            .mergeFromCloud(cloudSubs);
      }

      final items = ((snapshot['plugins'] as List?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList();
      if (items.isEmpty) {
        _lens.item = _lens.item.copyWith(
          syncing: false,
          lastSummary: mergedSubs > 0
              ? tr('已同步 {n} 个订阅链接', {'n': mergedSubs})
              : tr('云端暂无插件数据'),
          lastTime: DateTime.now(),
        );
        return;
      }
      final errors = <String>[];
      var installed = 0;
      final restoredIds = <String>[];
      final downloadSkip = await PluginSyncState.downloadSkipIds();
      final pluginManager = _ref.read(pluginManagerProvider.notifier);
      for (final item in items) {
        final cloudId = (item['id'] as String?)?.trim() ?? '';
        if (cloudId.isNotEmpty && downloadSkip.contains(cloudId)) {
          continue;
        }
        final cloudName = (item['name'] as String?)?.trim() ?? '';
        final name = cloudName.isNotEmpty ? cloudName : tr('未知插件');
        var script = (item['script'] as String?) ?? '';
        if (item['scriptEncoded'] == true && script.isNotEmpty) {
          try {
            script = SyncNotifier._decodeRevBase64(script);
          } catch (_) {
            errors.add(tr('插件 "{name}" 脚本解码失败', {'name': name}));
            continue;
          }
        }
        if (script.trim().isEmpty) {
          errors.add(tr('插件 "{name}" 脚本为空，已跳过', {'name': name}));
          continue;
        }
        try {
          final version = (item['version'] as String?)?.trim() ?? '';
          final source = await pluginManager.installFromScript(
            script,
            nameOverride: cloudName.isEmpty ? null : cloudName,
            versionOverride: version.isEmpty ? null : version,
            sourceUrl: (item['sourceUrl'] as String?)?.trim() ?? '',
          );
          if (item['enabled'] == false && source.enabled) {
            await pluginManager.toggleEnabled(source.id);
          }
          final encBlock = item['userVariablesEncrypted'];
          if (encBlock is Map) {
            final ciyuanxiId = _api.ciyuanxiId;
            if (ciyuanxiId != null && ciyuanxiId.isNotEmpty) {
              final values = PluginUserVarCrypto.decrypt(
                  ciyuanxiId, encBlock.cast<String, dynamic>());
              if (values != null && values.isNotEmpty) {
                await _ref
                    .read(pluginUserVarValuesProvider.notifier)
                    .save(source.id, values);
                await pluginManager.syncBilibiliCookiesFromVars(
                    source.id, values);
              } else {
                errors.add(tr('插件 "{name}" 用户变量解密失败', {'name': name}));
              }
            }
          }
          installed++;
          restoredIds.add(source.id);
        } catch (e) {
          AppLogger.instance.log('sync', '插件 $name 恢复失败: $e');
          errors.add(tr('插件 "{name}" 恢复失败：{e}', {'name': name, 'e': e}));
        }
      }
      await PluginSyncState.addSyncedIds(restoredIds);
      _lens.item = _lens.item.copyWith(
        syncing: false,
        lastSummary: installed > 0
            ? tr('已恢复 {n} 个插件{subs}', {'n': installed, 'subs': mergedSubs > 0 ? tr('、{n} 个订阅', {'n': mergedSubs}) : ''})
            : (mergedSubs > 0 ? tr('已同步 {n} 个订阅链接', {'n': mergedSubs}) : tr('没有插件被恢复')),
        lastTime: DateTime.now(),
        errors: errors,
      );
    } catch (e) {
      AppLogger.instance.log('sync', '插件下载失败: $e');
      _fail(e is AuthException ? e.message : tr('下载失败: {e}', {'e': e}));
    }
  }

  void _fail(String err) {
    _lens.item = _lens.item.copyWith(
      syncing: false,
      errors: [err],
    );
  }

}
