import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../src/core/settings.dart';
import '../../src/home/home_providers.dart';
import '../../src/library/library_provider.dart';
import '../../src/navigation/shell.dart';
import '../../src/responsive/landscape.dart';
import '../../src/widgets/cover_carousel.dart';
import '../../src/widgets/cover_image.dart';
import '../../src/widgets/glass_appbar.dart';
import '../../src/widgets/glass_settings.dart';
import '../../src/widgets/page_search_bar.dart';
import 'discover_section.dart';
import '../../src/i18n/i18n.dart';

/// 首页：顶栏（标题+搜索框）/ 封面轮播 / 发现 / 听过最多。
///
/// 顶栏为毛玻璃固定条，扩展至搜索框下；设置入口在「我的」页右上角菜单。
class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  /// 首页内容背板：静态快照供顶栏离线缓存复用（被二级页盖住/弹回时零抓屏）。
  final _backdropKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final ref = this.ref;
    // 竖屏 / 横屏两套完全分开：横屏顶栏改横向（搜索框 + 扫码齐平一行）、
    // 「弦予音乐」标题移入左侧侧栏、去掉封面卡片直接以「发现」起步。
    return useLandscape(ref)
        ? _buildLandscape(context, ref)
        : _buildPortrait(context, ref);
  }

  /// 竖屏：原默认布局（封面轮播 + 发现 + 听过最多，标题 + 底部搜索框顶栏）。
  Widget _buildPortrait(BuildContext context, WidgetRef ref) {
    final floating = ref.watch(settingsProvider.select(
        (s) => s.valueOrNull?.floatingSearchBar ?? false));
    final searchBar = PageSearchBarBottom(
      onTap: () => context.push('/search'),
      onRecognize: () => context.push('/recognize'),
    );
    // 悬浮顶部栏（标题胶囊+搜索胶囊+玻璃按钮）由壳层统一渲染在状态栏下方，
    // 悬浮模式下本页不再渲染自己的标题行。
    final statusBar = MediaQuery.paddingOf(context).top;
    final topInset = floating
        ? statusBar + 8 + 44 + 14
        : GlassTopBar.height(context, bottom: searchBar);

    return Scaffold(
      body: Stack(
        children: [
          const _AmbientBackground(),
          // 内容主体：顶部避让扩展后的顶栏（标题行+搜索框）。
          // 整体包 RepaintBoundary 并按 _backdropKey 暴露，供顶栏离线缓存背板。
          RepaintBoundary(
            key: _backdropKey,
            child: ListView(
            padding: EdgeInsets.fromLTRB(
                18, topInset, 18, ref.watch(navBarInsetProvider) + 24),
            children:   [
              SizedBox(height: 14),
              CoverCarousel(),
              SizedBox(height: 26),
              _SectionHeader(
                title: tr('发现'),
                action: _viewAllAction(context, ref, '/home/toplists'),
              ),
              SizedBox(height: 12),
              DiscoverSection(),
              SizedBox(height: 26),
              _SectionHeader(
                title: tr('每日推荐'),
                action: _viewAllAction(context, ref, '/home/daily'),
              ),
              SizedBox(height: 14),
              DailyRecommendSection(),
              SizedBox(height: 26),
              _SectionHeader(title: tr('听过最多')),
              SizedBox(height: 14),
              _MostPlayedList(),
            ],
            ),
          ),
          // 顶栏（仅非悬浮模式）：状态栏+「弦予音乐」标题+搜索框，
          // 滚动内容从其下方穿过被毛玻璃模糊；悬浮模式由壳层悬浮顶栏接管。
          if (!floating)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: GlassTopBar(
              // 离线缓存背板：静止/切页/弹回时直接复用预模糊快照。
              cachedBackdropKey: _backdropKey,
              titleSpacing: 18,
              title:   Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: tr('弦予')),
                    TextSpan(
                      text: tr('音乐'),
                      style: TextStyle(
                        color: Color(0xFFEC4141),
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.5,
                ),
              ),
              actions: [
                // 皮肤（壁纸中心）入口：与我的页账号区的扫码入口位置互换
                IconButton(
                  icon: const Icon(Icons.checkroom),
                  tooltip: tr('皮肤'),
                  onPressed: () => context.push('/wallpaper'),
                ),
                const SizedBox(width: 16),
              ],
              bottom: floating ? null : searchBar,
            ),
          ),
        ],
      ),
    );
  }

  /// 横屏：独立一套 UI。去掉封面轮播卡片、直接以「发现」起步。
  /// 顶栏由壳层统一提供（全局继承），本页不再渲染自身顶栏。
  Widget _buildLandscape(BuildContext context, WidgetRef ref) {
    // 悬浮模式：壳层横屏全局顶栏独立悬浮在容器顶部（控件独立显示），
    // 内容需预留其高度，滚动时才能从悬浮控件下方穿过（默认模式顶栏在
    // 上方 Column 中，无需预留）。
    final floating = ref.watch(
        settingsProvider.select((s) => s.valueOrNull?.floatingSearchBar ?? false));
    final topInset = floating ? MediaQuery.paddingOf(context).top + 60 + 12 : 12.0;
    return Scaffold(
      body: Stack(
        children: [
          const _AmbientBackground(),
          // 内容主体：顶部无需再避让顶栏（壳层全局顶栏在上方 Column 中），
          // 直接以「发现」起步，仅留少量呼吸间距。
          ListView(
            padding: EdgeInsets.fromLTRB(
                18, topInset, 18, ref.watch(navBarInsetProvider) + 24),
            children: [
              SizedBox(height: 10),
              _SectionHeader(
                title: tr('发现'),
                action: _viewAllAction(context, ref, '/home/toplists'),
              ),
              SizedBox(height: 12),
              DiscoverSection(),
              SizedBox(height: 26),
              _SectionHeader(
                title: tr('每日推荐'),
                action: _viewAllAction(context, ref, '/home/daily'),
              ),
              SizedBox(height: 14),
              DailyRecommendSection(),
              SizedBox(height: 26),
              _SectionHeader(title: tr('听过最多')),
              SizedBox(height: 14),
              _MostPlayedList(),
            ],
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.action});

  final String title;

  /// 标题行右侧动作（如「查看全部」入口）。
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w700),
          ),
        ),
        ?action,
      ],
    );
  }
}

