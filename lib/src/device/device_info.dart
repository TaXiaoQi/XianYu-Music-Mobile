import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 设备信息：反馈 / 错误上报 / 启动统计时携带，便于后台定位具体机型。
class MobileDeviceInfo {
  final String brand;
  final String manufacturer;
  final String model;
  /// 设备市场名（如「小米16」，国产 ROM 经 ro.product.marketname 读取），可能为空
  final String marketName;
  final String osVersion;

  const MobileDeviceInfo({
    required this.brand,
    required this.manufacturer,
    required this.model,
    this.marketName = '',
    required this.osVersion,
  });
}

const MobileDeviceInfo _fallback = MobileDeviceInfo(
  brand: 'Android',
  manufacturer: 'Android',
  model: 'Android',
  osVersion: 'Android',
);

MobileDeviceInfo? _cached;

/// 读取真实厂商/型号/系统版本。Android/iOS 走原生 MethodChannel
/// （iOS 在 SceneDelegate 注册同名通道），结果缓存，失败或其他平台回退默认值。
Future<MobileDeviceInfo> fetchDeviceInfo() async {
  if (_cached != null) return _cached!;
  if (kIsWeb) {
    return _fallback;
  }
  try {
    const channel = MethodChannel('xianyu/device_info');
    final raw = await channel.invokeMethod<String>('getDeviceInfo');
    if (raw == null || raw.isEmpty) return _fallback;
    final j = jsonDecode(raw) as Map<String, dynamic>;
    _cached = MobileDeviceInfo(
      brand: j['brand'] as String? ?? 'Android',
      manufacturer: j['manufacturer'] as String? ?? '',
      model: j['model'] as String? ?? '',
      marketName: j['market_name'] as String? ?? '',
      osVersion: j['os_version'] as String? ?? 'Android',
    );
    return _cached!;
  } catch (_) {
    return _fallback;
  }
}

String? _cachedInstallerSource;

/// 应用安装来源（installer 包名，如 Google Play 的 com.android.vending、
/// F-Droid 客户端的 org.fdroid.fdroid）；侧载/未知/非 Android 返回 null。
/// 结果缓存。供自更新逻辑判定商店渠道（商店政策禁止绕过商店自更新）。
Future<String?> fetchInstallerSource() async {
  if (_cachedInstallerSource != null) return _cachedInstallerSource;
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
  try {
    const channel = MethodChannel('xianyu/device_info');
    final source = await channel.invokeMethod<String>('getInstallerSource');
    _cachedInstallerSource = (source == null || source.isEmpty) ? '' : source;
    return _cachedInstallerSource!.isEmpty ? null : _cachedInstallerSource;
  } catch (_) {
    // 查询失败视为侧载（沿用官网直发自更新），缓存空串避免反复探测
    _cachedInstallerSource = '';
    return null;
  }
}

String? _cachedStableDeviceId;
bool _stableDeviceIdFetched = false;

/// 平台级稳定设备 ID（卸载重装不变，用于登录签名/设备封禁等）。
/// Android 优先 Widevine DRM 设备 ID（硬件派生，恢复出厂通常也不变），
/// 退回 ANDROID_ID；iOS 取 Keychain 持久化 UUID（卸载不清除，仅抹机才清除）。
/// 获取失败（通道未就绪/平台不支持）返回 null，由调用方回退本地随机 ID。
Future<String?> fetchStableDeviceId() async {
  if (_stableDeviceIdFetched) return _cachedStableDeviceId;
  if (kIsWeb) return null;
  try {
    const channel = MethodChannel('xianyu/device_info');
    final id = await channel.invokeMethod<String>('getStableDeviceId');
    _cachedStableDeviceId = (id == null || id.isEmpty) ? null : id;
    // 仅成功取到才锁定缓存：iOS 通道晚于 Dart 首次调用注册时，
    // null 不缓存，下次调用（登录/上报）重试仍可拿到稳定 ID
    _stableDeviceIdFetched = _cachedStableDeviceId != null;
  } catch (_) {
    _cachedStableDeviceId = null;
  }
  return _cachedStableDeviceId;
}

