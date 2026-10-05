import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../auth/account_api.dart' show appVersion;
import '../../core/application_logger.dart';
import '../../rust/api.dart' as frb;
import 'types.dart';

// ==================== 兜底模块注册表（移植自桌面端 fallbackModules/registry） ====================
// 模块在移动端 Rust QuickJS 宿主执行：验签 + 编译 + 四条硬校验一体（load），
// 调用走 fallback_module_call。_loaded 只保存「已加载标记 + 熔断状态」。

const _storageKey = 'xianyu_fallback_modules_v1';

const _maxConsecutiveErrors = 3;

// ==================== 降级/熔断事件上报（statistics 通道） ====================
// 走 reportError → 服务端 error_log，按 error_type 聚合即可量化热修效果；
// 同事件 60s 去重，避免模块故障时刷屏。
const _eventReportDedup = Duration(minutes: 1);
const _maxRecentEventReports = 32;

final _recentEventReports = <String, DateTime>{};

// dataDir 解析与事件上报由启动流程注入（initFallbackModuleSync），
// 未注入时所有调用直接回退内置实现
Future<String> Function()? _dataDirResolver;
void Function(String eventType, String detail)? _eventReporter;

void configureFallbackModules({
  required Future<String> Function() dataDirResolver,
  void Function(String eventType, String detail)? reportEvent,
}) {
  _dataDirResolver = dataDirResolver;
  _eventReporter = reportEvent;
}

void _reportFallbackEvent(String eventType, String detail) {
  final reporter = _eventReporter;
  if (reporter == null) return;
  final now = DateTime.now();
  if (_recentEventReports.length > _maxRecentEventReports) {
    _recentEventReports
        .removeWhere((_, t) => now.difference(t) >= _eventReportDedup);
  }
  final dedupKey = '$eventType::$detail';
  final last = _recentEventReports[dedupKey];
  if (last != null && now.difference(last) < _eventReportDedup) return;
  _recentEventReports[dedupKey] = now;
  try {
    reporter(eventType, detail);
  } catch (_) {
    // 上报层异常不影响兜底主流程
  }
}

/// 已加载标记 + 熔断状态
class _LoadedModule {
  final int version;
  int consecutiveErrors = 0;
  bool disabled = false;

  _LoadedModule(this.version);
}

final _loaded = <String, _LoadedModule>{};

// 防预热/首调竞态：同 key 的 load 只发一次，其余等待同一 Future
final _loadPromises = <String, Future<_LoadedModule?>>{};

class _ModuleCache {
  final int fetchedAt;
  final Map<String, CachedFallbackModule> modules;

  const _ModuleCache({required this.fetchedAt, required this.modules});
}

const _emptyCache = _ModuleCache(fetchedAt: 0, modules: {});

Future<_ModuleCache> _readCache() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey);
    if (raw == null || raw.isEmpty) return _emptyCache;
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return _emptyCache;
    final modules = <String, CachedFallbackModule>{};
    final rawModules = decoded['modules'];
    if (rawModules is Map) {
      for (final e in rawModules.entries) {
        if (e.value is! Map) continue;
        modules[e.key.toString()] =
            CachedFallbackModule.fromJson(Map<String, dynamic>.from(e.value as Map));
      }
    }
    return _ModuleCache(
      fetchedAt: (decoded['fetchedAt'] as num?)?.toInt() ?? 0,
      modules: modules,
    );
  } catch (e) {
    AppLog.warn('plugin', '[FallbackModule] 读取本地缓存失败: $e');
    return _emptyCache;
  }
}

Future<void> _writeCacheModules(
  int fetchedAt,
  Map<String, CachedFallbackModule> modules,
) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _storageKey,
      jsonEncode({
        'fetchedAt': fetchedAt,
        'modules': modules.map((k, v) => MapEntry(k, v.toJson())),
      }),
    );
  } catch (e) {
    AppLog.warn('plugin', '[FallbackModule] 写入本地缓存失败: $e');
  }
}

Future<bool> _verifySignature(
  String moduleKey,
  int version,
  String code,
  String signature,
) async {
  try {
    return await frb.verifyFallbackModuleSignature(
      moduleKey: moduleKey,
      version: version,
      code: code,
      signature: signature,
    );
  } catch (e) {
    AppLog.warn('plugin', '[FallbackModule] $moduleKey 验签命令不可用，按未通过处理: $e');
    return false;
  }
}

