import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/library/library_provider.dart';
import '../../src/widgets/song_list_view.dart';

/// 歌曲列表详情页：用于歌手/专辑/文件夹的下钻浏览。
class SongListPage extends ConsumerWidget {
  final String title;
  final Future<List<Song>> Function() loader;
  const SongListPage({super.key, required this.title, required this.loader});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: FutureBuilder<List<Song>>(
        future: loader(),
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(
              child: Text('加载失败：${snap.error}'),
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
    );
  }
}