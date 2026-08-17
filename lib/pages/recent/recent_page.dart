import 'package:flutter/material.dart';

import '../../src/widgets/mini_player_bar.dart';

class RecentPage extends StatelessWidget {
  const RecentPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('最近播放')),
      body: Column(
        children: [
          const Expanded(child: Center(child: Text('暂无播放记录'))),
          const MiniPlayerBar(),
        ],
      ),
    );
  }
}