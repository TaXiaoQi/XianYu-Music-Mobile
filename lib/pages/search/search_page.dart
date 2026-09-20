import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../src/auth/account_api.dart';
import '../../src/auth/auth_provider.dart';
import '../../src/core/app_colors.dart';
import '../../src/core/app_logger.dart';
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
import '../../src/widgets/bottom_play_bar_slot.dart';
import '../../src/widgets/cover_image.dart';
import '../../src/widgets/flying_cover.dart';
import '../../src/widgets/glass_appbar.dart';
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

// ==================== 来源模型 ====================

enum _SourceType { local, musicfree, lx }

class _SourceItem {
  final String id;
  final String name;
  final _SourceType type;
  final PluginSource? plugin;
  final String? lxKey;

  const _SourceItem({
    required this.id,
    required this.name,
    required this.type,
    this.plugin,
    this.lxKey,
  });

  bool get isLocal => type == _SourceType.local;
}

const _validLxSources = {'kw', 'kg', 'tx', 'wy', 'mg'};
Map<String, String> get _lxSourceNames => <String, String>{
  'kw': tr('小蜗音乐'),
  'kg': tr('小枸音乐'),
  'tx': tr('小秋音乐'),
  'wy': tr('小芸音乐'),
  'mg': tr('小蜜音乐'),
};

// ==================== 结果模型 ====================

class _TrackEntry {
  final bool isLocal;
  final Song? localSong;
  final PluginSource? pluginSource;
  final PluginSearchResult? pluginResult;

  const _TrackEntry({
    required this.isLocal,
    this.localSong,
    this.pluginSource,
    this.pluginResult,
  });
}

enum _CatalogKind { artist, album, playlist }

String _formatPlayCount(num n) {
  if (n >= 100000000) {
    return tr('{n}亿', {'n': (n / 100000000).toStringAsFixed(1)});
  }
  if (n >= 10000) return tr('{n}万', {'n': (n / 10000).toStringAsFixed(1)});
  return '$n';
}

class _CatalogItem {
  final String kind;
  final String title;
  final String subtitle;
  final String? coverUrl;
  final String sourceTag;
  final ArtistInfo? localArtist;
  final AlbumInfo? localAlbum;
  final ImportedPlaylist? localPlaylist;
  final PluginSource? onlinePlugin;
  final Map<String, dynamic>? onlineRaw;
  final PluginSource? directSource;
  final List<PluginSearchResult> directSongs;

  _CatalogItem({
    required this.kind,
    required this.title,
    this.subtitle = '',
    this.coverUrl,
    required this.sourceTag,
    this.localArtist,
    this.localAlbum,
    this.localPlaylist,
    this.onlinePlugin,
    this.onlineRaw,
    this.directSource,
    List<PluginSearchResult>? directSongs,
  }) : directSongs = directSongs ?? [];

  bool get isLocalEntry =>
      localArtist != null || localAlbum != null || localPlaylist != null;
  bool get isDirectPlay => directSource != null && directSongs.isNotEmpty;
}

// ==================== 在线搜索会话（跨搜索页/结果页两级路由） ====================

class SearchSession {
  final String query;
  final String sourceId;
  const SearchSession({this.query = '', this.sourceId = ''});
}

final searchSessionProvider =
    NotifierProvider<SearchSessionNotifier, SearchSession>(
        SearchSessionNotifier.new);

class SearchSessionNotifier extends Notifier<SearchSession> {
  @override
  SearchSession build() => const SearchSession();

  void startSearch(String query, String sourceId) =>
      state = SearchSession(query: query, sourceId: sourceId);

  void setSource(String id) =>
      state = SearchSession(query: state.query, sourceId: id);
}

// ==================== 横屏搜索容器（参考桌面端：顶栏即搜索输入） ====================

final landscapeSearchOpenProvider = StateProvider<bool>((ref) => false);

final landscapeSearchResultsProvider = StateProvider<bool>((ref) => false);

final landscapeSearchCtrlProvider = Provider<TextEditingController>((ref) {
  final ctrl = TextEditingController();
  ref.onDispose(ctrl.dispose);
  return ctrl;
});

final landscapeSearchFocusProvider = Provider<FocusNode>((ref) {
  final node = FocusNode();
  ref.onDispose(node.dispose);
  return node;
});

void closeLandscapeSearch(WidgetRef ref) {
  ref.read(landscapeSearchOpenProvider.notifier).state = false;
  ref.read(landscapeSearchResultsProvider.notifier).state = false;
}

void submitLandscapeSearch(WidgetRef ref, String raw) {
  final q = raw.trim();
  if (q.isEmpty) return;
  FocusManager.instance.primaryFocus?.unfocus();
  ref.read(landscapeSearchCtrlProvider).text = q;
  ref.read(searchHistoryProvider.notifier).add(q);
  final sourceId = ref.read(searchSessionProvider).sourceId;
  ref.read(searchSessionProvider.notifier).startSearch(q, sourceId);
  ref.read(landscapeSearchResultsProvider.notifier).state = true;
}

// ==================== 输入关键词联想视图 ====================

class _SuggestionView extends StatelessWidget {
  const _SuggestionView({
    required this.query,
    required this.keywords,
    required this.topPadding,
    required this.onSubmit,
  });

