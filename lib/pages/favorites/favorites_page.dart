import 'package:flutter/material.dart';

import '../../src/widgets/mini_player_bar.dart';

class FavoritesPage extends StatelessWidget {
  const FavoritesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('收藏')),
      body: Column(
        children: [
          const Expanded(child: Center(child: Text('暂无收藏'))),
          const MiniPlayerBar(),
        ],
      ),
    );
  }
}