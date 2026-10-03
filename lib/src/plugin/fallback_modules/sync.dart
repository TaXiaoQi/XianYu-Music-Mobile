import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/account_api.dart';
import '../../core/application_logger.dart';
import '../../core/db_path.dart';
import '../../rust/api.dart' as frb;
import 'registry.dart';
import 'types.dart';

// ==================== 兜底模块服务端同步（移植自桌面端 fallbackModules/sync） ====================
// 启动即拉取一次，之后 30min 轮询；拉取失败保留本地缓存并做验签清理。
// 配置快照推送（update_config）暂未接入：移动端 settings 体系与桌面不同，
// 热修模块按 config 为空编写即可；Rust 门面已就绪，后续接入无需改桥。

const _syncInterval = Duration(minutes: 30);

Timer? _timer;
var _syncing = false;

/// 服务端下发条目 → ServerFallbackModule；字段残缺返回 null
ServerFallbackModule? normalizeServerModule(Object? raw) {
  if (raw is! Map) return null;
  final moduleKey = raw['moduleKey']?.toString() ?? '';
  final code = raw['code']?.toString() ?? '';
  final version = (raw['version'] as num?)?.toInt() ?? 0;
  final digest = raw['digest']?.toString().toLowerCase() ?? '';
  final signature = raw['signature']?.toString().toLowerCase() ?? '';
  if (moduleKey.isEmpty ||
      code.isEmpty ||
      version < 1 ||
      digest.isEmpty ||
      signature.isEmpty) {
    return null;
  }
  final name = raw['name']?.toString() ?? '';
  final updatedAt = raw['updatedAt']?.toString() ?? '';
  return ServerFallbackModule(
    moduleKey: moduleKey,
    version: version,
    digest: digest,
    code: code,
    signature: signature,
    name: name.isEmpty ? null : name,
    updatedAt: updatedAt.isEmpty ? null : updatedAt,
  );
}

Future<bool> _verifyModuleSignature(ServerFallbackModule item) async {
  try {
    return await frb.verifyFallbackModuleSignature(
      moduleKey: item.moduleKey,
      version: item.version,
      code: item.code,
      signature: item.signature,
    );
  } catch (e) {
    AppLog.warn('plugin', '[FallbackModule] ${item.moduleKey} 验签命令不可用，按未通过处理: $e');
    return false;
  }
}

Future<bool> syncFallbackModules(AccountApi api) async {
  if (_syncing) return false;
  _syncing = true;
  try {
    final data = await api.fetchFallbackModules();
    final rawList = data['modules'];
    final modules = <ServerFallbackModule>[];
    for (final raw in (rawList is List ? rawList : const [])) {
      final item = normalizeServerModule(raw);
      // 只验签/缓存移动端已接入的 key，桌面专属模块直接跳过
      if (item == null || !fallbackModuleMethods.containsKey(item.moduleKey)) {
        continue;
      }
      if (!await _verifyModuleSignature(item)) {
        AppLog.warn('plugin',
            '[FallbackModule] 模块 ${item.moduleKey} v${item.version} 签名校验失败，已丢弃（回退内置实现）');
        continue;
      }
      modules.add(item);
    }
    await applyServerFallbackModules(modules);
    await prewarmFallbackModules();
    return true;
  } catch (e) {
    AppLog.warn('plugin', '[FallbackModule] 拉取兜底模块失败（保留本地缓存）: $e');
    await sanitizeFallbackModuleCache();
    return false;
  } finally {
    _syncing = false;
  }
}

/// 启动挂载：注入 dataDir/上报，清理缓存后预热，并开启 30min 轮询。
/// 需在 Rust 初始化完成后调用（验签/load 依赖桥）。
void initFallbackModuleSync(ProviderContainer container) {
  if (_timer != null) return;
  configureFallbackModules(
    dataDirResolver: () => container.read(appDataDirProvider.future),
    reportEvent: (eventType, detail) {
      try {
        unawaited(container.read(accountApiProvider).reportError(
              errorType: eventType,
              errorMessage: detail,
              page: 'fallback_module',
            ));
      } catch (_) {
        // 上报层异常不影响兜底主流程
      }
    },
  );
  unawaited(() async {
    await sanitizeFallbackModuleCache();
    await prewarmFallbackModules();
    unawaited(syncFallbackModules(container.read(accountApiProvider)));
  }());
  _timer = Timer.periodic(_syncInterval, (_) {
    unawaited(syncFallbackModules(container.read(accountApiProvider)));
  });
}
