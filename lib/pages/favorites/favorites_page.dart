import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/favorites/favorites_provider.dart';
import '../../src/library/library_provider.dart';
import '../../src/widgets/song_list_view.dart';

/// 收藏页：展示已收藏的歌曲，点击即播放整个收藏列表。
class FavoritesPage extends ConsumerWidget {
  const FavoritesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final favPaths = ref.watch(favoritesProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('收藏')),
      body: Padding(
        padding: const EdgeInsets.only(bottom: 150),
        child: favPaths.isEmpty
            ? const Center(child: Text('暂无收藏'))
            : FutureBuilder<List<Song>>(
                // 收藏集合变化时重新查询。
                key: ValueKey(favPaths.length),
                future: ref
                    .read(libraryProvider.notifier)
                    .songsByPaths(favPaths.toList()),
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snap.hasError) {
                    return Center(child: Text('加载失败：${snap.error}'));
                  }
                  final songs = snap.data ?? const <Song>[];
                  if (songs.isEmpty) {
                    return const Center(child: Text('收藏的歌曲已不在音乐库中'));
                  }
                  return SongsListView(
                    songs: songs,
                    onPlay: (list, i) =>
                        ref.read(libraryProvider.notifier).playList(list, i),
                  );
                },
              ),
      ),
    );
  }
}