/// 清除本地缓存中验签不过/字段残缺的模块（拉取失败、签名密钥轮换后调用）。
/// 返回清除数量。
Future<int> sanitizeFallbackModuleCache() async {
  final cache = await _readCache();
  var removed = 0;
  final next = <String, CachedFallbackModule>{};
  for (final e in cache.modules.entries) {
    final m = e.value;
    if (m.code.isEmpty || m.signature.isEmpty) {
      removed += 1;
      continue;
    }
    if (!await _verifySignature(e.key, m.version, m.code, m.signature)) {
      removed += 1;
      AppLog.warn('plugin',
          '[FallbackModule] 缓存模块 ${e.key} v${m.version} 验签失败，已清除（回退内置实现）');
      continue;
    }
    next[e.key] = m;
  }
  if (removed > 0) {
    await _writeCacheModules(cache.fetchedAt, next);
    _loaded.clear();
  }
  return removed;
}

void _printModuleLogs(String key, Object? logs) {
  if (logs is! List) return;
  for (final entry in logs) {
    if (entry is! Map) continue;
    final line =
        '[FallbackModule] $key: ${entry['message']?.toString() ?? ''}';
    final level = entry['level']?.toString() ?? '';
    if (level == 'error') {
      AppLog.error('plugin', line);
    } else if (level == 'warn') {
      AppLog.warn('plugin', line);
    } else {
      AppLog.debug('plugin', line);
    }
  }
}

Future<_LoadedModule?> _loadModuleFromCache(String key) async {
  final cache = await _readCache();
  final cached = cache.modules[key];
  AppLog.info('plugin',
      '[FallbackModule] load $key: cacheModules=${cache.modules.length} cached=${cached != null}');
  if (cached == null || cached.code.isEmpty || cached.signature.isEmpty) {
    AppLog.info('plugin', '[FallbackModule] load $key: 无有效缓存');
    return null;
  }
  try {
    final dataDir =
        _dataDirResolver == null ? null : await _dataDirResolver!();
    if (dataDir == null || dataDir.isEmpty) return null;
    // Dart 层超时兜底：Rust 内部有 7s 上界，但桥传输层挂起时 await 永不返回
    final raw = await frb.fallbackModuleLoad(
      dataDir: dataDir,
      moduleKey: key,
      version: cached.version,
      code: cached.code,
      signature: cached.signature,
      appVersion: appVersion,
    ).timeout(const Duration(seconds: 10));
    AppLog.info('plugin', '[FallbackModule] load $key: bridge returned');
    final res = jsonDecode(raw);
    if (res is Map && res['ok'] == true) {
      _printModuleLogs(key, res['logs']);
      return _LoadedModule((res['version'] as num?)?.toInt() ?? cached.version);
    }
    // 验签/编译失败是确定性错误：本会话禁用，避免每次调用都重试
    final error = res is Map ? res['error']?.toString() : raw;
    _printModuleLogs(key, res is Map ? res['logs'] : null);
    AppLog.warn('plugin',
        '[FallbackModule] 模块 $key v${cached.version} 宿主加载失败，本会话回退内置实现: $error');
    _reportFallbackEvent(
        'FallbackModuleLoadFail', '$key v${cached.version} 宿主加载失败: $error');
    return _LoadedModule(cached.version)..disabled = true;
  } catch (e) {
    // 桥接异常可能是暂时的：不缓存状态，下次调用重试 load
    AppLog.warn('plugin', '[FallbackModule] $key 宿主加载命令不可用，本次回退内置实现: $e');
    _reportFallbackEvent('FallbackModuleLoadFail', '$key 宿主加载命令不可用: $e');
    return null;
  }
}

Future<_LoadedModule?> _ensureModuleLoaded(String key) {
  final existing = _loaded[key];
  if (existing != null) return Future.value(existing);
  var pending = _loadPromises[key];
  if (pending == null) {
    pending = _loadModuleFromCache(key).then((loaded) {
      if (loaded != null) _loaded[key] = loaded;
      return loaded;
    }).whenComplete(() => _loadPromises.remove(key));
    _loadPromises[key] = pending;
  }
  return pending;
}

/// 启动/同步后把缓存中的模块批量加载进 Rust 宿主，消除首次调用的 load 延迟
Future<void> prewarmFallbackModules() async {
  for (final key in (await _readCache()).modules.keys) {
    unawaited(_ensureModuleLoaded(key));
  }
}

