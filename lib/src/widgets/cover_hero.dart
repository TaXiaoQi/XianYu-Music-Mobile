import 'dart:ui';

import 'package:flutter/material.dart';

import 'cover_image.dart';

/// Hero 飞行中的封面：从迷你播放栏封面过渡到播放页大封面。
///
/// 飞行期间封面保持静态（不随底栏旋转），圆角从 [fromRadius] 插值到
/// [toRadius]——参考桌面端 CSS transition 与 RwaS 的 Overlay 圆角插值。
class CoverHeroShuttle extends StatelessWidget {
  const CoverHeroShuttle({
    super.key,
    required this.animation,
    required this.songPath,
    this.networkUrl,
    this.fromRadius = 23,
    this.toRadius = 28,
  });

  final Animation<double> animation;
  final String songPath;
  final String? networkUrl;
  final double fromRadius;
  final double toRadius;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final radius =
            lerpDouble(fromRadius, toRadius, animation.value) ?? toRadius;
        return CoverImage(
          songPath: songPath,
          networkUrl: networkUrl,
          width: double.infinity,
          height: double.infinity,
          radius: radius,
        );
      },
    );
  }
}
