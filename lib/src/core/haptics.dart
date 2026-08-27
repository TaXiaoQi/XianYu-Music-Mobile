import 'package:flutter/services.dart';
import '../i18n/i18n.dart';

/// 触觉反馈强度档位（与设置里的「触觉反馈力度」对应）。
enum HapticStrength {
  light('轻'),
  normal('正常'),
  heavy('重');

  const HapticStrength(this._label);
  final String _label;
  String get label => tr(_label);
}

/// 由设置存储的整数值解析强度档：0=轻，1=正常，2=重，越界兜底正常。
HapticStrength hapticStrengthFromInt(int? v) => switch (v) {
      0 => HapticStrength.light,
      2 => HapticStrength.heavy,
      _ => HapticStrength.normal,
    };

/// 触发一次与档位对应的触觉反馈（点击底栏 tab 时调用）。
void triggerHaptic(HapticStrength strength) {
  switch (strength) {
    case HapticStrength.light:
      HapticFeedback.lightImpact();
    case HapticStrength.normal:
      HapticFeedback.mediumImpact();
    case HapticStrength.heavy:
      HapticFeedback.heavyImpact();
  }
}

/// 触发一次选中确认反馈（轻档），用于侧栏展开切换等轻量交互。
void triggerSelectionHaptic() => HapticFeedback.selectionClick();