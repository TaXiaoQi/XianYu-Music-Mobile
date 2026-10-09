import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../src/auth/account_api.dart';
import '../../src/theme/theme_tint.dart';
import '../../src/core/app_colors.dart';
import '../../src/core/application_logger.dart';
import '../../src/core/db_path.dart';
import '../../src/core/settings.dart';
import '../../src/favorites/favorites_provider.dart';
import '../../src/library/library_provider.dart';
import '../../src/navigation/shell.dart';
import '../../src/player/player_provider.dart';
import '../../src/plugin/plugin_catalog.dart';
import '../../src/plugin/plugin_host_fallback.dart';
import '../../src/plugin/plugin_models.dart';
import '../../src/plugin/plugin_provider.dart';
import '../../src/plugin/plugin_search.dart';
import '../../src/playlist/playlist_provider.dart';
import '../../src/playlist/playlist_store.dart';
import '../../src/widgets/app_toast.dart';
import '../../src/rust/api.dart';
import '../../src/search/search_history_store.dart';
import '../../src/widgets/cover_image.dart';
import '../../src/widgets/drag_handle.dart';
import '../../src/widgets/flying_cover.dart';
import '../../src/widgets/glass_appbar.dart';
import '../../src/widgets/stagger_in.dart';
import '../../src/widgets/glass_settings.dart';
import '../../src/widgets/floating_search_bar.dart';
import '../../src/widgets/list_metrics.dart';
import '../../src/widgets/source_tag.dart';
import '../../src/widgets/online_cover.dart';
import '../../src/widgets/song_actions_sheet.dart';
import '../../src/widgets/song_list_scroll_fabs.dart';
import '../../src/widgets/song_list_view.dart';
import '../home/online_detail_page.dart';
import '../library/song_list_page.dart';
import '../../src/widgets/custom_background.dart';
import '../../src/i18n/i18n.dart';

part 'search_page.models.dart';
part 'search_page.session.dart';
part 'search_page.input.dart';
part 'search_page.idle.dart';
part 'search_page.result_bar.dart';
part 'search_page.track_tab.dart';
part 'search_page.catalog_tab.dart';

// ==================== 搜索页 ====================

