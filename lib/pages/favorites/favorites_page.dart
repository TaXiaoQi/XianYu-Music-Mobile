import 'package:xianyu_music_mobile/src/widgets/predictive_dialog_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../src/core/app_colors.dart';
import '../../src/favorites/favorites_provider.dart';
import '../../src/navigation/shell.dart';
import '../../src/player/player_provider.dart';
import '../../src/plugin/plugin_provider.dart';
import '../../src/widgets/cover_image.dart';
import '../../src/widgets/flying_cover.dart';
import '../../src/widgets/glass_appbar.dart';
import '../../src/widgets/list_metrics.dart';
import '../../src/widgets/mini_player_bar.dart';
import '../../src/widgets/online_cover.dart';
import '../../src/widgets/song_list_view.dart';
import '../home/online_detail_page.dart';

/// 收藏页：单曲 / 歌单 / 专辑三 tab（对齐桌面）。
class FavoritesPage extends ConsumerStatefulWidget {
  const FavoritesPage({super.key, this.initialTab = 0});

  /// 初始 Tab：0 单曲 / 1 歌单 / 2 专辑（「我的」页收藏歌单/专辑直达）。
  final int initialTab;

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
    _tab.index = widget.initialTab.clamp(0, 2);
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
    final hasSong = ref.watch(playerProvider.select((s) => s.current != null));
    final tabBar = TabBar(
      controller: _tab,
      onTap: (_) => setState(() {}),
      tabs: const [
        Tab(text: '单曲'),
        Tab(text: '歌单'),
        Tab(text: '专辑'),
      ],
    );

    return HideShellChrome(
      child: Scaffold(
        backgroundColor: appSurfaceBg(context),
        body: Stack(
          children: [
            Padding(
              padding: EdgeInsets.only(
                top: GlassTopBar.height(context, bottom: tabBar),
              ),
              child: fav.loading
                  ? const Center(child: CircularProgressIndicator())
                  : TabBarView(
                      controller: _tab,
                      children: [
                        _SongsTab(fav: fav, notifier: notifier, showPlayer: hasSong),
                        _CollectionsTab(fav: fav, kind: 'playlist', showPlayer: hasSong),
                        _CollectionsTab(fav: fav, kind: 'album', showPlayer: hasSong),
                      ],
                    ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: GlassTopBar(
                leading: const BackButton(),
                title: const Text('收藏'),
                actions: [
                  if (fav.entries.isNotEmpty && _tab.index == 0)
                    IconButton(
                      icon: const Icon(Icons.delete_sweep_outlined),
                      tooltip: '清空',
                      onPressed: () => _confirmClear(context, notifier),
                    ),
                ],
                bottom: tabBar,
              ),
            ),
            if (hasSong)
              const MiniPlayerBar(),
          ],
        ),
      ),
    );
  }

  void _confirmClear(BuildContext context, FavoritesManager notifier) {
    showPredictiveDialog<void>(
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
  const _SongsTab({
    required this.fav,
    required this.notifier,
    this.showPlayer = false,
  });

  final FavoritesState fav;
  final FavoritesManager notifier;
  final bool showPlayer;

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
    return ListView.builder(
      padding: EdgeInsets.only(
        bottom: (showPlayer ? 92.0 : 24.0) +
            MediaQuery.of(context).padding.bottom,
      ),
      itemCount: fav.entries.length,
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
  const _CollectionsTab({
    required this.fav,
    required this.kind,
    this.showPlayer = false,
  });

  final FavoritesState fav;
  final String kind;
  final bool showPlayer;

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
    final m = ListMetrics.ofRef(ref);
    return ListView.builder(
      padding: EdgeInsets.only(
        bottom: (showPlayer ? 92.0 : 24.0) +
            MediaQuery.of(context).padding.bottom,
      ),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final c = items[i];
        final type = c.kind == 'album'
            ? OnlineDetailType.album
            : (c.kind == 'toplist'
                ? OnlineDetailType.toplist
                : OnlineDetailType.playlist);
        return CoverRow(
          cover: OnlineCover(
            url: c.coverUrl,
            size: m.songCover,
            radius: m.songRadius,
          ),
          title: Text(
            c.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: m.titleSize, fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            [
              if (c.subtitle.isNotEmpty) c.subtitle,
              _pluginName(ref, c.pluginId),
            ].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: m.subtitleSize, color: scheme.onSurfaceVariant),
          ),
          verticalPadding: m.vPad,
          trailing: IconButton(
            icon: Icon(Icons.favorite,
                size: 20, color: scheme.primary),
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
          onTap: () => context.push(
              '/online-detail',
              extra: OnlineDetailArgs(
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
    final m = ListMetrics.ofRef(ref);
    // 捕获封面自身 context：飞封面直接取封面 RenderBox 的全局矩形，与列表封面像素级一致。
    BuildContext? coverCtx;
    final g = songRowPlay(ref, onPlay: () async {
      // 等封面落地后再播放：播放条封面随落地同步更新。
      final ok = await launchFlyCover(
        context,
        coverContext: coverCtx,
        coverSize: m.songCover,
        vPad: m.vPad,
        songPath: entry.path,
        networkUrl: entry.coverUrl,
        radius: m.songRadius,
      );
      if (ok) onPlay();
    });
    return g.wrap(
      CoverRow(
        cover: Builder(
          builder: (c) {
            coverCtx = c;
            return CoverImage(
              songPath: entry.path,
              networkUrl: entry.coverUrl,
              width: m.songCover,
              height: m.songCover,
              radius: m.songRadius,
              icon: Icons.music_note,
            );
          },
        ),
        onTap: g.onTap,
        title: Text(entry.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style:
                TextStyle(fontSize: m.titleSize, fontWeight: FontWeight.w600)),
        subtitle: Text(
          entry.artist,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style:
              TextStyle(fontSize: m.subtitleSize, color: scheme.onSurfaceVariant),
        ),
        verticalPadding: m.vPad,
        trailing: IconButton(
          icon: Icon(Icons.favorite,
              size: 20, color: scheme.primary),
          tooltip: '取消收藏',
          onPressed: onRemove,
        ),
      ),
    );
  }
}
