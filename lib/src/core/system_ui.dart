import 'package:flutter/services.dart';

/// 旧安卓（API ≤ S）三键区底色通道。
///
/// 三键区恒定涂底栏色块的等效不透明色（null=透明，横屏沉浸用），与
/// 底栏连成一体；原生收到即重申 edge-to-edge 布局 flag——引擎迁移会在
/// 首帧/聚焦改写系统栏，纯 Dart 重建无法自愈。玻璃磨砂由 Flutter 侧
/// 底栏玻璃/三键区磨砂垫呈现，原生无需复刻。
class SystemUiChannel {
  static const MethodChannel _channel = MethodChannel('xianyu/system_ui');

  static Future<void> setNavigationBarColor(Color? color) async {
    try {
      await _channel.invokeMethod<void>('setNavigationBarColor', {
        'color': color?.toARGB32(),
      });
    } on PlatformException {
      // 涂色失败仅影响三键区观感
    } on MissingPluginException {
      // 无对应原生实现的平台（鸿蒙等）
    }
  }
}
