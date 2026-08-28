import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/i18n/i18n.dart';
import '../../src/player/player_provider.dart';
import '../../src/share/share_sheet.dart';
import '../../src/widgets/app_toast.dart';

/// 桌面组件「分享」钮的桥接页。
///
/// 深链处理器只持有 [ProviderContainer]，而分享弹窗 [showSongShareSheet] 需要
/// [WidgetRef]，因此借一个瞬时页面，在其 initState 弹出当前歌曲的分享菜单，
/// 菜单关闭后自动返回（pop），用户几乎感知不到它存在。
class SongShareBridgePage extends ConsumerStatefulWidget {
  const SongShareBridgePage({super.key});

  @override
  ConsumerState<SongShareBridgePage> createState() =>
      _SongShareBridgePageState();
}

class _SongShareBridgePageState extends ConsumerState<SongShareBridgePage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _open());
  }

  Future<void> _open() async {
    final cur = ref.read(playerProvider).current;
    final ctx = context;
    if (cur == null) {
      if (ctx.mounted) {
        showXianYuToastByOverlay(
          Overlay.of(ctx, rootOverlay: true),
          tr('暂未播放歌曲'),
        );
      }
      if (mounted) Navigator.of(context).pop();
      return;
    }
    await showSongShareSheet(context, ref: ref, song: cur);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}