void _reportModuleError(String key, String method, Object? error) {
  final loaded = _loaded[key];
  if (loaded == null) return;
  loaded.consecutiveErrors += 1;
  AppLog.warn('plugin',
      '[FallbackModule] 模块 $key.$method 第 ${loaded.consecutiveErrors} 次执行失败，本次回退内置实现: $error');
  _reportFallbackEvent('FallbackModuleCallFail', '$key.$method: $error');
  if (loaded.consecutiveErrors >= _maxConsecutiveErrors) {
    loaded.disabled = true;
    AppLog.warn('plugin',
        '[FallbackModule] 模块 $key 连续失败 ${loaded.consecutiveErrors} 次，本会话内已禁用（等待服务器下发新版本）');
    _reportFallbackEvent('FallbackModuleCircuitOpen',
        '$key 连续失败 ${loaded.consecutiveErrors} 次已熔断（method=$method）');
  }
}

/// 是否存在可用的下发模块缓存。调用方在无模块时可直接走 builtin，
/// 跳过 dispatch 的加载/熔断链路（无模块时该链路纯属开销）。
Future<bool> fallbackModuleCached(String key) async {
  final m = (await _readCache()).modules[key];
  return m != null && m.code.isNotEmpty && m.signature.isNotEmpty;
}

/// 分发到热修模块执行；模块未加载/被熔断/执行失败时回退 [builtin] 内置实现。
/// [builtin] 与模块返回同构数据（模块侧经 JSON 还原）。
Future<T> dispatchFallbackModule<T>(
  String key,
  String method,
  Map<String, dynamic> args,
  FutureOr<T> Function() builtin,
) async {
  AppLog.info('plugin', '[FallbackModule] dispatch $key.$method 进入');
  // 无下发模块时直接走内置实现：跳过桥加载/调用链路（无模块时该链路
  // 纯属开销，load 超时窗口还会让歌词等首调场景白转 10s+）
  if (!await fallbackModuleCached(key)) {
    return await builtin();
  }
  final loaded = await _ensureModuleLoaded(key);
  AppLog.info('plugin',
      '[FallbackModule] dispatch $key.$method: loaded=${loaded != null} disabled=${loaded?.disabled ?? false}');
  if (loaded != null && !loaded.disabled) {
    try {
      final dataDir =
          _dataDirResolver == null ? null : await _dataDirResolver!();
      if (dataDir != null && dataDir.isNotEmpty) {
        // Dart 层超时兜底：Rust 内部有 15s 上界，但桥传输层挂起时
        // await 永不返回，上层会永久停留在加载态
        final raw = await frb.fallbackModuleCall(
          dataDir: dataDir,
          moduleKey: key,
          method: method,
          argsJson: jsonEncode(args),
        ).timeout(const Duration(seconds: 20));
        AppLog.info('plugin',
            '[FallbackModule] call $key.$method: bridge returned');
        final res = jsonDecode(raw);
        _printModuleLogs(key, res is Map ? res['logs'] : null);
        if (res is Map && res['ok'] == true) {
          loaded.consecutiveErrors = 0;
          return res['data'] as T;
        }
        // Rust 侧超时/中断会销毁实例：删掉已加载标记，下次调用重新 load
        if (res is Map &&
            res['error']?.toString().contains('模块未加载') == true) {
          _loaded.remove(key);
        }
        _reportModuleError(
            key, method, res is Map ? (res['error'] ?? '模块调用失败') : '模块调用失败');
      }
    } catch (e) {
      _reportModuleError(key, method, e);
    }
  }
  return await builtin();
}

/// 用服务端下发的模块清单整包替换本地缓存（仅保留移动端已接入的 key）。
/// 有增删/更新时清空已加载标记，下次调用按新版本重新 load。
Future<void> applyServerFallbackModules(List<ServerFallbackModule> modules) async {
  final prev = (await _readCache()).modules;
  final next = <String, CachedFallbackModule>{};
  var added = 0;

  for (final item in modules) {
    if (item.code.isEmpty) continue;
    final expected = fallbackModuleMethods[item.moduleKey];
    if (expected == null) continue;
    final cached = prev[item.moduleKey];
    final sameVerified = cached != null &&
        cached.version == item.version &&
        cached.digest == item.digest &&
        cached.code == item.code &&
        cached.signature == item.signature &&
        cached.signature.isNotEmpty;
    if (sameVerified) {
      next[item.moduleKey] = cached;
      continue;
    }
    next[item.moduleKey] = CachedFallbackModule(
      version: item.version,
      digest: item.digest,
      code: item.code,
      signature: item.signature,
      name: item.name,
      updatedAt: item.updatedAt,
    );
    added += 1;
  }

  final removed = prev.keys.where((k) => !next.containsKey(k)).length;
  if (added > 0 || removed > 0) {
    await _writeCacheModules(DateTime.now().millisecondsSinceEpoch, next);
    _loaded.clear();
  }
}
