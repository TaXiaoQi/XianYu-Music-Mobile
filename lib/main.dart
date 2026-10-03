import 'dart:async';
import 'dart:ui';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'app.dart';
import 'src/core/app_logger.dart';
import 'src/core/application_logger.dart';
import 'src/core/platform_caps.dart';
import 'src/core/rust_init.dart';
import 'src/core/settings.dart';
import 'src/player/cast_provider.dart';
import 'src/plugin/plugin_updates.dart';
import 'src/plugin/fallback_modules/sync.dart';
import 'src/auth/account_api.dart';
import 'src/player/ios_widget_bridge.dart';
import 'src/player/player_provider.dart';
import 'src/player/player_widget_bridge.dart';
import 'src/deeplink/deep_link_handler.dart';
import 'src/lyrics/floating_lyrics.dart';
import 'src/lyrics/status_bar_lyrics.dart';
import 'src/navigation/routes.dart';
import 'src/watch_link/watch_link_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final imageCache = PaintingBinding.instance.imageCache;
  imageCache.maximumSize = 800;
  imageCache.maximumSizeBytes = 120 << 20;
  final container = ProviderContainer();
  ApplicationLogManager.instance.bootstrap();
  WidgetsBinding.instance
      .addObserver(AppLogLifecycleObserver());
  WidgetsBinding.instance
      .addObserver(AppLogBackGestureObserver());
  BackGestureNativeBridge.init();
  _installErrorReporting(container);
  AppLog.info('startup', '应用启动（main 开始）');

  container.read(rustInitProvider);

  unawaited(LiquidGlassWidgets.initialize().catchError((Object _) {}));

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

  XianYuDeepLink.init(container, appRouter);

  if (PlatformCaps.supportsFloatingLyrics) {
    container.read(floatingLyricsControllerProvider).init();
  }

  if (PlatformCaps.supportsStatusBarLyrics) {
    container.read(statusBarLyricsControllerProvider).init();
  }

  if (PlatformCaps.supportsHomeWidgets) {
    container.read(playerWidgetControllerProvider).init();
  }

  if (PlatformCaps.supportsLiveActivity) {
    container.read(iosWidgetControllerProvider).init();
  }

  if (PlatformCaps.isAndroid) {
    container.read(watchLinkControllerProvider).init();
  }

  final t0 = Stopwatch()..start();
  WidgetsBinding.instance.addPostFrameCallback((_) {
    final ms = t0.elapsedMilliseconds;
    AppLog.info('startup', '首帧渲染完成 ${ms}ms（从 main 起算）');
  });

  unawaited(
    AudioService.init(
      builder: () => XianYuAudioHandler(),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'cc.xymusic.mobile.channel.audio',
        androidNotificationChannelName: '弦予音乐播放控制',
        androidNotificationOngoing: false,
        androidStopForegroundOnPause: false,
        androidNotificationIcon: 'drawable/ic_notification',
        // 不设 artDownscaleWidth/Height：锁屏/通知封面按原图解码（原生侧 -1），
        // 512 降采样在系统音乐锁屏全屏放大后明显模糊
        androidNotificationClickStartsActivity: true,
      ),
    ).then((h) {
      audioHandler = h;
      final notifier = activePlayerNotifier;
      if (notifier != null) h.bindNotifier(notifier);
      AppLog.info('startup', 'AudioService 初始化完成');
    }, onError: (Object e, StackTrace st) {
      AppLog.error('startup', 'AudioService 初始化失败: $e\n$st');
    }),
  );
}

void _installErrorReporting(ProviderContainer container) {
  var reportingError = false;
  FlutterError.onError = (details) {
    if (reportingError) return;
    reportingError = true;
    scheduleMicrotask(() => reportingError = false);
    final msg = details.exceptionAsString();
    final stack = details.stack?.toString() ?? '';
    AppLogger.instance
        .log('fatal', '未捕获异常: $msg\n$stack');
    AppLog.fatal('flutter', '$msg\n$stack');
    FlutterError.presentError(details);
    try {
      container.read(accountApiProvider).reportError(
            errorType: 'flutter',
            errorMessage: msg,
            errorStack: stack,
            page: 'global',
          );
    } catch (e) {
      AppLog.warn('startup', '错误上报失败: $e');
    }
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    if (reportingError) return true;
    reportingError = true;
    scheduleMicrotask(() => reportingError = false);
    AppLogger.instance
        .log('fatal', '平台异常: $error\n$stack');
    AppLog.fatal('platform', '$error\n$stack');
    try {
      container.read(accountApiProvider).reportError(
            errorType: 'platform',
            errorMessage: error.toString(),
            errorStack: stack.toString(),
            page: 'global',
          );
    } catch (e) {
      AppLog.warn('startup', '错误上报失败: $e');
    }
    return true;
  };
}

class AppWarmupRunner extends ConsumerStatefulWidget {
  const AppWarmupRunner({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<AppWarmupRunner> createState() => _AppWarmupRunnerState();
}

class _AppWarmupRunnerState extends ConsumerState<AppWarmupRunner> {
  @override
  void initState() {
    super.initState();

    ref.listenManual(rustInitProvider, (prev, next) {
      if (next.hasValue || next.hasError) _runStartupPluginAutoUpdate();
      // Rust 就绪后挂载兜底模块同步（验签/load 依赖桥）
      if (next.hasValue) {
        initFallbackModuleSync(ProviderScope.containerOf(context));
      }
    });

    ref.listenManual(settingsProvider, (prev, next) {
      if (next.hasValue) {
        final container = ProviderScope.containerOf(context);
        unawaited(container
            .read(dlnaCastProvider.notifier)
            .applyRendererSetting());
      }
    });
  }

  void _runStartupPluginAutoUpdate() {
    runPluginAutoUpdateOnStartup(
      ProviderScope.containerOf(context),
      (message) => AppLogger.instance.log('plugin', message),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
