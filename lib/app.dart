import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/core/rust_init.dart';
import 'src/core/settings.dart';
import 'src/navigation/routes.dart';

class XianYuApp extends ConsumerWidget {
  const XianYuApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final init = ref.watch(rustInitProvider);
    final settings = ref.watch(settingsProvider).valueOrNull;
    final accent = Color(settings?.accentColor ?? 0xFFE0245E);
    final themeMode = switch (settings?.themeMode ?? ThemeModePreference.system) {
      ThemeModePreference.light => ThemeMode.light,
      ThemeModePreference.dark => ThemeMode.dark,
      ThemeModePreference.system => ThemeMode.system,
    };
    return MaterialApp.router(
      title: '弦予音乐',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: accent,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: accent,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      themeMode: themeMode,
      routerConfig: init.when(
        data: (_) => appRouter,
        error: (_, _) => appRouter,
        loading: () => appRouter,
      ),
    );
  }
}