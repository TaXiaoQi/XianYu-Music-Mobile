import 'dart:async';
import 'dart:ui';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'app.dart';
import 'src/core/app_logger.dart';
import 'src/core/rust_init.dart';
import 'src/plugin/plugin_updates.dart';
import 'src/auth/account_api.dart';
import 'src/player/player_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final container = ProviderContainer();
  _installErrorReporting(container);

  // 尽早触发 rust 初始化（与首帧渲染并行），缩短「打开→可交互」的等待。
  container.read(rustInitProvider);

  // 液态玻璃 shader 预热改为后台，不再 await 阻塞首帧（秒开优先，预热随后完成）。
  // 液态玻璃为可选视觉增强，不可用时降级即可，不影响主功能。
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

  // 总体首帧计时（从 main 开始）
  final t0 = Stopwatch()..start();
  WidgetsBinding.instance.addPostFrameCallback((_) {
    debugPrint('[startup] first frame rendered in ${t0.elapsedMilliseconds}ms (from main)');
  });

  // 后台初始化系统 MediaSession / 控制中心音频服务，不阻塞首帧。
  // audioHandler 全链路已做空值保护（audioHandler?.xxx），init 完成前可安全降级。
  unawaited(
    AudioService.init(
      builder: () => XianYuAudioHandler(),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'cc.xymusic.mobile.channel.audio',
        androidNotificationChannelName: '弦予音乐播放控制',
        // 常驻媒体通知（暂停也在锁屏/通知栏可恢复），需要在通知栏显示为普通
        // 媒体卡片而非 ongoing 前台。audio_service 断言 ongoing 必须搭配
        // stopForegroundOnPause，故两者同为 false 以得到持久播放岛。
        androidNotificationOngoing: false,
        androidStopForegroundOnPause: false,
        androidNotificationIcon: 'drawable/ic_notification',
        artDownscaleWidth: 512,
        artDownscaleHeight: 512,
        androidNotificationClickStartsActivity: true,
      ),
    ).then(
      (h) => audioHandler = h,
      onError: (Object _, StackTrace _) {},
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

/// 轻量启动器：等待 rust 初始化完成后触发启动插件自动更新。
///
/// 原先的离屏「12 页预热沙盒」已在 Impeller 渲染器下判为多余：Impeller 引擎启动时
/// 即预编译自身 shader 集，不再有 Skia 时代"首次进入画面卡"的运行时编译卡顿；
/// 而该沙盒会在首帧后立刻于主线程全量构建 12 个页面，正好在用户刚看到首页时抢占
/// CPU/GPU，造成"打开后呆滞"的观感。冷启动实测（release 冷启 ≈3s，其中引擎占大头）
/// 也指向：不要拿启动帧做重活，因此这里移除沙盒，换取"点开即响应"。
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

    // rust 初始化完成（无论成功/失败）即触发启动插件自动更新。
    ref.listenManual(rustInitProvider, (prev, next) {
      if (next.hasValue || next.hasError) _runStartupPluginAutoUpdate();
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
