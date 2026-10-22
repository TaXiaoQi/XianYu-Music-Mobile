part of 'shell.dart';
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

extension _ShellScaffoldLandscape on _ShellScaffoldState {

  void _deferLibPaneMount() {
    _libPaneMountable = false;
    _libPaneMountTimer?.cancel();
    _libPaneMountTimer = Timer(const Duration(milliseconds: 400), () {
      _libPaneMountTimer = null;
      if (mounted) setState(() => _libPaneMountable = true);
    });
  }

  Future<void> _applyLandscapeImmersive(bool landscape) async {
    try {
      if (landscape) {
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      } else {
        await SystemChrome.setEnabledSystemUIMode(
          SystemUiMode.manual,
          overlays: SystemUiOverlay.values,
        );
        SystemChrome.setSystemUIOverlayStyle(
          const SystemUiOverlayStyle(statusBarColor: Colors.transparent),
        );
      }
    } catch (e) {
      AppLog.debug('ui', '设置横屏沉浸式系统栏失败: $e');
    }
  }

  Widget _landscapeFadePanel({
    required bool useCameraArea,
    required EdgeInsets padding,
    required BuildContext context,
    required Widget child,
  }) {
    return useCameraArea
        ? MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(padding: padding.copyWith(left: 0, right: 0)),
            child: child,
          )
        : child;
  }

  Widget _landscapeSlide({
    required bool enabled,
    required bool open,
    required Object? trigger,
    required Widget? child,
  }) {
    if (!enabled) {
      return (open && child != null) ? child : const SizedBox.shrink();
    }
    return LandscapePageFade(open: open, trigger: trigger, child: child);
  }

}

class _ShellRailDivider extends StatelessWidget {
  const _ShellRailDivider({required this.onDragUpdate});

  final ValueChanged<double> onDragUpdate;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragUpdate: (d) => onDragUpdate(d.delta.dx),
      child: Center(
        child: Container(
          width: 3,
          height: 56,
          decoration: BoxDecoration(
            color: scheme.onSurface.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );
  }
}

class _LandscapeRail extends ConsumerWidget {
  const _LandscapeRail({
    required this.index,
    required this.onSelect,
    required this.railWidth,
    required this.floating,
  });

  final int index;
  final ValueChanged<int> onSelect;
  final double railWidth;

  final bool floating;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final collapsed = railWidth < kLandscapeRailCollapseAt;

    final primary = navItemsFor(
      ref.watch(settingsProvider.select(
          (s) => s.valueOrNull?.navShowPlugins ?? false)),
      ref.watch(settingsProvider.select(
          (s) => s.valueOrNull?.navOrderLandscape ?? kDefaultNavOrder)),
    );
    final library = [
      (tr('本地音乐'), Icons.library_music_outlined),
      (tr('我的收藏'), Icons.favorite_outline),
      (tr('最近播放'), Icons.history_outlined),
      (tr('我的歌单'), Icons.queue_music_outlined),
    ];
    final libSel = ref.watch(landscapeLibraryProvider);

