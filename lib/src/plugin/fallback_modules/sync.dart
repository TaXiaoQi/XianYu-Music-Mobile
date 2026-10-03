import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/account_api.dart';
import '../../core/application_logger.dart';
import '../../core/db_path.dart';
import '../../core/rust_init.dart';
import '../../core/settings.dart';
import '../../rust/api.dart' as frb;
import 'registry.dart';
import 'types.dart';

// ==================== 兜底模块服务端同步（移植自桌面端 fallbackModules/sync） ====================
// 启动即拉取一次，之后 30min 轮询；拉取失败保留本地缓存并做验签清理。
// 配置快照推送：settings 变化整包推给 Rust（模块 ctx.config.get 读取），
// 快照复用 settingsToSyncMap（跨端设置同步的扁平键形态，与桌面深层嵌套
// shape 不同，跨端热修模块需按「key 可能缺失」编写）。

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

/// 启动挂载：注入 dataDir/上报，清理缓存后预热，配置对账，并开启 30min 轮询。
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
    await reconcileFallbackModuleConfig(container);
  }());
  _timer = Timer.periodic(_syncInterval, (_) {
    unawaited(syncFallbackModules(container.read(accountApiProvider)));
  });
}

// ==================== 兜底模块配置快照推送 ====================

const _configPushDebounce = Duration(milliseconds: 500);
// 推送失败重试：1s → 2s → 4s，共 3 次尝试，仍失败才放弃（等下次设置变化或重启）
const _configPushMaxRetries = 3;
const _configPushRetryBase = Duration(seconds: 1);

Timer? _pushDebounce;
var _pushInFlight = false;
var _pushPending = false;

/// 与 Rust update_config 的哈希口径一致：对原始 JSON 字符串取 sha256-hex
String _computeConfigHash(String configJson) =>
    sha256.convert(utf8.encode(configJson)).toString();

Future<String> _settingsConfigJson(ProviderContainer container) async {
  final settings = await container.read(settingsProvider.future);
  return jsonEncode(settingsToSyncMap(settings));
}

void pushFallbackModuleConfig(ProviderContainer container) {
  // 上一轮重试尚未结束：只记待推标记，结束后按最新设置补推一次
  if (_pushInFlight) {
    _pushPending = true;
    return;
  }
  _pushInFlight = true;
  unawaited(() async {
    try {
      for (var attempt = 1; ; attempt += 1) {
        // 每次尝试重取最新快照，重试期间设置再变也不会推出旧配置
        try {
          final configJson = await _settingsConfigJson(container);
          final dataDir = await container.read(appDataDirProvider.future);
          await frb.fallbackModuleUpdateConfig(
              dataDir: dataDir, configJson: configJson);
          return;
        } catch (e) {
          if (attempt >= _configPushMaxRetries) {
            AppLog.warn('plugin',
                '[FallbackModule] 推送兜底模块配置失败（已重试 $_configPushMaxRetries 次，等待下次设置变化或重启）: $e');
            return;
          }
          final delay = _configPushRetryBase * math.pow(2, attempt - 1);
          AppLog.warn('plugin',
              '[FallbackModule] 推送兜底模块配置失败，${delay.inMilliseconds}ms 后重试（第 ${attempt + 1}/$_configPushMaxRetries 次）: $e');
          await Future<void>.delayed(delay);
        }
      }
    } finally {
      _pushInFlight = false;
      if (_pushPending) {
        _pushPending = false;
        pushFallbackModuleConfig(container);
      }
    }
  }());
}

/// 启动对账：比对本地 settings 快照与 Rust 已存配置的 hash，不一致才重推。
/// 覆盖「上次推送失败后 Rust 侧配置缺失/漂移」的场景；查询失败直接推送兜底。
Future<void> reconcileFallbackModuleConfig(ProviderContainer container) async {
  try {
    // 等 settings 加载完成，避免推出空快照
    await container.read(settingsProvider.future);
    final configJson = await _settingsConfigJson(container);
    final dataDir = await container.read(appDataDirProvider.future);
    final remoteHash = await frb.fallbackModuleConfigHash(dataDir: dataDir);
    if (_computeConfigHash(configJson) == remoteHash) return;
    AppLog.info('plugin', '[FallbackModule] 配置对账不一致，重新推送');
  } catch (e) {
    AppLog.warn('plugin', '[FallbackModule] 配置对账查询失败，直接推送兜底: $e');
  }
  pushFallbackModuleConfig(container);
}

/// 设置变化防抖推送（500ms），挂 settingsProvider 监听调用。
/// Rust 未就绪时跳过（桥不可调），启动对账会在就绪后推送。
void scheduleFallbackModuleConfigPush(ProviderContainer container) {
  _pushDebounce?.cancel();
  _pushDebounce = Timer(_configPushDebounce, () {
    if (!container.read(rustInitProvider).hasValue) return;
    pushFallbackModuleConfig(container);
  });
}
