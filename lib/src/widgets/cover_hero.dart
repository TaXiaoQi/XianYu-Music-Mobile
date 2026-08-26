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

/// 播放页 Hero 飞行中的封面：在 [CoverHeroShuttle] 基础上叠加目标大封面的
/// 描边与投影，且描边/投影透明度随飞行进度从 0 渐变到 1。
///
/// 播放页大封面（_BigCover/_TraditionalCover）自带 1px 描边 + 投影，而普通
/// [CoverHeroShuttle] 只渲染纯封面，飞行结束瞬间会被「带描边+阴影」的目标
/// 封面替换，产生「形变嵌入」的跳变。本组件让飞行中的封面始终与目标封面
/// 同构（描边/阴影淡入），结束时像素级无缝衔接，参考桌面端 CSS transition。
class PlayerCoverShuttle extends StatelessWidget {
  const PlayerCoverShuttle({
    super.key,
    required this.animation,
    required this.songPath,
    this.networkUrl,
    this.fromRadius = 23,
    this.toRadius = 31,
    this.borderColor = const Color(0x2EFFFFFF),
    this.shadow,
    this.gradient,
  });

  final Animation<double> animation;
  final String songPath;
  final String? networkUrl;
  final double fromRadius;
  final double toRadius;

  /// 目标封面描边颜色（含透明度，如 white 0.18）。
  final Color borderColor;

  /// 目标封面投影；null 时不渲染投影。
  final BoxShadow? shadow;

  /// 占位渐变（无封面图时的回退），与目标封面一致。
  final List<Color>? gradient;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final t = animation.value;
        final radius =
            lerpDouble(fromRadius, toRadius, t) ?? toRadius;
        final sh = shadow;
        return Container(
          decoration: BoxDecoration(
            // 描边在封面外缘 1px：目标封面外层圆角 = 内层 + 1。
            borderRadius: BorderRadius.circular(radius + 1),
            border: Border.all(
              color: borderColor.withValues(alpha: borderColor.a * t),
              width: 1.0,
            ),
            boxShadow: sh == null
                ? null
                : [
                    BoxShadow(
                      color: sh.color.withValues(alpha: sh.color.a * t),
                      blurRadius: sh.blurRadius,
                      spreadRadius: sh.spreadRadius,
                      offset: sh.offset,
                    ),
                  ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(radius),
            clipBehavior: Clip.antiAlias,
            child: CoverImage(
              songPath: songPath,
              networkUrl: networkUrl,
              width: double.infinity,
              height: double.infinity,
              radius: radius,
              gradient: gradient,
            ),
          ),
        );
      },
    );
  }
}
