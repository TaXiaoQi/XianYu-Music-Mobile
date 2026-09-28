import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xianyu_music_mobile/src/widgets/custom_background.dart';

// 验证 ImageFiltered + blur 的边界渐隐，以及 WallpaperMediaLayer 的垫底副本补救效果。
// 直接采样渲染像素，不依赖人眼看图。
void main() {
  Future<List<int>> sampleAt(RenderRepaintBoundary rb, double fx, double fy) async {
    final img = await rb.toImage();
    final data = await img.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    );
    final x = (img.width * fx).clamp(0, img.width - 1).toInt();
    final y = (img.height * fy).clamp(0, img.height - 1).toInt();
    final i = (y * img.width + x) * 4;
    return <int>[
      data!.getUint8(i),
      data.getUint8(i + 1),
      data.getUint8(i + 2),
      data.getUint8(i + 3),
    ];
  }

  testWidgets('裸 ImageFiltered+blur：边缘渐隐发暗（框架行为）',
      (WidgetTester tester) async {
    final key = GlobalKey();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ColoredBox(
          color: Colors.black,
          child: Center(
            child: RepaintBoundary(
              key: key,
              child: SizedBox(
                width: 200,
                height: 200,
                child: ImageFiltered(
                  imageFilter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                  child: const ColoredBox(color: Color(0xFFFF0000)),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final rb = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final corner = await sampleAt(rb, 0.02, 0.02);
    final center = await sampleAt(rb, 0.5, 0.5);
    debugPrint('裸模糊 corner=$corner center=$center');
    expect(center[0], greaterThan(200)); // 中心仍是纯红
    expect(corner[0], lessThan(120)); // 角落被渐隐吃掉了大部分
  });

  testWidgets('WallpaperMediaLayer：模糊时边缘不露黑底', (WidgetTester tester) async {
    final key = GlobalKey();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ColoredBox(
          color: Colors.black,
          child: Center(
            child: RepaintBoundary(
              key: key,
              child: SizedBox(
                width: 200,
                height: 200,
                child: WallpaperMediaLayer(
                  box: const Size(200, 200),
                  scale: 1.0,
                  offset: Offset.zero,
                  blurSigma: 12,
                  opacity: 1.0,
                  child: const ColoredBox(color: Color(0xFFFF0000)),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final rb = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final corner = await sampleAt(rb, 0.02, 0.02);
    final edge = await sampleAt(rb, 0.5, 0.02);
    final center = await sampleAt(rb, 0.5, 0.5);
    debugPrint('垫底层 corner=$corner edge=$edge center=$center');
    expect(center[0], greaterThan(200));
    expect(edge[0], greaterThan(180));
    expect(corner[0], greaterThan(120)); // 角落仍是图，不是黑底
  });

  testWidgets('WallpaperMediaLayer：无模糊时不产生额外层', (WidgetTester tester) async {
    final key = GlobalKey();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ColoredBox(
          color: Colors.black,
          child: Center(
            child: RepaintBoundary(
              key: key,
              child: SizedBox(
                width: 200,
                height: 200,
                child: WallpaperMediaLayer(
                  box: const Size(200, 200),
                  scale: 1.0,
                  offset: Offset.zero,
                  blurSigma: 0,
                  opacity: 0.6,
                  child: const ColoredBox(color: Color(0xFFFF0000)),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final rb = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final center = await sampleAt(rb, 0.5, 0.5);
    debugPrint('无模糊 center=$center');
    // 0.6 不透明度叠在黑底上 → 约 153，不能因为垫底叠乘变亮
    expect(center[0], inInclusiveRange(140, 175));
  });
}
