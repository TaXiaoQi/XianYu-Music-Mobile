import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/core/rust_init.dart';
import 'src/core/settings.dart';
import 'src/auth/account_api.dart';
import 'src/navigation/routes.dart';
import 'l10n/gen/app_localizations.dart';

class XianYuApp extends ConsumerStatefulWidget {
  const XianYuApp({super.key});

  @override
  ConsumerState<XianYuApp> createState() => _XianYuAppState();
}

class _XianYuAppState extends ConsumerState<XianYuApp> {
  int? _cachedAccent;
  ThemeData? _lightTheme;
  ThemeData? _darkTheme;

  @override
  void initState() {
    super.initState();
    // 启动统计上报（fire-and-forget，失败静默）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(accountApiProvider).reportAppOpen();
    });
  }

  void _ensureThemes(int accent) {
    if (_cachedAccent == accent && _lightTheme != null) return;
    _cachedAccent = accent;
    final seed = Color(accent);
    final pageTransitions = PageTransitionsTheme(
      builders: {
        TargetPlatform.android: const PredictiveBackPageTransitionsBuilder(),
        TargetPlatform.iOS: const CupertinoPageTransitionsBuilder(),
      },
    );
    _lightTheme = ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: seed,
        brightness: Brightness.light,
      ),
      pageTransitionsTheme: pageTransitions,
      useMaterial3: true,
    );
    final darkBase = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.dark,
    );
    _darkTheme = ThemeData(
      colorScheme: darkBase.copyWith(
        surface: const Color(0xFF262626),
        surfaceContainerLowest: const Color(0xFF1f1f1f),
        surfaceContainerLow: const Color(0xFF262626),
        surfaceContainer: const Color(0xFF2c2c2c),
        surfaceContainerHigh: const Color(0xFF333333),
        surfaceContainerHighest: const Color(0xFF3a3a3a),
      ),
      pageTransitionsTheme: pageTransitions,
      useMaterial3: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final init = ref.watch(rustInitProvider);
    final settings = ref.watch(settingsProvider).valueOrNull;
    final accent = settings?.accentColor ?? 0xFFEC4141;
    final themeMode = switch (settings?.themeMode ?? ThemeModePreference.system) {
      ThemeModePreference.light => ThemeMode.light,
      ThemeModePreference.dark => ThemeMode.dark,
      ThemeModePreference.system => ThemeMode.system,
    };
    _ensureThemes(accent);
    final theme = _lightTheme!;
    final darkTheme = _darkTheme!;
    final locale = _localeFor(settings?.language ?? AppLanguage.system);
    final l10nDelegates = [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ];

    // 启动页由 main.dart 的 AppWarmupRunner 统一负责（等待 rust 初始化完成）
    return init.hasValue
        ? MaterialApp.router(
            // XianYuApp 的 context 位于 MaterialApp 之上、无 Localizations 祖先，
            // 必须用可空版 Localizations.of（生成的 AppLocalizations.of 内含 !，会空指针崩溃）。
            title: Localizations.of<AppLocalizations>(context, AppLocalizations)
                    ?.appTitle ??
                '弦予音乐',
            debugShowCheckedModeBanner: false,
            theme: theme,
            darkTheme: darkTheme,
            themeMode: themeMode,
            locale: locale,
            localizationsDelegates: l10nDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            routerConfig: appRouter,
          )
        : MaterialApp(
            title: '弦予音乐',
            debugShowCheckedModeBanner: false,
            theme: theme,
            darkTheme: darkTheme,
            themeMode: themeMode,
            locale: locale,
            localizationsDelegates: l10nDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: init.when(
              data: (_) => const SizedBox.shrink(),
              loading: () => const SizedBox.shrink(),
              error: (e, _) => _InitErrorScreen(
                error: e,
                onRetry: () => ref.invalidate(rustInitProvider),
              ),
            ),
          );
  }

  Locale? _localeFor(AppLanguage lang) => switch (lang) {
        AppLanguage.system => null,
        AppLanguage.zhCN => const Locale('zh'),
        AppLanguage.zhTW => const Locale('zh', 'TW'),
        AppLanguage.en => const Locale('en'),
      };
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
