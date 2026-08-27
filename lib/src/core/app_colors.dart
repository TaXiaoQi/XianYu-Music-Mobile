import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'settings.dart';

/// 是否启用自定义壁纸。启用时设置页/我的页等控件切换为玻璃透明样式以透出壁纸。
final wallpaperActiveProvider = Provider<bool>((ref) {
  return ref.watch(
    settingsProvider.select((s) => s.valueOrNull?.customBackground.active ?? false),
  );
});

/// 未受「自定义壁纸前景覆盖」影响的原始 ColorScheme（亮/暗各一，app.dart 构建主题时写入）。
///
/// 壁纸启用时页面前景会按「亮字/暗字」覆盖为固定色；而弹窗面板是不透明的
/// （#FFFFFF / #262626），其文字应保持各自的明暗前景，不能跟着前景覆盖变成
/// 白底白字/黑底黑字。showSheetDialog 等弹窗封装据此恢复基础配色。
ColorScheme? lightBaseScheme;
ColorScheme? darkBaseScheme;

/// 自定义壁纸启用时控件使用的半透明白玻璃填充 / 描边
/// （对齐首页「发现」区卡片 _CardContainer：底 alpha 0.06、描边 alpha 0.08）。
final Color glassControlFill = Colors.white.withValues(alpha: 0.06);
final Color glassControlBorder = Colors.white.withValues(alpha: 0.08);

/// 全局统一页面底色。
///
/// 所有页面的 Scaffold/Container 背景统一使用本函数，保证全 App 明暗一致：
/// 亮色：淡灰白 #F4F4F6，暗色：#222。
Color appSurfaceBg(BuildContext context) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return dark ? const Color(0xFF222222) : const Color(0xFFF4F4F6);
}

/// 全局统一控件/卡片底色。
///
/// 卡片、列表项、输入框等控件的底色统一使用本函数：
/// 亮色：纯白 #FFFFFF，暗色：#303030。
Color appCardColor(BuildContext context) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return dark ? const Color(0xFF303030) : const Color(0xFFFFFFFF);
}