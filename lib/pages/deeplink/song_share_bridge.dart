import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/i18n/i18n.dart';
import '../../src/player/player_provider.dart';
import '../../src/share/share_sheet.dart';
import '../../src/widgets/app_toast.dart';

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