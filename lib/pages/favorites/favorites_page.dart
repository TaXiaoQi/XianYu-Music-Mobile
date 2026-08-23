import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../src/favorites/favorites_provider.dart';
import '../../src/navigation/shell.dart';
import '../../src/plugin/plugin_provider.dart';
import '../../src/widgets/cover_image.dart';
import '../../src/widgets/online_cover.dart';
import '../../src/widgets/song_list_view.dart';
import '../home/online_detail_page.dart';

/// 收藏页：单曲 / 歌单 / 专辑三 tab（对齐桌面）。
class FavoritesPage extends ConsumerStatefulWidget {
  const FavoritesPage({super.key});

  @override
  ConsumerState<FavoritesPage> createState() => _FavoritesPageState();
}

class _FavoritesPageState extends ConsumerState<FavoritesPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fav = ref.watch(favoritesProvider);
    final notifier = ref.read(favoritesProvider.notifier);

    return HideShellChrome(
      child: Scaffold(
        appBar: AppBar(
          title: const Text('收藏'),
          actions: [
            if (fav.entries.isNotEmpty && _tab.index == 0)
              IconButton(
                icon: const Icon(Icons.delete_sweep_outlined),
                tooltip: '清空',
                onPressed: () => _confirmClear(context, notifier),
              ),
          ],
          bottom: TabBar(
            controller: _tab,
            onTap: (_) => setState(() {}),
            tabs: const [
              Tab(text: '单曲'),
              Tab(text: '歌单'),
              Tab(text: '专辑'),
            ],
          ),
        ),
        body: fav.loading
            ? const Center(child: CircularProgressIndicator())
            : TabBarView(
                controller: _tab,
                children: [
                  _SongsTab(fav: fav, notifier: notifier),
                  _CollectionsTab(fav: fav, kind: 'playlist'),
                  _CollectionsTab(fav: fav, kind: 'album'),
                ],
              ),
      ),
    );
  }

  void _confirmClear(BuildContext context, FavoritesManager notifier) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空收藏'),
        content: const Text('确定要清空全部收藏歌曲吗？收藏的歌单与专辑不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              notifier.clear();
            },
            child: const Text('清空'),
          ),
        ],
      ),
    );
  }
}

/// 单曲收藏列表。
class _SongsTab extends StatelessWidget {
  const _SongsTab({required this.fav, required this.notifier});

  final FavoritesState fav;
  final FavoritesManager notifier;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (fav.entries.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.favorite_border,
                size: 48,
                color: scheme.onSurface.withValues(alpha: 0.25)),
            const SizedBox(height: 12),
            Text(
              '暂无收藏歌曲',
              style:
                  TextStyle(fontSize: 14, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: fav.entries.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final entry = fav.entries[i];
        return _FavoriteTile(
          entry: entry,
          onPlay: () => notifier.play(i),
          onRemove: () => notifier.remove(entry.path),
        );
      },
    );
  }
}

/// 歌单/专辑收藏列表（来自收藏集）。
class _CollectionsTab extends ConsumerWidget {
  const _CollectionsTab({required this.fav, required this.kind});

  final FavoritesState fav;
  final String kind;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final items =
        fav.collections.where((c) => c.kind == kind).toList();
    if (items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              kind == 'album'
                  ? Icons.album_outlined
                  : Icons.queue_music_outlined,
              size: 48,
              color: scheme.onSurface.withValues(alpha: 0.25),
            ),
            const SizedBox(height: 12),
            Text(
              kind == 'album' ? '暂无收藏专辑' : '暂无收藏歌单',
              style:
                  TextStyle(fontSize: 14, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            Text(
              '在在线详情页点击收藏按钮',
              style: TextStyle(
                  fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: items.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final c = items[i];
        final type = c.kind == 'album'
            ? OnlineDetailType.album
            : (c.kind == 'toplist'
                ? OnlineDetailType.toplist
                : OnlineDetailType.playlist);
        return ListTile(
          leading: OnlineCover(
            url: c.coverUrl,
            size: 48,
            radius: c.kind == 'album' ? 8 : 8,
          ),
          title: Text(c.title,
              maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            [
              if (c.subtitle.isNotEmpty) c.subtitle,
              _pluginName(ref, c.pluginId),
            ].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          trailing: IconButton(
            icon: Icon(Icons.favorite, size: 20, color: const Color(0xFFEC4141)),
            tooltip: '取消收藏',
            onPressed: () => ref.read(favoritesProvider.notifier).toggleCollection(
                  kind: c.kind,
                  pluginId: c.pluginId,
                  title: c.title,
                  subtitle: c.subtitle,
                  coverUrl: c.coverUrl,
                  raw: c.raw,
                ),
          ),
          onTap: () => context.push('/online-detail', extra: OnlineDetailArgs(
                type: type,
                pluginId: c.pluginId,
                title: c.title,
                subtitle: c.subtitle,
                coverUrl: c.coverUrl,
                raw: c.raw,
              )),
        );
      },
    );
  }

  String _pluginName(WidgetRef ref, String id) {
    final source = ref
        .read(pluginManagerProvider)
        .sources
        .where((s) => s.id == id)
        .firstOrNull;
    return source?.name ?? '';
  }
}

class _FavoriteTile extends ConsumerWidget {
  const _FavoriteTile({
    required this.entry,
    required this.onPlay,
    required this.onRemove,
  });

  final FavoriteEntry entry;
  final VoidCallback onPlay;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return songRowPlayGesture(
      context,
      ref,
      ListTile(
        leading: CoverImage(
          songPath: entry.path,
          networkUrl: entry.coverUrl,
          width: 44,
          height: 44,
          radius: 8,
          icon: Icons.music_note,
        ),
        title: Text(entry.title,
            maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          entry.artist,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
        trailing: IconButton(
          icon: Icon(Icons.favorite,
              size: 20, color: const Color(0xFFEC4141)),
          tooltip: '取消收藏',
          onPressed: onRemove,
        ),
      ),
      onPlay: onPlay,
    );
  }
}
