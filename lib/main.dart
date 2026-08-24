import 'dart:ui';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'app.dart';
import 'src/core/app_logger.dart';
import 'src/core/rust_init.dart';
import 'src/plugin/plugin_updates.dart';
import 'l10n/gen/app_localizations.dart';
import 'pages/account/account_page.dart';
import 'pages/effects/effects_page.dart';
import 'pages/favorites/favorites_page.dart';
import 'pages/home/home_page.dart';
import 'pages/library/library_page.dart';
import 'pages/player/player_page.dart';
import 'pages/recent/recent_page.dart';
import 'pages/search/search_page.dart';
import 'pages/settings/music_sources_page.dart';
import 'pages/settings/scan_folders_page.dart';
import 'pages/settings/settings_page.dart';
import 'pages/settings/toolbar_settings_page.dart';
import 'src/auth/account_api.dart';
import 'src/player/player_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final container = ProviderContainer();
  _installErrorReporting(container);

  // 预热液态玻璃 shader，避免首次显示时卡顿。
  try {
    await LiquidGlassWidgets.initialize();
  } catch (_) {
    // 忽略：液态玻璃为可选视觉增强，不可用时降级即可。
  }

  // 初始化系统 MediaSession / 控制中心音频服务
  try {
    audioHandler = await AudioService.init(
      builder: () => XianYuAudioHandler(),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'cc.xymusic.mobile.channel.audio',
        androidNotificationChannelName: '弦予音乐播放控制',
        androidNotificationOngoing: true,
        androidStopForegroundOnPause: true,
        androidNotificationIcon: 'mipmap/ic_launcher',
      ),
    );
  } catch (_) {
    // 忽略：桌面端或不支持环境静默回退
  }

  runApp(
    LiquidGlassWidgets.wrap(
      adaptiveQuality: true,
      child: UncontrolledProviderScope(
        container: container,
        child: const AppWarmupRunner(
          child: XianYuApp(),
        ),
      ),
    ),
  );
}

/// 全局错误上报（fire-and-forget，失败静默），与桌面端 main.ts 对齐。
///
/// 除上报远端外，同时写入本地诊断日志（AppLogger 常驻环形缓冲，
/// 开启「问题诊断」后导出的 txt 会包含崩溃堆栈），便于本地排查。
void _installErrorReporting(ProviderContainer container) {
  FlutterError.onError = (details) {
    final msg = details.exceptionAsString();
    final stack = details.stack?.toString() ?? '';
    AppLogger.instance
        .log('fatal', '未捕获异常: $msg\n$stack');
    FlutterError.presentError(details);
    try {
      container.read(accountApiProvider).reportError(
            errorType: 'flutter',
            errorMessage: msg,
            errorStack: stack,
            page: 'global',
          );
    } catch (_) {
      // 上报失败静默，不影响主流程。
    }
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    AppLogger.instance
        .log('fatal', '平台异常: $error\n$stack');
    try {
      container.read(accountApiProvider).reportError(
            errorType: 'platform',
            errorMessage: error.toString(),
            errorStack: stack.toString(),
            page: 'global',
          );
    } catch (_) {}
    return true;
  };
}

/// 应用程序路由与关键页面预热器（含全屏精致 Splash / Warmup 加载屏）
class AppWarmupRunner extends ConsumerStatefulWidget {
  const AppWarmupRunner({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<AppWarmupRunner> createState() => _AppWarmupRunnerState();
}

class _AppWarmupRunnerState extends ConsumerState<AppWarmupRunner> {
  bool _warmedUp = false;
  bool _minTimeElapsed = false;

  @override
  void initState() {
    super.initState();

    // rust 初始化完成（无论成功/失败）后尝试结束预热
    ref.listenManual(rustInitProvider, (prev, next) {
      if (next.hasValue || next.hasError) _tryFinish();
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      // 预留足够时间预热所有离屏 Widget、Shader 和渲染管线 (约 800ms)
      Future.delayed(const Duration(milliseconds: 800), () {
        if (mounted) {
          setState(() {
            _minTimeElapsed = true;
          });
          _tryFinish();
        }
      });
    });
  }

  void _tryFinish() {
    if (!mounted || _warmedUp || !_minTimeElapsed) return;
    final init = ref.read(rustInitProvider);
    if (!init.hasValue && !init.hasError) return;
    setState(() {
      _warmedUp = true;
    });
    _runStartupPluginAutoUpdate();
  }

  void _runStartupPluginAutoUpdate() {
    // _runStartupPluginAutoUpdate 在 warmup 完成后调用，此时 context 有效。
    runPluginAutoUpdateOnStartup(
      ProviderScope.containerOf(context),
      (message) => AppLogger.instance.log('plugin', message),
    );
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 该 Stack 位于 MaterialApp 之上，无 Directionality 祖先，需显式提供文本方向
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Stack(
        children: [
          widget.child,

          // 离屏预热沙盒（隐藏在全屏加载页后）
          // 页面在 MaterialApp 之外渲染，需提供完整应用上下文（Directionality/MediaQuery/Theme/Localizations）
          if (!_warmedUp)
            Positioned.fill(
              child: TickerMode(
                enabled: true,
                child: IgnorePointer(
                  child: Opacity(
                    opacity: 0.001,
                    child: MaterialApp(
                      debugShowCheckedModeBanner: false,
                      // 预热沙盒会构建全部页面，需与真实应用一致提供本地化，
                      // 否则依赖 Localizations 的页面在预热即崩溃。
                      localizationsDelegates: const [
                        AppLocalizations.delegate,
                        GlobalMaterialLocalizations.delegate,
                        GlobalWidgetsLocalizations.delegate,
                        GlobalCupertinoLocalizations.delegate,
                      ],
                      supportedLocales: AppLocalizations.supportedLocales,
                      home: Scaffold(
                        body: SingleChildScrollView(
                          physics: const NeverScrollableScrollPhysics(),
                          child: SizedBox(
                            width: 400,
                            height: 800,
                            child: Stack(
                              children: const [
                                HomePage(),
                                LibraryPage(),
                                PlayerPage(),
                                AccountPage(),
                                SettingsPage(),
                                FavoritesPage(),
                                RecentPage(),
                                SearchPage(),
                                EffectsPage(),
                                MusicSourcesPage(),
                                ScanFoldersPage(),
                                ToolbarSettingsPage(),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
