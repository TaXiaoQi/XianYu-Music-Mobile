import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'routes.dart';

/// 主外壳：底部导航 + 页面内容区。
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) {
    final index = navigationShell.currentIndex;
    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: SafeArea(
        child: NavigationBar(
          selectedIndex: index,
          onDestinationSelected: (i) {
            navigationShell.goBranch(i, initialLocation: i == index);
          },
          destinations: [
            for (final item in bottomNavItems)
              NavigationDestination(icon: Icon(item.icon), label: item.title),
          ],
        ),
      ),
    );
  }
}