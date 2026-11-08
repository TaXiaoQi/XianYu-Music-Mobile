import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 三键区底色通道。
///
/// 三键区底色随底栏色块下发等效不透明色（null=透明，横屏沉浸/壁纸模式
/// 用），与底栏连成一体；原生收到即重申系统栏——旧安卓重申 edge-to-edge
/// 布局 flag，新安卓（API ≥ 33）关对比度 scrim 并涂色（35+ 涂色被系统
/// 忽略，底色由 Flutter 侧实色垫呈现，本次调用仅余图标亮度依据）。玻璃
/// 磨砂由 Flutter 侧底栏玻璃/三键区磨砂垫呈现，原生无需复刻。
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

  /// Android API level（非 Android/无原生实现返回 0），进程内缓存。
  /// 新安卓（API 35+）原生涂色被系统忽略，Dart 侧据此启用实色垫。
  static int? _sdkInt;

  static Future<int> androidSdkInt() async {
    final cached = _sdkInt;
    if (cached != null) return cached;
    int value = 0;
    try {
      value = await _channel.invokeMethod<int>('getSdkInt') ?? 0;
    } on PlatformException {
      // 保底 0：实色垫不启用，仅影响三键区观感
    } on MissingPluginException {
      // 无对应原生实现的平台（鸿蒙等）
    }
    return _sdkInt = value;
  }
}

/// Android API level（非 Android 为 0）
final androidSdkIntProvider = FutureProvider<int>(
  (ref) => SystemUiChannel.androidSdkInt(),
);

/// 底部 chrome（悬浮底栏/固定底栏胶囊/mini 条/播放页控制区）相对屏幕底缘
/// 的下沉量。手势条与 iOS Home 横条按惯例对安全区打 30% 折（留出上沿
/// 间隙、两端下沉量一致）；三大键导航条（AOSP 48dp，按键直接绘制在
/// inset 带内，ROM 自定义 navigation_mode 值不可靠）必须整条让出，
/// 否则胶囊叠在三大键上（Android 12 三键实测）。手势条 inset ≤32dp，
/// ≥40dp 即判三键；模式切换时 inset 变化经 MediaQuery 自然驱动重建。
double chromeBottomSink(double safeBottom) =>
    safeBottom >= 40 ? safeBottom : safeBottom * 0.3;

/// 相对 30% 折扣基线的抬升差：页面底部预留（navBarInsetProvider）等
/// 以折扣基线为口径的常量，在三键导航下需补差，避免内容钻进抬升后的
/// chrome 底下。
double chromeBottomSinkExtra(double safeBottom) =>
    chromeBottomSink(safeBottom) - safeBottom * 0.3;
