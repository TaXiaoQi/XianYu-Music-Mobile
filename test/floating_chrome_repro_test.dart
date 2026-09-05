// 复现「二级页共用悬浮顶栏 → 无播放条时页面不渲染」。
// 共用路径：GlassTopBar 悬浮态 → floatingChromeBar。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xianyu_music_mobile/src/core/settings.dart';
import 'package:xianyu_music_mobile/src/widgets/glass_appbar.dart';

Future<Widget> _host() async {
  SharedPreferences.setMockInitialValues({
    'floatingSearchBar': true,
    'liquidGlass': false,
    'frostedGlass': true,
  });
  return ProviderScope(
    child: MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            // 共用页：悬浮模式下内容 Positioned.fill 铺满全屏（模拟 _floatHost）。
            const Positioned.fill(
              child: ColoredBox(
                color: Colors.white,
                child: Text('CONTENT'),
              ),
            ),
            // 共用悬浮顶栏：GlassTopBar 悬浮态（返回钮 + 标题胶囊）。
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: GlassTopBar(
                leading: const BackButton(),
                title: const Text('标题'),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('共用悬浮顶栏（无播放条）应能渲染内容', (tester) async {
    await tester.pumpWidget(await _host());
    await tester.pump();
    // 不应抛出布局/构建异常
    final err = tester.takeException();
    if (err != null) {
      fail('共月悬浮顶栏构建抛出异常: $err');
    }
    expect(find.text('CONTENT'), findsOneWidget);
    expect(find.text('标题'), findsOneWidget);
  });
}