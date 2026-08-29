import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'settings.dart';

/// 是否启用自定义壁纸。启用时仅替换根层底色（app.dart 铺 CustomBackgroundLayer、
/// 页面 Scaffold 底色透明透出壁纸），其余样式与普通模式完全一致。
final wallpaperActiveProvider = Provider<bool>((ref) {
  return ref.watch(
    settingsProvider.select((s) => s.valueOrNull?.customBackground.active ?? false),
  );
});

/// 页面默认底色：未启用自定义壁纸时使用根层真实底色 [appSurfaceBg]（与设置页/
/// 我的页一致，实色不像「没底色」）；启用壁纸时保持透明以透出根层的壁纸。
/// 二者均为「实色底色之上直接覆盖壁纸」的模型，无需额外垫透明层。
Color appScaffoldBackground(BuildContext context, WidgetRef ref) {
  return ref.watch(wallpaperActiveProvider)
      ? Colors.transparent
      : appSurfaceBg(context);
}

/// 未受主题前景覆盖影响的原始 ColorScheme（亮/暗各一，app.dart 构建主题时写入）。
///
/// 当前主题构建不做任何前景覆盖，恢复机制等于原样取回；保留全局指针供
/// showSheetDialog 等弹窗封装在主题变更时回退到基础配色。
ColorScheme? lightBaseScheme;
ColorScheme? darkBaseScheme;

/// 与 [lightBaseScheme]/[darkBaseScheme] 配套的原始 textTheme。
TextTheme? lightBaseTextTheme;
TextTheme? darkBaseTextTheme;

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