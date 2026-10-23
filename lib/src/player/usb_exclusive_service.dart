import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/application_logger.dart';

/// USB 独占输出格式（Rust 管线产出，ArkTS claim UAC alt setting 用）。
class UsbExclusiveFormat {
  const UsbExclusiveFormat({
    required this.sampleRate,
    required this.channels,
    required this.bytesPerSample,
  });

  final int sampleRate;
  final int channels;
  final int bytesPerSample;
}

/// 鸿蒙 USB 独占桥（椒盐式路线：Rust 当 UAC 主机产 PCM，ArkTS 经
/// usbManager claim 接口后按等时传输写入 DAC）。
///
/// · 数据面（推模型）：本服务每 8ms 经原始 FFI（xianyu_ohos_usb_*，直查
///   libxianyu_core.so 符号，不走 frb codegen）从 Rust 管线环形缓冲搬运
///   一块字节，经 MethodChannel('xianyu/usb_exclusive') 的 `push` 推给
///   ArkTS 等时循环。ArkTS 侧队列满时推入失败 → 数据滞留 ring 自然背压；
///   ring 干涸（暂停/欠载）时 ArkTS 补零发送。不使用 ArkTS→Dart 的
///   回调式 invokeMethod（签名未验证，推模型仅依赖单向 invokeMethod）。
/// · 控制面：`startDevice` 触发 ArkTS 侧 枚举→授权→claim→等时循环，
///   `stopDevice` 释放（releaseInterface/closePipe，并停推）；`onDeviceLost`
///   回调热拔出。
///
/// 非 ohos 平台全部 no-op（FFI/通道初始化失败静默降级，调用方回落普通
/// 播放）。控制面不感知 Rust 管线状态——管线启停由 frb 的
/// startUsbExclusivePlayback/stopUsbExclusivePlayback 负责。
class UsbExclusiveService {
  UsbExclusiveService._() {
    if (Platform.operatingSystem != 'ohos') return;
    try {
      final lib = ffi.DynamicLibrary.open('libxianyu_core.so');
      _ringRead = lib
          .lookupFunction<ffi.IntPtr Function(ffi.Pointer<ffi.Uint8>, ffi.IntPtr),
              int Function(ffi.Pointer<ffi.Uint8>, int)>(
              'xianyu_ohos_usb_ring_read');
      _ringLevel = lib
          .lookupFunction<ffi.IntPtr Function(), int Function()>(
              'xianyu_ohos_usb_ring_level');
      _formatJson = lib
          .lookupFunction<ffi.IntPtr Function(ffi.Pointer<ffi.Uint8>, ffi.IntPtr),
              int Function(ffi.Pointer<ffi.Uint8>, int)>(
              'xianyu_ohos_usb_format_json');
      _pullBuf = malloc<ffi.Uint8>(_pullBufSize);
      _ffiReady = true;
    } catch (e) {
      _ffiReady = false;
      assert(() {
        debugPrint('[usb-exclusive] FFI 初始化失败: $e');
        return true;
      }());
    }
    _channel.setMethodCallHandler(_onNativeCall);
  }

  static final UsbExclusiveService instance = UsbExclusiveService._();

  static const MethodChannel _channel = MethodChannel('xianyu/usb_exclusive');

  /// 单次推送上限（≈8ms @ 192kHz/2ch/S16；一整块推，等时循环按 1ms 包切）。
  static const int _pullBufSize = 16 * 1024;
  static const Duration _pushInterval = Duration(milliseconds: 8);

  late final int Function(ffi.Pointer<ffi.Uint8>, int) _ringRead;
  late final int Function() _ringLevel;
  late final int Function(ffi.Pointer<ffi.Uint8>, int) _formatJson;
  late final ffi.Pointer<ffi.Uint8> _pullBuf;
  bool _ffiReady = false;

  Timer? _pushTimer;
  bool _pushing = false;

  /// 设备热拔出回调（ArkTS 等时回调报 NO_DEVICE / 提交异常时触发），
  /// [reason] 为 ArkTS 侧给出的原因描述。由 PlayerNotifier 注入，
  /// 转 `_onExclusiveDisconnect` 走回退链。
  void Function(String reason)? onDeviceLost;

  bool get _ohos => Platform.operatingSystem == 'ohos' && _ffiReady;

  /// 环形缓冲当前字节数（诊断用）。
  int ringLevel() => _ohos ? _ringLevel() : 0;

