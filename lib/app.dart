import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/core/rust_init.dart';
import 'src/core/settings.dart';
import 'src/core/app_colors.dart';
import 'src/auth/account_api.dart';
import 'src/i18n/i18n.dart';
import 'src/navigation/routes.dart';
import 'src/update/app_update.dart';
import 'src/widgets/flying_cover.dart';
import 'src/widgets/privacy_policy.dart';
import 'src/widgets/custom_background.dart';
import 'src/widgets/liquid_wave.dart';
import 'l10n/gen/app_localizations.dart';

const SnackBarThemeData _toastTheme = SnackBarThemeData(
  behavior: SnackBarBehavior.floating,
  width: 240,
  shape: RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(60)),
  ),
  backgroundColor: Color(0xE6323232),
  elevation: 0,
  contentTextStyle: TextStyle(
    color: Colors.white,
    fontSize: 13.5,
    height: 1.3,
    decoration: TextDecoration.none,
  ),
  insetPadding: EdgeInsets.symmetric(vertical: 14),
);

class XianYuApp extends ConsumerStatefulWidget {
  const XianYuApp({super.key});

  @override
  ConsumerState<XianYuApp> createState() => _XianYuAppState();
}

class _XianYuAppState extends ConsumerState<XianYuApp> with WidgetsBindingObserver {
  int? _cachedAccent;
  bool? _cachedPredictiveBack;
  WallpaperTextColor _cachedTextMode = WallpaperTextColor.follow;
  ThemeData? _lightTheme;
  ThemeData? _darkTheme;
  bool _loggedHomeFirstFrame = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeLocales(List<Locale>? locales) {
    final settings = ref.read(settingsProvider).valueOrNull;
    if ((settings?.language ?? AppLanguage.system) == AppLanguage.system) {
      setState(() {});
    }
  }

