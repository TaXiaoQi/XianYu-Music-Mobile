import 'package:flutter/material.dart';

import '../library/library_provider.dart';

/// 通用歌曲列表：展示歌曲并支持点击播放。
class SongsListView extends StatelessWidget {
  final List<Song> songs;
  final Future<void> Function(List<Song> songs, int index)? onPlay;
  const SongsListView({super.key, required this.songs, this.onPlay});

  @override
  Widget build(BuildContext context) {
    if (songs.isEmpty) {
      return const Center(child: Text('暂无歌曲'));
    }
    return ListView.separated(
      itemCount: songs.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final s = songs[i];
        return ListTile(
          leading: SongCover(song: s),
          title: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            '${s.artist} · ${s.album}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Text(
            _fmt(s.duration),
            style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          onTap: () => onPlay?.call(songs, i),
        );
      },
    );
  }

  String _fmt(int s) {
    final m = s ~/ 60;
    final sec = s % 60;
    return '${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }
}

class SongCover extends StatelessWidget {
  const SongCover({super.key, required this.song});
  final Song song;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      alignment: Alignment.center,
      child: Icon(Icons.music_note,
          size: 20, color: Theme.of(context).colorScheme.onPrimaryContainer),
    );
  }
}