import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xianyu_music_mobile/src/core/app_colors.dart';
import 'package:xianyu_music_mobile/src/core/settings.dart';
import 'package:xianyu_music_mobile/src/widgets/modern_dialog.dart';
import 'package:xianyu_music_mobile/src/widgets/sheet_dialog.dart';

void main() {
  testWidgets('亮字覆盖下弹窗标题仍为基础前景（现代确认弹窗 + sheet 弹窗）',
      (tester) async {
    final baseScheme =
        ColorScheme.fromSeed(seedColor: const Color(0xFFEC4141));
    final baseTheme = ThemeData(colorScheme: baseScheme, useMaterial3: true);
    lightBaseScheme = baseScheme;
    lightBaseTextTheme = baseTheme.textTheme;

    final pageTheme = baseTheme.copyWith(
      colorScheme:
          baseScheme.copyWith(onSurface: Colors.white, onSurfaceVariant: Colors.white.withValues(alpha: 0.72)),
      textTheme: baseTheme.textTheme.apply(
        bodyColor: Colors.white,
        displayColor: Colors.white,
        decorationColor: Colors.white,
      ),
      iconTheme: baseTheme.iconTheme.copyWith(color: Colors.white),
    );

    await tester.pumpWidget(MaterialApp(
      theme: pageTheme,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  onPressed: () => showModernConfirmDialog(
                    context: context,
                    title: '确认标题',
                    message: '消息',
                  ),
                  child: const Text('open-confirm'),
                ),
                TextButton(
                  onPressed: () => showSheetDialog<void>(
                    context,
                    (_) => const SizedBox(
                        width: 200, height: 100, child: Text('sheet标题')),
                  ),
                  child: const Text('open-sheet'),
                ),
              ],
            ),
          ),
        ),
      ),
    ));

    Color resolvedColor(String text) {
      final rp = tester.renderObject<RenderParagraph>(
        find.text(text).last,
      );
      return rp.text.style?.color ?? Colors.transparent;
    }

    await tester.tap(find.text('open-confirm'));
    await tester.pumpAndSettle();
    expect(resolvedColor('确认标题'), isNot(Colors.white),
        reason: '确认弹窗标题不应继承页面的亮字覆盖（白底白字）');
    expect(resolvedColor('消息'), isNot(Colors.white),
        reason: '确认弹窗正文显式取 scheme.onSurfaceVariant，须恢复基础前景');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('open-sheet'));
    await tester.pumpAndSettle();
    expect(resolvedColor('sheet标题'), isNot(Colors.white),
        reason: 'sheet 弹窗内文字不应继承页面的亮字覆盖');
  });

  testWidgets('appCardColor 随亮字/暗字档位翻转极性', (tester) async {
    addTearDown(() => wallpaperTextMode = WallpaperTextColor.follow);
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    final context = tester.element(find.byType(Scaffold));
    wallpaperTextMode = WallpaperTextColor.light;
    expect(appCardColor(context), const Color(0xFF303030),
        reason: '亮字模式卡片应为暗底（白字可读）');
    wallpaperTextMode = WallpaperTextColor.dark;
    expect(appCardColor(context), const Color(0xFFFFFFFF),
        reason: '暗字模式卡片应为亮底（黑字可读）');
    wallpaperTextMode = WallpaperTextColor.follow;
    expect(appCardColor(context), const Color(0xFFFFFFFF),
        reason: '跟随主题时亮色主题卡片默认白底');
  });
}
