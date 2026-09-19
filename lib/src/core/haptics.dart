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

void triggerSelectionHaptic() => HapticFeedback.selectionClick();