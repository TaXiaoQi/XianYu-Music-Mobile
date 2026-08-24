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
  bool _loggedHomeFirstFrame = false;

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

    // 首页（真实 router）首个帧渲染完成埋点
    if (init.hasValue && !_loggedHomeFirstFrame) {
      _loggedHomeFirstFrame = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        debugPrint('[startup] home first frame rendered');
      });
    }

    // 冷启动「首页优先」：只在 rust 初始化【报错】时才拦下显示重试页；加载中、
    // 成功都立刻挂起真实路由（初始 /home 首帧即渲染），不再整屏空白等待 rust。
    // rust 在 main() 里已提前与首帧并行初始化，首页的数据访问大多走异步
    // FutureProvider（加载态显示转圈/空态），不会因未就绪而崩溃。
    //
    // key 关键：语言切换会改变 locale。若仍复用同一个 MaterialApp.router 实例做
    // 增量 locale 重建，会与 go_router 各分支 Navigator 的瞬态重建竞态，命中
    // navigator._debugLocked 断言并报“popped the last page”（flutter#141315），
    // 现场表现为切换语言黑屏。改用随 locale 变化的 key 强制整体重挂载：旧子树
    //（含全部 Navigator）整体销毁、新子树（回到初始路由 /home）干净重建，不做
    // 增量路由 reconfigure，从而彻底规避该竞态。语言切换重挂载一次开销可接受。
    return init.hasError
        ? MaterialApp(
            title: '弦予音乐',
            debugShowCheckedModeBanner: false,
            theme: theme,
            darkTheme: darkTheme,
            themeMode: themeMode,
            locale: locale,
            localizationsDelegates: l10nDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: _InitErrorScreen(
              error: init.error!,
              onRetry: () => ref.invalidate(rustInitProvider),
            ),
          )
        : MaterialApp.router(
            key: ValueKey('app-${locale ?? const Locale('system')}'),
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
