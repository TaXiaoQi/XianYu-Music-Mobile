import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../player/player_provider.dart';
import 'mini_player_bar.dart';

/// 底部播放条插槽：仅当存在当前歌曲时显示 [MiniPlayerBar]。
///
/// 独立订阅播放状态，使「有歌/无歌」翻转只触发本插槽重建，
/// 不波及承载它的整页（Header/列表）重建。
class BottomPlayBarSlot extends ConsumerWidget {
  const BottomPlayBarSlot({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasSong = ref.watch(playerProvider.select((s) => s.current != null));
    if (!hasSong) return const SizedBox.shrink();
    return const MiniPlayerBar();
  }
}