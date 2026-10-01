import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xianyu_music_mobile/src/core/settings.dart';
import 'package:xianyu_music_mobile/src/theme/theme_icon.dart';
import 'package:xianyu_music_mobile/src/theme/theme_package.dart';
import 'package:xianyu_music_mobile/src/theme/theme_store.dart';
import 'package:xianyu_music_mobile/src/theme/theme_tint.dart';

/// 主题包 v2 的解析与导入/激活。
///
/// 契约见《主题中心-移动端客户端对接说明》§2：`platform` 非 mobile 不收、
/// 三类槽位未知 id 忽略不报错、`surfaces` 的 `o` 缺省 0.5 且 `o=0` 视为关闭。
String pkgJson({
  Object? version = 2,
  Object? platform = 'mobile',
  String name = '晚风',
  String author = 'tester',
  String preview = 'https://example.com/p1.jpg',
  Map<String, Object?> payload = const {
    'accentColor': '#FF5722',
    'themeMode': 'dark',
    'icons': {'nav.home': 'https://example.com/a.png'},
    'stickers': {'recognize.deco': 'https://example.com/b.png'},
    'surfaces': {
      'home.stat': {'c': '#7C4DFF', 'o': 0.35},
    },
  },
}) =>
    jsonEncode({
      'version': version,
      'platform': platform,
      'name': name,
      'author': author,
      'preview': preview,
      'payload': payload,
    });

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('ThemePackage.parse', () {
    test('完整 v2 包解析出全部字段', () {
      final pkg = ThemePackage.parse(pkgJson())!;

      expect(pkg.name, '晚风');
      expect(pkg.author, 'tester');
      expect(pkg.accentColor, 0xFFFF5722);
      expect(pkg.themeMode, 'dark');
      expect(pkg.icons['nav.home'], 'https://example.com/a.png');
      expect(pkg.stickers['recognize.deco'], 'https://example.com/b.png');
      expect(pkg.surfaces['home.stat']!.color, 0xFF7C4DFF);
      expect(pkg.surfaces['home.stat']!.opacity, 0.35);
      expect(pkg.hasSlots, isTrue);
    });

    test('platform 非 mobile / version 非 2 一律不收', () {
      expect(ThemePackage.parse(pkgJson(platform: 'desktop')), isNull);
      expect(ThemePackage.parse(pkgJson(version: 3)), isNull);
      expect(ThemePackage.parse(pkgJson(version: '2')), isNull);
    });

    test('非法 JSON 与缺 payload 返回 null 而非抛异常', () {
      expect(ThemePackage.parse('not json'), isNull);
      expect(ThemePackage.parse('[]'), isNull);
      expect(ThemePackage.parse(jsonEncode({'version': 2, 'platform': 'mobile'})), isNull);
    });

    test('accentColor：6 位补不透明 alpha，8 位原样保留，非法为 null', () {
      expect(ThemePackage.parseHexColor('#FF5722'), 0xFFFF5722);
      expect(ThemePackage.parseHexColor('FF5722'), 0xFFFF5722);
      expect(ThemePackage.parseHexColor('#80FF5722'), 0x80FF5722);
      expect(ThemePackage.parseHexColor('#F52'), isNull);
      expect(ThemePackage.parseHexColor('red'), isNull);
      expect(ThemePackage.parseHexColor(123), isNull);
      expect(ThemePackage.parseHexColor(null), isNull);
    });

    test('surfaces：o 缺省 0.5、o=0 视为关闭、o 超界收敛到 1、c 非法剔除', () {
      final pkg = ThemePackage.parse(pkgJson(payload: const {
        'surfaces': {
          'a': {'c': '#112233'},
          'b': {'c': '#112233', 'o': 0},
          'c': {'c': '#112233', 'o': 1.8},
          'd': {'c': 'oops', 'o': 0.5},
          'e': {'o': 0.5},
        },
      }))!;

      expect(pkg.surfaces['a']!.opacity, 0.5);
      expect(pkg.surfaces.containsKey('b'), isFalse);
      expect(pkg.surfaces['c']!.opacity, 1.0);
      expect(pkg.surfaces.containsKey('d'), isFalse);
      expect(pkg.surfaces.containsKey('e'), isFalse);
    });

    test('三类槽位的非字符串值剔除；未知槽位保留（渲染时才忽略）', () {
      final pkg = ThemePackage.parse(pkgJson(payload: const {
        'icons': {'nav.home': 'https://e/a.png', 'bad': 42, 'empty': '  '},
        'stickers': {'totally.unknown.slot': 'https://e/b.png'},
        'surfaces': {'unknown.slot': {'c': '#010203', 'o': 0.4}},
      }))!;

      expect(pkg.icons.keys, ['nav.home']);
      expect(pkg.stickers['totally.unknown.slot'], 'https://e/b.png');
      expect(pkg.surfaces.containsKey('unknown.slot'), isTrue);
    });

    test('id 稳定：同一包多次解析同 id，改名后不同', () {
      final a = ThemePackage.parse(pkgJson())!;
      final b = ThemePackage.parse(pkgJson())!;
      final c = ThemePackage.parse(pkgJson(name: '另一个'))!;

      expect(a.id, b.id);
      expect(a.id, isNot(c.id));
    });
  });

  group('ThemeLibraryNotifier', () {
    Future<ProviderContainer> boot() async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(themeLibraryProvider.notifier).ready;
      await container.read(settingsProvider.future);
      return container;
    }

    test('导入有效包入列，重复导入同包只保留一条', () async {
      final c = await boot();
      final n = c.read(themeLibraryProvider.notifier);

      expect(await n.importJson(pkgJson()), isNotNull);
      expect(c.read(themeLibraryProvider).packages, hasLength(1));

      expect(await n.importJson(pkgJson()), isNotNull);
      expect(c.read(themeLibraryProvider).packages, hasLength(1),
          reason: '同 id 覆盖而非堆副本');

      final other = await n.importJson(pkgJson(name: '另一包'));
      expect(other, isNotNull);
      expect(c.read(themeLibraryProvider).packages, hasLength(2));
    });

    test('导入非法包返回 null 且不入列', () async {
      final c = await boot();
      final n = c.read(themeLibraryProvider.notifier);

      expect(await n.importJson('{{{'), isNull);
      expect(await n.importJson(pkgJson(platform: 'desktop')), isNull);
      expect(c.read(themeLibraryProvider).packages, isEmpty);
    });

    test('激活：强调色与深浅模式写回既有设置，槽位查询入口生效', () async {
      final c = await boot();
      final n = c.read(themeLibraryProvider.notifier);
      final pkg = (await n.importJson(pkgJson()))!;

      await n.activate(pkg.id);

      final settings = c.read(settingsProvider).valueOrNull!;
      expect(settings.accentColor, 0xFFFF5722);
      expect(settings.themeMode, ThemeModePreference.dark);

      final lib = c.read(themeLibraryProvider);
      expect(lib.themeIcon('nav.home'), 'https://example.com/a.png');
      expect(lib.themeSticker('recognize.deco'), 'https://example.com/b.png');
      expect(lib.themeSurface('home.stat')!.color, 0xFF7C4DFF);
      expect(lib.themeIcon('未设置的槽'), isNull);
    });

    test('取消激活：槽位查询回落 null，但已写入的强调色保持不动', () async {
      final c = await boot();
      final n = c.read(themeLibraryProvider.notifier);
      final pkg = (await n.importJson(pkgJson()))!;
      await n.activate(pkg.id);

      await n.deactivate();

      expect(c.read(themeLibraryProvider).themeIcon('nav.home'), isNull);
      expect(c.read(settingsProvider).valueOrNull!.accentColor, 0xFFFF5722,
          reason: '取消主题只解除槽位映射，不该回滚用户设置');
    });

    test('重启后从 prefs 恢复导入列表与激活状态', () async {
      final first = await boot();
      final n = first.read(themeLibraryProvider.notifier);
      final pkg = (await n.importJson(pkgJson()))!;
      await n.activate(pkg.id);
      first.dispose();

      final second = ProviderContainer();
      addTearDown(second.dispose);
      await second.read(themeLibraryProvider.notifier).ready;

      final lib = second.read(themeLibraryProvider);
      expect(lib.packages, hasLength(1));
      expect(lib.activeId, pkg.id);
      expect(lib.themeIcon('nav.home'), 'https://example.com/a.png');
    });

    test('删除已激活的包：列表移除且激活状态回落为空', () async {
      final c = await boot();
      final n = c.read(themeLibraryProvider.notifier);
      final pkg = (await n.importJson(pkgJson()))!;
      await n.activate(pkg.id);

      await n.remove(pkg.id);

      final lib = c.read(themeLibraryProvider);
      expect(lib.packages, isEmpty);
      expect(lib.activeId, isNull);
      expect(lib.themeIcon('nav.home'), isNull);
    });

    test('prefs 里的 activeId 指向已不存在的包时回落为空', () async {
      SharedPreferences.setMockInitialValues({
        'xianyu_theme_packs_v1': <String>[pkgJson()],
        'xianyu_active_theme_id_v1': 'deadbeef',
      });

      final c = await boot();
      final lib = c.read(themeLibraryProvider);

      expect(lib.packages, hasLength(1));
      expect(lib.activeId, isNull);
    });
  });

  group('我的下载 · 下载来源记录（docs/theme-center-downloads-handoff.md）', () {
    Future<ProviderContainer> boot() async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(themeLibraryProvider.notifier).ready;
      await container.read(settingsProvider.future);
      return container;
    }

    test('默认导入不产生下载标记，fromSquare 导入产生', () async {
      final c = await boot();
      final n = c.read(themeLibraryProvider.notifier);

      final local = (await n.importJson(pkgJson()))!;
      expect(c.read(themeLibraryProvider).downloadedIds, isNot(contains(local.id)));

      final remote =
          (await n.importJson(pkgJson(name: '广场包'), fromSquare: true))!;
      expect(c.read(themeLibraryProvider).downloadedIds, contains(remote.id));
    });

    test('标记只增不减：先下载、后文件导入同 id 不抹除', () async {
      final c = await boot();
      final n = c.read(themeLibraryProvider.notifier);
      final pkg = (await n.importJson(pkgJson(), fromSquare: true))!;

      await n.importJson(pkgJson());

      expect(c.read(themeLibraryProvider).downloadedIds, contains(pkg.id));
    });

    test('删除包时同步移除下载标记；再以文件导入不会诈尸', () async {
      final c = await boot();
      final n = c.read(themeLibraryProvider.notifier);
      final pkg = (await n.importJson(pkgJson(), fromSquare: true))!;

      await n.remove(pkg.id);
      expect(c.read(themeLibraryProvider).downloadedIds, isEmpty);

      await n.importJson(pkgJson());
      expect(c.read(themeLibraryProvider).downloadedIds, isEmpty);
    });

    test('激活 / 取消激活不丢下载标记', () async {
      final c = await boot();
      final n = c.read(themeLibraryProvider.notifier);
      final pkg = (await n.importJson(pkgJson(), fromSquare: true))!;

      await n.activate(pkg.id);
      expect(c.read(themeLibraryProvider).downloadedIds, contains(pkg.id));

      await n.deactivate();
      expect(c.read(themeLibraryProvider).downloadedIds, contains(pkg.id));
    });

    test('重启后从 prefs 恢复下载标记', () async {
      final first = await boot();
      final n = first.read(themeLibraryProvider.notifier);
      final pkg = (await n.importJson(pkgJson(), fromSquare: true))!;
      first.dispose();

      final second = ProviderContainer();
      addTearDown(second.dispose);
      await second.read(themeLibraryProvider.notifier).ready;

      expect(second.read(themeLibraryProvider).downloadedIds, {pkg.id});
    });

    test('prefs 里指向已删除包的下载 id 被净化', () async {
      SharedPreferences.setMockInitialValues({
        'xianyu_theme_packs_v1': <String>[pkgJson()],
        'xianyu_downloaded_theme_ids_v1': <String>['deadbeef'],
      });

      final c = await boot();

      expect(c.read(themeLibraryProvider).downloadedIds, isEmpty);
    });
  });

  group('图标/贴纸渲染入口（阶段3 契约 §4.1）', () {
    Future<ProviderContainer> boot() async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(themeLibraryProvider.notifier).ready;
      await container.read(settingsProvider.future);
      return container;
    }

    testWidgets('未激活主题时回落内置图标', (tester) async {
      final c = await boot();
      var captured = <Widget>[];
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) {
                captured = [
                  themeSlotIcon(ref, 'nav.home', fallback: Icons.home),
                ];
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );

      expect(captured.single, isA<Icon>());
      expect((captured.single as Icon).icon, Icons.home);
    });

    testWidgets('激活后该槽出网络图，未设置的槽仍回落内置图标', (tester) async {
      final c = await boot();
      final n = c.read(themeLibraryProvider.notifier);
      final pkg = (await n.importJson(pkgJson()))!;
      await n.activate(pkg.id);

      var captured = <String, Widget>{};
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) {
                captured = {
                  'set': themeSlotIcon(ref, 'nav.home',
                      fallback: Icons.home, size: 22),
                  'unset': themeSlotIcon(ref, 'player.queue',
                      fallback: Icons.queue_music, size: 22),
                };
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );

      expect(captured['set'], isA<CachedNetworkImage>());
      expect(captured['unset'], isA<Icon>());
      expect((captured['unset'] as Icon).icon, Icons.queue_music);
    });

    testWidgets('贴纸未设置时不渲染', (tester) async {
      final c = await boot();
      Widget? captured;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) {
                captured =
                    themeSlotSticker(ref, 'recognize.deco', width: 120);
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );

      expect(captured, isA<SizedBox>());
    });
  });

  group('叠色入口（阶段2 契约 §4.2）', () {
    Future<ProviderContainer> boot() async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(themeLibraryProvider.notifier).ready;
      await container.read(settingsProvider.future);
      return container;
    }

    /// 在真实 Consumer 里取一次叠色结果。
    Future<Color> tintOf(
      WidgetTester tester,
      ProviderContainer c,
      String slotId,
      Color base,
    ) async {
      late Color out;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) {
                out = themeTint(ref, slotId, base);
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      return out;
    }

    const base = Color(0xFF123456);

    testWidgets('未激活主题时原样返回 base —— 不装主题的用户零变化', (tester) async {
      final c = await boot();
      expect(await tintOf(tester, c, 'nav.bar', base), base);
    });

    testWidgets('激活但该槽未设置时同样原样返回', (tester) async {
      final c = await boot();
      final n = c.read(themeLibraryProvider.notifier);
      final pkg = (await n.importJson(pkgJson()))!;
      await n.activate(pkg.id);

      // 样例包里只设了 home.stat，nav.bar 未设置。
      expect(await tintOf(tester, c, 'nav.bar', base), base);
    });

    testWidgets('该槽设置后按 o 叠在 base 之上，结果既非 base 也非纯主题色', (tester) async {
      final c = await boot();
      final n = c.read(themeLibraryProvider.notifier);
      final pkg = (await n.importJson(pkgJson()))!;
      await n.activate(pkg.id);

      // home.stat: #7C4DFF @ 0.35
      final out = await tintOf(tester, c, 'home.stat', base);
      const themeColor = Color(0xFF7C4DFF);
      final expected = Color.alphaBlend(
        themeColor.withValues(alpha: 0.35),
        base,
      );

      expect(out, expected);
      expect(out, isNot(base));
      expect(out, isNot(themeColor));
    });

    testWidgets('themeTintOrNull：未设置返回 null，设置后返回带 alpha 的主题色', (tester) async {
      final c = await boot();
      Color? unset;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) {
                unset = themeTintOrNull(ref, 'nav.bar');
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      expect(unset, isNull, reason: '未激活时调用方不应新增容器');

      final n = c.read(themeLibraryProvider.notifier);
      final pkg = (await n.importJson(pkgJson()))!;
      await n.activate(pkg.id);

      Color? set;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) {
                set = themeTintOrNull(ref, 'home.stat');
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      expect(set, const Color(0xFF7C4DFF).withValues(alpha: 0.35));
    });
  });
}
