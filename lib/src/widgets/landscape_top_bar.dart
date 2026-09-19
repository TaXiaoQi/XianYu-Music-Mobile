import 'dart:async';

import 'package:go_router/go_router.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../pages/search/search_page.dart';
import '../auth/account_api.dart';
import '../i18n/i18n.dart';
import '../navigation/shell.dart'
    show
        landscapeDownloadOpenProvider,
        landscapeLibraryProvider,
        landscapeLibraryQueryProvider,
        landscapeLibrarySearchActiveProvider,
        landscapeLibrarySearchCtrlProvider,
        landscapeLibrarySearchFocusProvider,
        landscapePlaylistOpenProvider;
import 'glass_appbar.dart';
import 'floating_search_bar.dart';
import 'glass_settings.dart';
import 'page_search_bar.dart';
import 'skin_icon.dart';

class LandscapeSearchBar extends ConsumerWidget {
  const LandscapeSearchBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PageSearchBar(
      onTap: () {
        final inLibPane = ref.read(landscapeLibraryProvider) != null;
        if (inLibPane) {
          ref.read(landscapeLibraryQueryProvider.notifier).state = '';
          ref.read(landscapeLibrarySearchActiveProvider.notifier).state = true;
        } else {
          ref.read(landscapeSearchOpenProvider.notifier).state = true;
        }
      },
      onRecognize: () => context.push('/recognize'),
    );
  }
}

class LandscapeGlobalTopBar extends ConsumerWidget {
  const LandscapeGlobalTopBar({
    super.key,
    this.currentIndex = 0,
    this.floating = false,
  });

  final int currentIndex;

  final bool floating;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final downloadOpen = ref.watch(landscapeDownloadOpenProvider);
    final playlistOpenId = ref.watch(landscapePlaylistOpenProvider);
    final libSel = ref.watch(landscapeLibraryProvider);
    final isLibPane = libSel != null;
    final localSearchActive =
        ref.watch(landscapeLibrarySearchActiveProvider);
    final searchOpen = ref.watch(landscapeSearchOpenProvider);
    final canBack = searchOpen ||
        playlistOpenId != null ||
        downloadOpen ||
        libSel != null ||
        currentIndex != 0;

    void handleBack() {
      if (isLibPane &&
          ref.read(landscapeLibrarySearchActiveProvider.notifier).state) {
        ref.read(landscapeLibraryQueryProvider.notifier).state = '';
        ref.read(landscapeLibrarySearchActiveProvider.notifier).state = false;
        return;
      }
      if (ref.read(landscapeSearchOpenProvider.notifier).state) {
        final rs = ref.read(landscapeSearchResultsProvider.notifier);
        if (rs.state) {
          rs.state = false;
        } else {
          ref.read(landscapeSearchOpenProvider.notifier).state = false;
        }
        return;
      }
      final pl = ref.read(landscapePlaylistOpenProvider.notifier);
      if (pl.state != null) {
        pl.state = null;
        return;
      }
      final dl = ref.read(landscapeDownloadOpenProvider.notifier);
      if (dl.state) {
        dl.state = false;
        return;
      }
      final lib = ref.read(landscapeLibraryProvider.notifier);
      if (lib.state != null) {
        lib.state = null;
        return;
      }
      if (currentIndex != 0) {
        context.go('/home');
        return;
      }
      if (context.canPop()) context.pop();
    }

    if (floating) {
      return Padding(
        padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Row(
            children: [
              BiliPaiIconButton(
                icon: Icons.arrow_back,
                tooltip: tr('返回'),
                color: canBack ? null : Theme.of(context).disabledColor,
                onTap: canBack ? handleBack : null,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: (isLibPane && localSearchActive)
                    ? const _LandscapeLibrarySearchField(floating: true)
                    : searchOpen
                        ? const _LandscapeSearchField(floating: true)
                        : FloatingSearchBar(
                            onTap: () {
                              final inLibPane = ref
                                      .read(landscapeLibraryProvider) !=
                                  null;
                              if (inLibPane) {
                                ref
                                        .read(landscapeLibraryQueryProvider
                                            .notifier)
                                        .state =
                                    '';
                                ref
                                        .read(landscapeLibrarySearchActiveProvider
                                            .notifier)
                                        .state =
                                    true;
                              } else {
                                ref
                                    .read(landscapeSearchOpenProvider.notifier)
                                    .state = true;
                              }
                            },
                            onRecognize: () => context.push('/recognize'),
                          ),
              ),
              const SizedBox(width: 10),
              BiliPaiIconButton(
                iconChild: const SkinIcon(),
                tooltip: tr('皮肤'),
                onTap: () => context.push('/wallpaper'),
              ),
              const SizedBox(width: 8),
              BiliPaiIconButton(
                icon: Icons.settings_outlined,
                tooltip: tr('设置'),
                onTap: () => context.push('/settings'),
              ),
            ],
          ),
        ),
      );
    }

    return GlassTopBar(
      leading: IconButton(
        icon: const Icon(Icons.arrow_back),
        tooltip: tr('返回'),
        color: canBack ? null : Theme.of(context).disabledColor,
        onPressed: canBack ? handleBack : null,
      ),
      title: Padding(
        padding: const EdgeInsets.only(right: 8),
        child: DefaultTextStyle(
          style: const TextStyle(fontWeight: FontWeight.w400),
          child: SizedBox(
            width: double.infinity,
            child: (isLibPane && localSearchActive)
                ? const _LandscapeLibrarySearchField()
                : searchOpen
                    ? const _LandscapeSearchField()
                    : const LandscapeSearchBar(),
          ),
        ),
      ),
      actions: [
        IconButton(
          icon: const SkinIcon(),
          tooltip: tr('皮肤'),
          onPressed: () => context.push('/wallpaper'),
        ),
        const SizedBox(width: 8),
        IconButton(
          icon: const Icon(Icons.settings_outlined),
          tooltip: tr('设置'),
          onPressed: () => context.push('/settings'),
        ),
        const SizedBox(width: 16),
      ],
    );
  }
}

