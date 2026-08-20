import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../widgets/mini_player_bar.dart';
import 'routes.dart';

/// 浮动底栏占据的底部高度（距底 18 + 栏高 60 + 阴影余量）。
///
/// 底栏是叠在内容之上的 `Positioned`，不参与布局，`SafeArea` 也无法感知。
/// 弹窗、列表等需要避让它的地方统一引用此常量，改动底栏尺寸时只需改这里。
const double kFloatingNavBarInset = 90;

/// 请求隐藏底栏与迷你播放条的页面计数。
///
/// 二级页面（音源管理、扫描文件夹、歌曲列表等）不该被浮层遮挡，
/// 进入时 +1、离开时 -1；大于 0 时 shell 隐藏浮层。
/// 用计数而非布尔，以正确处理多层页面叠加。
final navBarHiddenProvider = StateProvider<int>((ref) => 0);

/// 让当前页面在显示期间隐藏 shell 浮层。
///
/// 用法：在页面 State 中混入本 mixin，无需手动管理计数。
mixin HidesShellChrome<T extends ConsumerStatefulWidget>
    on ConsumerState<T> {
  @override
  void initState() {
    super.initState();
    // 延后一帧，避免在 build 期间修改 provider。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(navBarHiddenProvider.notifier).state++;
    });
  }

  @override
  void dispose() {
    // 页面销毁时恢复；用 Future 规避 dispose 期间的状态修改限制。
    final notifier = ref.read(navBarHiddenProvider.notifier);
    Future.microtask(() {
      if (notifier.mounted && notifier.state > 0) notifier.state--;
    });
    super.dispose();
  }
}

/// 主外壳：浮动迷你播放器 + 液态玻璃底栏，叠加在页面内容之上。
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  DateTime? _lastBackTime;

  @override
  Widget build(BuildContext context) {
    final index = widget.navigationShell.currentIndex;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;

        // 1. 如果当前上下文内（包括内嵌的 Router/Navigator 或最外层 Router）有可 Pop 的路由，优先 Pop
        final router = GoRouter.of(context);
        if (router.canPop()) {
          router.pop();
          return;
        }

        // 2. 如果已在 Branch 根页面且不在“主界面”(index != 0)，返回“主界面” Tab
        if (index != 0) {
          widget.navigationShell.goBranch(0);
          return;
        }

        // 3. 如果已经在“主界面” Tab 根节点，提示“再按一次退出应用”
        final now = DateTime.now();
        if (_lastBackTime == null ||
            now.difference(_lastBackTime!) > const Duration(seconds: 2)) {
          _lastBackTime = now;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('再按一次退出应用'),
              duration: Duration(seconds: 2),
            ),
          );
          return;
        }

        // 4. 2秒内再次触发系统返回，顺畅退出程序
        SystemNavigator.pop();
      },
      child: Scaffold(
        body: Stack(
          children: [
            widget.navigationShell,
            // 二级页面（如音源管理、扫描文件夹、歌曲列表）隐藏底栏与播放条，
            // 避免浮层压住页面内容；由 _ShellOverlay 监听栈深自动切换。
            _ShellOverlay(
              index: index,
              onSelect: (i) => widget.navigationShell.goBranch(
                i,
                initialLocation: i == index,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 包装二级页面，使其显示期间隐藏 shell 浮层。
///
/// 供无状态页面（`ConsumerWidget` / `StatelessWidget`）使用；
/// 有状态页面可直接混入 [HidesShellChrome]。
///
/// 用法：`HideShellChrome(child: Scaffold(...))`
class HideShellChrome extends ConsumerStatefulWidget {
  const HideShellChrome({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<HideShellChrome> createState() => _HideShellChromeState();
}

class _HideShellChromeState extends ConsumerState<HideShellChrome>
    with HidesShellChrome {
  @override
  Widget build(BuildContext context) => widget.child;
}

/// shell 浮层：迷你播放条 + 液态玻璃底栏。
///
/// 有页面请求隐藏时整体淡出并让出手势，避免遮挡二级页面内容。
class _ShellOverlay extends ConsumerWidget {
  const _ShellOverlay({required this.index, required this.onSelect});

  final int index;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hidden = ref.watch(navBarHiddenProvider) > 0;

    return IgnorePointer(
      ignoring: hidden,
      child: AnimatedOpacity(
        opacity: hidden ? 0 : 1,
        duration: const Duration(milliseconds: 180),
        child: Stack(
          // 撑满父级，保证 Positioned 的定位基准与原实现一致。
          fit: StackFit.expand,
          children: [
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
              child: _LiquidNavBar(index: index, onSelect: onSelect),
            ),
          ],
        ),
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
