import 'package:flutter/material.dart';

import '../../src/navigation/shell.dart';

class RecentPage extends StatelessWidget {
  const RecentPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const HideShellChrome(
      child: Scaffold(
        appBar: _RecentAppBar(),
        // 底栏在二级页面已隐藏，无需额外底部避让。
        body: Center(child: Text('暂无播放记录')),
      ),
    );
  }
}

/// 顶栏抽出为常量组件，使外层可用 const 构造。
class _RecentAppBar extends StatelessWidget implements PreferredSizeWidget {
  const _RecentAppBar();

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    return AppBar(title: const Text('最近播放'));
  }
}
