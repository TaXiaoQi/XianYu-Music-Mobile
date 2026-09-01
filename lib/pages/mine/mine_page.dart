import 'dart:async';

import 'package:xianyu_music_mobile/src/widgets/predictive_dialog_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../src/auth/auth_provider.dart';
import '../../src/core/app_colors.dart';
import '../../src/core/settings.dart';
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
import '../../src/widgets/glass_settings.dart';
import '../../src/widgets/glass_appbar.dart';
import '../../src/widgets/online_cover.dart';
import '../../src/widgets/page_search_bar.dart';
import '../../src/widgets/sheet_dialog.dart';
import '../../src/widgets/user_avatar.dart';
import '../home/discover_section.dart' show StatsSummaryCard;
import '../home/online_detail_page.dart';
import '../search/search_page.dart' show searchSessionProvider;
import '../../src/responsive/landscape.dart';
import '../../src/i18n/i18n.dart';

/// 「我的」页：搜索条 + 账号区 + 快捷入口四宫格（参考魅族音乐我的页布局）。
///
/// 音乐库、歌单、收藏等曲库浏览统一从快捷入口与首页网格分流进入；
/// 设置入口位于右上角（底栏已无设置 Tab）。
class MinePage extends ConsumerWidget {
  const MinePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final floating = ref.watch(settingsProvider.select(
        (s) => s.valueOrNull?.floatingSearchBar ?? false));
    final searchBar = PageSearchBarBottom(
      // 我的页搜索默认引导到本地索引：进入前重置会话音源为 local，
      // 避免沿用首页/搜索页上一次选中的在线音源（无插件时来源条即显示「本地」）。
      onTap: () {
        ref.read(searchSessionProvider.notifier).setSource('local');
        context.push('/search');
      },
      onRecognize: () => context.push('/recognize'),
    );
    // 悬浮顶部栏（标题胶囊+搜索胶囊+玻璃按钮）由壳层统一渲染（首页/我的页共用
    // 同一实例，不随 tab 重建）。悬浮模式下本页不再渲染标题行，仅按其几何预留
    // 顶部避让，避免账号条飞到悬浮顶栏下方。
    final statusBar = MediaQuery.paddingOf(context).top;
    final topInset = floating
        ? statusBar + 8 + 44 + 14
        : GlassTopBar.height(context, bottom: searchBar);
    final portrait = Scaffold(
      // 背景交给 Shell 层统一渲染（自定义壁纸/默认底色），页面自身保持透明以透出壁纸。
      backgroundColor: appScaffoldBackground(context, ref),
      resizeToAvoidBottomInset: false,
      body: RepaintBoundary(child: Stack(
        children: [
          ListView(
            padding: EdgeInsets.fromLTRB(
              16,
              topInset,
              16,
              ref.watch(navBarInsetProvider) + 24,
            ),
            children:   [
              SizedBox(height: 18),
              _AccountArea(),
              SizedBox(height: 22),
              // 听歌统计三格卡（原首页「统计」tab 迁入）：账号区与音乐库入口之间，
              // 整卡点击打开完整听歌排行榜。
              StatsSummaryCard(),
              SizedBox(height: 22),
              _QuickEntries(),
              SizedBox(height: 24),
              _MyPlaylistsSection(),
              _FavoriteCollectionsSection(kind: 'playlist', title: tr('收藏歌单')),
              _FavoriteCollectionsSection(kind: 'album', title: tr('收藏专辑')),
            ],
          ),
          // 顶栏（仅非悬浮模式）已上提至壳层共用：竖屏固定顶栏（标题+搜索框）
          // 由 shell 统一渲染为常驻毛玻璃 overlay，首页/我的页切换不再重建；
          // 悬浮模式由壳层悬浮顶栏接管。本页只按其高度预留顶部避让。
        ],
        ),
      ),
    );

    // 竖屏=完整版默认布局，横屏=精简个人中心，两套 UI 完全分开（见 LandscapeGate）。
    return LandscapeGate(
      portrait: portrait,
      landscape: _buildLandscapeProfile(context, ref),
    );
  }

  /// 横屏专用：精简个人中心（独立一套 UI）。参考桌面版个人中心排布——
  /// 账号区 + 收藏/歌单/历史统计 + 四个快捷入口卡片。音乐库各入口已由
  /// 横屏侧边栏承接，此处不再重复列表分区。
  Widget _buildLandscapeProfile(BuildContext context, WidgetRef ref) {
    // 悬浮模式：壳层横屏全局顶栏独立悬浮在容器顶部，内容需预留其高度
    // （默认模式顶栏在上方 Column 中，无需预留）。
    final floating = ref.watch(
        settingsProvider.select((s) => s.valueOrNull?.floatingSearchBar ?? false));
    final topInset = floating ? MediaQuery.paddingOf(context).top + 60 + 12 : 12.0;
    return Scaffold(
      backgroundColor: appScaffoldBackground(context, ref),
      resizeToAvoidBottomInset: false,
      // 顶部无需避让：壳层全局顶栏在内容上方 Column 中，自身处理状态栏。
      body: ListView(
        padding: EdgeInsets.fromLTRB(24, topInset, 24, 24),
        children: const [
          SizedBox(height: 18),
          _AccountArea(),
          SizedBox(height: 16),
          StatsSummaryCard(),
          SizedBox(height: 16),
          _StatsRow(),
          SizedBox(height: 24),
          _QuickCards(),
          SizedBox(height: 12),
        ],
      ),
    );
  }
}

