import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../core/application_logger.dart';
import '../../rust/api.dart' as frb;
import 'types.dart';

// ==================== 兜底行为配置存取（签名配置下发，无可执行代码） ====================
// 服务端下发整包配置 JSON + ed25519 签名；验签通过才缓存并应用到内存。
// 全部逻辑固定在客户端原生实现（Rust builtin），配置只控制链路开关与
// 平台来源，因此无需宿主加载/熔断链路：查询直接读内存，未同步前按默认放行。

const _storageKey = 'xianyu_fallback_config_v2';

// ==================== 降级/异常事件上报（statistics 通道） ====================
// 走 reportError → 服务端 error_log（验签失败/同步失败等配置层异常）；
// 同事件 60s 去重，避免轮询失败时刷屏。
const _eventReportDedup = Duration(minutes: 1);
const _maxRecentEventReports = 32;

final _recentEventReports = <String, DateTime>{};

void Function(String eventType, String detail)? _eventReporter;

void configureFallbackModules({
  void Function(String eventType, String detail)? reportEvent,
}) {
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

// ==================== 内存态配置 ====================

FallbackRemoteConfig? _config;

/// 当前生效的整包配置（未同步/验签失败时为 null = 全部默认放行）
FallbackRemoteConfig? get currentFallbackConfig => _config;

/// 指定方法是否被服务端配置关闭。配置未同步时默认放行。
bool fallbackMethodDisabled(String moduleKey, String method) =>
    _config?.modules[moduleKey]?.disabledMethods.contains(method) ?? false;

/// 服务端下发的平台来源白名单与顺序（仅榜单/推荐歌单模块）。
/// 返回 null = 未配置（沿用调用方默认来源）；与调用方来源无交集时也返回
/// null，避免配置把当前页面打空。
List<String>? fallbackModuleSourceOrder(String moduleKey, List<String> wanted) {
  final configured = _config?.modules[moduleKey]?.sources;
  if (configured == null || wanted.isEmpty) return null;
  final filtered = configured.where(wanted.contains).toList();
  return filtered.isEmpty ? null : filtered;
}

// ==================== 缓存读写与应用 ====================

Future<String?> _readCachedConfig() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_storageKey);
  } catch (e) {
    AppLog.warn('plugin', '[FallbackConfig] 读取本地缓存失败: $e');
    return null;
  }
}

Future<void> _writeCachedConfig(String configJson) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_storageKey, configJson);
  } catch (e) {
    AppLog.warn('plugin', '[FallbackConfig] 写入本地缓存失败: $e');
  }
}

Future<void> _clearCachedConfig() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_storageKey);
  } catch (_) {}
}

Future<bool> _verifySignature(String configJson, String signature) async {
  try {
    return await frb.verifyFallbackConfigSignature(
      configJson: configJson,
      signature: signature,
    );
  } catch (e) {
    AppLog.warn('plugin', '[FallbackConfig] 验签命令不可用，按未通过处理: $e');
    return false;
  }
}

/// 应用一份已验签的配置（同步进内存）
void _applyConfig(String configJson) {
  final parsed = parseFallbackConfigJson(configJson);
  if (parsed == null) {
    AppLog.warn('plugin', '[FallbackConfig] 配置解析失败，忽略（沿用默认行为）');
    return;
  }
  _config = parsed;
  AppLog.info(
      'plugin', '[FallbackConfig] 应用配置 v${parsed.version}，模块数=${parsed.modules.length}');
}

/// 启动/同步前清理：验签不过或解析失败的缓存直接清除（签名密钥轮换、
/// 拉取失败后调用），回退全部默认行为。
Future<int> sanitizeFallbackConfigCache() async {
  final cached = await _readCachedConfig();
  if (cached == null || cached.isEmpty) return 0;
  Object? decoded;
  try {
    decoded = const JsonDecoder().convert(cached);
  } catch (_) {
    decoded = null;
  }
  final signature =
      decoded is Map ? (decoded['signature'] ?? '').toString() : '';
  final configJson =
      decoded is Map ? (decoded['config'] ?? '').toString() : '';
  if (configJson.isEmpty ||
      signature.isEmpty ||
      !await _verifySignature(configJson, signature)) {
    await _clearCachedConfig();
    _config = null;
    AppLog.warn('plugin', '[FallbackConfig] 缓存配置验签失败，已清除（回退默认行为）');
    return 1;
  }
  final parsed = parseFallbackConfigJson(configJson);
  if (parsed == null) {
    await _clearCachedConfig();
    _config = null;
    AppLog.warn('plugin', '[FallbackConfig] 缓存配置解析失败，已清除（回退默认行为）');
    return 1;
  }
  _config = parsed;
  return 0;
}

/// 服务端下发的整包配置（config JSON + 签名）验签后应用并缓存。
/// 验签失败丢弃并清除旧缓存（fail closed：回退客户端默认行为）。
Future<void> applyServerFallbackConfig(
  String configJson,
  String signature,
) async {
  if (configJson.isEmpty || signature.isEmpty) return;
  if (!await _verifySignature(configJson, signature)) {
    AppLog.warn('plugin', '[FallbackConfig] 服务端配置验签失败，已丢弃（回退默认行为）');
    _reportFallbackEvent('FallbackConfigVerifyFail', '配置验签失败已丢弃');
    await _clearCachedConfig();
    _config = null;
    return;
  }
  await _writeCachedConfig(_wrapCache(configJson, signature));
  _applyConfig(configJson);
}

String _wrapCache(String configJson, String signature) =>
    const JsonEncoder().convert({'config': configJson, 'signature': signature});
