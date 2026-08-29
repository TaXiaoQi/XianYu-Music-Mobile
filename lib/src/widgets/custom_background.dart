import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';

/// 自定义壁纸背景渲染层（对齐桌面端 GlobalBackground 的自定义分支）。
///
/// 启用时绘制「模糊 + 缩放/平移 + 半透明遮罩」的本地图片；未启用或图片缺失时
/// 返回空。可传入 [background] 覆盖已保存设置（用于编辑器实时预览草稿），
/// 否则从 settingsProvider 读取当前生效的背景。
///
/// 用 [RepaintBoundary] 隔离合成层：上层内容滚动时背景不需要逐帧重栅格化，
/// 避免掉帧（见「移动端渲染分级架构」约定）。
class CustomBackgroundLayer extends StatelessWidget {
  const CustomBackgroundLayer({super.key, this.background});

  /// 覆盖草稿；为 null 时读取已保存的自定义背景。
  final CustomBackground? background;

  @override
  Widget build(BuildContext context) {
    final cb = background;
    if (cb == null) {
      return _SettingsBound();
    }
    return _render(cb);
  }

  Widget _render(CustomBackground cb) {
    // 显式传入 background（编辑器草稿预览）时不校验 active：
    // 未保存的草稿 enabled 仍为 false，但预览需透出图片。
    // 全局背景层走 _SettingsBound，已在其内部完成 active 校验。
    final file = File(cb.imagePath);
    final hasImage = file.path.isNotEmpty;
    final blurSig = cb.blur * 0.6; // 0~40 → 0~24 sigma
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        final dx = cb.translateX / 100 * w;
        final dy = cb.translateY / 100 * h;
        return RepaintBoundary(
          child: SizedBox.expand(
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 用 ValueKey(路径) 强制「路径变化时重建全新图片流」：否则从空路径
                // 草稿切到真实路径时，Image 会复用旧的空路径 FileImage 错误流，
                // errorBuilder 触发后壁纸不渲染（仅默认底色）。
                if (hasImage)
                  ClipRect(
                    child: Transform.translate(
                      offset: Offset(dx, dy),
                      child: Transform.scale(
                        scale: cb.scale / 100,
                        alignment: Alignment.center,
                        child: ImageFiltered(
                          imageFilter: ImageFilter.blur(
                              sigmaX: blurSig, sigmaY: blurSig),
                          child: Opacity(
                            opacity: cb.opacity / 100,
                            child: Image.file(
                              key: ValueKey('wallpaper-${file.path}'),
                              file,
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) => const SizedBox.shrink(),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                if (cb.maskAlpha > 0)
                  Container(
                    color: Colors.black
                        .withValues(alpha: (cb.maskAlpha / 100).clamp(0.0, 1.0)),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 从设置读取背景并渲染（供主页等消费方直接使用）。
class _SettingsBound extends ConsumerWidget {
  const _SettingsBound();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cb = ref.watch(
      settingsProvider.select((s) => s.valueOrNull?.customBackground),
    );
    if (cb?.active != true) return const SizedBox.shrink();
    return CustomBackgroundLayer(background: cb);
  }
}

/// 页面底色层：回退为透明，页面透出根层壁纸/底色。
///
/// 纯平移转场（FadeForwards）下不在此烘焙壁纸，壁纸由根层
/// [CustomBackgroundLayer] 统一渲染；转场期间则由 [TransitionBackdrop] 铺壁纸
/// 垫底，避免透见下层造成「穿模」。
class AppPageBackground extends ConsumerWidget {
  const AppPageBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return child;
  }
}