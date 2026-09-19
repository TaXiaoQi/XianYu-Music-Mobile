import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/library/library_provider.dart';
import '../../src/core/app_colors.dart';
import '../../src/core/settings.dart';
import '../../src/widgets/glass_appbar.dart';
import '../../src/widgets/song_list_view.dart';
import '../../src/i18n/i18n.dart';

class SongListArgs {
  const SongListArgs({required this.title, required this.loader});
  final String title;
  final Future<List<Song>> Function() loader;
}

class SongListPage extends ConsumerWidget {
  final String title;
  final Future<List<Song>> Function() loader;
  const SongListPage({super.key, required this.title, required this.loader});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final floating = MediaQuery.of(context).orientation != Orientation.landscape &&
        (ref.watch(settingsProvider
                .select((s) => s.valueOrNull?.floatingSearchBar ?? false)) ==
            true);
    return Scaffold(
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
    );
  }

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