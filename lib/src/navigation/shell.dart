import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../notifications/notification_service.dart';
import '../sync/auto_sync.dart';
import '../widgets/mini_player_bar.dart';
import 'routes.dart';

/// 底部悬浮导航栏占位高度（页面底部避让用，含底栏自身高度与底部间距）。
final navBarInsetProvider = Provider<double>((ref) => 78);

/// 二级页面混入标记：这些页面以全屏路由压入，外壳控件天然被覆盖。
mixin HidesShellChrome<T extends StatefulWidget> on State<T> {}

/// 隐藏外壳悬浮控件（迷你播放器/底栏）的包装。
/// 这些页面以全屏路由压入，外壳控件天然被覆盖，此包装仅作语义标记。
class HideShellChrome extends StatelessWidget {
  const HideShellChrome({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// 主外壳：浮动迷你播放器 + 液态玻璃底栏，叠加在页面内容之上。
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  bool _notificationsChecked = false;

  @override
  void initState() {
    super.initState();
    // 启动自动同步调度器（每分钟 tick，到点才同步）。
    ref.read(autoSyncProvider).start();
    // 首帧后检查公告/反馈完成通知，避免与启动动画冲突。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_notificationsChecked) return;
      _notificationsChecked = true;
      ref
          .read(notificationServiceProvider)
          .checkOnStartup(context)
          .catchError((_) {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final index = widget.navigationShell.currentIndex;
    return Scaffold(
      body: Stack(
        children: [
          widget.navigationShell,
          Positioned(
            left: 14,
            right: 14,
            bottom: 82,
            child: MiniPlayerBar(),
          ),
          Positioned(
            left: 18,
            right: 18,
            bottom: 18,
            child: _LiquidNavBar(
              index: index,
              onSelect: (i) => widget.navigationShell.goBranch(
                i,
                initialLocation: i == index,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 液态玻璃底栏：毛玻璃胶囊 + 选中态红色 + 圆点指示。
class _LiquidNavBar extends StatelessWidget {
  const _LiquidNavBar({required this.index, required this.onSelect});

  final int index;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
        child: Container(
          height: 60,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.4),
                blurRadius: 26,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            children: [
              for (var i = 0; i < bottomNavItems.length; i++)
                Expanded(
                  child: _NavTab(
                    item: bottomNavItems[i],
                    selected: i == index,
                    onTap: () => onSelect(i),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavTab extends StatelessWidget {
  const _NavTab({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final BottomNavItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = selected
        ? const Color(0xFFEC4141)
        : scheme.onSurfaceVariant.withValues(alpha: 0.6);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(item.icon, size: 22, color: color),
          const SizedBox(height: 3),
          Text(
            item.title,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            margin: const EdgeInsets.only(top: 2),
            width: selected ? 4 : 0,
            height: 4,
            decoration: const BoxDecoration(
              color: Color(0xFFEC4141),
              shape: BoxShape.circle,
            ),
          ),
        ],
      ),
    );
  }
}