    Widget label(String t) => Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 0, 4),
      child: Text(
        t,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          color: scheme.primary,
          letterSpacing: 0.5,
        ),
      ),
    );

    // Stack 取代 Column：列表视口全高（Positioned.fill），rail 项滚上去
    // 从顶栏带下穿过被实时模糊——原 Expanded 视口从 logo 下起，滚到带
    // 底就出视口，带左段采不到内容（右侧内容列已页面自垫，rail 同款）。
    // 固定态品牌行改挂顶栏带 head 位（rail 在带下层，logo 留在 rail 里
    // 会被带玻璃盖住）；悬浮态 rail 是独立玻璃卡，品牌行仍在卡内排布
    final listTopPad = floating
        ? 14.0 + (collapsed ? 0.0 : 34.0) + 6
        : GlassTopBar.height(context, topInset: 8) + 6;
    final content = Stack(
      children: [
        Positioned.fill(
          child: ListView(
            // 左右各留 12 与右侧内容页边距对称：rail Positioned left:0，
            // 卡片原先贴死屏幕左缘，圆角屏上会被裁切。顶距复刻原 Column
            // 静止排布；底部预留贴纸块高，滚到底不压贴纸
            padding: EdgeInsets.fromLTRB(
              12,
              listTopPad,
              12,
              (floating ? 8 : 12) + (collapsed ? 0 : 76),
            ),
            children: [
              if (!collapsed) ...[
                // 分组独立玻璃卡，样式对齐设置页左列（frostedCardSurface
                // 同款）；小标题在卡外（设置页同款），红色在 label() 内
                label(tr('导航')),
                const SizedBox(height: 2),
                frostedCardSurface(
                  context: context,
                  ref: ref,
                  radius: 16,
                  themeSlot: 'settings.group',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < primary.length; i++)
                        _railItem(
                          context,
                          ref,
                          icon: primary[i].icon,
                          themeSlot: primary[i].themeSlot,
                          title: navTitle(context, primary[i]),
                          collapsed: collapsed,
                          selected:
                              libSel == null && primary[i].branchIndex == index,
                          onTap: () {
                            ref
                                .read(landscapeLibraryProvider.notifier)
                                .state = null;
                            onSelect(primary[i].branchIndex);
                          },
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                label(tr('音乐库')),
                const SizedBox(height: 2),
                frostedCardSurface(
                  context: context,
                  ref: ref,
                  radius: 16,
                  themeSlot: 'settings.group',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var j = 0; j < library.length; j++)
                        _railItem(
                          context,
                          ref,
                          icon: library[j].$2,
                          title: library[j].$1,
                          collapsed: collapsed,
                          // 文件夹管理(4)归属「本地音乐」：右侧容器打开时
                          // 保持其高亮
                          selected: libSel == j || (j == 0 && libSel == 4),
                          onTap: () {
                            closeLandscapeSearch(ref);
                            ref.read(landscapeLibraryProvider.notifier).state =
                                j;
                          },
                        ),
                    ],
                  ),
                ),
              ] else ...[
                for (var i = 0; i < primary.length; i++)
                  _railItem(
                    context,
                    ref,
                    icon: primary[i].icon,
                    themeSlot: primary[i].themeSlot,
                    title: navTitle(context, primary[i]),
                    collapsed: collapsed,
                    selected: libSel == null && i == index,
                    onTap: () {
                      ref.read(landscapeLibraryProvider.notifier).state = null;
                      onSelect(i);
                    },
                  ),
                for (var j = 0; j < library.length; j++)
                  _railItem(
                    context,
                    ref,
                    icon: library[j].$2,
                    title: library[j].$1,
                    collapsed: collapsed,
                    selected: libSel == j || (j == 0 && libSel == 4),
                    onTap: () {
                      closeLandscapeSearch(ref);
                      ref.read(landscapeLibraryProvider.notifier).state = j;
                    },
                  ),
              ],
            ],
          ),
        ),
        // 悬浮态品牌行：卡内流水排布（固定态挂顶栏带 head 位，见上）
        if (floating && !collapsed)
          Positioned(
            top: 14,
            left: 0,
            right: 0,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: landscapeRailLogo(ref, scheme),
            ),
          ),
        // 主题提供侧栏贴纸时才出现；未启用主题时零尺寸，观感不变。
        // 钉在 rail 底部（原 Column 尾位），列表底部已预留贴纸块高
        if (!collapsed)
          Positioned(
            left: 12,
            right: 12,
            bottom: 12,
            child: Align(
              alignment: Alignment.centerLeft,
              child: themeSlotSticker(
                ref,
                'ls-sidebar.bottom',
                width: (railWidth - 24).clamp(24.0, 240.0),
              ),
            ),
          ),
      ],
    );

    if (floating) {
      return FloatingGlassSurface(radius: 18, child: content);
    }

    return SafeArea(
      right: false,
      // 组卡（frostedCardSurface）自带玻璃底，整列不再垫玻璃，
      // 否则卡间空隙和列底会露出第二层玻璃面
      child: Padding(
        // 悬浮顶栏的胶囊元素从 rail 右缘起排（返回钮 x≈railWidth），
        // logo 区不重叠，无需下移让位
        padding: EdgeInsets.zero,
        child: SizedBox(width: railWidth, child: content),
      ),
    );
  }

  Widget _railItem(
    BuildContext context,
    WidgetRef ref, {
    required IconData icon,
    required String title,
    required bool selected,
    required VoidCallback onTap,
    bool collapsed = false,
    String? themeSlot,
  }) {
    final scheme = Theme.of(context).colorScheme;
    // 字重/颜色对齐设置页 _CategoryTile（ListTile 默认）：常规粗细，
    // 非选中用 onSurface（不用淡化灰）
    final color = selected ? scheme.primary : scheme.onSurface;
    return PressableScale(
      pressScale: 0.92,
      child: Padding(
        padding:
            EdgeInsets.symmetric(horizontal: collapsed ? 0 : 4, vertical: 2),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            padding: EdgeInsets.symmetric(
              horizontal: collapsed ? 0 : 12,
              vertical: 11,
            ),
            decoration: BoxDecoration(
              color: selected ? scheme.primary.withValues(alpha: 0.14) : null,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: collapsed
                  ? MainAxisAlignment.center
                  : MainAxisAlignment.start,
              children: [
                themeSlotIcon(
                  ref,
                  themeSlot,
                  fallback: icon,
                  size: 22,
                  color: color,
                ),
                if (!collapsed) ...[
                  const SizedBox(width: 10),
                  // 弹性截断：侧栏宽可拖拽收窄（下限仅 icon 档），固定宽
                  // 文本在窄列下会把 Row 挤溢出（RenderFlex overflow）
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight:
                            selected ? FontWeight.w600 : FontWeight.w400,
                        color: color,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MusicLibraryPane extends ConsumerWidget {
  const _MusicLibraryPane({required this.index});

  final int index;

  /// 横屏音乐库面板的页面 id；文件夹面板不映射，回落全局壁纸。
  static const _panePageIds = <String?>[
    'ls-local',
    'ls-fav',
    'ls-recent',
    'ls-sheets',
    null,
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 固定态：shell 固定带盖住顶部，面板内容整体垫到带下（与首页/我的
    // 自垫带高同口径）；悬浮态顶距由页面自垫 chrome 高，不再重复垫
    final floating = ref.watch(
      settingsProvider.select((s) => s.valueOrNull?.floatingSearchBar ?? false),
    );
    final topInset =
        MediaQuery.orientationOf(context) == Orientation.landscape && !floating
        ? GlassTopBar.height(context, topInset: 8)
        : 0.0;
    return PageWallpaperScope(
      pageId: _panePageIds[index],
      child: ColoredBox(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: Padding(
          padding: EdgeInsets.only(top: topInset),
          child: KeyedSubtree(
            key: musicLibraryPageKeys[index],
            child: switch (index) {
              0 => const LibraryPage(),
              1 => const FavoritesPage(),
              2 => const RecentPage(),
              3 => const PlaylistsPage(),
              // 横屏：文件夹管理接在「本地音乐」右侧容器内，不单独开路由页
              _ => const LibraryFolderPage(embedded: true),
            },
          ),
        ),
      ),
    );
  }
}

class _AccountPane extends StatelessWidget {
  const _AccountPane({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return AccountPage(embedded: true, onBack: onBack);
  }
}

class _DownloadPane extends StatelessWidget {
  const _DownloadPane();

  @override
  Widget build(BuildContext context) {
    return const DownloadPage(embedded: true);
  }
}

class _PlaylistDetailPane extends StatelessWidget {
  const _PlaylistDetailPane({required this.playlistId});

  final String playlistId;

  @override
  Widget build(BuildContext context) {
    return PlaylistDetailPage(playlistId: playlistId, embedded: true);
  }
}

class _SearchPane extends ConsumerWidget {
  const _SearchPane({required this.showResults});

  final bool showResults;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final floatingBar = ref.watch(
      settingsProvider.select((s) => s.valueOrNull?.floatingSearchBar ?? false),
    );
    if (!showResults) {
      if (floatingBar) {
        return ColoredBox(
          color: appScaffoldBackground(context, ref),
          child: SearchIdleView(
            onSearch: (q) => submitLandscapeSearch(ref, q),
            topPadding: GlassTopBar.height(context),
          ),
        );
      }
      return ColoredBox(
        color: appScaffoldBackground(context, ref),
        child: Padding(
          padding: EdgeInsets.only(top: GlassTopBar.height(context)),
          child: SearchIdleView(onSearch: (q) => submitLandscapeSearch(ref, q)),
        ),
      );
    }
    return const SearchResultPage(embedded: true);
  }
}

class _ContentPane extends StatelessWidget {
  const _ContentPane({required this.path, required this.onBack});

  final String path;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final page = switch (path) {
      '/home/daily' => const DailyRecommendPage(embedded: true),
      '/home/toplists' => const TopListsPage(embedded: true),
      '/home/recommend-sheets' => const RecommendSheetsPage(embedded: true),
      '/leaderboard' => const LeaderboardPage(embedded: true),
      _ => const SizedBox.shrink(),
    };
    final title = switch (path) {
      '/home/daily' => tr('每日推荐'),
      '/home/toplists' => tr('音源榜单'),
      '/home/recommend-sheets' => tr('推荐歌单'),
      '/leaderboard' => tr('听歌排行榜'),
      _ => '',
    };
    return Column(
      children: [
        FlatTopBar(
          title: title,
          leading: BackButton(onPressed: onBack),
        ),
        Expanded(child: page),
      ],
    );
  }
}
