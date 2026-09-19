import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../src/core/settings.dart';
import '../../src/home/home_providers.dart';
import '../../src/library/library_provider.dart';
import '../../src/navigation/shell.dart';
import '../../src/plugin/plugin_provider.dart';
import '../../src/responsive/landscape.dart';
import '../../src/widgets/cover_carousel.dart';
import '../../src/widgets/cover_image.dart';
import '../../src/widgets/glass_appbar.dart';
import '../../src/widgets/glass_settings.dart';
import '../../src/widgets/page_search_bar.dart';
import 'discover_section.dart';
import '../../src/i18n/i18n.dart';

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  @override
  Widget build(BuildContext context) {
    final ref = this.ref;
    return useLandscape(ref)
        ? _buildLandscape(context, ref)
        : _buildPortrait(context, ref);
  }

  List<Widget> _discoverBlocks(BuildContext context, WidgetRef ref) {
    final hasEnabledPlugin = ref.watch(pluginManagerProvider
        .select((s) => s.sources.any((p) => p.enabled)));
    if (!hasEnabledPlugin) return const [];
    return [
      _SectionHeader(
        title: tr('发现'),
        action: _viewAllAction(context, ref, '/home/toplists'),
      ),
      const SizedBox(height: 12),
      const DiscoverSection(),
      const SizedBox(height: 26),
      _SectionHeader(
        title: tr('每日推荐'),
        action: _viewAllAction(context, ref, '/home/daily'),
      ),
      const SizedBox(height: 14),
      const DailyRecommendSection(),
      const SizedBox(height: 26),
    ];
  }

  Widget _buildPortrait(BuildContext context, WidgetRef ref) {
    final floating = ref.watch(settingsProvider.select(
        (s) => s.valueOrNull?.floatingSearchBar ?? false));
    final searchBar = PageSearchBarBottom(
      onTap: () => context.push('/search'),
      onRecognize: () => context.push('/recognize'),
    );
    final statusBar = MediaQuery.paddingOf(context).top;
    final topInset = floating
        ? statusBar + 8 + 44 + 14
        : GlassTopBar.height(context, bottom: searchBar);

    return Scaffold(
      body: Stack(
        children: [
          const _AmbientBackground(),
          RepaintBoundary(
            child: ListView(
            padding: EdgeInsets.fromLTRB(
                18, topInset, 18, ref.watch(navBarInsetProvider) + 24),
            children: [
              SizedBox(height: 14),
              CoverCarousel(),
              SizedBox(height: 26),
              ..._discoverBlocks(context, ref),
              _SectionHeader(title: tr('听过最多')),
              SizedBox(height: 14),
              _MostPlayedList(),
            ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLandscape(BuildContext context, WidgetRef ref) {
    final floating = ref.watch(
        settingsProvider.select((s) => s.valueOrNull?.floatingSearchBar ?? false));
    final topInset = floating ? MediaQuery.paddingOf(context).top + 60 + 12 : 12.0;
    return Scaffold(
      body: Stack(
        children: [
          const _AmbientBackground(),
          ListView(
            padding: EdgeInsets.fromLTRB(
                18, topInset, 18, ref.watch(navBarInsetProvider) + 24),
            children: [
              SizedBox(height: 10),
              ..._discoverBlocks(context, ref),
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
