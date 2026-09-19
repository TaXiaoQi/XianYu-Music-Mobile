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
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 300));
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
    await _switch(tester, 1, suppress: true);
    expect(find.text('PROFILE'), findsOneWidget);
    expect(_opacityOf(tester, 'PROFILE'), 1.0);
  });
}
