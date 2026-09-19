import 'dart:ui';

import 'package:flutter/material.dart';

import 'cover_image.dart';

class CoverHeroShuttle extends StatelessWidget {
  const CoverHeroShuttle({
    super.key,
    required this.animation,
    required this.songPath,
    this.networkUrl,
    this.fromRadius = 23,
    this.toRadius = 28,
    this.highQuality = true,
  });

  final Animation<double> animation;
  final String songPath;
  final String? networkUrl;
  final double fromRadius;
  final double toRadius;

  final bool highQuality;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
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
            highQuality: highQuality,
          );
        },
      ),
    );
  }
}

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
    this.highQuality = true,
  });

  final Animation<double> animation;
  final String songPath;
  final String? networkUrl;
  final double fromRadius;
  final double toRadius;

  final Color borderColor;

  final BoxShadow? shadow;

  final List<Color>? gradient;

  final bool highQuality;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: animation,
        builder: (context, _) {
          final t = animation.value;
          final radius =
              lerpDouble(fromRadius, toRadius, t) ?? toRadius;
          final sh = shadow;
          return Container(
          decoration: BoxDecoration(
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
              highQuality: highQuality,
            ),
          ),
          );
        },
      ),
    );
  }
}
