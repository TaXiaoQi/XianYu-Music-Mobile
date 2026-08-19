import 'package:flutter/material.dart';

class RecentPage extends StatelessWidget {
  const RecentPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('最近播放')),
      body: const Padding(
        padding: EdgeInsets.only(bottom: 150),
        child: Center(child: Text('暂无播放记录')),
      ),
    );
  }
}
