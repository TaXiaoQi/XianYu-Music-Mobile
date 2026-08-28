import 'dart:async';

import 'package:xianyu_music_mobile/src/widgets/predictive_dialog_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../src/auth/auth_provider.dart';
import '../../src/core/app_colors.dart';
import '../../src/download/download_provider.dart';
import '../../src/favorites/favorites_provider.dart';
import '../../src/library/library_provider.dart';
import '../../src/navigation/shell.dart';
import '../../src/plugin/plugin_provider.dart';
import '../../src/playlist/playlist_provider.dart';
import '../../src/playlist/playlist_store.dart';
import '../../src/recent/recent_provider.dart';
import '../../src/widgets/app_toast.dart';
import '../../src/widgets/cover_image.dart';
import '../../src/widgets/drag_handle.dart';
import '../../src/widgets/glass_appbar.dart';
import '../../src/widgets/online_cover.dart';
import '../../src/widgets/sheet_dialog.dart';
import '../../src/widgets/user_avatar.dart';
import '../home/online_detail_page.dart';
import '../../src/i18n/i18n.dart';

/// 「我的」页：搜索条 + 账号区 + 快捷入口四宫格（参考魅族音乐我的页布局）。
///
/// 音乐库、歌单、收藏等曲库浏览统一从快捷入口与首页网格分流进入；
/// 设置入口位于右上角（底栏已无设置 Tab）。
class MinePage extends ConsumerWidget {
  const MinePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      // 背景交给 Shell 层统一渲染（自定义壁纸/默认底色），页面自身保持透明以透出壁纸。
      backgroundColor: appScaffoldBackground(context, ref),
      resizeToAvoidBottomInset: false,
      body: RepaintBoundary(child: Stack(
        children: [
          ListView(
            padding: EdgeInsets.fromLTRB(
              16,
              GlassTopBar.height(context) + 10,
              16,
              ref.watch(navBarInsetProvider) + 24,
            ),
            children:   [
              _SearchEntry(),
              SizedBox(height: 18),
              _AccountArea(),
              SizedBox(height: 22),
              _QuickEntries(),
              SizedBox(height: 24),
              _MyPlaylistsSection(),
              _FavoriteCollectionsSection(kind: 'playlist', title: tr('收藏歌单')),
              _FavoriteCollectionsSection(kind: 'album', title: tr('收藏专辑')),
            ],
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: GlassTopBar(
              title:   Text(tr('我的')),
              actions: [
                IconButton(
                  icon: const Icon(Icons.settings_outlined),
                  tooltip: tr('设置'),
                  onPressed: () => context.push('/settings'),
                ),
              ],
            ),
          ),
        ],
        ),
      ),
    );
  }
}

