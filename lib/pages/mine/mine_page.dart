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
import '../../src/widgets/glass_appbar.dart';
import '../../src/widgets/online_cover.dart';
import '../../src/widgets/sheet_dialog.dart';
import '../../src/widgets/user_avatar.dart';
import '../home/online_detail_page.dart';
import '../playlist/playlists_page.dart' show PlaylistDetailPage;

/// 「我的」页：搜索条 + 账号区 + 快捷入口四宫格（参考魅族音乐我的页布局）。
///
/// 音乐库、歌单、收藏等曲库浏览统一从快捷入口与首页网格分流进入；
/// 设置入口位于右上角（底栏已无设置 Tab）。
class MinePage extends ConsumerWidget {
  const MinePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      backgroundColor: appSurfaceBg(context),
      body: Stack(
        children: [
          ListView(
            padding: EdgeInsets.fromLTRB(
              16,
              GlassTopBar.height(context),
              16,
              ref.watch(navBarInsetProvider) + 24,
            ),
            children: const [
              _SearchEntry(),
              SizedBox(height: 18),
              _AccountArea(),
              SizedBox(height: 22),
              _QuickEntries(),
              SizedBox(height: 24),
              _MyPlaylistsSection(),
              _FavoriteCollectionsSection(kind: 'playlist', title: '收藏歌单'),
              _FavoriteCollectionsSection(kind: 'album', title: '收藏专辑'),
            ],
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: GlassTopBar(
              title: const Text('我的'),
              actions: [
                IconButton(
                  icon: const Icon(Icons.settings_outlined),
                  tooltip: '设置',
                  onPressed: () => context.push('/settings'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 顶部搜索条：点击进入搜索页（参考图布局）。
class _SearchEntry extends StatelessWidget {
  const _SearchEntry();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: appCardColor(context),
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
              color: scheme.outlineVariant.withValues(alpha: 0.3),
            ),
          ),
          child: Row(
            children: [
              Icon(Icons.search, size: 18, color: scheme.onSurfaceVariant),
              const SizedBox(width: 10),
              Text(
                '搜索歌曲、歌手、专辑',
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
                      '登录弦予音乐账号',
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
            '登录后同步你的歌单与设置',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ],
      );
    }

    return Material(
      color: appCardColor(context),
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
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
                      )
                    : _fallback(scheme, user.nickname),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      user.nickname.isEmpty ? '未命名用户' : user.nickname,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '管理账号与安全',
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: scheme.outline),
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
      color: appCardColor(context),
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            entry(
              icon: Icons.favorite_rounded,
              label: '喜欢',
              count: '$favCount',
              onTap: () => context.push('/favorites'),
            ),
            entry(
              icon: Icons.history_rounded,
              label: '最近',
              count: '$recentCount',
              onTap: () => context.push('/recent'),
            ),
            entry(
              icon: Icons.library_music_rounded,
              label: '本地',
              count: '$localCount',
              onTap: () => context.push('/library?tab=0'),
            ),
            entry(
              icon: Icons.download_rounded,
              label: '下载',
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

/// 分组圆角卡片容器：条目间细分隔线（与封面-文字对齐）。
class _CardGroup extends StatelessWidget {
  const _CardGroup({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final items = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      items.add(children[i]);
      if (i != children.length - 1) {
        items.add(
          Divider(
            height: 1,
            indent: 82,
            endIndent: 12,
            thickness: 0.5,
            color: scheme.onSurface.withValues(alpha: 0.06),
          ),
        );
      }
    }

    return Material(
      color: appCardColor(context),
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Column(children: items),
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(
          title: '自建歌单',
          count: state.playlists.length,
          action: OutlinedButton.icon(
            onPressed: () => _promptCreate(context, manager),
            icon: const Icon(Icons.add, size: 15),
            label: const Text('新建', style: TextStyle(fontSize: 13)),
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
        _CardGroup(
          children: [
            for (final playlist in state.playlists)
              _PlaylistRow(playlist: playlist),
            _ImportPlaylistRow(),
          ],
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  Future<void> _promptCreate(
    BuildContext context,
    PlaylistManager manager,
  ) async {
    final name = await _promptPlaylistName(context, '新建歌单');
    if (name == null || name.trim().isEmpty) return;
    await manager.create(name.trim());
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已创建歌单「${name.trim()}」')));
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
        decoration: const InputDecoration(hintText: '歌单名称'),
        onSubmitted: (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, controller.text),
          child: const Text('确定'),
        ),
      ],
    ),
  );
}

/// 自建歌单条目：封面（取歌单第一首歌，无则占位）+ 名称 + 共N首歌。
/// 点击进详情；右侧菜单提供重命名/删除。
class _PlaylistRow extends ConsumerWidget {
  const _PlaylistRow({required this.playlist});
  final ImportedPlaylist playlist;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;

    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PlaylistDetailPage(playlistId: playlist.id),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
        child: Row(
          children: [
            OnlineCover(
              url: playlist.songs.firstOrNull?.coverUrl,
              size: 56,
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
                    '共${playlist.songs.length}首歌',
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
              tooltip: '歌单操作',
              onPressed: () => _sheetActions(context, ref),
            ),
          ],
        ),
      ),
    );
  }

  /// 操作菜单：重命名 / 删除歌单。
  void _sheetActions(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final manager = ref.read(playlistManagerProvider.notifier);

    showSheetDialog<void>(
      context,
      (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(
                Icons.edit_outlined,
                color: scheme.primary,
                size: 22,
              ),
              title: const Text('重命名歌单'),
              onTap: () async {
                Navigator.pop(ctx);
                final name = await _promptPlaylistName(context, '重命名歌单');
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
              title: const Text('删除歌单'),
              onTap: () {
                Navigator.pop(ctx);
                _confirmRemove(context, manager);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _confirmRemove(BuildContext context, PlaylistManager manager) {
    showPredictiveDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除歌单'),
        content: Text('确定要删除「${playlist.name}」吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              manager.remove(playlist.id);
            },
            child: const Text('删除'),
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
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        child: Row(
          children: [
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
                  const Text(
                    '导入外部歌单',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '备份文件 / 本地文件夹 / 云端导入',
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(title: title, count: items.length),
        _CardGroup(
          children: [for (final c in items) _CollectionRow(collection: c)],
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

/// 收藏条目：在线封面 + 标题 + 来源副标题，右侧取消收藏。
class _CollectionRow extends ConsumerWidget {
  const _CollectionRow({required this.collection});
  final FavoriteCollection collection;

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
        padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
        child: Row(
          children: [
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
              tooltip: '取消收藏',
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