  final String query;
  final List<String> keywords;
  final double topPadding;
  final void Function(String) onSubmit;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bottomInset = MediaQuery.of(context).padding.bottom + 24;

    return ListView(
      padding: EdgeInsets.fromLTRB(16, topPadding, 16, bottomInset),
      children: [
        Row(
          children: [
            Icon(Icons.search, size: 18, color: scheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Text(
              tr('搜索联想'),
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        for (final w in keywords)
          InkWell(
            onTap: () => onSubmit(w),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                children: [
                  const SizedBox(width: 4),
                  Icon(Icons.search,
                      size: 16, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 12),
                  Expanded(
                    child: highlightedText(
                      w,
                      query,
                      scheme.primary,
                      maxLines: 1,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w500),
                    ),
                  ),
                  Icon(Icons.north_west,
                      size: 14, color: scheme.onSurfaceVariant),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

// ==================== 搜索页 ====================

class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key, this.initialQuery});

  final String? initialQuery;

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage>
    with HidesShellChrome {
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

    _suggestDebounce?.cancel();
    final q = keyword.trim();
    if (q.isEmpty) {
      if (_suggestQuery.isNotEmpty || _keywords.isNotEmpty) {
        setState(() {
          _suggestQuery = '';
          _keywords = const [];
        });
      }
      return;
    }
    _suggestDebounce = Timer(const Duration(milliseconds: 300), () {
      _runKeywordSuggest(q);
    });
  }

  Future<void> _runKeywordSuggest(String q) async {
    final lower = q.toLowerCase();
    final starts = <String>[];
    final contains = <String>[];
    void feed(String? raw) {
      final w = raw?.trim() ?? '';
      if (w.isEmpty || w == q) return;
      final wl = w.toLowerCase();
      if (starts.contains(w) || contains.contains(w)) return;
      if (wl.startsWith(lower)) {
        starts.add(w);
      } else if (wl.contains(lower)) {
        contains.add(w);
      }
    }

    for (final h in ref.read(searchHistoryProvider)) {
      feed(h);
    }
    try {
      final dbPath = await ref.read(dbPathProvider.future);
      final json = await searchLibrarySongs(
          dbPath: dbPath, query: q, limit: BigInt.from(10));
      final list = (jsonDecode(json) as List)
          .map((e) => Song.fromJson(e as Map<String, dynamic>))
          .toList();
      for (final s in list) {
        feed(s.title);
        feed(s.artist);
      }
    } catch (_) {}

    if (!mounted || _ctrl.text.trim() != q) return;
    setState(() {
      _suggestQuery = q;
      _keywords = [...starts, ...contains].take(10).toList();
    });
  }

  void _submitSearch(String raw) {
    final q = raw.trim();
    if (q.isEmpty) return;
    FocusScope.of(context).unfocus();
    if (_ctrl.text != q) _ctrl.text = q;
    ref.read(searchHistoryProvider.notifier).add(q);
    final sourceId = ref.read(searchSessionProvider).sourceId;
    ref.read(searchSessionProvider.notifier).startSearch(q, sourceId);
    // 结果页已紧邻本页下方（结果页→搜索页→再搜索）时直接返回复用它，
    // 否则 pushReplacement 会不断堆叠结果页，退出需逐层弹出。
    final matches = GoRouter.of(context).routerDelegate.currentConfiguration.matches;
    final below = matches.length >= 2 ? matches[matches.length - 2] : null;
    if (below is RouteMatch && below.matchedLocation == '/search/result') {
      context.pop();
      return;
    }
    context.pushReplacement('/search/result');
  }

  void _clearInput() {
    if (_ctrl.text.isNotEmpty) _ctrl.clear();
    setState(() {});
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
    // 从搜索页提交新关键词后 pop 回本页时，同步搜索框文本（结果页签 watch 会话自动刷新）。
    ref.listenManual(searchSessionProvider, (prev, next) {
      if (next.query != _queryCtrl.text) {
        _queryCtrl.text = next.query;
      }
    });
    _refreshSources();
  }

  void _onTabChanged() {
    final idx = _tab.index;
    if (idx == _activeIndex || !mounted) return;
    _activeIndex = idx;
    setState(() {});
  }

  void _onSourcePageChanged(int index) {
    if (!mounted || index < 0 || index >= _sources.length) return;
    final s = _sources[index];
    final changed = s.id != _selectedSourceId;
    _selectedSourceId = s.id;
    ref.read(searchSessionProvider.notifier).setSource(s.id);
    if (changed) setState(() {});
    final ctx = _sourceKeys[s.id]?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 300),
        curve: Curves.fastLinearToSlowEaseIn,
        alignment: 0.5,
      );
    }
  }

  @override
  void dispose() {
    _tab.removeListener(_onTabChanged);
    _tab.dispose();
    _pageCtrl?.dispose();
    _queryCtrl.dispose();
    super.dispose();
  }

  _SourceItem get _selected {
    for (final s in _sources) {
      if (s.id == _selectedSourceId) return s;
    }
    return _sources.isNotEmpty
        ? _sources.first
        :   _SourceItem(
            id: 'local', name: tr('本地'), type: _SourceType.local);
  }

  void _refreshSources() {
    final plugins = ref.read(pluginManagerProvider).sources;
    final showReal =
        ref.read(settingsProvider).valueOrNull?.showRealSourceName ?? false;
    final enabled = sortPluginSources(plugins.where((p) => p.enabled).toList());
    final items = <_SourceItem>[];
    for (final p in enabled) {
      final pName = showReal ? resolveRealSourceName(p.name) : p.name;
      if (p.format.isMfCompatible) {
        items.add(_SourceItem(
            id: p.id, name: pName, type: _SourceType.musicfree, plugin: p));
      } else if (p.format == PluginFormat.lx) {
        final lx = p.sources.where(_validLxSources.contains).toList();
        if (lx.isEmpty) continue;
        if (lx.length == 1) {
          items.add(_SourceItem(
              id: p.id,
              name: pName,
              type: _SourceType.lx,
              plugin: p,
              lxKey: lx.first));
        } else {
          for (final key in lx) {
            final rawName = _lxSourceNames[key] ?? key;
            items.add(_SourceItem(
                id: '${p.id}__$key',
                name: showReal ? resolveRealSourceName(rawName) : rawName,
                type: _SourceType.lx,
                plugin: p,
                lxKey: key));
          }
        }
      }
    }
    final result = items.isEmpty
        ?   [
            _SourceItem(id: 'local', name: tr('本地'), type: _SourceType.local)
          ]
        : items;
    if (!mounted) return;
    final sessionSource = ref.read(searchSessionProvider).sourceId;
    final initial = sessionSource.isNotEmpty ? sessionSource : result.first.id;

    if (result.length > 1) {
      _pageCtrl ??= PageController();
      for (final s in result) {
        _sourceKeys[s.id] ??= GlobalKey();
      }
      _sourceKeys.removeWhere((id, _) => !result.any((s) => s.id == id));
    } else {
      _pageCtrl = null;
      _sourceKeys.clear();
    }

    setState(() {
      _sources = result;
      _selectedSourceId =
          result.any((s) => s.id == initial) ? initial : result.first.id;
    });
  }

  void _onSourceSelected(String id) {
    if (id == _selectedSourceId) return;
    final newIdx = _sources.indexWhere((s) => s.id == id);
    if (newIdx == -1) return;
    final ctrl = _pageCtrl;
    if (ctrl != null) {
      if (!ctrl.hasClients) return;
      ctrl.animateToPage(
        newIdx,
        duration: const Duration(milliseconds: 300),
        curve: Curves.fastLinearToSlowEaseIn,
      );
      return;
    }
    _selectedSourceId = id;
    ref.read(searchSessionProvider.notifier).setSource(id);
    setState(() {});
  }

  Widget _buildSourceBar({bool floating = false}) {
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding: EdgeInsets.symmetric(
          horizontal: floating ? 2 : 14,
        ),
        children: [
          for (final s in _sources)
            Padding(
              key: _sourceKeys[s.id],
              padding: const EdgeInsets.only(right: 8),
              child: FloatingSourcePill(
                name: s.name,
                selected: s.id == _selected.id,
                onTap: () => _onSourceSelected(s.id),
              ),
            ),
        ],
      ),
    );
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
          const BottomPlayBarSlot(),
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
// ==================== 默认页（搜索历史 + 大家都在搜） ====================

final _hotSearchProvider = FutureProvider<List<HotSearchItem>>((ref) {
  return ref.read(accountApiProvider).fetchHotSearch(limit: 10);
});

class SearchIdleView extends ConsumerWidget {
  const SearchIdleView({
    super.key,
    required this.onSearch,
    this.topPadding = 4,
  });

  final void Function(String keyword) onSearch;

  final double topPadding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final history = ref.watch(searchHistoryProvider);
    final loggedIn = ref.watch(authProvider.select((a) => a.isLoggedIn));
    final hasEnabledPlugin = ref.watch(
        pluginManagerProvider.select((s) => s.sources.any((p) => p.enabled)));
    final hotAsync = loggedIn && hasEnabledPlugin
        ? ref.watch(_hotSearchProvider)
        : const AsyncValue<List<HotSearchItem>>.data([]);
    final bottomInset = MediaQuery.of(context).padding.bottom + 24;

    return ListView(
      padding: EdgeInsets.fromLTRB(16, topPadding, 16, bottomInset),
      children: [
        Row(
          children: [
            Icon(Icons.history, size: 18, color: scheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Text(
              tr('搜索历史'),
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const Spacer(),
            if (history.isNotEmpty)
              InkWell(
                onTap: () =>
                    ref.read(searchHistoryProvider.notifier).clear(),
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 4),
                  child: Text(
                    tr('清空'),
                    style: TextStyle(
                        fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (history.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              tr('暂无搜索历史'),
              style: TextStyle(fontSize: 13, color: scheme.outline),
            ),
          )
        else
          for (final kw in history) _HistoryTile(keyword: kw, onTap: onSearch),
        const SizedBox(height: 24),

        if (loggedIn) ...[
          Row(
            children: [
              Icon(Icons.local_fire_department_outlined,
                  size: 18, color: scheme.primary),
              const SizedBox(width: 8),
              Text(
                tr('大家都在搜'),
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          hotAsync.when(
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2.4),
                ),
              ),
            ),
            error: (_, _) => _EmptyHotHint(scheme),
            data: (list) => list.isEmpty
                ? _EmptyHotHint(scheme)
                : Column(
                    children: [
                      for (var i = 0; i < list.length; i++)
                        _HotTile(
                          index: i,
                          item: list[i],
                          onTap: onSearch,
                        ),
                    ],
                  ),
          ),
        ],
      ],
    );
  }
}

class _HistoryTile extends ConsumerWidget {
  const _HistoryTile({required this.keyword, required this.onTap});

  final String keyword;
  final void Function(String keyword) onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () => onTap(keyword),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Text(
                keyword,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 14, color: scheme.onSurface),
              ),
            ),
            InkWell(
              onTap: () => ref
                  .read(searchHistoryProvider.notifier)
                  .remove(keyword),
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(
                  Icons.close,
                  size: 16,
                  color: scheme.outline,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HotTile extends ConsumerWidget {
  const _HotTile({
    required this.index,
    required this.item,
    required this.onTap,
  });

  final int index;
  final HotSearchItem item;
  final void Function(String keyword) onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final hot = index < 3;
    final color = hot ? scheme.primary : scheme.onSurfaceVariant;
    final size = index == 0
        ? 15.5
        : index == 1
            ? 15.0
            : 14.5;
    return InkWell(
      onTap: () => onTap(item.keyword),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            SizedBox(
              width: 26,
              child: Text(
                '${index + 1}',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
            ),
            Expanded(
              child: Text(
                item.keyword,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: size,
                  fontWeight: hot ? FontWeight.w600 : FontWeight.w400,
                  color: scheme.onSurface,
                ),
              ),
            ),
            Text(
              tr('{n}人搜', {'n': item.count}),
              style: TextStyle(
                  fontSize: 11, color: scheme.outline),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyHotHint extends StatelessWidget {
  const _EmptyHotHint(this.scheme);
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(
        tr('暂无热搜'),
        style: TextStyle(fontSize: 13, color: scheme.outline),
      ),
    );
  }
}

// ==================== 单曲 tab ====================

class _TrackTab extends ConsumerStatefulWidget {
  final String keyword;
  final _SourceItem source;

  const _TrackTab({
    required this.keyword,
    required this.source,
  });

  @override
  ConsumerState<_TrackTab> createState() => _TrackTabState();
}

class _ContentTopInsetScope extends InheritedWidget {
  const _ContentTopInsetScope({required this.inset, required super.child});

  final double inset;

  static double of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_ContentTopInsetScope>()
          ?.inset ??
      0;

  @override
  bool updateShouldNotify(_ContentTopInsetScope oldWidget) =>
      oldWidget.inset != inset;
}

class _TrackTabState extends ConsumerState<_TrackTab>
    with AutomaticKeepAliveClientMixin {
  List<_TrackEntry> _results = const [];
  bool _loading = false;
  String _searchedHash = '';
  List<String> _paths = const [];
  final ScrollController _scroll = ScrollController();
  String _searchError = '';

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    if (widget.keyword.trim().isNotEmpty) {
      final q = widget.keyword.trim();
      _search(q, '${widget.source.id}|$q');
    }
  }

  @override
  void didUpdateWidget(covariant _TrackTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    final q = widget.keyword.trim();
    if (q.isEmpty) return;
    final hash = '${widget.source.id}|$q';
    if (hash != _searchedHash) _search(q, hash);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  List<PluginSource> _plugins() => ref.read(pluginManagerProvider).sources;

  Future<void> _search(String q, String hash) async {
    final src = widget.source;
    setState(() {
      _searchedHash = hash;
      _loading = q.isNotEmpty;
      _searchError = '';
      if (q.isEmpty) _results = const [];
    });
    if (q.isEmpty) return;

    final List<_TrackEntry> out = [];
    try {
      if (src.isLocal) {
        final dbPath = await ref.read(dbPathProvider.future);
        final json = await searchLibrarySongs(
            dbPath: dbPath, query: q, limit: BigInt.from(100));
        final list = (jsonDecode(json) as List)
            .map((e) => Song.fromJson(e as Map<String, dynamic>))
            .toList();
        out.addAll(list.map((s) =>
            _TrackEntry(isLocal: true, localSong: s)));
        ref.read(accountApiProvider).reportSearch(q, 'local', list.length);
      } else {
        final engine = await ref.read(pluginEngineProvider.future);
        List<PluginSearchResult> items;
        if (src.type == _SourceType.musicfree) {
          final catalog = PluginCatalogService(engine, _plugins());
          items = await catalog.searchMusic(src.plugin!, q);
        } else {
          items = await engine.searchInPlugin(src.plugin!, src.lxKey!, q);
        }
        out.addAll(items.map((r) => _TrackEntry(
            isLocal: false, pluginSource: src.plugin, pluginResult: r)));
        ref.read(accountApiProvider).reportSearch(q, 'online', items.length);
      }
    } catch (e) {
      AppLogger.instance.log('search', '音源搜索失败 source=${src.id} q=$q error=$e');
      if (!mounted) return;
      if (_searchedHash != hash) return;
      setState(() {
        _searchError = e.toString();
        _results = const [];
        _loading = false;
      });
      return;
    }
    if (!mounted) return;
    if (_searchedHash != hash) return;
    setState(() {
      _results = out;
      _paths = _buildPaths(out);
      _loading = false;
    });
  }

  List<String> _buildPaths(List<_TrackEntry> out) {
    final engine = ref.read(pluginEngineProvider).valueOrNull;
    if (engine == null) {
      return [
        for (final e in out) e.isLocal ? (e.localSong?.path ?? '') : '',
      ];
    }
    final service = PluginSearchService(engine, _plugins());
    return [
      for (final e in out)
        e.isLocal
            ? (e.localSong?.path ?? '')
            : service.toQueueItem(e.pluginSource!, e.pluginResult!).path,
    ];
  }

  void _play(int index) {
    FocusScope.of(context).unfocus();
    final e = _results[index];
    if (e.isLocal) {
      ref.read(libraryProvider.notifier).playList([e.localSong!], 0);
      return;
    }
    final engine = ref.read(pluginEngineProvider).valueOrNull;
    if (engine == null) return;
    final service = PluginSearchService(engine, _plugins());
    final item = service.toQueueItem(e.pluginSource!, e.pluginResult!);
    ref.read(playerProvider.notifier).playQueue([item], startIndex: 0);
  }

  Rect? _coverSourceRect(BuildContext rowContext, BuildContext? coverCtx) {
    final ro = (coverCtx ?? rowContext).findRenderObject();
    if (ro is RenderBox && ro.hasSize) {
      return ro.localToGlobal(Offset.zero) & ro.size;
    }
    return null;
  }

  void _openActions(int index) {
    final item = _queueItem(index);
    if (item == null) return;
    showSongActionsSheet(context, ref: ref, item: item);
  }

  void _toggleFavorite(int index) {
    final item = _queueItem(index);
    if (item == null) return;
    final wasFav = ref.read(favoritesProvider).contains(item.path);
    ref.read(favoritesProvider.notifier).toggle(item);
    showXianYuToast(
        context, wasFav ? tr('已取消收藏：{t}', {'t': item.title}) : tr('已收藏：{t}', {'t': item.title}));
  }

  QueueItem? _queueItem(int index) {
    final e = _results[index];
    if (e.isLocal) return null;
    final engine = ref.read(pluginEngineProvider).valueOrNull;
    if (engine == null) return null;
    return PluginSearchService(engine, _plugins())
        .toQueueItem(e.pluginSource!, e.pluginResult!);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final scheme = Theme.of(context).colorScheme;
    final q = widget.keyword.trim();
    final m = ListMetrics.ofRef(ref);
    final favorites = ref.watch(favoritesProvider);

    if (q.isEmpty) {
      return _emptyHint(
          tr('输入关键词搜索音乐'), scheme, source: widget.source.name);
    }
    if (_loading && _results.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_searchError.isNotEmpty && _results.isEmpty) {
      return _emptyHint(
        tr('搜索失败：{e}', {'e': _searchError}),
        scheme,
        source: widget.source.name,
        actionLabel: tr('重试'),
        onAction: () => _search(q, '${widget.source.id}|$q'),
      );
    }
    if (_results.isEmpty) {
      return _emptyHint(
          tr('没有找到相关歌曲'), scheme, source: widget.source.name);
    }

    final bottomInset = 92.0 + MediaQuery.of(context).padding.bottom;
    final topInset = _ContentTopInsetScope.of(context);
    final rowExtent = m.songCover + 2 * m.vPad;
    return Stack(
      children: [
        ListView.builder(
          controller: _scroll,
          padding: EdgeInsets.only(
            top: topInset,
            bottom: bottomInset,
          ),
      itemCount: _results.length,
      itemBuilder: (context, i) {
        final e = _results[i];
        if (e.isLocal) {
          final s = e.localSong!;
          return Builder(
            builder: (rowContext) {
              BuildContext? coverCtx;
              return CoverRow(
                cover: Builder(
                  builder: (c) {
                    coverCtx = c;
                    return SongCover(song: s, size: m.songCover);
                  },
                ),
                title: highlightedText(s.title, q, scheme.primary,
                    maxLines: 1,
                    style: TextStyle(
                        fontSize: m.titleSize, fontWeight: FontWeight.w600)),
                subtitle: Text(
                  [s.artist, s.album, tr('本地')]
                      .where((x) => x.isNotEmpty)
                      .join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: m.subtitleSize, color: scheme.onSurfaceVariant),
                ),
                verticalPadding: m.vPad,
                onTap: () async {
                  final from = _coverSourceRect(rowContext, coverCtx);
                  _play(i);
                  if (from == null) return;
                  if (!await FlyingCover.instance.waitTargetReady()) return;
                  await FlyingCover.instance.launch(
                    fromRect: from,
                    songPath: s.path,
                    thumbPath: s.coverThumbPath,
                    radius: m.songRadius,
                  );
                },
              );
            },
          );
        }
        final r = e.pluginResult!;
        final item = _queueItem(i);
        final isFav = item != null && favorites.contains(item.path);
        return Builder(
          builder: (rowContext) {
            BuildContext? coverCtx;
            return CoverRow(
              cover: Builder(
                builder: (c) {
                  coverCtx = c;
                  return OnlineCover(
                      url: r.img, size: m.songCover, radius: m.songRadius);
                },
              ),
              title: highlightedText(r.name, q, scheme.primary,
                  maxLines: 1,
                  style: TextStyle(
                      fontSize: m.titleSize, fontWeight: FontWeight.w600)),
              subtitle: Text(
                [r.singer, r.albumName, widget.source.name]
                    .where((x) => x.isNotEmpty)
                    .join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: m.subtitleSize, color: scheme.onSurfaceVariant),
              ),
              verticalPadding: m.vPad,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: Icon(
                    isFav ? Icons.favorite : Icons.favorite_border,
                    size: 20,
                    color: isFav ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                  tooltip: tr('收藏'),
                  onPressed: () => _toggleFavorite(i),
                ),
                Text(
                  r.interval,
                  style: TextStyle(
                      fontSize: m.subtitleSize, color: scheme.outline),
                ),
                IconButton(
                  icon: const Icon(Icons.more_horiz, size: 22),
                  color: scheme.onSurfaceVariant,
                  tooltip: tr('更多'),
                  onPressed: () => _openActions(i),
                ),
              ],
            ),
            onLongPress: () => _openActions(i),
            onTap: () async {
                try {
                  final from = _coverSourceRect(rowContext, coverCtx);
                  _play(i);
                  if (from == null) return;
                  if (!await FlyingCover.instance.waitTargetReady()) return;
                  await FlyingCover.instance.launch(
                    fromRect: from,
                    networkUrl: r.img,
                    radius: m.songRadius,
                  );
                } catch (_) {
                }
              },
            );
          },
        );
      },
        ),
        SongListScrollFabs(
          controller: _scroll,
          paths: _paths,
          rowTopOf: (i) => topInset + i * rowExtent,
          itemExtent: rowExtent,
          bottom: bottomInset + 8,
          right: 12,
        ),
      ],
    );
  }
}

// ==================== 歌手 / 专辑 / 歌单 tab ====================

class _CatalogTab extends ConsumerStatefulWidget {
  final _CatalogKind kind;
  final String keyword;
  final _SourceItem source;

  const _CatalogTab({
    required this.kind,
    required this.keyword,
    required this.source,
  });

  @override
  ConsumerState<_CatalogTab> createState() => _CatalogTabState();
}

class _CatalogTabState extends ConsumerState<_CatalogTab>
    with AutomaticKeepAliveClientMixin {
  List<_CatalogItem> _items = const [];
  bool _loading = false;
  String _searchedHash = '';
  _CatalogKind? _searchedKind;
  int _page = 1;
  bool _hasMore = false;
  bool _loadingMore = false;

  bool get _isLxPlaylist =>
      widget.source.type == _SourceType.lx &&
      widget.kind == _CatalogKind.playlist;

  @override
  bool get wantKeepAlive => true;

  String _kindName(_CatalogKind k) => switch (k) {
        _CatalogKind.artist => tr('歌手'),
        _CatalogKind.album => tr('专辑'),
        _CatalogKind.playlist => tr('歌单'),
      };

  @override
  void initState() {
    super.initState();
    if (widget.keyword.trim().isNotEmpty) {
      final q = widget.keyword.trim();
      _search(q, '${widget.source.id}|${widget.kind.name}|$q');
    }
  }

  @override
  void didUpdateWidget(covariant _CatalogTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    final q = widget.keyword.trim();
    if (q.isEmpty) return;
    final hash = '${widget.source.id}|${widget.kind.name}|$q';
    if (hash != _searchedHash) _search(q, hash);
  }

  List<PluginSource> _plugins() => ref.read(pluginManagerProvider).sources;

  Future<void> _search(String q, String hash) async {
    final src = widget.source;
    setState(() {
      _searchedHash = hash;
      _loading = q.isNotEmpty;
      if (q.isEmpty) _items = const [];
      if (_searchedKind != widget.kind) _items = const [];
      _page = 1;
      _hasMore = false;
      _loadingMore = false;
    });
    if (q.isEmpty) return;

    final List<_CatalogItem> out = [];
    try {
      if (src.isLocal) {
        out.addAll(_searchLocal(q));
      } else if (src.type == _SourceType.musicfree) {
        out.addAll(await _searchMusicFree(q));
      } else {
        if (widget.kind == _CatalogKind.playlist) {
          final sheets = await _fetchLxSheets(q, 1);
          _hasMore = sheets.length >= 30;
          out.addAll(_lxSheetsItems(sheets));
        } else {
          out.addAll(await _searchLxDerive(q));
        }
      }
    } catch (e) {
      AppLog.warn('plugin', '[search] ${widget.source.name} 搜索异常: $e');
    }
    if (!mounted) return;
    if (_searchedHash != hash) return;
    setState(() {
      _items = out;
      _searchedKind = widget.kind;
      _loading = false;
    });
  }

  List<_CatalogItem> _searchLocal(String q) {
    final lower = q.toLowerCase();
    final tag = tr('本地');
    final out = <_CatalogItem>[];
    try {
      switch (widget.kind) {
        case _CatalogKind.artist:
          final artists = ref.read(libraryProvider).artists;
          for (final a in artists) {
            if (a.name.toLowerCase().contains(lower)) {
              out.add(_CatalogItem(
                kind: 'artist',
                title: a.name,
                subtitle: tr('{n} 首', {'n': a.count}),
                sourceTag: tag,
                localArtist: a,
              ));
            }
          }
        case _CatalogKind.album:
          final albums = ref.read(libraryProvider).albums;
          for (final a in albums) {
            if (a.name.toLowerCase().contains(lower) ||
                a.artist.toLowerCase().contains(lower)) {
              out.add(_CatalogItem(
                kind: 'album',
                title: a.name,
                subtitle: tr('{artist} · {n} 首', {'artist': a.artist, 'n': a.count}),
                sourceTag: tag,
                localAlbum: a,
              ));
            }
          }
        case _CatalogKind.playlist:
          final playlists = ref.read(playlistManagerProvider).playlists;
          for (final p in playlists) {
            if (p.name.toLowerCase().contains(lower)) {
              out.add(_CatalogItem(
                kind: 'playlist',
                title: p.name,
                subtitle: tr('{n} 首', {'n': p.songs.length}),
                sourceTag: tag,
                localPlaylist: p,
              ));
            }
          }
      }
    } catch (_) {}
    return out;
  }

  Future<List<_CatalogItem>> _searchMusicFree(String q) async {
    final engine = await ref.read(pluginEngineProvider.future);
    final source = widget.source;
    final catalog = PluginCatalogService(engine, _plugins());
    final out = <_CatalogItem>[];
    final tag = source.name;
    try {
      switch (widget.kind) {
        case _CatalogKind.artist:
          final list = await catalog.searchArtists(source.plugin!, q);
          for (final a in list) {
            out.add(_CatalogItem(
              kind: 'artist',
              title: a.name,
              coverUrl: a.avatarUrl,
              sourceTag: tag,
              onlinePlugin: source.plugin,
              onlineRaw: a.raw,
            ));
          }
        case _CatalogKind.album:
          final list = await catalog.searchAlbums(source.plugin!, q);
          for (final a in list) {
            out.add(_CatalogItem(
              kind: 'album',
              title: a.name,
              subtitle: a.artist,
              coverUrl: a.coverUrl,
              sourceTag: tag,
              onlinePlugin: source.plugin,
              onlineRaw: a.raw,
            ));
          }
        case _CatalogKind.playlist:
          final list = await catalog.searchSheets(source.plugin!, q);
          for (final s in list) {
            out.add(_CatalogItem(
              kind: 'playlist',
              title: s.title,
              subtitle: s.subtitle,
              coverUrl: s.coverUrl,
              sourceTag: tag,
              onlinePlugin: source.plugin,
              onlineRaw: s.raw,
            ));
          }
      }
    } catch (_) {}
    return out;
  }

  Future<List<_CatalogItem>> _searchLxDerive(String q) async {
    final engine = await ref.read(pluginEngineProvider.future);
    final source = widget.source;
    final songs = await engine
        .searchInPlugin(source.plugin!, source.lxKey ?? '', q, limit: 60);
    final isArtist = widget.kind == _CatalogKind.artist;
    final map = <String, _CatalogItem>{};
    for (final s in songs) {
      final key = isArtist ? s.singer.trim() : s.albumName.trim();
      if (key.isEmpty) continue;
      final existing = map[key];
      if (existing != null) {
        existing.directSongs.add(s);
        continue;
      }
      map[key] = _CatalogItem(
        kind: isArtist ? 'artist' : 'album',
        title: key,
        subtitle: isArtist ? '' : s.singer,
        coverUrl: s.img,
        sourceTag: source.name,
        directSource: source.plugin,
        directSongs: [s],
      );
    }
    return map.values.toList();
  }

  Future<List<Map<String, dynamic>>> _fetchLxSheets(String q, int page) async {
    final source = widget.source;
    return lxHostPlaylistSearchFallback(
      source.plugin!,
      source.lxKey ?? '',
      q,
      page: page,
      limit: 30,
    );
  }

  List<_CatalogItem> _lxSheetsItems(List<Map<String, dynamic>> sheets) {
    final source = widget.source;
    final out = <_CatalogItem>[];
    for (final s in sheets) {
      final trackCount = s['trackCount'];
      final playCount = s['playCount'];
      final parts = <String>[
        if ((s['artist'] as String?)?.isNotEmpty == true) s['artist'] as String,
        if (trackCount is num && trackCount > 0)
          tr('{n} 首', {'n': trackCount.toInt()}),
        if (playCount is num && playCount > 0) _formatPlayCount(playCount),
      ];
      out.add(_CatalogItem(
        kind: 'playlist',
        title: s['title'] as String,
        subtitle: parts.join(' · '),
        coverUrl: s['coverUrl'] as String?,
        sourceTag: source.name,
        onlinePlugin: source.plugin,
        onlineRaw: s,
      ));
    }
    return out;
  }

  Future<void> _loadNextLxPage() async {
    if (_loading || _loadingMore || !_hasMore) return;
    final q = widget.keyword.trim();
    if (q.isEmpty) return;
    setState(() => _loadingMore = true);
    final next = _page + 1;
    try {
      final sheets = await _fetchLxSheets(q, next);
      if (!mounted) return;
      final add = _lxSheetsItems(sheets);
      setState(() {
        if (add.isNotEmpty) {
          _items = [..._items, ...add];
          _page = next;
        }
        _hasMore = sheets.length >= 30;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _hasMore = false;
        _loadingMore = false;
      });
    }
  }

  void _maybeLoadMore(ScrollMetrics metrics) {
    if (!_isLxPlaylist) return;
    if (metrics.extentAfter > 320) return;
    _loadNextLxPage();
  }

  void _open(_CatalogItem item) {
    FocusScope.of(context).unfocus();
    if (item.localArtist != null) {
      final a = item.localArtist!;
      context.push('/song-list', extra: SongListArgs(
        title: a.name,
        loader: () =>
            ref.read(libraryProvider.notifier).songsByArtist(a.name),
      ));
      return;
    }
    if (item.localAlbum != null) {
      final a = item.localAlbum!;
      context.push('/song-list', extra: SongListArgs(
        title: a.name,
        loader: () =>
            ref.read(libraryProvider.notifier).songsByAlbum(a.key),
      ));
      return;
    }
    if (item.localPlaylist != null) {
      ref
          .read(playlistManagerProvider.notifier)
          .play(item.localPlaylist!, 0);
      return;
    }
    final engine = ref.read(pluginEngineProvider).valueOrNull;
    if (engine == null) return;
    if (item.isDirectPlay) {
      final source = item.directSource!;
      final first = item.directSongs.first;
      final isAlbum = item.kind == 'album';
      final lxKey = first.source;
      final raw = <String, dynamic>{
        '_lxSource': lxKey,
        'name': item.title,
        if (isAlbum) ...{
          'id': first.albumId ?? first.albumMid ?? item.title,
          'albumId': first.albumId,
          'albumMid': first.albumMid,
        },
      };
      context.push(
        '/online-detail',
        extra: OnlineDetailArgs(
          type: isAlbum ? OnlineDetailType.album : OnlineDetailType.artist,
          pluginId: source.id,
          title: item.title,
          subtitle: item.subtitle,
          coverUrl: item.coverUrl,
          raw: raw,
        ),
      );
      return;
    }
    context.push(
      '/online-detail',
      extra: OnlineDetailArgs(
        type: switch (item.kind) {
          'artist' => OnlineDetailType.artist,
          'album' => OnlineDetailType.album,
          _ => OnlineDetailType.playlist,
        },
        pluginId: item.onlinePlugin?.id ?? '',
        title: item.title,
        subtitle: item.subtitle,
        coverUrl: item.coverUrl,
        raw: item.onlineRaw ?? const {},
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final scheme = Theme.of(context).colorScheme;
    final q = widget.keyword.trim();
    final m = ListMetrics.ofRef(ref);
    final name = _kindName(widget.kind);

    if (q.isEmpty) {
      return _emptyHint(
          tr('输入关键词搜索{name}', {'name': name}),
          scheme,
          source: widget.source.name);
    }
    if (_loading && _items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_items.isEmpty) {
      return _emptyHint(
          tr('没有找到相关{name}', {'name': name}),
          scheme,
          source: widget.source.name);
    }

    final bottomInset = 92.0 + MediaQuery.of(context).padding.bottom;
    final showMore = _isLxPlaylist && _loadingMore;
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.axis == Axis.vertical) _maybeLoadMore(n.metrics);
        return false;
      },
      child: ListView.builder(
        padding: EdgeInsets.only(
          top: _ContentTopInsetScope.of(context),
          bottom: bottomInset,
        ),
        itemCount: _items.length + (showMore ? 1 : 0),
        itemBuilder: (context, i) {
          if (i >= _items.length) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
          }
          final item = _items[i];
          final isArtist = item.kind == 'artist';
          return CoverRow(
            cover: _catalogLeading(item, isArtist, m, scheme),
            title: highlightedText(item.title, q, scheme.primary,
                maxLines: 1,
                style: TextStyle(
                    fontSize: m.titleSize, fontWeight: FontWeight.w600)),
            subtitle: Text(
              [item.subtitle, item.sourceTag]
                  .where((x) => x.isNotEmpty)
                  .join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: m.subtitleSize, color: scheme.onSurfaceVariant),
            ),
            verticalPadding: m.vPad,
            trailing:
                Icon(Icons.chevron_right, color: scheme.outline, size: 22),
            onTap: () => _open(item),
          );
        },
      ),
    );
  }

  Widget _catalogLeading(
      _CatalogItem item, bool isArtist, ListMetrics m, ColorScheme scheme) {
    final size = isArtist ? m.artistCover : m.songCover;
    final radius = isArtist ? m.artistCover / 2 : m.songRadius;
    if (item.localArtist != null) {
      final a = item.localArtist!;
      return CoverImage(
        songPath: a.firstSongPath,
        width: size,
        height: size,
        radius: m.artistCover / 2,
        icon: Icons.person,
        placeholder: _letterLeading(a.name, scheme),
      );
    }
    if (item.localAlbum != null) {
      final a = item.localAlbum!;
      return CoverImage(
        songPath: a.firstSongPath,
        width: size,
        height: size,
        radius: m.songRadius,
        icon: Icons.album,
      );
    }
    if (item.localPlaylist != null) {
      return Container(
        width: m.playCover,
        height: m.playCover,
        decoration: BoxDecoration(
          color: scheme.secondaryContainer,
          borderRadius: BorderRadius.circular(m.songRadius),
        ),
        alignment: Alignment.center,
        child: Icon(Icons.queue_music, size: m.playCover * 0.45),
      );
    }
    return OnlineCover(url: item.coverUrl, size: size, radius: radius);
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