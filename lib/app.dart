import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/core/rust_init.dart';
import 'src/core/settings.dart';
import 'src/core/app_colors.dart';
import 'src/auth/account_api.dart';
import 'src/i18n/i18n.dart';
import 'src/navigation/mini_player_overlay.dart';
import 'src/navigation/routes.dart';
import 'src/navigation/shell.dart'
    show
        NavDropletOverlay,
        isLandscapeProvider,
        navBarHiddenProvider,
        navOnRootPathProvider;
import 'src/plugin/lx_update_alerts.dart';
import 'src/update/app_update.dart';
import 'src/widgets/flying_cover.dart';
import 'src/widgets/glass_settings.dart';
import 'src/widgets/privacy_policy.dart';
import 'src/widgets/custom_background.dart';
import 'src/widgets/chrome_glass_frame.dart';
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
  // 飞行封面顶层宿主（第一级）：位于 Navigator 与 mini 播放条之上的独立 Overlay
  final GlobalKey<OverlayState> _flyingOverlayKey = GlobalKey<OverlayState>();
  int? _cachedAccent;
  bool? _cachedPredictiveBack;
  WallpaperTextColor _cachedTextMode = WallpaperTextColor.follow;
  ThemeData? _lightTheme;
  ThemeData? _darkTheme;
  bool _loggedHomeFirstFrame = false;

  /// 上次键盘高度（物理像素）：IME 收起键不经过框架、焦点残留在输入框，
  /// 据 inset 归零主动失焦——全局清除键入状态，避免残留焦点把键盘再拉起
  double? _lastKeyboardInset;

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

  @override
  void didChangeMetrics() {
    final view = WidgetsBinding.instance.platformDispatcher.implicitView;
    if (view == null) return;
    final inset = view.viewInsets.bottom;
    if (_lastKeyboardInset != null &&
        _lastKeyboardInset! > 0 &&
        inset == 0) {
      FocusManager.instance.primaryFocus?.unfocus();
    }
    _lastKeyboardInset = inset;
  }

  Future<void> _runStartupAfterConsent(WidgetRef ref) async {
    final navContext = appNavigatorKey.currentContext;
    if (navContext == null) {
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
      dialogTheme: DialogThemeData(
        backgroundColor: const Color(0xFFFFFFFF),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
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
      dialogTheme: DialogThemeData(
        backgroundColor: const Color(0xFF333333),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
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
    // stretch 效果的 shader filter 层会让 Impeller 下的 backdrop 采样失效
    // （见 _NoStretchScrollBehavior 注释），玻璃材质开启时整体禁用
    final glassActive = glassMaterialActive(ref);
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
            scrollBehavior: glassActive
                ? const _NoStretchScrollBehavior()
                : null,
            localizationsDelegates: l10nDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            routerConfig: appRouter,
            builder: (context, child) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                final overlay = _flyingOverlayKey.currentState;
                if (overlay != null) FlyingCover.instance.attach(overlay);
              });
              final fontSize = settings?.fontSize ?? AppFontSize.system;
              final textScaler = fontSize.followsSystem
                  ? MediaQuery.textScalerOf(context)
                  : TextScaler.linear(fontSize.scale);
              final baseMq = MediaQuery.of(context);
              // 整套 UI 缩放（外观-样式大小）：标准档直通；其余档把路由
              // 子树按「逻辑画布 = 视口 / 缩放」布局，再用 FittedBox 等比
              // 铺回视口——矢量绘制不糊、命中测试随变换自动映射；页内
              // MediaQuery 同步改写口径，避免 mq.size 仍按整屏算导致溢出；
              // 壁纸与迷你条/水滴等系统 chrome 不参与缩放
              final uiScale = uiScaleOf(settings?.uiScaleIndex ?? 1);
              Widget routeChild = MediaQuery(
                data: baseMq.copyWith(textScaler: textScaler),
                child: child!,
              );
              if (uiScale != 1.0) {
                routeChild = FittedBox(
                  fit: BoxFit.fill,
                  child: SizedBox(
                    width: baseMq.size.width / uiScale,
                    height: baseMq.size.height / uiScale,
                    child: MediaQuery(
                      data: baseMq.copyWith(
                        textScaler: textScaler,
                        size: baseMq.size / uiScale,
                        padding: baseMq.padding / uiScale,
                        viewPadding: baseMq.viewPadding / uiScale,
                        viewInsets: baseMq.viewInsets / uiScale,
                        devicePixelRatio: baseMq.devicePixelRatio * uiScale,
                      ),
                      child: child,
                    ),
                  ),
                );
              }
              // 壁纸模式系统三键区磨砂垫：全局挂在路由之上——二级页等
              // push 路由会盖住 shell，shell 内的垫子够不着三键区，必须
              // 在最上层补材质；播放页（独立 Navigator 在垫之上）保持沉
              // 浸不垫。固定底栏可见时其玻璃已覆盖三键区，不叠垫
              final navPadSafeBottom = baseMq.padding.bottom;
              final navPadFloating =
                  ref.watch(settingsProvider.select(
                    (s) => s.valueOrNull?.floatingNavBar,
                  )) ??
                  true;
              final navPadHidden = ref.watch(navBarHiddenProvider) > 0 ||
                  !ref.watch(navOnRootPathProvider);
              final navPadShow = wallpaperGlassActive(ref) &&
                  !ref.watch(isLandscapeProvider) &&
                  !(ref.watch(settingsProvider.select(
                            (s) => s.valueOrNull?.navBarPosition,
                          )) ==
                          NavBarPosition.side) &&
                  (navPadFloating || navPadHidden) &&
                  navPadSafeBottom > 0;
              return MediaQuery(
                data: baseMq.copyWith(textScaler: textScaler),
                child: NotificationListener<NavigationNotification>(
                  onNotification: (_) {
                    // app 完全接管返回（frameworkHandlesBack 恒 true）：
                    // 1) 系统永不自动处理返回——根部退出不再触发系统的
                    //    back-to-home 预测预览（app 内关闭预测开关后，
                    //    退出软件就不走系统预测路线了）；
                    // 2) 手势/返回键全部进 Dart：预测开时 detector 认领走
                    //    预测转场；detector 全 decline（预测关/根部）时
                    //    PredictiveBackOffFallback 兜底走经典链（根部
                    //    「再按一次退出」）。
                    // 吞掉子树全部 NavigationNotification，防播放页 idle
                    // 待机页的后发 canPop=false 覆盖导致引擎注销回调、
                    // 下一次手势被系统直接 finish 退软件
                    SystemNavigator.setFrameworkHandlesBack(true);
                    return true;
                  },
                  child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // chrome 液态玻璃缓存帧边界：包住背景层 + 路由子树
                    // （含 shell 悬浮顶栏/底栏），供转场降级窗口复用
                    // 上一帧液态渲染输出（见 chrome_glass_frame.dart）
                    ChromeGlassFrameBoundary(
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          ColoredBox(
                            color: appSurfaceBg(context),
                            child: const CustomBackgroundLayer(),
                          ),
                          ScrollOffsetCapture(child: routeChild),
                        ],
                      ),
                    ),
                    // 壁纸模式三键区磨砂垫：三键区恒定存在，垫在路由
                    // 与 mini 播放条之间（播放页 Navigator 在其上，不垫）
                    if (navPadShow)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        height: navPadSafeBottom,
                        child: const SystemNavGlassPad(),
                      ),
                    // mini 播放条顶层宿主：位于 Navigator 之上，
                    // 所有页面（含播放页）转场都从播放条背后滑过
                    const MiniPlayerOverlay(),
                    // 底栏水滴顶层宿主：位于播放条之上——水滴独立于底栏
                    // 树，长按放大鼓出栏缘、覆盖并折射上方内容
                    const NavDropletOverlay(),
                    // 播放页独立 Navigator（五级模型第二级）：位于播放条
                    // 之上、飞行封面之下——播放页转场物理盖过播放条
                    const PlayerNavigatorHost(),
                    // 飞行封面顶层宿主（第一级）：高于播放条与一切路由，
                    // 预测性返回的页面缩放不再牵连封面飞行
                    Overlay(
                      key: _flyingOverlayKey,
                      initialEntries: [
                        OverlayEntry(builder: (_) => const SizedBox.shrink()),
                      ],
                    ),
                    // LX 插件自报更新（updateAlert）提示弹窗宿主
                    const LxUpdateAlertHost(),
                  ],
                ),
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
        if (first.scriptCode == 'Hant' ||
            cc == 'TW' ||
            cc == 'HK' ||
            cc == 'MO') {
          return I18nMode.zhTw;
        }
        return I18nMode.zhCn;
    }
    return I18nMode.zhCn;
  }
}

/// 玻璃材质开启时禁用 Android 12 的 stretch overscroll 效果。
///
/// 框架的 StretchingOverscrollIndicator 在 overscroll 时用
/// ImageFilter.shader（stretch_effect.frag）包裹整个列表内容，而 Impeller 上
/// BackdropFilter 的 backdrop 采样在该 shader filter 层之下会失效——表现为
/// 列表滑到最底部（fling 撞边界触发 stretch）时页内玻璃卡片瞬间只剩 tint
/// 变透明，反向滚动触发 ScrollUpdateNotification→scrollEnd(0) 才恢复。
/// 顶栏/底栏/mini 播放条在列表子树之外不受影响。材质关闭（纯色块）时
/// 无 backdrop 采样，保留原生 stretch 不受影响。
class _NoStretchScrollBehavior extends MaterialScrollBehavior {
  const _NoStretchScrollBehavior();

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) =>
      child;
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
