import 'package:flutter/services.dart';

import 'application_logger.dart';
import 'platform_caps.dart';

/// iOS 音频会话偏好（Apple Music 路线）：输出路由与混音交给系统
/// （AVAudioSession），App 只提交「偏好采样率」提示——外接 DAC 时系统
/// 尽量贴近源规格，内建扬声器按硬件上限执行。偏好≠保证，系统可拒绝；
/// 非 iOS 平台全部空操作。
const MethodChannel _channel = MethodChannel('xianyu/ios_audio');

/// 提交偏好采样率（Hz，<=0 视为未知直接跳过）。返回系统实际输出采样率
/// （0=未知/未生效），仅供日志对照。
Future<int> setIosPreferredSampleRate(int sampleRate) async {
  if (!PlatformCaps.isIOS || sampleRate <= 0) return 0;
  try {
    final out = await _channel.invokeMethod<int>(
      'setPreferredSampleRate',
      {'rate': sampleRate.toDouble()},
    );
    AppLog.info(
      'ios-audio',
      '偏好采样率已提交: $sampleRate Hz（系统实际输出 ${out ?? 0} Hz）',
    );
    return out ?? 0;
  } catch (e) {
    AppLog.warn('ios-audio', '偏好采样率提交失败: $e');
    return 0;
  }
}
