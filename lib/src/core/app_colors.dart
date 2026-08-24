import 'package:flutter/material.dart';

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