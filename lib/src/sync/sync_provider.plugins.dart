part of 'sync_provider.dart';

/// 插件同步服务：由 [SyncNotifier] 装配，状态经 [SyncDomainLens] 读写。
class PluginsSyncService {
  PluginsSyncService(this._ref, this._lens);

  final Ref _ref;
  final SyncDomainLens _lens;

  AccountApi get _api => _ref.read(accountApiProvider);

  Future<String> _dataDir() => _ref.read(appDataDirProvider.future);

  Future<void> upload({bool overwrite = false, SyncManualCtx? manual}) async {
    _lens.item = _lens.item.copyWith(syncing: true, errors: []);
    try {
      var sources = _ref.read(pluginManagerProvider).sources;
      if (sources.isEmpty) {
        await _ref.read(pluginManagerProvider.notifier).refresh();
        sources = _ref.read(pluginManagerProvider).sources;
      }
      // 覆盖上传：忽略「仅保留本地」墓碑，全部用户插件参与上传
      final uploadSkip = await PluginSyncState.uploadSkipIds();
      final targets = overwrite
          ? sources.where((p) => !p.isBuiltin).toList()
          : sources.where((p) => !uploadSkip.contains(p.id)).toList();
      final subs = _ref
          .read(pluginSubscriptionsProvider)
          .map((s) => s.toJson())
          .toList();
      if (overwrite) {
        // 批量覆盖上传：先读全部脚本与用户变量，全部可读 → 一次
        // plugin_sync_upload_batch 把云端替换为本地全集（多余项删除广播
        // 由服务端处理）；任一脚本读不出来或批量请求失败 → 回退旧两步流程
        final dir = await _dataDir();
        final ciyuanxiId = _api.ciyuanxiId;
        final items = <Map<String, dynamic>>[];
        var readFailed = false;
        final batchErrors = <String>[];
        for (final p in targets) {
          try {
            final script =
                await rust.readPluginFile(path: '$dir/plugins/${p.id}.js');
            if (script.trim().isEmpty) {
              batchErrors.add(
                  tr('插件 "{name}" 脚本读取失败，已跳过', {'name': p.name}));
              readFailed = true;
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
              'filePath': '$dir/plugins/${p.id}.js',
              'sourceUrl': p.sourceUrl,
              'script': SyncNotifier._encodeRevBase64(script),
              'scriptEncoded': true,
            };
            if (ciyuanxiId != null && ciyuanxiId.isNotEmpty) {
              final userVars = await _ref
                  .read(pluginUserVarValuesProvider.notifier)
                  .valuesOf(p.id);
              if (userVars.isNotEmpty) {
                final block =
                    PluginUserVarCrypto.encrypt(ciyuanxiId, userVars);
                if (block != null) plugin['userVariablesEncrypted'] = block;
              }
            }
            items.add(plugin);
          } catch (e) {
            AppLog.warn('sync', '批量上传预读插件 ${p.name} 失败: $e');
            batchErrors.add(
                tr('插件 "{name}" 脚本读取失败，已跳过', {'name': p.name}));
            readFailed = true;
          }
        }
        if (targets.isNotEmpty && items.isEmpty) {
          // 全部脚本读不出来：中止覆盖（避免把云端清成空集）
          _lens.item = _lens.item.copyWith(
            syncing: false,
            lastSummary: tr('覆盖上传已中止'),
            lastTime: DateTime.now(),
            errors: batchErrors,
          );
          return;
        }
        if (!readFailed && manual?.cancelled != true) {
          try {
            await _api.uploadPluginsBatch(items, subscriptions: subs);
            await PluginSyncState.setSyncedIds(
                items.map((p) => p['id'] as String).toList());
            _lens.item = _lens.item.copyWith(
              syncing: false,
              lastSummary: items.isNotEmpty
                  ? tr('已上传 {n} 个插件{subs}', {
                      'n': items.length,
                      'subs': subs.isNotEmpty
                          ? tr('、{n} 个订阅', {'n': subs.length})
                          : ''
                    })
                  : (subs.isNotEmpty
                      ? tr('已上传 {n} 个订阅链接', {'n': subs.length})
                      : tr('本地暂无可上传的插件')),
              lastTime: DateTime.now(),
            );
            return;
          } catch (e) {
            AppLog.warn('sync', '插件批量上传失败，回退逐个上传: $e');
            batchErrors.add(tr('批量上传失败，已回退逐个上传'));
          }
        }
        // 回退旧两步流程：以本地为准清理云端多余插件/订阅；清理失败则中止，
        // 否则继续上传会得到既非本地也非云端的混合状态
        if (!await _cleanCloudExtraForOverwrite(
            targets.map((p) => p.id).toSet(), subs, batchErrors)) {
          _lens.item = _lens.item.copyWith(
            syncing: false,
            lastSummary: tr('覆盖上传已中止'),
            lastTime: DateTime.now(),
            errors: batchErrors,
          );
          return;
        }
      }
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
        // 软取消：下一项边界停止，已完成项保留（对齐桌面端）
        if (manual?.cancelled == true) break;
        final p = targets[i];
        manual?.onStep?.call(i + 1, targets.length, p.name);
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
          AppLog.warn('sync', '插件 ${p.name} 上传失败: $e');
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
      AppLog.warn('sync', '插件上传失败: $e');
      _fail(e is AuthException ? e.message : tr('上传失败: {e}', {'e': e}));
    }
  }

