import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../navigation/shell.dart' show isLandscapeProvider;

/// 统一竖屏 / 横屏两套独立布局的排布组件（横屏适配总收纳第一层）。
///
/// 页面顶层统一这么接：
/// ```dart
/// return LandscapeGate(
///   portrait: _buildPortrait(context),   // 竖屏（默认）布局子树
///   landscape: _buildLandscape(context), // 横屏（独立一套 UI）布局子树
/// );
/// ```
/// - 竖屏树与横屏树在结构上【完全分开】；新增 / 修改横屏只动 [landscape]，
///   竖屏逻辑不受影响，横屏是一套独立 UI。
/// - 是否横屏由统一的 [isLandscapeProvider] 判定（宽 ≥ 1.05 × 高）。
///
/// 横屏适配的“总入口”就是这个：任何页面要接横屏，就在顶层套一层
/// `LandscapeGate`。全部横屏适配点见 `lib/src/responsive/README.md` 索引。
class LandscapeGate extends ConsumerWidget {
  const LandscapeGate({
    super.key,
    required this.portrait,
    required this.landscape,
  });

  /// 竖屏（默认）布局子树。
  final Widget portrait;

  /// 横屏（独立一套 UI）布局子树。
  final Widget landscape;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref.watch(isLandscapeProvider) ? landscape : portrait;
  }
}

/// 便捷读横屏态：`final ls = useLandscape(ref);` 等效 `ref.watch(isLandscapeProvider)`。
///
/// 用于侧栏、`if (ls)` 等不套 `LandscapeGate` 的局部判断，保证断点判断单一来源。
bool useLandscape(WidgetRef ref) => ref.watch(isLandscapeProvider);