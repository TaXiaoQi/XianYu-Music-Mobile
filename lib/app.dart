import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/core/rust_init.dart';
import 'src/core/settings.dart';
import 'src/core/app_colors.dart';
import 'src/auth/account_api.dart';
import 'src/i18n/i18n.dart';
import 'src/navigation/routes.dart';
import 'src/widgets/flying_cover.dart';
import 'src/widgets/custom_background.dart';
import 'l10n/gen/app_localizations.dart';

/// 统一消息提示样式：底部居中、圆角小胶囊（椭圆）、深底白字，替换默认铺满全宽的横条。
const SnackBarThemeData _toastTheme = SnackBarThemeData(
  // 浮动模式：胶囊悬浮贴底，不退化为全宽长条。
  behavior: SnackBarBehavior.floating,
  // 固定宽度：无论屏幕多宽都是居中的紧凑小胶囊；文本过长时换行增高。
  width: 240,
  // 大圆角构成椭圆药丸外观。
  shape: RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(60)),
  ),
  backgroundColor: Color(0xE6323232),
  elevation: 0,
  contentTextStyle: TextStyle(
    color: Colors.white,
    fontSize: 13.5,
    height: 1.3,
    // 显式清除下划线，避免 toast 文字继承出横线。
    decoration: TextDecoration.none,
  ),
  // 上下留白让胶囊稍离底部。
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
  ThemeData? _lightTheme;
  ThemeData? _darkTheme;
  bool _loggedHomeFirstFrame = false;

  @override
  void initState() {
    super.initState();
    // 系统语言变化时（跟随系统模式下）刷新界面语言。
    WidgetsBinding.instance.addObserver(this);
    // 启动统计上报（fire-and-forget，失败静默）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(accountApiProvider).reportAppOpen();
    });
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
    // 安卓切换特效：开启预测返回时用 PredictiveBackPageTransitionsBuilder——
    // 非手势的打开/关闭回退到 M3 FadeForwards（新页面淡入+轻微缩放上移，返回
    // 淡出，柔和不生硬），手势中则整屏缩放跟手（预测返回行程）；关闭预测返回
    // 时退化为纯 FadeForwards（无跟手，直接 pop）。
    final pageTransitions = PageTransitionsTheme(
      builders: {
        TargetPlatform.android: predictiveBack
            ? const PredictiveBackPageTransitionsBuilder()
            : const FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.iOS: const CupertinoPageTransitionsBuilder(),
      },
    );
    final lightScheme =
        _schemeWithExactAccent(accent: seed, brightness: Brightness.light);
    _lightTheme = ThemeData(
      colorScheme: lightScheme,
      // 页面底色交给根层统一渲染（自定义壁纸/默认底色）：Scaffold 本身透明，
      // 由各页面背景透出根层。透明不改变 colorScheme.surface（卡片/输入底色不受影响）。
      scaffoldBackgroundColor: Colors.transparent,
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
      // 全局消息提示：底部居中的小胶囊 toast（对齐大众 toast 设计），替换默认长横条。
      snackBarTheme: _toastTheme,
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
      // 页面底色交给根层统一渲染（自定义壁纸/默认底色），Scaffold 本身透明以透出。
      scaffoldBackgroundColor: Colors.transparent,
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
      dialogTheme:
          const DialogThemeData(backgroundColor: Color(0xFF262626)),
      snackBarTheme: _toastTheme,
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
    final language = settings?.language ?? AppLanguage.system;
    final locale = _localeFor(language);
    // 同步全局界面语言：tr() 无 context 查表依赖该模式（系统模式按系统 locale 解析）。
    // 必须在计算 MaterialApp key 之前完成，保证 key 与语言一致。
    I18n.setMode(_i18nModeFor(language));
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
            title: tr('弦予音乐'),
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
            // key 随「解析后的界面语言」变化（覆盖系统模式下的系统语言切换），
            // 强制整体重挂载刷新全部 tr() 文案。
            key: ValueKey('app-${I18n.mode.name}'),
            title: tr('弦予音乐'),
            debugShowCheckedModeBanner: false,
            theme: theme,
            darkTheme: darkTheme,
            themeMode: themeMode,
            locale: locale,
            localizationsDelegates: l10nDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            routerConfig: appRouter,
            // 注册根 Overlay 供「飞封面」动画使用（首帧后 Navigator 已挂载）。
            builder: (context, child) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                final overlay = appNavigatorKey.currentState?.overlay;
                if (overlay != null) FlyingCover.instance.attach(overlay);
              });
              // 全局壁纸层：置于 Navigator 之下，作为所有页面（主 Tab + 二级页）
              // 的统一底色。壁纸未启用时由 ColoredBox 提供原默认底色，视觉不变。
              return Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(
                    color: appSurfaceBg(context),
                    child: const CustomBackgroundLayer(),
                  ),
                  child!,
                ],
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

  /// 系统语言解析：中文按地区分简繁（TW/HK/MO → 繁体），英文 → en，其余默认简体。
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
