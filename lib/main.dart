import 'dart:async';
import 'dart:ui';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'app.dart';
import 'src/core/rust_init.dart';
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
void _installErrorReporting(ProviderContainer container) {
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    container.read(accountApiProvider).reportError(
          errorType: 'flutter',
          errorMessage: details.exceptionAsString(),
          errorStack: details.stack?.toString() ?? '',
          page: 'global',
        );
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    container.read(accountApiProvider).reportError(
          errorType: 'platform',
          errorMessage: error.toString(),
          errorStack: stack.toString(),
          page: 'global',
        );
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

class _AppWarmupRunnerState extends ConsumerState<AppWarmupRunner>
    with SingleTickerProviderStateMixin {
  bool _warmedUp = false;
  bool _minTimeElapsed = false;
  double _progress = 0.0;
  Timer? _timer;
  late final AnimationController _fadeController;
  late final Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeOutCubic,
    );

    // 启动平滑模拟进度条，涵盖预热过程
    _startProgressSimulation();

    // rust 初始化完成（无论成功/失败）后尝试结束启动页
    // initState 中只能使用 listenManual（listen 仅限 build 方法内）
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
      _progress = 1.0;
    });
    // 进度拉满后停留 150ms 然后平滑淡出全屏加载页
    Future.delayed(const Duration(milliseconds: 150), () {
      if (!mounted) return;
      _fadeController.forward().then((_) {
        if (mounted) {
          setState(() {
            _warmedUp = true;
          });
        }
      });
    });
  }

  void _startProgressSimulation() {
    _timer = Timer.periodic(const Duration(milliseconds: 30), (timer) {
      if (!mounted || _progress >= 0.92) {
        timer.cancel();
        return;
      }
      setState(() {
        _progress = (_progress + 0.035).clamp(0.0, 0.92);
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _fadeController.dispose();
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

          // 全屏启动加载遮罩界面：品牌 Logo "弦予音乐-移动端" + 动态进度条
          if (!_warmedUp)
            Positioned.fill(
              child: FadeTransition(
                opacity: Tween(begin: 1.0, end: 0.0).animate(_fadeAnimation),
                child: _FullSplashScreen(progress: _progress),
              ),
            ),
        ],
      ),
    );
  }
}

/// 全屏品牌 Splash 加载界面
class _FullSplashScreen extends StatelessWidget {
  const _FullSplashScreen({required this.progress});

  final double progress;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF141416), // 高质感深色沉浸背景
      child: SafeArea(
        child: Stack(
          children: [
            // 居中品牌 Logo 标识与标题
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 弦予品牌大图标 Logo
                  Container(
                    width: 88,
                    height: 88,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(0xFFEC4141), Color(0xFFFF6B6B)],
                      ),
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFFEC4141).withValues(alpha: 0.45),
                          blurRadius: 28,
                          offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.music_note_rounded,
                      color: Colors.white,
                      size: 48,
                    ),
                  ),
                  const SizedBox(height: 24),
                  // 主标题：弦予音乐-移动端
                  const Text(
                    '弦予音乐-移动端',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                      letterSpacing: 1.2,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '优雅 · 极致 · 纯粹',
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.white.withValues(alpha: 0.6),
                      letterSpacing: 3.0,
                    ),
                  ),
                ],
              ),
            ),

            // 底部加载进度条区域
            Positioned(
              left: 48,
              right: 48,
              bottom: 64,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 进度条文字百分比
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '正在预热界面与 Shader...',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.white.withValues(alpha: 0.7),
                        ),
                      ),
                      Text(
                        '${(progress * 100).toInt()}%',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFFEC4141),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  // 胶囊动态进度条
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: SizedBox(
                      height: 6,
                      child: LinearProgressIndicator(
                        value: progress,
                        backgroundColor: Colors.white.withValues(alpha: 0.12),
                        valueColor: const AlwaysStoppedAnimation<Color>(
                          Color(0xFFEC4141),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
