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

/// DSP 管线起播前的会话准备：.playback category + 采样率偏好 + 激活
/// （AURemoteIO 输出流要求会话处于激活状态；与 audio_session 的
/// setActive 双保险，重复配置幂等）。
Future<void> prepareIosPipelineAudioSession({int sampleRate = 0}) async {
  if (!PlatformCaps.isIOS) return;
  try {
    final out = await _channel.invokeMethod<int>(
      'configurePipeline',
      {'rate': sampleRate.toDouble()},
    );
    AppLog.info(
      'ios-audio',
      '管线会话已激活（.playback，系统输出 ${out ?? 0} Hz）',
    );
  } catch (e) {
    AppLog.warn('ios-audio', '管线会话激活失败: $e');
  }
}

/// DSP 管线停止后的会话释放（notifyOthersOnDeactivation，
/// 让其他 App 的后台音频恢复）。
Future<void> releaseIosPipelineAudioSession() async {
  if (!PlatformCaps.isIOS) return;
  try {
    await _channel.invokeMethod<void>('releasePipeline');
    AppLog.info('ios-audio', '管线会话已释放');
  } catch (e) {
    AppLog.warn('ios-audio', '管线会话释放失败: $e');
  }
}

/// 订阅管线中断/路由事件（Swift 侧常驻观察 AVAudioSession，转发
/// "onPipelineInterruption" / "onPipelineRouteChanged"；与 audio_session
/// 插件在 iOS 投递的 interruption 流并存，消费方做幂等处理）。
/// 返回取消订阅句柄；非 iOS 返回 null。
VoidCallback? subscribeIosPipelineEvents(
  void Function(String method, Map<Object?, Object?> args) handler,
) {
  if (!PlatformCaps.isIOS) return null;
  _channel.setMethodCallHandler((call) async {
    final args = call.arguments;
    handler(call.method, args is Map<Object?, Object?> ? args : const {});
  });
  return () => _channel.setMethodCallHandler(null);
}