  /// 轮询等待管线输出格式就绪（最多 [timeout]），超时返回 null。
  Future<UsbExclusiveFormat?> waitFormat(Duration timeout) async {
    if (!_ohos) return null;
    final deadline = DateTime.now().add(timeout);
    final buf = malloc<ffi.Uint8>(256);
    try {
      while (DateTime.now().isBefore(deadline)) {
        final n = _formatJson(buf, 256);
        if (n > 0) {
          final map = jsonDecode(
                  utf8.decode(buf.asTypedList(n))) as Map<String, dynamic>;
          final rate = (map['sampleRate'] as num?)?.toInt() ?? 0;
          final ch = (map['channels'] as num?)?.toInt() ?? 0;
          final bps = (map['bytesPerSample'] as num?)?.toInt() ?? 0;
          if (rate > 0 && ch > 0 && bps > 0) {
            return UsbExclusiveFormat(
              sampleRate: rate,
              channels: ch,
              bytesPerSample: bps,
            );
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      return null;
    } finally {
      malloc.free(buf);
    }
  }

  /// 触发 ArkTS 侧设备枚举 → 系统授权弹窗 → UAC 解析 → claim → 等时循环，
  /// 成功后启动 push 定时器。返回设备名；任何失败抛 PlatformException
  /// （调用方停管线并回落）。
  Future<String> startDevice({
    required int sampleRate,
    required int channels,
    required int bytesPerSample,
  }) async {
    if (!_ohos) {
      throw PlatformException(
          code: 'unavailable', message: 'USB 独占仅在鸿蒙可用');
    }
    final r = await _channel.invokeMethod<Object>('start', <String, Object?>{
      'sampleRate': sampleRate,
      'channels': channels,
      'bytesPerSample': bytesPerSample,
    });
    final map = r as Map<Object?, Object?>?;
    _startPushLoop();
    return (map?['deviceName'] as String?) ?? 'USB DAC';
  }

  /// 停 push 定时器并释放 ArkTS 侧等时循环与接口占用（幂等）。
  Future<void> stopDevice() async {
    _stopPushLoop();
    if (!_ohos) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } on MissingPluginException {
      // 通道未注册（冷启动竞态等）：无设备可释放
    }
  }

  // =========================================================================
  // 数据面：ring → ArkTS 推送循环
  // =========================================================================

  void _startPushLoop() {
    _stopPushLoop();
    _pushTimer = Timer.periodic(_pushInterval, (_) => _pushOnce());
  }

  void _stopPushLoop() {
    _pushTimer?.cancel();
    _pushTimer = null;
    _pushing = false;
  }

  Future<void> _pushOnce() async {
    if (_pushing || !_ohos) return;
    _pushing = true;
    try {
      final level = _ringLevel();
      if (level <= 0) return; // 暂停/欠载：ArkTS 侧补零，位置不虚走
      final want = level < _pullBufSize ? level : _pullBufSize;
      final got = _ringRead(_pullBuf, want);
      if (got <= 0) return;
      final bytes = Uint8List.sublistView(
          _pullBuf.asTypedList(_pullBufSize), 0, got);
      await _channel.invokeMethod<void>(
          'push', <String, Object?>{'pcm': bytes});
    } catch (e) {
      // ArkTS 未就绪/设备丢失等：静默，等 deviceLost 或 stopDevice 收尾
      assert(() {
        debugPrint('[usb-exclusive] push 失败: $e');
        return true;
      }());
    } finally {
      _pushing = false;
    }
  }

  // =========================================================================
  // ArkTS → Dart 单向通知
  // =========================================================================

  Future<dynamic> _onNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'deviceLost':
        final cb = onDeviceLost;
        if (cb != null) {
          cb(call.arguments is String
              ? call.arguments as String
              : 'unknown');
        }
        return null;
      case 'log':
        // ArkTS 关键事件双写：hilog（开发态）+ AppLog（随用户反馈上传）
        final args = call.arguments as Map<Object?, Object?>?;
        final level = (args?['level'] as String?) ?? 'info';
        final msg = (args?['msg'] as String?) ?? '';
        switch (level) {
          case 'error':
            AppLog.error('usb-dac', msg);
            break;
          case 'warn':
            AppLog.warn('usb-dac', msg);
            break;
          case 'debug':
            AppLog.debug('usb-dac', msg);
            break;
          default:
            AppLog.info('usb-dac', msg);
        }
        return null;
      default:
        throw MissingPluginException('usb_exclusive: ${call.method}');
    }
  }
}
