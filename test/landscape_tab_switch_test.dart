// 横屏主 tab 切换回归测试（独立切换器 LandscapeTabSwitcher）。
//
// 历史 bug：横屏 out-in 曾与竖屏 PageView 容器共用一个组件（build 在
// AnimatedBuilder ↔ PageView 间切换根槽位 widget 类型导致重挂载、跳页丢失）。
// 现横屏为独立模式：独立的 LandscapeTabSwitcher（out-in + Offstage 保活），
// 与竖屏 PageSwitchTabView 完全分开。本组测试锁定：
// - out-in 切换落在目标页且结束后不透明度归位；
// - 首页→我的→首页→我的 连续切换不卡死；
// - enabled=false 硬切与面板 suppress 硬切（取 old 值）均正常换页。
//
// 运行：flutter test test/landscape_tab_switch_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:xianyu_music_mobile/src/navigation/landscape_tab_switcher.dart';

Widget _host(int index, {bool enabled = true, bool suppress = false}) =>
    MaterialApp(
      home: Scaffold(
        body: LandscapeTabSwitcher(
          currentIndex: index,
          enabled: enabled,
          suppress: suppress,
          children: const [
            Center(child: Text('HOME')),
            Center(child: Text('PROFILE')),
          ],
        ),
      ),
    );

Future<void> _switch(WidgetTester tester, int target,
    {bool suppress = false}) async {
  await tester.pumpWidget(_host(target, suppress: suppress));
  await tester.pump(); // didUpdateWidget → out 阶段开始（硬切则立即换页）
  await tester.pump(const Duration(milliseconds: 300)); // out 完成 + 换页
  await tester.pump(const Duration(milliseconds: 300)); // in 完成
}

double _opacityOf(WidgetTester tester, String text) {
  final opacity = tester
      .widget<Opacity>(find
          .ancestor(of: find.text(text), matching: find.byType(Opacity))
          .first);
  return opacity.opacity;
}

void main() {
  testWidgets('横屏 out-in：首页→我的 落在目标页且不透明', (tester) async {
    await tester.pumpWidget(_host(0));
    await tester.pump();

    await _switch(tester, 1);

    // 动画结束：静止态 Opacity 包装应回到恒等（opacity 1.0）
    expect(find.text('PROFILE'), findsOneWidget);
    expect(_opacityOf(tester, 'PROFILE'), 1.0,
        reason: 'out-in 结束后透明度应归位 1.0，否则页面停留在半透明');
  });

  testWidgets('横屏 out-in：连续 首页→我的→首页→我的 不卡死', (tester) async {
    await tester.pumpWidget(_host(0));
    await tester.pump();

    await _switch(tester, 1);
    expect(find.text('PROFILE'), findsOneWidget);

    await _switch(tester, 0);
    expect(find.text('HOME'), findsOneWidget);

    await _switch(tester, 1);
    expect(find.text('PROFILE'), findsOneWidget);
    expect(_opacityOf(tester, 'PROFILE'), 1.0,
        reason: '第三次切到我的页应正常且透明度归位');
  });

  testWidgets('硬切（enabled=false）：跳页正常且无残留透明度', (tester) async {
    await tester.pumpWidget(_host(0, enabled: false));
    await tester.pump();
    await _switch(tester, 1);
    expect(find.text('PROFILE'), findsOneWidget);
    expect(_opacityOf(tester, 'PROFILE'), 1.0);
  });

  testWidgets('面板打开时切 tab（suppress，取 old 值）：硬切换页', (tester) async {
    await tester.pumpWidget(_host(0));
    await tester.pump();
    // 切换前 suppress=true（面板开着）→ 硬切，换页被面板淡出盖住。
    await _switch(tester, 1, suppress: true);
    expect(find.text('PROFILE'), findsOneWidget);
    expect(_opacityOf(tester, 'PROFILE'), 1.0);
  });
}
