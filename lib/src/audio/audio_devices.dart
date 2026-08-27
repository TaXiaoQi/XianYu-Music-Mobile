import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../i18n/i18n.dart';

/// 枚举到的输出音频设备。id 与 AAudio `setDeviceId` 一致，可传入独占播放。
class AudioOutputDevice {
  final int id;
  final String name;
  final String type;
  final List<int> sampleRates;
  final List<int> channelCounts;

  const AudioOutputDevice({
    required this.id,
    required this.name,
    required this.type,
    required this.sampleRates,
    required this.channelCounts,
  });

  factory AudioOutputDevice.fromJson(Map<String, dynamic> j) =>
      AudioOutputDevice(
        id: (j['id'] as num).toInt(),
        name: j['name'] as String? ?? tr('未知设备'),
        type: j['type'] as String? ?? tr('其他'),
        sampleRates: (j['sampleRates'] as List? ?? const [])
            .whereType<num>()
            .map((e) => e.toInt())
            .toList(),
        channelCounts: (j['channelCounts'] as List? ?? const [])
            .whereType<num>()
            .map((e) => e.toInt())
            .toList(),
      );

  /// 展示名称，如「USB 设备 · USB DAC (44100Hz)」
  String get displayName => '$type · $name';
}

/// 仅 Android 提供平台通道枚举输出设备；其余平台返回空列表。
Future<List<AudioOutputDevice>> listOutputDevices() async {
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    try {
      const channel = MethodChannel('xianyu/audio_devices');
      final raw = await channel.invokeMethod<String>('listOutputDevices');
      if (raw == null || raw.isEmpty) return const [];
      final list = jsonDecode(raw) as List;
      return list
          .whereType<Map>()
          .map((e) =>
              AudioOutputDevice.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return const [];
    }
  }
  return const [];
}