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
  bool? _cachedPredictiveBack;
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

  /// 精确主题色 ColorScheme：primary/tertiary 家族直接取用户所选颜色。
  ///
  /// fromSeed 的 tonal palette 会把高饱和色（如红 EC4141）压成低饱和粉调
  /// （暗色 primary ≈ #FFB4AB），导致「选红色出来粉色」。此处仅借用 fromSeed
  /// 的中性色板（surface/outline/error），强调色家族全部精确覆盖：
  /// - primary：亮色用原色；暗色下过暗时保色相提亮到可辨
  /// - secondary：同色相降饱和派生，避免界面出现两种不相干的颜色
  ColorScheme _schemeWithExactAccent(
      {required Color accent, required Brightness brightness}) {
    final dark = brightness == Brightness.dark;
    final base =
        ColorScheme.fromSeed(seedColor: accent, brightness: brightness);
    final hsl = HSLColor.fromColor(accent);
    var primary = accent;
    if (dark && hsl.lightness < 0.4) {
      primary = hsl.withLightness(0.5).toColor();
    }
    Color onOf(Color c) => c.computeLuminance() > 0.55
        ? const Color(0xFF1F1F1F)
        : Colors.white;
    final primaryContainer = dark
        ? Color.lerp(primary, Colors.black, 0.55)!
        : Color.lerp(primary, Colors.white, 0.85)!;
    final onPrimaryContainer = dark
        ? Color.lerp(primary, Colors.white, 0.8)!
        : Color.lerp(primary, Colors.black, 0.45)!;
    final secondary = hsl
        .withSaturation((hsl.saturation * 0.45).clamp(0.0, 1.0))
        .toColor();
    final secondaryContainer = dark
        ? Color.lerp(secondary, Colors.black, 0.5)!
        : Color.lerp(secondary, Colors.white, 0.85)!;
    final onSecondaryContainer = dark
        ? Color.lerp(secondary, Colors.white, 0.75)!
        : Color.lerp(secondary, Colors.black, 0.4)!;
    return base.copyWith(
      primary: primary,
      onPrimary: onOf(primary),
      primaryContainer: primaryContainer,
      onPrimaryContainer: onPrimaryContainer,
      // 亮色 inversePrimary 应等于暗色 primary（原色），反之亦然。
      inversePrimary: dark ? onPrimaryContainer : primary,
      secondary: secondary,
      onSecondary: onOf(secondary),
      secondaryContainer: secondaryContainer,
      onSecondaryContainer: onSecondaryContainer,
      tertiary: primary,
      onTertiary: onOf(primary),
      tertiaryContainer: primaryContainer,
      onTertiaryContainer: onPrimaryContainer,
    );
  }

  void _ensureThemes(int accent, bool predictiveBack) {
    if (_cachedAccent == accent &&
        _cachedPredictiveBack == predictiveBack &&
        _lightTheme != null) {
      return;
    }
    _cachedAccent = accent;
    _cachedPredictiveBack = predictiveBack;
    final seed = Color(accent);
    // 安卓官方切换特效（缩放）始终使用 Zoom 转场；仅在开启预测返回时叠加
    // PredictiveBackPageTransitionsBuilder 手势动画（Android 13+ 手势导航下生效）。
    final pageTransitions = PageTransitionsTheme(
      builders: {
        TargetPlatform.android: predictiveBack
            ? const PredictiveBackPageTransitionsBuilder()
            : const ZoomPageTransitionsBuilder(),
        TargetPlatform.iOS: const CupertinoPageTransitionsBuilder(),
      },
    );
    final lightScheme =
        _schemeWithExactAccent(accent: seed, brightness: Brightness.light);
    _lightTheme = ThemeData(
      colorScheme: lightScheme,
      // 统一页面底色与控件底色（对齐设置页规范）。
      scaffoldBackgroundColor: const Color(0xFFF4F4F6),
      // 顶栏与页面背景同色，滚动时不变色（禁用 scrolledUnder 阴影叠加）。
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFFF4F4F6),
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      cardTheme: const CardThemeData(
        color: Color(0xFFFFFFFF),
        surfaceTintColor: Colors.transparent,
      ),
      dialogTheme: const DialogThemeData(backgroundColor: Color(0xFFFFFFFF)),
      pageTransitionsTheme: pageTransitions,
      useMaterial3: true,
    );
    final darkScheme =
        _schemeWithExactAccent(accent: seed, brightness: Brightness.dark);
    _darkTheme = ThemeData(
      colorScheme: darkScheme.copyWith(
        surface: const Color(0xFF262626),
        surfaceContainerLowest: const Color(0xFF1f1f1f),
        surfaceContainerLow: const Color(0xFF262626),
        surfaceContainer: const Color(0xFF2c2c2c),
        surfaceContainerHigh: const Color(0xFF333333),
        surfaceContainerHighest: const Color(0xFF3a3a3a),
      ),
      // 统一页面底色与控件底色（对齐设置页规范）。
      scaffoldBackgroundColor: const Color(0xFF222222),
      // 顶栏与页面背景同色，滚动时不变色（禁用 scrolledUnder 阴影叠加）。
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF222222),
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      cardTheme: const CardThemeData(
        color: Color(0xFF303030),
        surfaceTintColor: Colors.transparent,
      ),
      dialogTheme: const DialogThemeData(backgroundColor: Color(0xFF303030)),
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
    _ensureThemes(accent, settings?.enablePredictiveBack ?? true);
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
