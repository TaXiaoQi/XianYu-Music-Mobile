import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/core/rust_init.dart';
import 'src/core/settings.dart';
import 'src/navigation/routes.dart';

class XianYuApp extends ConsumerStatefulWidget {
  const XianYuApp({super.key});

  @override
  ConsumerState<XianYuApp> createState() => _XianYuAppState();
}

class _XianYuAppState extends ConsumerState<XianYuApp> {
  // 按 accent 缓存两套主题，避免深浅色切换时重复执行较重的
  // ColorScheme.fromSeed（HCT 调色），把计算从动画首帧移除。
  int? _cachedAccent;
  ThemeData? _lightTheme;
  ThemeData? _darkTheme;

  void _ensureThemes(int accent) {
    if (_cachedAccent == accent && _lightTheme != null) return;
    _cachedAccent = accent;
    final seed = Color(accent);
    _lightTheme = ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: seed,
        brightness: Brightness.light,
      ),
      useMaterial3: true,
    );
    _darkTheme = ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: seed,
        brightness: Brightness.dark,
      ),
      useMaterial3: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final init = ref.watch(rustInitProvider);
    final settings = ref.watch(settingsProvider).valueOrNull;
    final accent = settings?.accentColor ?? 0xFFE0245E;
    final themeMode = switch (settings?.themeMode ?? ThemeModePreference.system) {
      ThemeModePreference.light => ThemeMode.light,
      ThemeModePreference.dark => ThemeMode.dark,
      ThemeModePreference.system => ThemeMode.system,
    };
    _ensureThemes(accent);
    final theme = _lightTheme!;
    final darkTheme = _darkTheme!;

    // 初始化完成后交由 go_router 接管；未完成时展示加载/错误界面。
    if (init.hasValue) {
      return MaterialApp.router(
        title: '弦予音乐',
        debugShowCheckedModeBanner: false,
        theme: theme,
        darkTheme: darkTheme,
        themeMode: themeMode,
        routerConfig: appRouter,
      );
    }
    return MaterialApp(
      title: '弦予音乐',
      debugShowCheckedModeBanner: false,
      theme: theme,
      darkTheme: darkTheme,
      themeMode: themeMode,
      home: init.when(
        data: (_) => const _InitLoadingScreen(),
        loading: () => const _InitLoadingScreen(),
        error: (e, _) => _InitErrorScreen(
          error: e,
          onRetry: () => ref.invalidate(rustInitProvider),
        ),
      ),
    );
  }
}

class _InitLoadingScreen extends StatelessWidget {
  const _InitLoadingScreen();
  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
  }
}

class _InitErrorScreen extends StatelessWidget {
  const _InitErrorScreen({required this.error, required this.onRetry});
  final Object error;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48),
              const SizedBox(height: 16),
              const Text('核心初始化失败', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Text('$error', textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}