class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key, this.initialQuery});

  final String? initialQuery;

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage>
    with HidesShellChrome, HideMiniBar {
  final TextEditingController _ctrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    final q = widget.initialQuery;
    if (q != null && q.isNotEmpty) {
      _ctrl.text = q;
      _lastQueryLength = q.length;
    }
  }

  int _pendingCharCount = 0;
  int _lastQueryLength = 0;
  Timer? _inputFlushTimer;

  Timer? _suggestDebounce;
  String _suggestQuery = '';
  List<String> _keywords = const [];

  @override
  void dispose() {
    _inputFlushTimer?.cancel();
    _suggestDebounce?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final floating = ref.watch(settingsProvider.select(
        (s) => s.valueOrNull?.floatingSearchBar ?? false));
    final statusBar = MediaQuery.paddingOf(context).top;

    return Scaffold(
      backgroundColor: appScaffoldBackground(context, ref),
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          if (_suggestQuery.isNotEmpty && _keywords.isNotEmpty)
            _SuggestionView(
              query: _suggestQuery,
              keywords: _keywords,
              topPadding:
                  floating ? statusBar + 66 : GlassTopBar.height(context),
              onSubmit: _submitSearch,
            )
          else
            SearchIdleView(
              onSearch: _submitSearch,
              topPadding:
                  floating ? statusBar + 66 : GlassTopBar.height(context),
            ),
          if (floating)
            Positioned(
              top: statusBar + 8,
              left: 12,
              right: 12,
              child: FloatingSearchTopBar(
                onBack: () => context.pop(),
                field: FloatingGlassSearchField(
                  controller: _ctrl,
                  autofocus: true,
                  onChanged: _onChanged,
                  onSubmitted: (q) => _submitSearch(q),
                  showClear: _ctrl.text.isNotEmpty,
                  onClear: _clearInput,
                ),
                action: BiliPaiIconButton(
                  icon: Icons.search,
                  tooltip: tr('搜索'),
                  color: scheme.primary,
                  onTap: () => _submitSearch(_ctrl.text),
                ),
              ),
            )
          else
            Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: GlassTopBar(
              leading: const BackButton(),
              title: Container(
                height: 40,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: searchBoxFill(context, ref),
                  borderRadius: BorderRadius.circular(20),
                ),
                alignment: Alignment.centerLeft,
                child: TextField(
                  controller: _ctrl,
                  autofocus: true,
                  textInputAction: TextInputAction.search,
                  style: const TextStyle(fontSize: 15),
                  textAlignVertical: TextAlignVertical.center,
                  onChanged: _onChanged,
                  onSubmitted: (q) => _submitSearch(q),
                  decoration: InputDecoration(
                    hintText: tr('搜索音乐、歌手、专辑、歌单'),
                    isDense: true,
                    contentPadding: EdgeInsets.zero,
                    border: InputBorder.none,
                    suffixIcon: _ctrl.text.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.clear, size: 20),
                            padding: EdgeInsets.zero,
                            constraints:
                                const BoxConstraints.tightFor(width: 32, height: 40),
                            onPressed: _clearInput,
                          ),
                  ),
                ),
              ),
              actions: [
                IconButton(
                  tooltip: tr('搜索'),
                  icon: const Icon(Icons.search),
                  style: IconButton.styleFrom(
                    backgroundColor: scheme.primary,
                    foregroundColor: scheme.onPrimary,
                  ),
                  onPressed: () => _submitSearch(_ctrl.text),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ==================== 搜索结果页 ====================

class SearchResultPage extends ConsumerStatefulWidget {
  const SearchResultPage({super.key, this.embedded = false});

  final bool embedded;

  @override
  ConsumerState<SearchResultPage> createState() => _SearchResultPageState();
}

class _SearchResultPageState extends ConsumerState<SearchResultPage>
    with TickerProviderStateMixin, HidesShellChrome {
  @override
  bool get hidesChrome => !widget.embedded;

  late final TabController _tab;
  final TextEditingController _queryCtrl = TextEditingController();

  List<_SourceItem> _sources = const [];
  String _selectedSourceId = '';
  int _activeIndex = 0;

  PageController? _pageCtrl;
  final Map<String, GlobalKey> _sourceKeys = {};

  @override
  void initState() {
    super.initState();
    _queryCtrl.text = ref.read(searchSessionProvider).query;
    _tab = TabController(length: 4, vsync: this);
    _tab.addListener(_onTabChanged);
    ref.listenManual(pluginManagerProvider, (_, _) => _refreshSources());
    ref.listenManual(searchSessionProvider, (prev, next) {
      if (next.query != _queryCtrl.text) {
        _queryCtrl.text = next.query;
      }
    });
    _refreshSources();
  }

  @override
  void dispose() {
    _tab.removeListener(_onTabChanged);
    _tab.dispose();
    _pageCtrl?.dispose();
    _queryCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final keyword = ref.watch(searchSessionProvider).query;
    final selected = _selected;

    final tabBar = TabBar(
      controller: _tab,
      dividerColor: Colors.transparent,
      tabs:   [
        Tab(text: tr('单曲')),
        Tab(text: tr('歌手')),
        Tab(text: tr('专辑')),
        Tab(text: tr('歌单')),
      ],
    );

    final Widget contentArea = _pageCtrl != null
        ? PageView.builder(
            controller: _pageCtrl,
            onPageChanged: _onSourcePageChanged,
            itemCount: _sources.length,
            itemBuilder: (context, i) => _buildSourceContent(_sources[i]),
          )
        : TabBarView(
            controller: _tab,
            children: [
              _TrackTab(
                keyword: keyword,
                source: selected,
              ),
              _CatalogTab(
                kind: _CatalogKind.artist,
                keyword: keyword,
                source: selected,
              ),
              _CatalogTab(
                kind: _CatalogKind.album,
                keyword: keyword,
                source: selected,
              ),
              _CatalogTab(
                kind: _CatalogKind.playlist,
                keyword: keyword,
                source: selected,
              ),
            ],
          );

    if (widget.embedded) {
      return Scaffold(
        backgroundColor: appScaffoldBackground(context, ref),
        resizeToAvoidBottomInset: false,
        body: Padding(
          padding: EdgeInsets.only(top: GlassTopBar.height(context)),
          child: Column(
            children: [
              tabBar,
              _buildSourceBar(),
              Expanded(child: contentArea),
            ],
          ),
        ),
      );
    }

    final statusBar = MediaQuery.paddingOf(context).top;
    final floating = ref.watch(settingsProvider.select(
        (s) => s.valueOrNull?.floatingSearchBar ?? false));
    final wallpaperGap = ref.watch(wallpaperActiveProvider) ? 8.0 : 0.0;
    final chromeBottom = PreferredSizeProxy(
      height: tabBar.preferredSize.height + wallpaperGap + 40,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          tabBar,
          SizedBox(height: wallpaperGap),
          _buildSourceBar(),
        ],
      ),
    );
    final topInset = floating
        ? statusBar + 8 + 44 + 10 + 48 + 10 + 40
        : GlassTopBar.height(context, bottom: chromeBottom);

    return AppPageBackground(
      child: Scaffold(
        backgroundColor: appScaffoldBackground(context, ref),
        resizeToAvoidBottomInset: false,
        body: Stack(
        children: [
          SizedBox.expand(
            child: _withContentTopInset(contentArea, topInset + 6),
          ),
          if (floating)
            Positioned(
              top: statusBar + 8,
              left: 12,
              right: 12,
              child: FloatingSearchTopBar(
                onBack: () => context.pop(),
                field: FloatingGlassSearchField(
                  controller: _queryCtrl,
                  readOnly: true,
                  onTap: _goToSearchPage,
                  hint: keyword.isEmpty ? tr('搜索音乐、歌手、专辑、歌单') : null,
                ),
                action: BiliPaiIconButton(
                  icon: Icons.search,
                  tooltip: tr('返回搜索'),
                  color: scheme.primary,
                  onTap: _goToSearchPage,
                ),
                tabPill: FloatingTabPill(child: tabBar),
                bottomPill: _buildSourceBar(floating: true),
              ),
            )
          else
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: GlassTopBar(
                leading: const BackButton(),
              title: Container(
                height: 40,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: searchBoxFill(context, ref),
                  borderRadius: BorderRadius.circular(20),
                ),
                alignment: Alignment.centerLeft,
                child: TextField(
                  controller: _queryCtrl,
                  readOnly: true,
                  onTap: _goToSearchPage,
                  style: const TextStyle(fontSize: 15),
                  textAlignVertical: TextAlignVertical.center,
                  decoration: InputDecoration(
                    hintText:
                        keyword.isEmpty ? tr('搜索音乐、歌手、专辑、歌单') : null,
                    isDense: true,
                    contentPadding: EdgeInsets.zero,
                    border: InputBorder.none,
                  ),
                ),
              ),
              actions: [
                IconButton(
                  tooltip: tr('返回搜索'),
                  icon: const Icon(Icons.search),
                  style: IconButton.styleFrom(
                    backgroundColor: scheme.primary,
                    foregroundColor: scheme.onPrimary,
                  ),
                  onPressed: _goToSearchPage,
                ),
              ],
              bottom: chromeBottom,
              ),
            ),
        ],
      ),
    ),
  );
  }

  Widget _withContentTopInset(Widget contentArea, double inset) {
    return _ContentTopInsetScope(inset: inset, child: contentArea);
  }

  Widget _buildSourceContent(_SourceItem source) {
    final keyword = ref.watch(searchSessionProvider).query;
    switch (_tab.index) {
      case 1:
        return _CatalogTab(
          kind: _CatalogKind.artist,
          keyword: keyword,
          source: source,
        );
      case 2:
        return _CatalogTab(
          kind: _CatalogKind.album,
          keyword: keyword,
          source: source,
        );
      case 3:
        return _CatalogTab(
          kind: _CatalogKind.playlist,
          keyword: keyword,
          source: source,
        );
      default:
        return _TrackTab(keyword: keyword, source: source);
    }
  }

  void _goToSearchPage() {
    final q = ref.read(searchSessionProvider).query;
    context.push(q.isEmpty ? '/search' : '/search?q=${Uri.encodeComponent(q)}');
  }
}

// ==================== 公共组件 ====================

Widget _emptyHint(String message, ColorScheme scheme,
    {required String source, String? actionLabel, VoidCallback? onAction}) {
  return Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.search_off, size: 40, color: scheme.outline),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            message,
            style: TextStyle(color: scheme.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          tr('结果来自 {source}', {'source': source}),
          style: TextStyle(fontSize: 12, color: scheme.outline),
        ),
        if (actionLabel != null && onAction != null) ...[
          const SizedBox(height: 12),
          FilledButton.tonal(
            onPressed: onAction,
            child: Text(actionLabel),
          ),
        ],
      ],
    ),
  );
}

Widget _letterLeading(String name, ColorScheme scheme) {
  return DecoratedBox(
    decoration: BoxDecoration(
      color: scheme.primaryContainer,
      shape: BoxShape.circle,
    ),
    child: Center(
      child: Text(
        name.isEmpty ? '?' : String.fromCharCode(name.runes.first),
        style: TextStyle(color: scheme.onPrimaryContainer),
      ),
    ),
  );
}