  Future<void> download({bool overwrite = false, SyncManualCtx? manual}) async {
    _lens.item = _lens.item.copyWith(syncing: true, errors: []);
    // 覆盖下载的事务回滚：清空本地后任何异常整体写回覆盖前状态
    Future<void> Function()? overwriteRollback;
    try {
      final snapshot = await _api.downloadPluginSnapshot();

      // 云端删除广播裁剪：其他端「删除全部/删除云端」的插件与订阅真删本地
      // （覆盖下载不裁剪：云端快照即本地目标状态，账本无意义）
      if (!overwrite) {
        await _trimCloudDeleted(
          ((snapshot['deleted_plugin_ids'] as List?) ?? const [])
              .whereType<String>()
              .toSet(),
          ((snapshot['deleted_subscription_urls'] as List?) ?? const [])
              .whereType<String>()
              .toSet(),
        );
      }

      // 覆盖下载：先缓存本地用户插件（含脚本内容与用户变量）、订阅与同步账本，
      // 再清空本地（不记墓碑），随后按云端重装；脚本读不出来即中止覆盖
      //（清空后无法复原），清空后任何异常走回滚，本地完全回到覆盖前
      if (overwrite) {
        final rollback = await _snapshotForOverwrite();
        if (rollback == null) {
          _lens.item = _lens.item.copyWith(
            syncing: false,
            lastSummary: tr('覆盖下载已中止：本地插件脚本读取失败'),
            lastTime: DateTime.now(),
            errors: [tr('覆盖下载已中止：本地插件脚本读取失败')],
          );
          return;
        }
        overwriteRollback = rollback;
        final pluginManager = _ref.read(pluginManagerProvider.notifier);
        for (final p in _ref.read(pluginManagerProvider).sources) {
          if (p.isBuiltin) continue;
          try {
            await pluginManager.remove(p.id);
          } catch (e) {
            AppLog.warn('sync', '覆盖下载移除本地插件 ${p.name} 失败: $e');
          }
        }
        final localSubUrls = _ref
            .read(pluginSubscriptionsProvider)
            .map((s) => s.url)
            .toList();
        if (localSubUrls.isNotEmpty) {
          await _ref
              .read(pluginSubscriptionsProvider.notifier)
              .removeByUrls(localSubUrls);
        }
        AppLog.info('sync', '覆盖下载已清空本地插件与订阅');
      }

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
        if (overwrite) {
          // 云端无插件：本地已清空，同步账本随之重置为空
          await PluginSyncState.setSyncedIds(const <String>[]);
        }
        _lens.item = _lens.item.copyWith(
          syncing: false,
          lastSummary: mergedSubs > 0
              ? tr('已同步 {n} 个订阅链接', {'n': mergedSubs})
              : (overwrite ? tr('云端暂无插件数据，本地已清空') : tr('云端暂无插件数据')),
          lastTime: DateTime.now(),
        );
        return;
      }
      final errors = <String>[];
      var installed = 0;
      final restoredIds = <String>[];
      // 覆盖下载忽略「仅删本地」墓碑：云端快照即本地目标状态
      final downloadSkip = overwrite
          ? const <String>{}
          : await PluginSyncState.downloadSkipIds();
      final pluginManager = _ref.read(pluginManagerProvider.notifier);
      for (var idx = 0; idx < items.length; idx++) {
        final item = items[idx];
        // 软取消：下一项边界停止（清空本地后的覆盖下载同样适用——
        // 已恢复项保留、账本按实际恢复集重置，下次同步续齐剩余）
        if (manual?.cancelled == true) break;
        final cloudId = (item['id'] as String?)?.trim() ?? '';
        if (cloudId.isNotEmpty && downloadSkip.contains(cloudId)) {
          continue;
        }
        final cloudName = (item['name'] as String?)?.trim() ?? '';
        final name = cloudName.isNotEmpty ? cloudName : tr('未知插件');
        manual?.onStep?.call(idx + 1, items.length, name);
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
          AppLog.warn('sync', '插件 $name 恢复失败: $e');
          errors.add(tr('插件 "{name}" 恢复失败：{e}', {'name': name, 'e': e}));
        }
      }
      if (overwrite) {
        // 覆盖下载后本机与云端一致：同步账本重置为云端快照，并清掉这些插件
        // 的「仅保留本地/仅删本地」墓碑残留，避免阻断后续同步（快照即弃）
        await PluginSyncState.setSyncedIds(restoredIds);
        await PluginSyncState.clearTombstones(restoredIds);
        overwriteRollback = null;
      } else {
        await PluginSyncState.addSyncedIds(restoredIds);
      }
      _lens.item = _lens.item.copyWith(
        syncing: false,
        lastSummary: installed > 0
            ? tr('已恢复 {n} 个插件{subs}', {'n': installed, 'subs': mergedSubs > 0 ? tr('、{n} 个订阅', {'n': mergedSubs}) : ''})
            : (mergedSubs > 0 ? tr('已同步 {n} 个订阅链接', {'n': mergedSubs}) : tr('没有插件被恢复')),
        lastTime: DateTime.now(),
        errors: errors,
      );
    } catch (e) {
      AppLog.warn('sync', '插件下载失败: $e');
      if (overwriteRollback != null) {
        // 清空后的异常整体回滚，避免本地残留在半覆盖状态
        try {
          await overwriteRollback();
        } catch (re) {
          AppLog.warn('sync', '覆盖下载回滚失败: $re');
        }
      }
      _fail(e is AuthException ? e.message : tr('下载失败: {e}', {'e': e}));
    }
  }

  /// 覆盖下载前的事务快照：读出每个用户插件的脚本内容与用户变量、订阅全集、
  /// 同步账本，返回清空后异常时的回滚闭包（移除已恢复项 → 写回快照）。
  /// 任一脚本读不出来即返回 null（中止覆盖，避免清空后无法复原）。
  Future<Future<void> Function()?> _snapshotForOverwrite() async {
    try {
      final dir = await _dataDir();
      final sources = _ref
          .read(pluginManagerProvider)
          .sources
          .where((p) => !p.isBuiltin)
          .toList();
      final scripts = <String, String>{};
      final userVars = <String, Map<String, String>>{};
      for (final p in sources) {
        scripts[p.id] =
            await rust.readPluginFile(path: '$dir/plugins/${p.id}.js');
        try {
          final values = await _ref
              .read(pluginUserVarValuesProvider.notifier)
              .valuesOf(p.id);
          if (values.isNotEmpty) userVars[p.id] = values;
        } catch (_) {
          // 用户变量快照失败不阻断：回滚时插件本体与订阅仍完整
        }
      }
      final subs = _ref
          .read(pluginSubscriptionsProvider)
          .map((s) => s.toJson())
          .toList();
      final synced = await PluginSyncState.syncedIds();
      return () async {
        AppLog.warn('sync', '覆盖下载中断，开始回滚到覆盖前状态');
        final manager = _ref.read(pluginManagerProvider.notifier);
        for (final p in _ref.read(pluginManagerProvider).sources) {
          if (p.isBuiltin) continue;
          try {
            await manager.remove(p.id);
          } catch (_) {
            // 已不存在则忽略
          }
        }
        final curUrls =
            _ref.read(pluginSubscriptionsProvider).map((s) => s.url).toList();
        if (curUrls.isNotEmpty) {
          await _ref
              .read(pluginSubscriptionsProvider.notifier)
              .removeByUrls(curUrls);
        }
        for (final p in sources) {
          try {
            final source = await manager.installFromScript(
              scripts[p.id]!,
              nameOverride: p.name,
              versionOverride: p.version,
              sourceUrl: p.sourceUrl,
            );
            if (!p.enabled && source.enabled) {
              await manager.toggleEnabled(source.id);
            }
            final values = userVars[p.id];
            if (values != null && values.isNotEmpty) {
              await _ref
                  .read(pluginUserVarValuesProvider.notifier)
                  .save(source.id, values);
            }
          } catch (e) {
            AppLog.warn('sync', '覆盖下载回滚插件 ${p.name} 失败: $e');
          }
        }
        if (subs.isNotEmpty) {
          await _ref
              .read(pluginSubscriptionsProvider.notifier)
              .mergeFromCloud(subs);
        }
        await PluginSyncState.setSyncedIds(synced);
        AppLog.info(
            'sync', '覆盖下载已回滚（插件 ${sources.length} 个, 订阅 ${subs.length} 个）');
      };
    } catch (e) {
      AppLog.warn('sync', '覆盖下载快照失败: $e');
      return null;
    }
  }

  /// 覆盖上传前置清理：以本地全集为准删除云端多余的插件与订阅。
  /// 任一清理失败即返回 false（中止上传，避免混合状态）。
  Future<bool> _cleanCloudExtraForOverwrite(Set<String> localIds,
      List<Map<String, dynamic>> localSubs, List<String> errors) async {
    try {
      final cloud = await _api.downloadPluginSnapshot();
      final cloudIds = ((cloud['plugins'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => (e['id'] as String?) ?? '')
          .where((id) => id.isNotEmpty && !localIds.contains(id))
          .toList();
      final localSubUrls = localSubs
          .map((s) => (s['url'] as String?) ?? '')
          .where((u) => u.isNotEmpty)
          .toSet();
      final cloudSubUrls = ((cloud['subscriptions'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => (e['url'] as String?) ?? '')
          .where((u) => u.isNotEmpty && !localSubUrls.contains(u))
          .toList();
      var ok = true;
      if (cloudIds.isNotEmpty) {
        try {
          await _api.deleteCloudPlugins(cloudIds);
          AppLog.info('sync', '覆盖上传清理云端多余插件 ${cloudIds.length} 个');
        } catch (e) {
          AppLog.warn('sync', '覆盖上传清理云端多余插件失败: $e');
          errors.add(tr('云端多余插件清理失败（{n} 个）', {'n': cloudIds.length}));
          ok = false;
        }
      }
      if (cloudSubUrls.isNotEmpty) {
        try {
          await _api.deleteCloudSubscriptions(cloudSubUrls);
          AppLog.info('sync', '覆盖上传清理云端多余订阅 ${cloudSubUrls.length} 个');
        } catch (e) {
          AppLog.warn('sync', '覆盖上传清理云端多余订阅失败: $e');
          errors.add(tr('云端多余订阅清理失败（{n} 个）', {'n': cloudSubUrls.length}));
          ok = false;
        }
      }
      return ok;
    } catch (e) {
      AppLog.warn('sync', '覆盖上传云端清理失败: $e');
      errors.add(tr('覆盖上传云端清理失败: {e}', {'e': e}));
      return false;
    }
  }

  /// 云端删除广播裁剪：按 id 卸载插件、按 url 移除订阅。
  /// 本机「仅保留本地」(uploadSkip) 或已删 (downloadSkip) 墓碑中的插件跳过；
  /// 裁剪后从 syncedIds 清除，避免下次删除弹窗误判「已同步到云端」。
  Future<void> _trimCloudDeleted(
      Set<String> pluginIds, Set<String> subUrls) async {
    if (pluginIds.isNotEmpty) {
      final uploadSkip = await PluginSyncState.uploadSkipIds();
      final downloadSkip = await PluginSyncState.downloadSkipIds();
      final victims = pluginIds
          .where((id) => id.isNotEmpty && !uploadSkip.contains(id))
          .where((id) => !downloadSkip.contains(id))
          .toList();
      if (victims.isNotEmpty) {
        final manager = _ref.read(pluginManagerProvider.notifier);
        for (final id in victims) {
          try {
            await manager.remove(id);
          } catch (e) {
            AppLog.warn('sync', '插件 $id 云端删除裁剪失败: $e');
          }
        }
        await PluginSyncState.removeSyncedIds(victims);
      }
    }
    if (subUrls.isNotEmpty) {
      await _ref
          .read(pluginSubscriptionsProvider.notifier)
          .removeByUrls(subUrls);
    }
  }

  void _fail(String err) {
    _lens.item = _lens.item.copyWith(
      syncing: false,
      errors: [err],
    );
  }

}
