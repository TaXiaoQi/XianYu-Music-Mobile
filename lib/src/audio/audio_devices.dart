import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../i18n/i18n.dart';

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

  String get displayName => '$type · $name';
}

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