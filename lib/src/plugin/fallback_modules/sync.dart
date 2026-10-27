import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../auth/account_api.dart';
import '../../core/application_logger.dart';
import 'registry.dart';

// ==================== 兜底行为配置服务端同步 ====================
// 启动即拉取一次，之后 30min 轮询；拉取失败保留本地缓存（启动时已验签清理）。
// 服务端返回 { config: <配置 JSON 字符串>, signature: <ed25519 hex> }，
// 客户端验签（xianyu-fallback-config-v1）通过才采纳。

const _syncInterval = Duration(minutes: 30);

Timer? _timer;
var _syncing = false;

/// 服务端响应条目 → (configJson, signature)；字段残缺返回 null
(String, String)? normalizeServerFallbackConfig(Object? raw) {
  if (raw is! Map) return null;
  final configJson = raw['config']?.toString() ?? '';
  final signature = raw['signature']?.toString().toLowerCase() ?? '';
  if (configJson.isEmpty || signature.isEmpty) return null;
  return (configJson, signature);
}

Future<bool> syncFallbackModules(AccountApi api) async {
  if (_syncing) return false;
  _syncing = true;
  try {
    final data = await api.fetchFallbackModules();
    final normalized = normalizeServerFallbackConfig(data);
    if (normalized == null) {
      // 服务端未配置/字段残缺：保持现状（本地缓存或默认行为）
      return true;
    }
    await applyServerFallbackConfig(normalized.$1, normalized.$2);
    return true;
  } catch (e) {
    AppLog.warn('plugin', '[FallbackConfig] 拉取兜底配置失败（保留本地缓存）: $e');
    return false;
  } finally {
    _syncing = false;
  }
}

/// 启动挂载：注入上报，清理缓存后同步一次，并开启 30min 轮询。
/// 需在 Rust 初始化完成后调用（验签依赖桥）。
void initFallbackModuleSync(ProviderContainer container) {
  if (_timer != null) return;
  configureFallbackModules(
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
    await _legacyCacheCleanup();
    await sanitizeFallbackConfigCache();
    unawaited(syncFallbackModules(container.read(accountApiProvider)));
  }());
  _timer = Timer.periodic(_syncInterval, (_) {
    unawaited(syncFallbackModules(container.read(accountApiProvider)));
  });
}

/// 旧缓存键清理：v1 缓存存的是热修模块代码，升级到配置化后不再读取。
/// 延迟一次性清掉，避免残留可执行代码落盘。
Future<void> _legacyCacheCleanup() async {
  // 由 initFallbackModuleSync 的首次同步触发一次即可；SharedPreferences
  // 单例内部有缓存，直接按 key 删除 v1 存储。
  try {
    final prefs = await SharedPreferences.getInstance();
    const legacyKey = 'xianyu_fallback_modules_v1';
    if (prefs.containsKey(legacyKey)) {
      await prefs.remove(legacyKey);
      AppLog.info('plugin', '[FallbackConfig] 已清理旧版模块缓存');
    }
  } catch (_) {}
}