/// 顶部搜索条：点击进入搜索页（参考图布局）。
class _SearchEntry extends ConsumerWidget {
  const _SearchEntry();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final glass = ref.watch(wallpaperActiveProvider);
    return Material(
      color: glass ? glassControlFill : appCardColor(context),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: () => context.push('/search'),
        borderRadius: BorderRadius.circular(999),
        child: Container(
          height: 42,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: glass
                  ? glassControlBorder
                  : scheme.outlineVariant.withValues(alpha: 0.3),
            ),
          ),
          child: Row(
            children: [
              Icon(Icons.search, size: 18, color: scheme.onSurfaceVariant),
              const SizedBox(width: 10),
              Text(
                tr('搜索歌曲、歌手、专辑'),
                style: TextStyle(
                  fontSize: 13.5,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 账号区：未登录时展示登录胶囊按钮（参考图布局），已登录展示头像卡片。
class _AccountArea extends ConsumerWidget {
  const _AccountArea();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final auth = ref.watch(authProvider);
    final glass = ref.watch(wallpaperActiveProvider);
    final user = auth.user;
    final loggedIn = auth.isLoggedIn && user != null;

    if (!loggedIn) {
      return Column(
        children: [
          const SizedBox(height: 6),
          Material(
            borderRadius: BorderRadius.circular(999),
            child: InkWell(
              onTap: () => context.push('/account'),
              borderRadius: BorderRadius.circular(999),
              child: Container(
                height: 52,
                padding: const EdgeInsets.symmetric(horizontal: 28),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFFEC4141), Color(0xFFFF6B6B)],
                  ),
                  borderRadius: BorderRadius.circular(999),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFFEC4141).withValues(alpha: 0.35),
                      blurRadius: 18,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      tr('登录弦予音乐账号'),
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: scheme.onPrimary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            tr('登录后同步你的歌单与设置'),
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ],
      );
    }

    return Material(
      color: glass ? glassControlFill : appCardColor(context),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: glass ? BorderSide(color: glassControlBorder) : BorderSide.none,
      ),
      child: InkWell(
        onTap: () => context.push('/account'),
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: scheme.primary,
                ),
                clipBehavior: Clip.antiAlias,
                child: user.avatar != null && user.avatar!.isNotEmpty
                    ? UserAvatarImage(
                        avatar: user.avatar,
                        fallback: _fallback(scheme, user.nickname),
                        size: 56,
                      )
                    : _fallback(scheme, user.nickname),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      user.nickname.isEmpty ? tr('未命名用户') : user.nickname,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      tr('管理账号与安全'),
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: () => context.push('/wallpaper'),
                icon: Icon(Icons.checkroom, color: scheme.outline),
                tooltip: tr('皮肤'),
                splashRadius: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _fallback(ColorScheme scheme, String nickname) {
    final char = nickname.isEmpty
        ? '?'
        : String.fromCharCode(nickname.runes.first);
    return Center(
      child: Text(
        char,
        style: TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.bold,
          color: scheme.onPrimary,
        ),
      ),
    );
  }
}

/// 快捷入口四宫格：喜欢 / 最近 / 本地 / 下载（参考图布局，图标带数量角标）。
class _QuickEntries extends ConsumerWidget {
  const _QuickEntries();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final glass = ref.watch(wallpaperActiveProvider);
    final favCount = ref.watch(
      favoritesProvider.select((s) => s.entries.length),
    );
    final recentCount = ref.watch(
      recentProvider.select((s) => s.entries.length),
    );
    final localCount = ref.watch(libraryProvider.select((s) => s.songs.length));
    final dl = ref.watch(downloadProvider);
    final dlCount =
        dl.tasks
            .where(
              (t) =>
                  t.status == DownloadStatus.waiting ||
                  t.status == DownloadStatus.downloading,
            )
            .length +
        dl.history.length;

    Widget entry({
      required IconData icon,
      required String label,
      required String count,
      required VoidCallback onTap,
    }) {
      return Expanded(
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.10),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, color: scheme.primary, size: 24),
                ),
                const SizedBox(height: 8),
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  count,
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Material(
      color: glass ? glassControlFill : appCardColor(context),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: glass ? BorderSide(color: glassControlBorder) : BorderSide.none,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            entry(
              icon: Icons.favorite_rounded,
              label: tr('喜欢'),
              count: '$favCount',
              onTap: () => context.push('/favorites'),
            ),
            entry(
              icon: Icons.history_rounded,
              label: tr('最近'),
              count: '$recentCount',
              onTap: () => context.push('/recent'),
            ),
            entry(
              icon: Icons.library_music_rounded,
              label: tr('本地'),
              count: '$localCount',
              onTap: () => context.push('/library?tab=0'),
            ),
            entry(
              icon: Icons.download_rounded,
              label: tr('下载'),
              count: '$dlCount',
              onTap: () => context.push('/download'),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 歌单 / 收藏分区（QQ 音乐样式：分区头「标题 数量」+ 右侧操作、封面式条目列表）
// ---------------------------------------------------------------------------

/// 分区头：左「标题 数量」，右操作（自建歌单带「新建」，收藏分区无）。
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.count, this.action});

  final String title;
  final int count;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
      child: Row(
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
          ),
          const SizedBox(width: 6),
          Text(
            '$count',
            style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
          ),
          const Spacer(),
          ?action,
        ],
      ),
    );
  }
}

