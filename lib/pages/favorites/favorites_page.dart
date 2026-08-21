import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/favorites/favorites_provider.dart';
import '../../src/navigation/shell.dart';
import '../../src/widgets/cover_image.dart';

/// 收藏页：展示已收藏的歌曲（本地 + 在线），点击即播放整个收藏列表。
class FavoritesPage extends ConsumerWidget {
  const FavoritesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fav = ref.watch(favoritesProvider);
    final notifier = ref.read(favoritesProvider.notifier);
    final scheme = Theme.of(context).colorScheme;

    return HideShellChrome(
      child: Scaffold(
        appBar: AppBar(
          title: const Text('收藏'),
          actions: [
            if (fav.entries.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.delete_sweep_outlined),
                tooltip: '清空',
                onPressed: () => _confirmClear(context, notifier),
              ),
          ],
        ),
        body: fav.loading
            ? const Center(child: CircularProgressIndicator())
            : fav.entries.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.favorite_border,
                            size: 48,
                            color: scheme.onSurface.withValues(alpha: 0.25)),
                        const SizedBox(height: 12),
                        Text(
                          '暂无收藏',
                          style: TextStyle(
                              fontSize: 14,
                              color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  )
                : ListView.separated(
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
                  ),
      ),
    );
  }

  void _confirmClear(BuildContext context, FavoritesManager notifier) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空收藏'),
        content: const Text('确定要清空全部收藏吗？'),
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

class _FavoriteTile extends StatelessWidget {
  const _FavoriteTile({
    required this.entry,
    required this.onPlay,
    required this.onRemove,
  });

  final FavoriteEntry entry;
  final VoidCallback onPlay;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: CoverImage(
        songPath: entry.path,
        networkUrl: entry.coverUrl,
        width: 44,
        height: 44,
        radius: 8,
        icon: Icons.music_note,
      ),
      title: Text(entry.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        entry.artist,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
      ),
      trailing: IconButton(
        icon: Icon(Icons.favorite, size: 20, color: const Color(0xFFEC4141)),
        tooltip: '取消收藏',
        onPressed: onRemove,
      ),
      onTap: onPlay,
    );
  }
}
