import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/library/library_provider.dart';
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
    return HideShellChrome(
      child: Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          Padding(
            padding: EdgeInsets.only(top: GlassTopBar.height(context)),
            child: FutureBuilder<List<Song>>(
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
                  onPlay: (list, i) =>
                      ref.read(libraryProvider.notifier).playList(list, i),
                );
              },
            ),
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
}