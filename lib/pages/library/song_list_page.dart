import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/library/library_provider.dart';
import '../../src/core/app_colors.dart';
import '../../src/core/settings.dart';
import '../../src/navigation/shell.dart';
import '../../src/widgets/glass_appbar.dart';
import '../../src/widgets/song_list_view.dart';
import '../../src/i18n/i18n.dart';

/// 歌曲列表详情页：用于歌手/专辑/文件夹的下钻浏览。
class SongListPage extends ConsumerWidget {
  final String title;
  final Future<List<Song>> Function() loader;
  const SongListPage({super.key, required this.title, required this.loader});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 竖屏悬浮顶栏：顶栏自动换装玻璃胶囊组，列表铺满全屏、滚动时从顶栏
    // 下方穿过（穿透观感）；固定模式沿用原 Padding 避让结构。
    final floating = MediaQuery.of(context).orientation != Orientation.landscape &&
        (ref.watch(settingsProvider
                .select((s) => s.valueOrNull?.floatingSearchBar ?? false)) ==
            true);
    return HideShellChrome(
      child: Scaffold(
      backgroundColor: appScaffoldBackground(context, ref),
      body: Stack(
        children: [
          if (floating)
            Positioned.fill(child: _body(ref, contentTop: GlassTopBar.height(context) + 6))
          else
            Padding(
              padding: EdgeInsets.only(top: GlassTopBar.height(context)),
              child: _body(ref),
            ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: GlassTopBar(
              leading: const BackButton(),
              title: Text(title),
            ),
          ),
        ],
      ),
      ),
    );
  }

  /// 列表主体。[contentTop]=悬浮模式避让量（注入列表 padding.top，内容
  /// 穿透顶栏）；null=固定模式，列表用默认 padding（MediaQuery 安全区）。
  Widget _body(WidgetRef ref, {double? contentTop}) {
    return FutureBuilder<List<Song>>(
      future: loader(),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return Center(
            child: Text(tr('加载失败：{e}', {'e': snap.error.toString()})),
          );
        }
        final songs = snap.data ?? const <Song>[];
        return SongsListView(
          songs: songs,
          enableScrollFabs: true,
          padding: contentTop == null
              ? null
              : EdgeInsets.only(
                  top: contentTop,
                  bottom: MediaQuery.paddingOf(context).bottom,
                ),
          onPlay: (list, i) =>
              ref.read(libraryProvider.notifier).playList(list, i),
        );
      },
    );
  }
}