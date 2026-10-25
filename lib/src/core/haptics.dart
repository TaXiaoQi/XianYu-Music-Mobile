import 'package:flutter/services.dart';
import '../i18n/i18n.dart';

enum HapticStrength {
  light('轻'),
  normal('正常'),
  heavy('重');

  const HapticStrength(this._label);
  final String _label;
  String get label => tr(_label);
}

HapticStrength hapticStrengthFromInt(int? v) => switch (v) {
      0 => HapticStrength.light,
      2 => HapticStrength.heavy,
      _ => HapticStrength.normal,
    };

/// 三档幅值通道：轻 64 / 正常 160 / 重 255。
/// 原生用 VibrationEffect.createOneShot 按幅值振动（API 26+，Android 12
/// 实测生效），不依赖系统对 HapticFeedbackConstants 的渲染——部分 ROM
/// （Android 12）把引擎三档常量（CONTEXT_CLICK / VIRTUAL_KEY / LONG_PRESS）
/// 全部渲染成最重效果，设置里的轻/正常/重形同虚设；新版安卓该映射正常。
const MethodChannel _hapticsChannel = MethodChannel('xianyu/haptics');

void triggerHaptic(HapticStrength strength) {
  _vibrateWithFallback(strength);
}

Future<void> _vibrateWithFallback(HapticStrength strength) async {
  const amplitudes = {
    HapticStrength.light: 64,
    HapticStrength.normal: 160,
    HapticStrength.heavy: 255,
  };
  try {
    // 原生幅值振动成功（含 hasAmplitudeControl 判定）即结束
    final done = await _hapticsChannel.invokeMethod<bool>('vibrateAmplitude', {
      'amplitude': amplitudes[strength],
      'durationMs': 24,
    });
    if (done == true) return;
  } on MissingPluginException catch (_) {
    // 无该通道的平台（鸿蒙等）直接走引擎回落
  } on PlatformException catch (_) {
    // 通道异常同样回落
  }
  switch (strength) {
    case HapticStrength.light:
      HapticFeedback.lightImpact();
    case HapticStrength.normal:
      HapticFeedback.mediumImpact();
    case HapticStrength.heavy:
      HapticFeedback.heavyImpact();
  }
}
