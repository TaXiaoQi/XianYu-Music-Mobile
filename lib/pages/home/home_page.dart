import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../src/home/home_providers.dart';
import '../../src/library/library_provider.dart';
import '../../src/navigation/shell.dart';
import '../../src/widgets/cover_carousel.dart';
import '../../src/widgets/cover_image.dart';
import '../../src/widgets/glass_appbar.dart';
import 'discover_section.dart';
import '../../src/i18n/i18n.dart';

/// 首页：顶栏（标题+搜索框）/ 封面轮播 / 发现 / 听过最多。
///
/// 顶栏为毛玻璃固定条，扩展至搜索框下；设置入口在「我的」页右上角菜单。
class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final searchBar = _SearchBarBottom(
      onTap: () => context.push('/search'),
      onRecognize: () => context.push('/recognize'),
    );

    return Scaffold(
      body: Stack(
        children: [
          const _AmbientBackground(),
          // 内容主体：顶部避让扩展后的顶栏（标题行+搜索框）。
          ListView(
            padding: EdgeInsets.fromLTRB(
                18, GlassTopBar.height(context, bottom: searchBar), 18, ref.watch(navBarInsetProvider) + 24),
            children:   [
              SizedBox(height: 14),
              CoverCarousel(),
              SizedBox(height: 26),
              _SectionHeader(title: tr('发现')),
              SizedBox(height: 12),
              DiscoverSection(),
              SizedBox(height: 26),
              _SectionHeader(title: tr('听过最多')),
              SizedBox(height: 14),
              _MostPlayedList(),
            ],
          ),
          // 顶栏：状态栏+「弦予音乐」标题+搜索框，滚动内容从其下方穿过被毛玻璃模糊。
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: GlassTopBar(
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
              titleSpacing: 18,
              bottom: searchBar,
            ),
          ),
        ],
      ),
    );
  }
}

/// 顶栏搜索框扩展区（PreferredSizeWidget 以便 GlassTopBar 计算 height）。
class _SearchBarBottom extends StatelessWidget implements PreferredSizeWidget {
  const _SearchBarBottom({required this.onTap, required this.onRecognize});

  final VoidCallback onTap;
  final VoidCallback onRecognize;

  @override
  Size get preferredSize => const Size.fromHeight(58);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 2, 18, 12),
      child: _SearchBar(onTap: onTap, onRecognize: onRecognize),
    );
  }
}

class _SearchBar extends StatelessWidget {
  const _SearchBar({required this.onTap, required this.onRecognize});

  final VoidCallback onTap;
  final VoidCallback onRecognize;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.white.withValues(alpha: 0.34),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          height: 44,
          padding: const EdgeInsets.fromLTRB(18, 0, 6, 0),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
          ),
          child: Row(
            children: [
              Icon(Icons.search, size: 18, color: scheme.onSurfaceVariant),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  tr('搜索歌曲、歌手、专辑'),
                  style: TextStyle(
                    fontSize: 14,
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // 听歌识曲入口：搜索框内右侧
              GestureDetector(
                onTap: onRecognize,
                behavior: HitTestBehavior.opaque,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEC4141).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children:   [
                      Icon(Icons.mic_none, size: 16, color: Color(0xFFEC4141)),
                      SizedBox(width: 3),
                      Text(
                        tr('识曲'),
                        style: TextStyle(
                          fontSize: 12,
                          color: Color(0xFFEC4141),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w700),
    );
  }
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
    return Material(
      color: Colors.white.withValues(alpha: 0.34),
      borderRadius: BorderRadius.circular(13),
      child: InkWell(
        onTap: () =>
            ref.read(libraryProvider.notifier).playList([song], 0),
        borderRadius: BorderRadius.circular(13),
        child: Container(
          height: 62,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(13),
            border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
          ),
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
