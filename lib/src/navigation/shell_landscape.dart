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

    final primary = bottomNavItems;
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
          fontWeight: FontWeight.w600,
          color: scheme.onSurfaceVariant.withValues(alpha: 0.45),
          letterSpacing: 0.5,
        ),
      ),
    );

    final content = Column(
      children: [
        SizedBox(height: floating ? 14 : 20),
        if (!collapsed)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 主题提供品牌图时才出现；未启用主题时是零尺寸，观感不变。
                themeSlotWidget(
                  ref,
                  'landscape.logo',
                  size: 22,
                  fallback: const SizedBox.shrink(),
                ),
                Text.rich(
                  TextSpan(
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: scheme.onSurface,
                    ),
                    children: [
                      TextSpan(text: tr('弦予')),
                      TextSpan(
                        text: tr('音乐'),
                        style: const TextStyle(
                          color: Color(0xFFEC4141),
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        Expanded(
          child: ListView(
            padding: EdgeInsets.only(top: 6, bottom: floating ? 8 : 12),
            children: [
              if (!collapsed) label(tr('导航')),
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
              if (!collapsed) label(tr('音乐库')),
              for (var j = 0; j < library.length; j++)
                _railItem(
                  context,
                  ref,
                  icon: library[j].$2,
                  title: library[j].$1,
                  collapsed: collapsed,
                  // 文件夹管理(4)归属「本地音乐」：右侧容器打开时保持其高亮
                  selected: libSel == j || (j == 0 && libSel == 4),
                  onTap: () {
                    closeLandscapeSearch(ref);
                    ref.read(landscapeLibraryProvider.notifier).state = j;
                  },
                ),
            ],
          ),
        ),
        const Spacer(),
        // 主题提供侧栏贴纸时才出现；未启用主题时零尺寸，观感不变。
        if (!collapsed)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
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
      child: SizedBox(
        width: railWidth,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(
              right: BorderSide(
                color: scheme.onSurface.withValues(alpha: 0.08),
              ),
            ),
          ),
          child: content,
        ),
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
    final color = selected
        ? scheme.primary
        : scheme.onSurfaceVariant.withValues(alpha: 0.6);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: collapsed ? 0 : 8, vertical: 2),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          padding: EdgeInsets.symmetric(
            horizontal: collapsed ? 0 : 10,
            vertical: 9,
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
                size: 20,
                color: color,
              ),
              if (!collapsed) ...[
                const SizedBox(width: 9),
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: color,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _MusicLibraryPane extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return PageWallpaperScope(
      pageId: _panePageIds[index],
      child: ColoredBox(
        color: Theme.of(context).scaffoldBackgroundColor,
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
      '/leaderboard' => const LeaderboardPage(embedded: true),
      _ => const SizedBox.shrink(),
    };
    final title = switch (path) {
      '/home/daily' => tr('每日推荐'),
      '/home/toplists' => tr('音源榜单'),
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
