import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../player/player_provider.dart';
import 'mini_player_bar.dart';

class BottomPlayBarSlot extends ConsumerWidget {
  const BottomPlayBarSlot({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasSong = ref.watch(playerProvider.select((s) => s.current != null));
    if (!hasSong) return const SizedBox.shrink();
    return const MiniPlayerBar();
  }
}