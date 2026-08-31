import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xianyu_music_mobile/src/core/app_colors.dart';
import 'package:xianyu_music_mobile/src/core/settings.dart';
import 'package:xianyu_music_mobile/src/widgets/modern_dialog.dart';
import 'package:xianyu_music_mobile/src/widgets/sheet_dialog.dart';

/// 壁纸「亮色字体」覆盖下，弹窗标题必须保持基础明暗前景（不被污染成白字）。
void main() {
  testWidgets('亮字覆盖下弹窗标题仍为基础前景（现代确认弹窗 + sheet 弹窗）',
      (tester) async {
    // 1. 基础（未覆盖）主题：模拟 _ensureThemes 的 baseScheme/baseTextTheme 记录。
    final baseScheme =
        ColorScheme.fromSeed(seedColor: const Color(0xFFEC4141));
    final baseTheme = ThemeData(colorScheme: baseScheme, useMaterial3: true);
    lightBaseScheme = baseScheme;
    lightBaseTextTheme = baseTheme.textTheme;

    // 2. 页面主题 = 亮字覆盖（模拟 app.dart 的全局覆盖 copyWith）。
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

    // 现代确认弹窗：标题无显式颜色（靠 DefaultTextStyle 继承），正文显式取
    // scheme.onSurfaceVariant（Builder 在恢复 Theme 内执行后才不被污染）。
    await tester.tap(find.text('open-confirm'));
    await tester.pumpAndSettle();
    expect(resolvedColor('确认标题'), isNot(Colors.white),
        reason: '确认弹窗标题不应继承页面的亮字覆盖（白底白字）');
    expect(resolvedColor('消息'), isNot(Colors.white),
        reason: '确认弹窗正文显式取 scheme.onSurfaceVariant，须恢复基础前景');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    // sheet 弹窗（showSheetDialog → showPredictiveDialog）。
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
