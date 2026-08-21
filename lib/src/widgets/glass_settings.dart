import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

/// 液态玻璃参数：与底栏同一套观感（厚度/折射/色散），暗色与亮色微调玻璃色。
LiquidGlassSettings liquidGlassSettings(bool isDark) {
  return LiquidGlassSettings(
    thickness: 30,
    blur: 3,
    chromaticAberration: 0.3,
    lightIntensity: 0.6,
    refractiveIndex: 1.59,
    saturation: 0.7,
    ambientStrength: 1,
    lightAngle: 0.75 * math.pi,
    glassColor: isDark
        ? const Color(0x3DFFFFFF)
        : const Color(0x66FFFFFF),
  );
}
