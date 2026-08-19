import 'package:flutter/material.dart';

class FavoritesPage extends StatelessWidget {
  const FavoritesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('收藏')),
      body: const Padding(
        padding: EdgeInsets.only(bottom: 150),
        child: Center(child: Text('暂无收藏')),
      ),
    );
  }
}
