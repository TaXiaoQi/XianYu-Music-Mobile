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
}
