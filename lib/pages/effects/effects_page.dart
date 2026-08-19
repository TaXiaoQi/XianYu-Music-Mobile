import 'package:flutter/material.dart';

/// 音效页：占位，后续接入 Rust DSP 音效链。
class EffectsPage extends StatelessWidget {
  const EffectsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('音效')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.graphic_eq, size: 48, color: scheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(
              '音效功能开发中',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
