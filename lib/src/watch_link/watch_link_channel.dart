import 'dart:async';

import 'package:flutter/services.dart';

class WatchLinkConnection {
  const WatchLinkConnection({required this.connected, required this.name});

  final bool connected;
  final String name;
}

class WatchBondedDevice {
  const WatchBondedDevice({required this.address, required this.name});

  final String address;
  final String name;

  static WatchBondedDevice fromMap(Object? m) {
    final map = m as Map? ?? const {};
    return WatchBondedDevice(
      address: (map['address'] as String?) ?? '',
      name: (map['name'] as String?) ?? '',
    );
  }
}

class WatchLinkChannel {
  static const MethodChannel _ch = MethodChannel('xianyu/watch_link');

  final _rawCtrl = StreamController<Uint8List>.broadcast();
  final _connCtrl = StreamController<WatchLinkConnection>.broadcast();
  final _permCtrl = StreamController<bool>.broadcast();
  bool _bound = false;

  Stream<Uint8List> get onRaw => _rawCtrl.stream;

  Stream<WatchLinkConnection> get onConnection => _connCtrl.stream;

  Stream<bool> get onPermission => _permCtrl.stream;

  void bind() {
    if (_bound) return;
    _bound = true;
    _ch.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onRaw':
          final bytes = call.arguments as Uint8List?;
          if (bytes != null && bytes.isNotEmpty) _rawCtrl.add(bytes);
        case 'onConnection':
          final args = call.arguments as Map?;
          _connCtrl.add(WatchLinkConnection(
            connected: args?['connected'] == true,
            name: (args?['name'] as String?) ?? '',
          ));
        case 'onPermission':
          _permCtrl.add(call.arguments == true);
      }
    });
  }

  Future<List<WatchBondedDevice>> pairedDevices() async {
    try {
      final list = await _ch.invokeMethod<List<dynamic>>('pairedDevices');
      return (list ?? const []).map(WatchBondedDevice.fromMap).toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> connect(String address) async {
    try {
      await _ch.invokeMethod('connect', {'address': address});
    } catch (_) {}
  }

  Future<void> start() async {
    try {
      await _ch.invokeMethod('start');
    } catch (_) {}
  }

  Future<void> stop() async {
    try {
      await _ch.invokeMethod('stop');
    } catch (_) {}
  }

  Future<void> disconnect() async {
    try {
      await _ch.invokeMethod('disconnect');
    } catch (_) {}
  }

  Future<void> send(Uint8List bytes) async {
    try {
      await _ch.invokeMethod('send', {'bytes': bytes});
    } catch (_) {}
  }

  Future<bool> hasPermission() async {
    try {
      return await _ch.invokeMethod('hasPermission') == true;
    } catch (_) {
      return false;
    }
  }

  Future<void> requestPermission() async {
    try {
      await _ch.invokeMethod('requestPermission');
    } catch (_) {}
  }

  // ---- Wear Engine（华为运动健康通道）：查询/授权/远程拉起腕上端 ----

  /// 运动健康是否已安装（Android 11+ 包可见性已在清单声明）。
  Future<bool> hasWearEngine() async {
    try {
      return await _ch.invokeMethod('wearHasEngine') == true;
    } catch (_) {
      return false;
    }
  }

  /// 跳转应用市场安装华为运动健康。
  Future<void> installHealth() async {
    try {
      await _ch.invokeMethod('wearInstallHealth');
    } catch (_) {}
  }

  /// 请求 Wear Engine DEVICE_MANAGER 授权（未授权时弹华为授权页）。
  Future<WearAuthResult> wearAuthorize() async {
    try {
      return WearAuthResult.fromMap(await _ch.invokeMethod('wearAuthorize'));
    } catch (e) {
      return WearAuthResult(granted: false, canceled: false, message: '$e');
    }
  }

  /// 已绑定穿戴设备列表。
  Future<List<WearEngineDevice>> wearDevices() async {
    try {
      final list = await _ch.invokeMethod<List<dynamic>>('wearDevices');
      return (list ?? const []).map(WearEngineDevice.fromMap).toList();
    } catch (_) {
      return const [];
    }
  }

  /// ping 远程拉起腕上端（已安装未启动→冷启动，已启动→直接在线）。
  Future<WearWakeResult> wearWake({String? bundleName}) async {
    try {
      return WearWakeResult.fromMap(
        await _ch.invokeMethod('wearWake', {'bundleName': bundleName}),
      );
    } catch (e) {
      return WearWakeResult(ok: false, code: -1, message: '$e');
    }
  }
}

/// 华为运动健康通道已绑定的穿戴设备。
class WearEngineDevice {
  const WearEngineDevice({required this.name, required this.connected});

  final String name;
  final bool connected;

  static WearEngineDevice fromMap(Object? m) {
    final map = m as Map? ?? const {};
    return WearEngineDevice(
      name: (map['name'] as String?) ?? '',
      connected: map['connected'] == true,
    );
  }
}

/// Wear Engine 授权结果。
class WearAuthResult {
  const WearAuthResult({
    required this.granted,
    required this.canceled,
    required this.message,
  });

  final bool granted;
  final bool canceled;
  final String message;

  static WearAuthResult fromMap(Object? m) {
    final map = m as Map? ?? const {};
    return WearAuthResult(
      granted: map['granted'] == true,
      canceled: map['canceled'] == true,
      message: (map['message'] as String?) ?? '',
    );
  }
}

/// Wear Engine ping 拉起结果。
class WearWakeResult {
  const WearWakeResult({
    required this.ok,
    required this.code,
    required this.message,
  });

  final bool ok;

  /// 201=冷启动拉起，202=已在运行，200=手表端未安装，404=无绑定设备。
  final int code;
  final String message;

  static WearWakeResult fromMap(Object? m) {
    final map = m as Map? ?? const {};
    return WearWakeResult(
      ok: map['ok'] == true,
      code: (map['code'] as num?)?.toInt() ?? -1,
      message: (map['message'] as String?) ?? '',
    );
  }
}