  Future<void> _runStartupAfterConsent(WidgetRef ref) async {
    // 必须用根 Navigator 的 context：根 State 的 context 位于 Navigator 之上，
    // 直接 showDialog 会因 Navigator.of 找不到 NavigatorState 而空断言崩溃
    // （首次安装、尚未记录隐私同意时必现）。
    final navContext = appNavigatorKey.currentContext;
    if (navContext == null) {
      // Router 尚未挂载，推迟一帧重试
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_runStartupAfterConsent(ref));
      });
      return;
    }
    final agreed = await ensurePrivacyConsent(navContext);
    if (!agreed || !mounted) return;
    ref.read(accountApiProvider).reportAppOpen();
    unawaited(runStartupVersionChecks(ref));
  }

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

  void _ensureThemes(int accent, bool predictiveBack,
      WallpaperTextColor textMode) {
    if (_cachedAccent == accent &&
        _cachedPredictiveBack == predictiveBack &&
        _cachedTextMode == textMode &&
        _lightTheme != null) {
      return;
    }
    _cachedAccent = accent;
    _cachedPredictiveBack = predictiveBack;
    _cachedTextMode = textMode;
    final seed = Color(accent);
    PageTransitionsTheme transitions() => PageTransitionsTheme(
          builders: {
            TargetPlatform.android: predictiveBack
                ? const PredictiveBackPageTransitionsBuilder(
                    fallbackColor: Colors.transparent,
                  )
                : const FadeForwardsPageTransitionsBuilder(
                    backgroundColor: Colors.transparent,
                  ),
            TargetPlatform.iOS: const CupertinoPageTransitionsBuilder(),
          },
        );
    final lightTransitions = transitions();
    final darkTransitions = transitions();
    final lightScheme =
        _schemeWithExactAccent(accent: seed, brightness: Brightness.light);
    lightBaseScheme = lightScheme;
    final lightBase = ThemeData(
      colorScheme: lightScheme,
      scaffoldBackgroundColor: Colors.transparent,
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
      snackBarTheme: _toastTheme,
      pageTransitionsTheme: lightTransitions,
      useMaterial3: true,
    );
    lightBaseTextTheme = lightBase.textTheme;
    _lightTheme = _applyWallpaperTextMode(lightBase, textMode);
    final darkScheme =
        _schemeWithExactAccent(accent: seed, brightness: Brightness.dark);
    darkBaseScheme = darkScheme;
    _darkTheme = ThemeData(
      colorScheme: darkScheme.copyWith(
        surface: const Color(0xFF262626),
        surfaceContainerLowest: const Color(0xFF1f1f1f),
        surfaceContainerLow: const Color(0xFF262626),
        surfaceContainer: const Color(0xFF2c2c2c),
        surfaceContainerHigh: const Color(0xFF333333),
        surfaceContainerHighest: const Color(0xFF3a3a3a),
      ),
      scaffoldBackgroundColor: Colors.transparent,
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
      dialogTheme:
          const DialogThemeData(backgroundColor: Color(0xFF262626)),
      snackBarTheme: _toastTheme,
      pageTransitionsTheme: darkTransitions,
      useMaterial3: true,
    );
    darkBaseTextTheme = _darkTheme!.textTheme;
    _darkTheme = _applyWallpaperTextMode(_darkTheme!, textMode);
  }

  ThemeData _applyWallpaperTextMode(ThemeData base, WallpaperTextColor mode) {
    if (mode == WallpaperTextColor.follow) return base;
    final Color onSurface;
    final Color onSurfaceVariant;
    if (mode == WallpaperTextColor.light) {
      onSurface = const Color(0xFFFFFFFF);
      onSurfaceVariant = const Color(0xB3FFFFFF);
    } else {
      onSurface = const Color(0xE6000000);
      onSurfaceVariant = const Color(0x8A000000);
    }
    final ColorScheme containers;
    if (mode == WallpaperTextColor.light) {
      containers = base.colorScheme.copyWith(
        surfaceContainerLowest: const Color(0xFF1f1f1f),
        surfaceContainerLow: const Color(0xFF262626),
        surfaceContainer: const Color(0xFF2c2c2c),
        surfaceContainerHigh: const Color(0xFF333333),
        surfaceContainerHighest: const Color(0xFF3a3a3a),
      );
    } else {
      containers = base.colorScheme.copyWith(
        surfaceContainerLowest: const Color(0xFFFFFFFF),
        surfaceContainerLow: const Color(0xFFF7F7F8),
        surfaceContainer: const Color(0xFFEFEFF1),
        surfaceContainerHigh: const Color(0xFFE7E7EA),
        surfaceContainerHighest: const Color(0xFFDFDFE4),
      );
    }
    return base.copyWith(
      colorScheme:
          containers.copyWith(onSurface: onSurface, onSurfaceVariant: onSurfaceVariant),
      textTheme:
          base.textTheme.apply(bodyColor: onSurface, displayColor: onSurface),
      iconTheme: IconThemeData(color: onSurface),
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
    final cbActive = settings?.customBackground.active == true;
    final textMode = cbActive
        ? (settings!.customBackground.textMode)
        : WallpaperTextColor.follow;
    _ensureThemes(accent, settings?.enablePredictiveBack ?? false, textMode);
    final ThemeData theme = _lightTheme!;
    final ThemeData darkTheme = _darkTheme!;
    final cb = settings?.customBackground;
    if (cb?.active == true) {
      final bgPath = cb!.imagePath;
      if (bgPath.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          precacheImage(FileImage(File(bgPath)), this.context);
        });
      }
    }
    final language = settings?.language ?? AppLanguage.system;
    final locale = _localeFor(language);
    I18n.setMode(_i18nModeFor(language));
    final l10nDelegates = [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ];

    if (init.hasValue && !_loggedHomeFirstFrame) {
      _loggedHomeFirstFrame = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_runStartupAfterConsent(ref));
      });
    }

    return init.hasError
        ? MaterialApp(
            title: '${tr('弦予音乐')}${kDebugMode ? '·测试' : ''}',
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
            key: ValueKey('app-${I18n.mode.name}'),
            title: '${tr('弦予音乐')}${kDebugMode ? '·测试' : ''}',
            debugShowCheckedModeBanner: false,
            theme: theme,
            darkTheme: darkTheme,
            themeMode: themeMode,
            locale: locale,
            localizationsDelegates: l10nDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            routerConfig: appRouter,
            builder: (context, child) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                final overlay = appNavigatorKey.currentState?.overlay;
                if (overlay != null) FlyingCover.instance.attach(overlay);
              });
              final fontSize = settings?.fontSize ?? AppFontSize.system;
              final textScaler = fontSize.followsSystem
                  ? MediaQuery.textScalerOf(context)
                  : TextScaler.linear(fontSize.scale);
              return MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: textScaler),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ColoredBox(
                      color: appSurfaceBg(context),
                      child: const CustomBackgroundLayer(),
                    ),
                    ScrollOffsetCapture(child: child!),
                  ],
                ),
              );
            },
          );
  }

  Locale? _localeFor(AppLanguage lang) => switch (lang) {
        AppLanguage.system => null,
        AppLanguage.zhCN => const Locale('zh'),
        AppLanguage.zhTW => const Locale('zh', 'TW'),
        AppLanguage.en => const Locale('en'),
      };

  I18nMode _i18nModeFor(AppLanguage lang) => switch (lang) {
        AppLanguage.zhCN => I18nMode.zhCn,
        AppLanguage.zhTW => I18nMode.zhTw,
        AppLanguage.en => I18nMode.en,
        AppLanguage.system => _modeForSystemLocale(),
      };

  I18nMode _modeForSystemLocale() {
    final locales = WidgetsBinding.instance.platformDispatcher.locales;
    if (locales.isEmpty) return I18nMode.zhCn;
    final first = locales.first;
    switch (first.languageCode) {
      case 'en':
        return I18nMode.en;
      case 'zh':
        final cc = first.countryCode;
        return (cc == 'TW' || cc == 'HK' || cc == 'MO')
            ? I18nMode.zhTw
            : I18nMode.zhCn;
    }
    return I18nMode.zhCn;
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
              Text(tr('核心初始化失败'),
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Text('$error', textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: Text(tr('重试')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