class _LandscapeSearchField extends ConsumerStatefulWidget {
  const _LandscapeSearchField({this.floating = false});

  final bool floating;

  @override
  ConsumerState<_LandscapeSearchField> createState() =>
      _LandscapeSearchFieldState();
}

class _LandscapeSearchFieldState extends ConsumerState<_LandscapeSearchField> {
  late final TextEditingController _ctrl =
      ref.read(landscapeSearchCtrlProvider);

  int _pendingCharCount = 0;
  int _lastQueryLength = 0;
  Timer? _inputFlushTimer;

  @override
  void initState() {
    super.initState();
    _lastQueryLength = _ctrl.text.length;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final node = ref.read(landscapeSearchFocusProvider);
      if (node.hasFocus) {
        node.unfocus();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) node.requestFocus();
        });
      } else {
        node.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    _inputFlushTimer?.cancel();
    super.dispose();
  }

  void _onChanged(String keyword) {
    setState(() {});

    final len = keyword.length;
    final delta = len - _lastQueryLength;
    _lastQueryLength = len;
    if (delta > 0) {
      _pendingCharCount += delta;
      _inputFlushTimer?.cancel();
      _inputFlushTimer = Timer(const Duration(milliseconds: 1500), () {
        final count = _pendingCharCount;
        _pendingCharCount = 0;
        if (count > 0) {
          ref.read(accountApiProvider).reportInputStats(count);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasText = _ctrl.text.isNotEmpty;
    final content = Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        height: 44,
        padding: const EdgeInsets.fromLTRB(18, 0, 6, 0),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _ctrl,
                focusNode: ref.watch(landscapeSearchFocusProvider),
                textInputAction: TextInputAction.search,
                style: const TextStyle(fontSize: 15),
                onChanged: _onChanged,
                onSubmitted: (q) => submitLandscapeSearch(ref, q),
                decoration: InputDecoration(
                  hintText: tr('搜索音乐、歌手、专辑、歌单'),
                  isDense: true,
                  contentPadding: EdgeInsets.zero,
                  border: InputBorder.none,
                ),
              ),
            ),
            if (hasText)
              GestureDetector(
                onTap: () {
                  _ctrl.clear();
                  setState(() {});
                },
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Icon(
                    Icons.clear,
                    size: 17,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            const SizedBox(width: 6),
            GestureDetector(
              onTap: () => context.push('/recognize'),
              behavior: HitTestBehavior.opaque,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
                decoration: BoxDecoration(
                  color: const Color(0xFFEC4141).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(
                  Icons.mic_none,
                  size: 17,
                  color: Color(0xFFEC4141),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    if (widget.floating) {
      return FloatingGlassSurface(child: content);
    }
    return Material(
      color: searchBoxFill(context, ref),
      borderRadius: BorderRadius.circular(999),
      child: content,
    );
  }
}

class _LandscapeLibrarySearchField extends ConsumerStatefulWidget {
  const _LandscapeLibrarySearchField({this.floating = false});

  final bool floating;

  @override
  ConsumerState<_LandscapeLibrarySearchField> createState() =>
      _LandscapeLibrarySearchFieldState();
}

class _LandscapeLibrarySearchFieldState
    extends ConsumerState<_LandscapeLibrarySearchField> {
  late final TextEditingController _ctrl =
      ref.read(landscapeLibrarySearchCtrlProvider);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final node = ref.read(landscapeLibrarySearchFocusProvider);
      if (node.hasFocus) {
        node.unfocus();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) node.requestFocus();
        });
      } else {
        node.requestFocus();
      }
    });
  }

  void _onChanged(String value) {
    setState(() {});
    ref.read(landscapeLibraryQueryProvider.notifier).state = value;
  }

  void _clear() {
    _ctrl.clear();
    ref.read(landscapeLibraryQueryProvider.notifier).state = '';
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasText = _ctrl.text.isNotEmpty;
    final content = Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        height: 44,
        padding: const EdgeInsets.fromLTRB(18, 0, 6, 0),
        child: Row(
          children: [
            Icon(Icons.search, size: 18, color: scheme.onSurfaceVariant),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: _ctrl,
                focusNode: ref.watch(landscapeLibrarySearchFocusProvider),
                textInputAction: TextInputAction.search,
                style: const TextStyle(fontSize: 15),
                onChanged: _onChanged,
                onSubmitted: (_) =>
                    FocusManager.instance.primaryFocus?.unfocus(),
                decoration: InputDecoration(
                  hintText: tr('搜索本地歌曲、歌手、专辑'),
                  isDense: true,
                  contentPadding: EdgeInsets.zero,
                  border: InputBorder.none,
                ),
              ),
            ),
            if (hasText)
              GestureDetector(
                onTap: _clear,
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Icon(
                    Icons.clear,
                    size: 17,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            const SizedBox(width: 6),
          ],
        ),
      ),
    );
    if (widget.floating) {
      return FloatingGlassSurface(child: content);
    }
    return Material(
      color: searchBoxFill(context, ref),
      borderRadius: BorderRadius.circular(999),
      child: content,
    );
  }
}