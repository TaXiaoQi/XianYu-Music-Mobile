import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_colors.dart';
import '../core/settings.dart';
import 'glass_settings.dart';

class CustomBackgroundLayer extends StatelessWidget {
  const CustomBackgroundLayer({super.key, this.background});

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
    final file = File(cb.imagePath);
    final hasImage = file.path.isNotEmpty;
    final blurSig = cb.blur * 0.6;
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
                if (hasImage)
                  ClipRect(
                    child: Transform.translate(
                      offset: Offset(dx, dy),
                      child: Transform.scale(
                        scale: cb.scale / 100,
                        alignment: Alignment.center,
                        child: ImageFiltered(
                          imageFilter: cheapBackdropBlur(blurSig),
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

class AppPageBackground extends ConsumerWidget {
  const AppPageBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cb = ref.watch(
      settingsProvider.select((s) => s.valueOrNull?.customBackground),
    );
    if (cb?.active != true) return child;
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(
          color: appSurfaceBg(context),
          child: CustomBackgroundLayer(background: cb),
        ),
        child,
      ],
    );
  }
}