/// 「查看全部」入口：横屏开右侧内容容器，竖屏 push 二级路由。
Widget _viewAllAction(BuildContext context, WidgetRef ref, String route) {
  final scheme = Theme.of(context).colorScheme;
  return InkWell(
    onTap: () => openDiscoverEntry(context, ref, route),
    borderRadius: BorderRadius.circular(6),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      child: Row(
        children: [
          Text(
            tr('查看全部'),
            style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
          ),
          Icon(Icons.chevron_right, size: 16, color: scheme.onSurfaceVariant),
        ],
      ),
    ),
  );
}

class _MostPlayedList extends ConsumerWidget {
  const _MostPlayedList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final most = ref.watch(mostPlayedProvider);
    return most.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ),
      error: (_, _) => const SizedBox.shrink(),
      data: (entries) {
        if (entries.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Center(
              child: Text(
                tr('暂无播放记录'),
                style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          );
        }
        return Column(
          children: [
            for (var i = 0; i < entries.length; i++) ...[
              _MostPlayedRow(entry: entries[i]),
              if (i != entries.length - 1) const SizedBox(height: 8),
            ],
          ],
        );
      },
    );
  }
}

class _MostPlayedRow extends ConsumerWidget {
  const _MostPlayedRow({required this.entry});

  final MostPlayedEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final song = entry.song;
    return frostedCardSurface(
      context: context,
      ref: ref,
      radius: 13,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(13),
        child: InkWell(
          onTap: () =>
              ref.read(libraryProvider.notifier).playList([song], 0),
          borderRadius: BorderRadius.circular(13),
          child: Container(
            height: 62,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
            children: [
              CoverImage(
                songPath: song.path,
                width: 42,
                height: 42,
                radius: 10,
                icon: Icons.music_note,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      song.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      song.artist,
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
              const SizedBox(width: 8),
              Text(
                tr('{n} 次', {'n': entry.playCount}),
                style: TextStyle(
                  fontSize: 12,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                width: 34,
                height: 34,
                decoration: const BoxDecoration(
                  color: Color(0x24EC4141),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.play_arrow,
                  size: 20,
                  color: Color(0xFFEC4141),
                ),
              ),
            ],
          ),
        ),
      ),
      ),
    );
  }
}

class _AmbientBackground extends StatelessWidget {
  const _AmbientBackground();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Stack(
        children: [
          Positioned(
            top: -80,
            right: -60,
            child: _glow(300, const Color(0x59EC4141)),
          ),
          Positioned(
            bottom: 120,
            left: -100,
            child: _glow(340, const Color(0x4D5A78DC)),
          ),
        ],
      ),
    );
  }

  Widget _glow(double size, Color color) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [color, color.withValues(alpha: 0)],
        ),
      ),
    );
  }
}
