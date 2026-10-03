import 'dart:async';

import 'package:flutter/services.dart';

import '../core/application_logger.dart';

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
    } catch (e) {
      AppLog.warn('watch', '连接手表失败: $e');
    }
  }

  Future<void> start() async {
    try {
      await _ch.invokeMethod('start');
    } catch (e) {
      AppLog.warn('watch', '启动手表服务失败: $e');
    }
  }

  Future<void> stop() async {
    try {
      await _ch.invokeMethod('stop');
    } catch (e) {
      AppLog.debug('watch', '停止手表服务失败: $e');
    }
  }

  Future<void> disconnect() async {
    try {
      await _ch.invokeMethod('disconnect');
    } catch (e) {
      AppLog.debug('watch', '断开手表连接失败: $e');
    }
  }

  Future<void> send(Uint8List bytes) async {
    try {
      await _ch.invokeMethod('send', {'bytes': bytes});
    } catch (e) {
      AppLog.warn('watch', '发送数据到手表失败: $e');
    }
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
    } catch (e) {
      AppLog.warn('watch', '请求手表权限失败: $e');
    }
  }

  // ---- Wear Engine ----

  Future<bool> hasWearEngine() async {
    try {
      return await _ch.invokeMethod('wearHasEngine') == true;
    } catch (_) {
      return false;
    }
  }

  Future<void> installHealth() async {
    try {
      await _ch.invokeMethod('wearInstallHealth');
    } catch (e) {
      AppLog.warn('watch', '安装手表健康服务失败: $e');
    }
  }

  Future<WearAuthResult> wearAuthorize() async {
    try {
      return WearAuthResult.fromMap(await _ch.invokeMethod('wearAuthorize'));
    } catch (e) {
      return WearAuthResult(granted: false, canceled: false, message: '$e');
    }
  }

  Future<List<WearEngineDevice>> wearDevices() async {
    try {
      final list = await _ch.invokeMethod<List<dynamic>>('wearDevices');
      return (list ?? const []).map(WearEngineDevice.fromMap).toList();
    } catch (_) {
      return const [];
    }
  }

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

class WearWakeResult {
  const WearWakeResult({
    required this.ok,
    required this.code,
    required this.message,
  });

  final bool ok;

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
