import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 设备信息：反馈 / 错误上报时携带，便于后台定位具体机型。
class MobileDeviceInfo {
  final String brand;
  final String manufacturer;
  final String model;
  final String osVersion;

  const MobileDeviceInfo({
    required this.brand,
    required this.manufacturer,
    required this.model,
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

/// 读取真实厂商/型号/系统版本。仅 Android 走原生 MethodChannel，
/// 结果缓存，失败或非 Android 回退默认值。
Future<MobileDeviceInfo> fetchDeviceInfo() async {
  if (_cached != null) return _cached!;
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
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
      osVersion: j['os_version'] as String? ?? 'Android',
    );
    return _cached!;
  } catch (_) {
    return _fallback;
  }
}

