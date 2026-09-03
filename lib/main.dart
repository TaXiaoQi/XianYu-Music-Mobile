import 'dart:async';
import 'dart:ui';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'app.dart';
import 'src/core/app_logger.dart';
import 'src/core/application_logger.dart';
import 'src/core/rust_init.dart';
import 'src/core/settings.dart';
import 'src/player/cast_provider.dart';
import 'src/plugin/plugin_updates.dart';
import 'src/auth/account_api.dart';
import 'src/player/player_provider.dart';
import 'src/player/player_widget_bridge.dart';
import 'src/deeplink/deep_link_handler.dart';
import 'src/lyrics/floating_lyrics.dart';
import 'src/lyrics/status_bar_lyrics.dart';
import 'src/navigation/routes.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 封面/头像已按显示尺寸低清解码（单张很小），放宽条目数、收紧字节上限，
  // 让缓存多装小图、少触发整块 GC 造成的滚动/翻页卡顿。
  final imageCache = PaintingBinding.instance.imageCache;
  imageCache.maximumSize = 800;
  imageCache.maximumSizeBytes = 120 << 20;
  final container = ProviderContainer();
  // 通用应用日志：加载历史 + 挂生命周期观察者 + 安装全局错误捕获。
  ApplicationLogManager.instance.bootstrap();
  WidgetsBinding.instance
      .addObserver(AppLogLifecycleObserver());
  _installErrorReporting(container);
  AppLog.info('startup', '应用启动（main 开始）');

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

  // 挂载 xianyu:// 深链监听，让分享落地页能拉起本 App 并播放分享歌曲。
  XianYuDeepLink.init(container, appRouter);

  // 挂载悬浮歌词窗控制器：跟随设置与播放状态，向原生悬浮窗推送歌词/进度。
  container.read(floatingLyricsControllerProvider).init();

  // 挂载状态栏/通知栏歌词控制器：把当前歌词行推送成系统通知（蓝牙/锁屏展示）。
  container.read(statusBarLyricsControllerProvider).init();

  // 挂载桌面播放小组件桥：跟随播放状态写入组件数据，响应小组件按钮控制。
  container.read(playerWidgetControllerProvider).init();

  // 总体首帧计时（从 main 开始）
  final t0 = Stopwatch()..start();
  WidgetsBinding.instance.addPostFrameCallback((_) {
    final ms = t0.elapsedMilliseconds;
    AppLog.info('startup', '首帧渲染完成 ${ms}ms（从 main 起算）');
    debugPrint('[startup] first frame rendered in ${ms}ms (from main)');
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
    ).then((h) {
      audioHandler = h;
      // PlayerNotifier 通常先于 init 创建（首帧即触发 playerProvider），
      // 构造时 bindNotifier 落空——此处补绑，控制中心按键才能生效。
      final notifier = activePlayerNotifier;
      if (notifier != null) h.bindNotifier(notifier);
      AppLog.info('startup', 'AudioService 初始化完成');
    }, onError: (Object e, StackTrace st) {
      AppLog.error('startup', 'AudioService 初始化失败: $e\n$st');
    }),
  );
}

/// 全局错误上报（fire-and-forget，失败静默），与桌面端 main.ts 对齐。
///
/// 除上报远端外，同时写入本地诊断日志（AppLogger 常驻环形缓冲，
/// 开启「问题诊断」后导出的 txt 会包含崩溃堆栈），便于本地排查。
void _installErrorReporting(ProviderContainer container) {
  // 错误处理器自身一旦在“抛错→上报→再抛错”的同一波里被重入，会让
  // ApplicationLogManager 在 build 期同步换 state → 再 notify → 再抛，
  // 形成吞掉每帧、冻结触控的无限递归。用一个运行期标志抑制同波内的
  // 二次错误，下一个 microtask 再复位，仍保留对后续真实错误的正常上报。
  var reportingError = false;
  FlutterError.onError = (details) {
    if (reportingError) return;
    reportingError = true;
    scheduleMicrotask(() => reportingError = false);
    final msg = details.exceptionAsString();
    final stack = details.stack?.toString() ?? '';
    AppLogger.instance
        .log('fatal', '未捕获异常: $msg\n$stack');
    AppLog.error('fatal', '$msg\n$stack');
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
    if (reportingError) return true;
    reportingError = true;
    scheduleMicrotask(() => reportingError = false);
    AppLogger.instance
        .log('fatal', '平台异常: $error\n$stack');
    AppLog.error('platform', '$error\n$stack');
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

    // 设置加载完成后按设置恢复 DLNA 渲染器（接收端开机自启，幂等）。
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
