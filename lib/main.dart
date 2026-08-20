import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 预热液态玻璃 shader，避免首次显示时卡顿。
  // 失败不应阻断启动：设备不支持时组件会自行回退到普通渲染。
  try {
    await LiquidGlassWidgets.initialize();
  } catch (_) {
    // 忽略：液态玻璃为可选视觉增强，不可用时降级即可。
  }

  runApp(
    LiquidGlassWidgets.wrap(
      // 按设备性能自动调整渲染质量。
      adaptiveQuality: true,
      child: const ProviderScope(child: XianYuApp()),
    ),
  );
}
