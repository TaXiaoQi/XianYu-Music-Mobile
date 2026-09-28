import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:xianyu_music_mobile/src/widgets/custom_background.dart';

void main() {
  group('wallpaperCoverBox', () {
    test('比例未知时退化为容器本身', () {
      expect(wallpaperCoverBox(100, 200, null), const Size(100, 200));
      expect(
        wallpaperCoverBox(100, 200, const Size(0, 0)),
        const Size(100, 200),
      );
    });

    test('图片比容器更宽时水平方向外扩', () {
      // 容器 9:19.5，图片 9:16（更宽）→ cover 框宽度超出、高度贴合
      final box = wallpaperCoverBox(100, 216.6667, const Size(900, 1600));
      expect(box.height, closeTo(216.6667, 0.01));
      expect(box.width, closeTo(121.875, 0.01));
    });

    test('图片比容器更瘦时垂直方向外扩', () {
      final box = wallpaperCoverBox(100, 200, const Size(900, 2400));
      expect(box.width, closeTo(100, 0.01));
      expect(box.height, closeTo(266.6667, 0.01));
    });
  });

  group('wallpaperMaxTranslate（不露黑底不变量）', () {
    test('缩放 100% 时位移不超过 cover 框的溢出量一半', () {
      final box = wallpaperCoverBox(100, 216.6667, const Size(900, 1600));
      final maxT = wallpaperMaxTranslate(100, 216.6667, box, 1.0);
      // 水平有 (121.875-100)/2 的余量，垂直为 0
      expect(maxT.dx, closeTo(10.9375, 0.01));
      expect(maxT.dy, 0);
    });

    test('任何缩放与极限位移组合下 cover 框都覆盖容器', () {
      const w = 1080.0;
      const h = 2340.0;
      const src = Size(3000, 4000);
      final box = wallpaperCoverBox(w, h, src);
      for (final scale in const [1.0, 1.1, 1.6, 3.0]) {
        final maxT = wallpaperMaxTranslate(w, h, box, scale);
        for (final signX in [1.0, -1.0]) {
          for (final signY in [1.0, -1.0]) {
            final dx = maxT.dx * signX;
            final dy = maxT.dy * signY;
            // 极限位移的绝对值恰为 cover 框溢出量的一半，任何符号组合都不会露底
            expect(
              dx.abs() - (box.width * scale - w) / 2,
              closeTo(0, 0.001),
            );
            expect(
              dy.abs() - (box.height * scale - h) / 2,
              closeTo(0, 0.001),
            );
          }
        }
      }
    });

    test('cover 框本身保证铺满容器（无黑边下界）', () {
      const src = Size(900, 1600);
      final box = wallpaperCoverBox(1080, 2340, src);
      expect(box.width, greaterThanOrEqualTo(1080));
      expect(box.height, greaterThanOrEqualTo(2340));
    });
  });
}
