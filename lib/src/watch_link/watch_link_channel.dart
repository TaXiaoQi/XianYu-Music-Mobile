import 'dart:async';

import 'package:flutter/services.dart';

/// 连接事件（Kotlin 侧 onConnection 回传）。
class WatchLinkConnection {
  const WatchLinkConnection({required this.connected, required this.name});

  final bool connected;
  final String name;
}

/// 手机端手表联动 MethodChannel 封装（对应 Kotlin `watch/WatchLink.kt`）。
///
/// Kotlin 只做 RFCOMM 字节管道：本类把 onRaw 原始字节 / onConnection 连接事件 /
/// onPermission 权限结果转成广播流，帧编解码与协议语义在 [watch_link_provider]。
class WatchLinkChannel {
  static const MethodChannel _ch = MethodChannel('xianyu/watch_link');

  final _rawCtrl = StreamController<Uint8List>.broadcast();
  final _connCtrl = StreamController<WatchLinkConnection>.broadcast();
  final _permCtrl = StreamController<bool>.broadcast();
  bool _bound = false;

  /// 收到的原始字节流（帧解码由上层 FrameDecoder 完成）。
  Stream<Uint8List> get onRaw => _rawCtrl.stream;

  /// 连接建立/断开。
  Stream<WatchLinkConnection> get onConnection => _connCtrl.stream;

  /// 运行时权限请求结果（Android 12+ BLUETOOTH_CONNECT）。
  Stream<bool> get onPermission => _permCtrl.stream;

  /// 注册 Kotlin→Dart 回调 handler（幂等）。
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

  /// 启动 RFCOMM 服务端 accept 循环（幂等）。
  Future<void> start() async {
    try {
      await _ch.invokeMethod('start');
    } catch (_) {}
  }

  /// 停止服务并断开连接（幂等）。
  Future<void> stop() async {
    try {
      await _ch.invokeMethod('stop');
    } catch (_) {}
  }

  /// 发送原始帧字节。
  Future<void> send(Uint8List bytes) async {
    try {
      await _ch.invokeMethod('send', {'bytes': bytes});
    } catch (_) {}
  }

  /// 蓝牙运行时权限是否已授予。
  Future<bool> hasPermission() async {
    try {
      return await _ch.invokeMethod('hasPermission') == true;
    } catch (_) {
      return false;
    }
  }

  /// 发起权限请求，结果经 [onPermission] 回传。
  Future<void> requestPermission() async {
    try {
      await _ch.invokeMethod('requestPermission');
    } catch (_) {}
  }
}
