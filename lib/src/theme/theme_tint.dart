import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'theme_store.dart';

/// 该槽的主题叠色；未激活主题或该槽未设置时返回 null。
///
/// 供"本身没有底色容器"的组件（`search.item` / `ls-settings.nav`）判断是否
/// 需要新增一层容器——没有主题时不新增，保持原有结构。
Color? themeTintOrNull(WidgetRef ref, String slotId) {
  final surface = ref.watch(themeLibraryProvider).themeSurface(slotId);
  if (surface == null) return null;
  return Color(surface.color).withValues(alpha: surface.opacity);
}

/// 把当前主题的组件色块叠到组件现有材质上。
///
/// 与《主题中心-移动端客户端对接说明》§4.2 一致：`c` 按 `o` 叠在默认材质之上，
/// 未激活主题或该槽未设置时**原样返回 [base]**（`o=0` 已在解析阶段剔除）。
/// 因此未激活主题时渲染结果与接线前完全一致。
Color themeTint(WidgetRef ref, String slotId, Color base) {
  final tint = themeTintOrNull(ref, slotId);
  return tint == null ? base : Color.alphaBlend(tint, base);
}
