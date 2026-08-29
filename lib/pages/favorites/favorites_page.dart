import 'package:xianyu_music_mobile/src/widgets/predictive_dialog_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../src/favorites/favorites_provider.dart';
import '../../src/core/app_colors.dart';
import '../../src/navigation/shell.dart';
import '../../src/player/player_provider.dart';
import '../../src/plugin/plugin_provider.dart';
import '../../src/widgets/bottom_play_bar_slot.dart';
import '../../src/widgets/cover_image.dart';
import '../../src/widgets/drag_handle.dart';
import '../../src/widgets/flying_cover.dart';
import '../../src/widgets/glass_appbar.dart';
import '../../src/widgets/list_metrics.dart';
import '../../src/widgets/online_cover.dart';
import '../../src/widgets/song_list_view.dart';
import '../home/online_detail_page.dart';
import '../../src/i18n/i18n.dart';

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
    // 面板模式下隐藏本页顶部 GlassTopBar（由外层横屏胶囊顶栏占位）。
    final inMusicPane = ref.watch(landscapeLibraryProvider) != null;
    final notifier = ref.read(favoritesProvider.notifier);
    final tabBar = TabBar(
      controller: _tab,
      onTap: (_) => setState(() {}),
      tabs:   [
        Tab(text: tr('单曲')),
        Tab(text: tr('歌单')),
        Tab(text: tr('专辑')),
      ],
    );

    return HideShellChrome(
      child: Scaffold(
        backgroundColor: appScaffoldBackground(context, ref),
        body: Stack(
          children: [
            Padding(
              // 面板模式下仍保留 TabBar，故内容顶部始终按顶栏高度（含 TabBar）避让。
              padding: EdgeInsets.only(
                top: GlassTopBar.height(context, bottom: tabBar),
              ),
              child: fav.loading
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
            // 面板模式下保留 TabBar，仅去掉 leading / title / actions。
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: GlassTopBar(
                leading: inMusicPane ? null : const BackButton(),
                title: inMusicPane ? null : Text(tr('收藏')),
                actions: inMusicPane
                    ? null
                    : [
                        if (fav.entries.isNotEmpty && _tab.index == 0)
                          IconButton(
                            icon: const Icon(Icons.delete_sweep_outlined),
                            tooltip: tr('清空'),
                            onPressed: () => _confirmClear(context, notifier),
                          ),
                      ],
                bottom: tabBar,
              ),
            ),
            // 统一播放条由外壳承载：横屏面板模式下不渲染页内嵌条。
            if (!inMusicPane) const BottomPlayBarSlot(),
          ],
        ),
      ),
    );
  }

  void _confirmClear(BuildContext context, FavoritesManager notifier) {
    showPredictiveDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title:   Text(tr('清空收藏')),
        content:   Text(tr('确定要清空全部收藏歌曲吗？收藏的歌单与专辑不受影响。')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child:   Text(tr('取消')),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              notifier.clear();
            },
            child:   Text(tr('清空')),
          ),
        ],
      ),
    );
  }
}

/// 单曲收藏列表：长按行首把手可拖动排序（顶级列表，拖到边缘自动滚动）。
class _SongsTab extends ConsumerWidget {
  const _SongsTab({
    required this.fav,
    required this.notifier,
  });

  final FavoritesState fav;
  final FavoritesManager notifier;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final hasSong = ref.watch(playerProvider.select((s) => s.current != null));
    final entries = fav.entries;
    if (entries.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.favorite_border,
                size: 48,
                color: scheme.onSurface.withValues(alpha: 0.25)),
            const SizedBox(height: 12),
            Text(
              tr('暂无收藏歌曲'),
              style:
                  TextStyle(fontSize: 14, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }

    void onReorder(int oldIndex, int newIndex) {
      if (newIndex < 0 || newIndex >= entries.length || newIndex == oldIndex) return;
      final paths = entries.map((e) => e.path).toList();
      final moved = paths.removeAt(oldIndex);
      // onReorderItem 的 newIndex 已随移除项调整，直接作为目标下标。
      paths.insert(newIndex.clamp(0, paths.length), moved);
      notifier.reorderEntries(paths);
    }

    return ReorderableListView.builder(
      padding: EdgeInsets.only(
        bottom: (hasSong ? 92.0 : 24.0) +
            MediaQuery.of(context).padding.bottom,
      ),
      buildDefaultDragHandles: false,
      // 拖动 proxy 处于根 Overlay 下（无 Material 祖先），行内 InkWell 会以
      // debugCheckHasMaterial 报错；补一层透明 Material 提供水波纹上下文。
      proxyDecorator: (child, index, animation) =>
          Material(type: MaterialType.transparency, child: child),
      itemCount: entries.length,
      onReorderItem: onReorder,
      itemBuilder: (context, i) {
        final entry = entries[i];
        return RepaintBoundary(
          key: ValueKey(entry.path),
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 44),
                child: _FavoriteTile(
                  entry: entry,
                  onPlay: () => notifier.play(i),
                  onRemove: () => notifier.remove(entry.path),
                ),
              ),
              Positioned(
                left: 8,
                top: 0,
                bottom: 0,
                width: 36,
                child: Center(child: DragHandle(index: i)),
              ),
            ],
          ),
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
  });

  final FavoritesState fav;
  final String kind;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final hasSong = ref.watch(playerProvider.select((s) => s.current != null));
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
              kind == 'album' ? tr('暂无收藏专辑') : tr('暂无收藏歌单'),
              style:
                  TextStyle(fontSize: 14, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            Text(
              tr('在在线详情页点击收藏按钮'),
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
        bottom: (hasSong ? 92.0 : 24.0) +
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
            tooltip: tr('取消收藏'),
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
          tooltip: tr('取消收藏'),
          onPressed: onRemove,
        ),
      ),
    );
  }
}