/// 数据统计：收藏 / 歌单 / 历史（参考桌面版个人中心，数字+标签一行排布）。
class _StatsRow extends ConsumerWidget {
  const _StatsRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final favCount =
        ref.watch(favoritesProvider.select((s) => s.entries.length));
    final recentCount =
        ref.watch(recentProvider.select((s) => s.entries.length));
    final playlistCount = ref.watch(playlistManagerProvider).playlists.length;
    final card = Material(
      color: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Row(
          children: [
            _statItem(scheme, '$favCount', tr('收藏')),
            _statItem(scheme, '$playlistCount', tr('歌单')),
            _statItem(scheme, '$recentCount', tr('历史')),
          ],
        ),
      ),
    );
    return frostedCardSurface(
        context: context, ref: ref, radius: 16, child: card);
  }
}

Widget _statItem(ColorScheme scheme, String value, String label) {
  return Expanded(
    child: Column(
      children: [
        Text(
          value,
          style: TextStyle(
            fontSize: 19,
            fontWeight: FontWeight.bold,
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w300,
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    ),
  );
}

/// 快捷入口卡片：账号设置 / 主题外观 / 本地音乐 / 下载（参考桌面版个人中心宫格）。
/// 竖屏 2×2 网格；横屏 1×4 单行平铺。横屏下「账号设置」走容器内嵌、不开二级路由。
class _QuickCards extends ConsumerWidget {
  const _QuickCards();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final isLandscape = useLandscape(ref);
    final cards = [
      (tr('账号设置'), tr('管理账号信息'), Icons.account_circle_outlined, '/account'),
      (tr('主题外观'), tr('换肤与界面风格'), Icons.palette_outlined, '/wallpaper'),
      (tr('本地音乐'), tr('管理本地曲库'), Icons.library_music_outlined, '/library'),
      (tr('歌曲下载'), tr('管理下载任务'), Icons.download_outlined, '/download'),
    ];

    // 横屏：账号设置/歌曲下载在右侧容器内嵌打开、本地音乐切到侧边栏本地入口，
    // 均不开二级页；其余（主题外观）保持 push。
    void open((String, String, IconData, String) c) {
      if (!isLandscape) {
        context.push(c.$4);
        return;
      }
      switch (c.$4) {
        case '/account':
          ref.read(landscapeAccountOpenProvider.notifier).state = true;
        case '/download':
          ref.read(landscapeDownloadOpenProvider.notifier).state = true;
        case '/library':
          // 本地音乐：路由到侧边栏音乐库的本地入口（0=本地）。
          ref.read(landscapeLibraryProvider.notifier).state = 0;
        default:
          context.push(c.$4);
      }
    }

    Widget card((String, String, IconData, String) c) {
      return Material(
        color: Colors.transparent,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        child: InkWell(
          onTap: () => open(c),
          borderRadius: BorderRadius.circular(14),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: 0.5),
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: const Color(0xFFEC4141),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(c.$3, color: Colors.white, size: 21),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        c.$1,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        c.$2,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // 横屏：直接平铺 1×4（参考桌面版），单行四张卡均分宽度。
    if (isLandscape) {
      return Row(
        children: [
          for (var i = 0; i < cards.length; i++) ...[
            Expanded(
              child: SizedBox(height: 88, child: card(cards[i])),
            ),
            if (i != cards.length - 1) const SizedBox(width: 12),
          ],
        ],
      );
    }

    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: 1.85,
      children: [for (final c in cards) card(c)],
    );
  }
}

/// 账号区：未登录时展示登录胶囊按钮（参考图布局），已登录展示头像卡片。
class _AccountArea extends ConsumerWidget {
  const _AccountArea();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final isLandscape = useLandscape(ref);
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

    final accountCard = Material(
      color: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide.none,
      ),
      child: InkWell(
        // 横屏：账号与安全在右侧容器内嵌显示，不开二级路由。
        onTap: () {
          if (isLandscape) {
            ref.read(landscapeAccountOpenProvider.notifier).state = true;
          } else {
            context.push('/account');
          }
        },
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
              // 扫码登录入口：竖屏与首页顶栏的皮肤入口位置互换；横屏保持扫码。
              IconButton(
                onPressed: () => context.push('/scan'),
                icon: Icon(
                  Icons.qr_code_scanner,
                  color: scheme.outline,
                ),
                tooltip: tr('扫码'),
                splashRadius: 20,
              ),
            ],
          ),
        ),
      ),
    );
    // 毛玻璃表面：跟随全局开关，与顶栏底栏一致。
    return frostedCardSurface(
        context: context, ref: ref, radius: 16, child: accountCard);
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

    final entriesCard = Material(
      color: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide.none,
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
    // 毛玻璃表面：跟随全局开关，与顶栏底栏一致。
    return frostedCardSurface(
        context: context, ref: ref, radius: 16, child: entriesCard);
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
    final reorderCard = Material(
      color: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide.none,
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
    // 毛玻璃表面：跟随全局开关，与顶栏底栏一致。
    return frostedCardSurface(
        context: context, ref: ref, radius: 16, child: reorderCard);
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