/// 内嵌滚动条中的可拖动排序卡片（shrinkWrap + NeverScrollable，供外层 ListView 使用）。
/// 每项自带一条与封面-文字对齐的分隔线（末项除外），视觉对齐原 _CardGroup。
class _ReorderCard extends ConsumerWidget {
  const _ReorderCard({
    required this.itemCount,
    required this.onReorder,
    required this.itemKey,
    required this.itemBuilder,
  });

  final int itemCount;
  final ReorderCallback onReorder;

  /// 每项稳定身份 Key（对应条目 id/key），供拖拽框架追踪 & 隔离合成层。
  final Key Function(int index) itemKey;
  final IndexedWidgetBuilder itemBuilder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final glass = ref.watch(wallpaperActiveProvider);
    return Material(
      color: glass ? glassControlFill : appCardColor(context),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: glass ? BorderSide(color: glassControlBorder) : BorderSide.none,
      ),
      child: ReorderableListView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        buildDefaultDragHandles: false,
        itemCount: itemCount,
        onReorderItem: onReorder,
        // 拖动代理样式与正常条目保持一致（去掉默认拖拽阴影）。
        // 拖动 proxy 处于根 Overlay 下（无 Material 祖先），行内 InkWell/ListTile
        // 会以 debugCheckHasMaterial 报错；补一层透明 Material 提供水波纹上下文。
        proxyDecorator: (child, index, animation) =>
            Material(type: MaterialType.transparency, child: child),
        itemBuilder: (ctx, i) {
          final row = itemBuilder(ctx, i);
          final isLast = i == itemCount - 1;
          // ReorderableListView 不像 ListView 那样自动给子项加 RepaintBoundary：
          // 多条目时可见卡片每帧被整体重绘 → 抽帧。每项隔离为独立合成层后，
          // 滑动只搬运已有图层，不重绘内容。
          return RepaintBoundary(
            key: itemKey(i),
            child: Column(
              children: [
                row,
                if (!isLast)
                  Divider(
                    height: 1,
                    indent: 100,
                    endIndent: 12,
                    thickness: 0.5,
                    color: scheme.onSurface.withValues(alpha: 0.06),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// 自建歌单分区：头部带「+ 新建」；条目封面+名称+歌曲数；末尾「导入外部歌单」。
class _MyPlaylistsSection extends ConsumerWidget {
  const _MyPlaylistsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(playlistManagerProvider);
    final manager = ref.read(playlistManagerProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    final playlists = state.playlists;
    // 末尾固定「导入外部歌单」条目，不参与排序。
    final itemCount = playlists.length + 1;

    void onReorder(int oldIndex, int newIndex) {
      if (newIndex < 0 || newIndex >= itemCount || newIndex == oldIndex) return;
      // 仅允许在歌单条目间排序；末尾「导入」条目不可被移动。
      if (oldIndex >= playlists.length) return;
      final ids = playlists.map((p) => p.id).toList();
      final moved = ids.removeAt(oldIndex);
      // onReorderItem 的 newIndex 已随移除项调整，直接作为目标下标。
      ids.insert(newIndex.clamp(0, ids.length), moved);
      manager.reorder(ids);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(
          title: tr('自建歌单'),
          count: playlists.length,
          action: OutlinedButton.icon(
            onPressed: () => _promptCreate(context, manager),
            icon: const Icon(Icons.add, size: 15),
            label:   Text(tr('新建'), style: TextStyle(fontSize: 13)),
            style: OutlinedButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
              minimumSize: const Size(0, 32),
              side: BorderSide(
                color: scheme.outlineVariant.withValues(alpha: 0.6),
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
        ),
        _ReorderCard(
          itemCount: itemCount,
          onReorder: onReorder,
          itemKey: (i) => i < playlists.length
              ? ValueKey(playlists[i].id)
              : const ValueKey('import'),
          itemBuilder: (ctx, i) {
            if (i < playlists.length) {
              return _PlaylistRow(
                playlist: playlists[i],
                index: i,
                dragEnabled: true,
              );
            }
            return const _ImportPlaylistRow();
          },
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  Future<void> _promptCreate(
    BuildContext context,
    PlaylistManager manager,
  ) async {
    final name = await _promptPlaylistName(context, tr('新建歌单'));
    if (name == null || name.trim().isEmpty) return;
    await manager.create(name.trim());
    if (!context.mounted) return;
    showXianYuToast(context, tr('已创建歌单「{name}」', {'name': name.trim()}));
  }
}

/// 歌单名称输入弹窗（新建/重命名共用，不显示当前值）。
Future<String?> _promptPlaylistName(BuildContext context, String title) {
  final controller = TextEditingController();
  return showPredictiveDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        maxLength: 40,
        decoration:   InputDecoration(hintText: tr('歌单名称')),
        onSubmitted: (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child:   Text(tr('取消')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, controller.text),
          child:   Text(tr('确定')),
        ),
      ],
    ),
  );
}

/// 自建歌单条目：封面（取歌单第一首歌，无则占位）+ 名称 + 共N首歌。
/// 点击进详情；右侧菜单提供重命名/删除。
class _PlaylistRow extends ConsumerWidget {
  const _PlaylistRow({
    required this.playlist,
    required this.index,
    this.dragEnabled = true,
  });

  final ImportedPlaylist playlist;
  final int index;
  final bool dragEnabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final first = playlist.songs.firstOrNull;

    final row = InkWell(
      // 走 go_router 顶层路由压 root navigator，保证返回行为与 shell 一致，
      // 否则返回会被 shell 的 canPop 逻辑误判而直接退出程序。
      onTap: () => context.push('/playlist/${playlist.id}'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(6, 10, 6, 10),
        child: Row(
          children: [
            first == null
                ? Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: scheme.primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(Icons.queue_music,
                        color: scheme.primary, size: 24),
                  )
                : CoverImage(
                    songPath: first.path,
                    networkUrl: first.coverUrl,
                    thumbPath: first.coverThumbPath,
                    width: 56,
                    height: 56,
                    radius: 12,
                  ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    playlist.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    tr('共{n}首歌', {'n': playlist.songs.length}),
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              icon: Icon(Icons.more_vert, size: 20, color: scheme.outline),
              tooltip: tr('歌单操作'),
              onPressed: () => _sheetActions(context, ref),
            ),
          ],
        ),
      ),
    );
    // 整条即拖拽把手：长按任意处拖动排序，不再单独展示拖拽图标。
    return dragEnabled
        ? ReorderableRowDragStart(index: index, child: row)
        : row;
  }

  /// 操作菜单：重命名 / 删除歌单。
  void _sheetActions(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final manager = ref.read(playlistManagerProvider.notifier);

    showSheetDialog<void>(
      context,
      (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(
                  Icons.edit_outlined,
                  color: scheme.primary,
                  size: 22,
                ),
                title:   Text(tr('重命名歌单')),
                onTap: () async {
                  Navigator.pop(ctx);
                  final name = await _promptPlaylistName(context, tr('重命名歌单'));
                  if (name == null || name.trim().isEmpty) return;
                  await manager.rename(playlist.id, name.trim());
                },
              ),
              ListTile(
                leading: Icon(
                  Icons.delete_outline,
                  color: const Color(0xFFEC4141),
                  size: 22,
                ),
                title:   Text(tr('删除歌单')),
                onTap: () {
                  Navigator.pop(ctx);
                  _confirmRemove(context, manager);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _confirmRemove(BuildContext context, PlaylistManager manager) {
    showPredictiveDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title:   Text(tr('删除歌单')),
        content: Text(tr('确定要删除「{name}」吗？', {'name': playlist.name})),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child:   Text(tr('取消')),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              manager.remove(playlist.id);
            },
            child:   Text(tr('删除')),
          ),
        ],
      ),
    );
  }
}

/// 「导入外部歌单」特殊条目（参考图：功能型条目，与内容条目区分）。
class _ImportPlaylistRow extends StatelessWidget {
  const _ImportPlaylistRow();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return InkWell(
      onTap: () => context.push('/playlist-import'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(6, 10, 14, 10),
        child: Row(
          children: [
            // 可排序歌单行为整行长按拖拽，左侧并无常驻把手列，
            // 故与上方歌单行一致，封面直接贴着 6px 左边距，不留空缺。
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: scheme.onSurface.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                Icons.file_download_outlined,
                size: 26,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                    Text(
                    tr('导入外部歌单'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    tr('备份文件 / 本地文件夹 / 云端导入'),
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, size: 20, color: scheme.outline),
          ],
        ),
      ),
    );
  }
}

/// 收藏分区（收藏歌单 / 收藏专辑）：头部无操作按钮，条目点击进在线详情。
/// 无收藏时整个分区隐藏（对齐 QQ 音乐）。
class _FavoriteCollectionsSection extends ConsumerWidget {
  const _FavoriteCollectionsSection({required this.kind, required this.title});

  /// collection kind：playlist | album。
  final String kind;
  final String title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fav = ref.watch(favoritesProvider);
    final items = fav.collections.where((c) => c.kind == kind).toList();
    if (items.isEmpty) return const SizedBox.shrink();
    final manager = ref.read(favoritesProvider.notifier);

    void onReorder(int oldIndex, int newIndex) {
      if (newIndex < 0 || newIndex >= items.length || newIndex == oldIndex) return;
      final moved = items[oldIndex];
      final next = List.of(items)..removeAt(oldIndex);
      // onReorderItem 的 newIndex 已随移除项调整，直接作为目标下标。
      next.insert(newIndex.clamp(0, next.length), moved);
      manager.reorderCollections(next.map((c) => c.key).toList());
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(title: title, count: items.length),
        _ReorderCard(
          itemCount: items.length,
          onReorder: onReorder,
          itemKey: (i) => ValueKey(items[i].key),
          itemBuilder: (ctx, i) => _CollectionRow(
            collection: items[i],
            index: i,
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

/// 收藏条目：在线封面 + 标题 + 来源副标题，右侧取消收藏。
class _CollectionRow extends ConsumerWidget {
  const _CollectionRow({required this.collection, required this.index});

  final FavoriteCollection collection;
  final int index;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final type = collection.kind == 'album'
        ? OnlineDetailType.album
        : OnlineDetailType.playlist;

    return InkWell(
      onTap: () => context.push(
        '/online-detail',
        extra: OnlineDetailArgs(
          type: type,
          pluginId: collection.pluginId,
          title: collection.title,
          subtitle: collection.subtitle,
          coverUrl: collection.coverUrl,
          raw: collection.raw,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(6, 10, 6, 10),
        child: Row(
          children: [
            DragHandle(index: index),
            OnlineCover(url: collection.coverUrl, size: 56, radius: 12),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    collection.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    [
                      if (collection.subtitle.isNotEmpty) collection.subtitle,
                      _pluginName(ref, collection.pluginId),
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(
                Icons.favorite,
                size: 20,
                color: Color(0xFFEC4141),
              ),
              tooltip: tr('取消收藏'),
              onPressed: () => ref
                  .read(favoritesProvider.notifier)
                  .toggleCollection(
                    kind: collection.kind,
                    pluginId: collection.pluginId,
                    title: collection.title,
                    subtitle: collection.subtitle,
                    coverUrl: collection.coverUrl,
                    raw: collection.raw,
                  ),
            ),
          ],
        ),
      ),
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
