import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xianyu_music_mobile/src/core/settings.dart';
import 'package:xianyu_music_mobile/src/navigation/shell.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('navBarInsetProvider', () {
    test('悬浮式返回 175，页面需自行避让', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      await c.read(settingsProvider.future);
      await c.read(settingsProvider.notifier).setFloatingNavBar(true);
      expect(c.read(navBarInsetProvider), 175);
    });

    test('固定式返回 82，仅为悬浮播放条留白', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      await c.read(settingsProvider.future);
      await c.read(settingsProvider.notifier).setFloatingNavBar(false);
      expect(c.read(navBarInsetProvider), 82);
    });

    test('悬浮式留白大于固定式（需多容纳一个底栏）', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      await c.read(settingsProvider.future);
      final n = c.read(settingsProvider.notifier);

      await n.setFloatingNavBar(true);
      final floatingInset = c.read(navBarInsetProvider);
      await n.setFloatingNavBar(false);
      final fixedInset = c.read(navBarInsetProvider);

      expect(floatingInset, greaterThan(fixedInset));
    });
  });

  group('floatingNavBar 设置项', () {
    test('默认启用悬浮底栏', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final s = await c.read(settingsProvider.future);
      expect(s.floatingNavBar, isTrue);
    });

    test('切换后可持久化读回', () async {
      SharedPreferences.setMockInitialValues({'floatingNavBar': false});
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final s = await c.read(settingsProvider.future);
      expect(s.floatingNavBar, isFalse);
    });

    test('copyWith 正确覆盖该字段', () {
      const base = AppSettings();
      expect(base.floatingNavBar, isTrue);
      expect(base.copyWith(floatingNavBar: false).floatingNavBar, isFalse);
      expect(base.copyWith(volume: 0.5).floatingNavBar, isTrue);
    });
  });

  group('liquidGlass 设置项', () {
    test('默认启用液态玻璃', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final s = await c.read(settingsProvider.future);
      expect(s.liquidGlass, isTrue);
    });

    test('关闭后可持久化读回', () async {
      SharedPreferences.setMockInitialValues({'liquidGlass': false});
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final s = await c.read(settingsProvider.future);
      expect(s.liquidGlass, isFalse);
    });

    test('copyWith 与其他字段互不干扰', () {
      const base = AppSettings();
      expect(base.copyWith(liquidGlass: false).liquidGlass, isFalse);
      expect(base.copyWith(liquidGlass: false).floatingNavBar, isTrue);
      expect(base.copyWith(floatingNavBar: false).liquidGlass, isTrue);
    });

    test('两项设置可独立持久化', () async {
      SharedPreferences.setMockInitialValues({});
      final c = ProviderContainer();
      addTearDown(c.dispose);
      await c.read(settingsProvider.future);
      final n = c.read(settingsProvider.notifier);
      await n.setFloatingNavBar(false);
      await n.setLiquidGlass(false);
      final s = c.read(settingsProvider).valueOrNull!;
      expect(s.floatingNavBar, isFalse);
      expect(s.liquidGlass, isFalse);
    });
  });
}
