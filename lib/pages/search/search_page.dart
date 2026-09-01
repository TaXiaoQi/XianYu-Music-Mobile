import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../src/auth/account_api.dart';
import '../../src/core/app_colors.dart';
import '../../src/core/app_logger.dart';
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
import '../../src/widgets/online_cover.dart';
import '../../src/widgets/song_actions_sheet.dart';
import '../../src/widgets/song_list_view.dart';
import '../home/online_detail_page.dart';
import '../library/song_list_page.dart';
import '../../src/i18n/i18n.dart';

// ==================== 来源模型 ====================

enum _SourceType { local, musicfree, lx }

/// 单个可选搜索来源：插件音源（musicfree 单条 / lx 多平台拆分）或“本地”。
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

/// LX 插件声明的合法音源 key 及展示名（与桌面端对齐）。
const _validLxSources = {'kw', 'kg', 'tx', 'wy', 'mg'};
Map<String, String> get _lxSourceNames => <String, String>{
  'kw': tr('小蜗音乐'),
  'kg': tr('小枸音乐'),
  'tx': tr('小秋音乐'),
  'wy': tr('小芸音乐'),
  'mg': tr('小蜜音乐'),
};

// ==================== 结果模型 ====================

/// 单曲结果：本地歌曲或插件歌曲。
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

/// 播放量格式化（对齐 MfSheetItem 的亿/万缩写）。
String _formatPlayCount(num n) {
  if (n >= 100000000) {
    return tr('{n}亿', {'n': (n / 100000000).toStringAsFixed(1)});
  }
  if (n >= 10000) return tr('{n}万', {'n': (n / 10000).toStringAsFixed(1)});
  return '$n';
}

/// 歌手/专辑/歌单结果：本地条目、在线导航或 LX 派生直放。
class _CatalogItem {
  final String kind; // artist | album | playlist
  final String title;
  final String subtitle;
  final String? coverUrl;
  final String sourceTag;
  // 本地导航
  final ArtistInfo? localArtist;
  final AlbumInfo? localAlbum;
  final ImportedPlaylist? localPlaylist;
  // 在线插件（musicfree）导航到详情页
  final PluginSource? onlinePlugin;
  final Map<String, dynamic>? onlineRaw;
  // LX 派生：直接从派生歌曲列表播放
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

/// 搜索页 → 结果页之间共享的关键词与所选音源。
class SearchSession {
  final String query;
  final String sourceId;
  const SearchSession({this.query = '', this.sourceId = ''});
}

final searchSessionProvider =
    NotifierProvider<SearchSessionNotifier, SearchSession>(
        SearchSessionNotifier.new);

/// 保留音源选择，便于从结果页返回搜索页后发起新搜索仍沿用所选音源。
class SearchSessionNotifier extends Notifier<SearchSession> {
  @override
  SearchSession build() => const SearchSession();

  void startSearch(String query, String sourceId) =>
      state = SearchSession(query: query, sourceId: sourceId);

  void setSource(String id) =>
      state = SearchSession(query: state.query, sourceId: id);
}

// ==================== 横屏搜索容器（参考桌面端：顶栏即搜索输入） ====================

/// 横屏搜索容器是否打开：右侧容器内嵌搜索页/结果页（不开二级路由），
/// 由全局顶栏搜索胶囊点击打开，输入框由全局顶栏承接。
final landscapeSearchOpenProvider = StateProvider<bool>((ref) => false);

/// 横屏搜索容器当前是否显示结果页（false=搜索默认页：历史+热搜）。
final landscapeSearchResultsProvider = StateProvider<bool>((ref) => false);

/// 横屏搜索输入控制器：全局顶栏输入框持有，与搜索容器共享。
final landscapeSearchCtrlProvider = Provider<TextEditingController>((ref) {
  final ctrl = TextEditingController();
  ref.onDispose(ctrl.dispose);
  return ctrl;
});

/// 横屏顶栏搜索输入框的全局焦点节点：容器打开后由打开方在下一帧显式
/// requestFocus，保证第一次点击顶栏搜索框输入法就弹出（输入框与胶囊在同一
/// 帧切换重建，autofocus 在该时机可能被吞掉）。
final landscapeSearchFocusProvider = Provider<FocusNode>((ref) {
  final node = FocusNode();
  ref.onDispose(node.dispose);
  return node;
});

/// 关闭横屏搜索容器并复位到默认页（切主 tab / 点侧边栏音乐库入口时调用）。
void closeLandscapeSearch(WidgetRef ref) {
  ref.read(landscapeSearchOpenProvider.notifier).state = false;
  ref.read(landscapeSearchResultsProvider.notifier).state = false;
}

/// 提交横屏搜索：记录历史与会话、容器切到结果页。
/// 全局顶栏输入框回车/搜索按钮与搜索默认页（历史/热搜点击）共用。
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

// ==================== 搜索页 ====================

/// 搜索页：顶部搜索输入框 + 搜索历史/热搜。提交后跳到结果页（/search/result）。
/// 结果页不在此页内联展示，因此本路由不显示迷你播放条。
class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage>
    with HidesShellChrome {
  final TextEditingController _ctrl = TextEditingController();

  // 输入统计：1.5s 无新输入后批量上报新增字符数。
  int _pendingCharCount = 0;
  int _lastQueryLength = 0;
  Timer? _inputFlushTimer;

  @override
  void dispose() {
    _inputFlushTimer?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  void _onChanged(String keyword) {
    setState(() {}); // 更新清除按钮显隐。

    // 输入统计上报（1.5s 无新输入后批量上报新增字符数）。
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

  /// 提交搜索：记录历史与会话，跳到结果页（/search/result）。
  void _submitSearch(String raw) {
    final q = raw.trim();
    if (q.isEmpty) return;
    FocusScope.of(context).unfocus();
    if (_ctrl.text != q) _ctrl.text = q;
    ref.read(searchHistoryProvider.notifier).add(q);
    final sourceId = ref.read(searchSessionProvider).sourceId;
    ref.read(searchSessionProvider.notifier).startSearch(q, sourceId);
    context.push('/search/result');
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
      // 键盘弹/收时不让 Scaffold 按 viewInsets 逐帧缩放 body，避免顶栏
      // BackdropFilter 背光被压缩变化反复重采样导致输入法动画掉帧。
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          // 内容铺满全屏，避让量走 SearchIdleView.topPadding（列表滚动 padding）：
          // 滚动时内容从顶栏下方穿过（与首页/本地音乐页一致的悬浮穿透观感）。
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
              // 固定对比色搜索框：带一点透明、不随毛玻璃开关变化，与玻璃顶栏形成对比。
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
                  // 字段被高 40 的清除按钮撑高后，dense 输入框默认顶部对齐，
                  // 文字会偏上；显式居中让键入文字与 hint 都垂直居中。
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

/// 搜索结果页：竖屏为独立 /search/result 路由；横屏以内嵌容器模式
/// （[embedded]=true，不开二级路由）显示在右侧容器，顶栏由全局横屏顶栏
/// 承接（内容 tab 与来源切换条改在内容区顶部展示），迷你播放条由壳层常驻。
class SearchResultPage extends ConsumerStatefulWidget {
  const SearchResultPage({super.key, this.embedded = false});

  /// 横屏右侧容器内嵌模式。
  final bool embedded;

  @override
  ConsumerState<SearchResultPage> createState() => _SearchResultPageState();
}

class _SearchResultPageState extends ConsumerState<SearchResultPage>
    with TickerProviderStateMixin, HidesShellChrome {
  /// 内嵌容器模式不隐藏 shell 浮层（迷你播放条由壳层常驻承接）。
  @override
  bool get hidesChrome => !widget.embedded;

  late final TabController _tab;
  final TextEditingController _queryCtrl = TextEditingController();

  List<_SourceItem> _sources = const [];
  String _selectedSourceId = '';
  int _activeIndex = 0;

  /// 多音源时用于音源横滑切换的 TabController（参考榜单页切换效果：
  /// 每个音源页独立加载，TabBarView 原生动画与搜索并行）。单音源时为 null，
  /// 内容 TabBarView 原生横滑切 tab。
  TabController? _sourceTab;
  int _activeSourceIndex = 0;

  /// 来源切换条是否处于壁纸抽透明态（见 ChoiceChip 的适配分支）。
  bool get _wallpaper => ref.watch(wallpaperActiveProvider);

  @override
  void initState() {
    super.initState();
    _queryCtrl.text = ref.read(searchSessionProvider).query;
    _tab = TabController(length: 4, vsync: this);
    // tab 由 TabController 内部驱动切换，父页面需监听其 index 变化并重建，
    // 以把新的 visible 标记传给子 tab，否则切换后新 tab 不会发起搜索。
    _tab.addListener(_onTabChanged);
    ref.listenManual(pluginManagerProvider, (_, _) => _refreshSources());
    _refreshSources();
  }

  void _onTabChanged() {
    final idx = _tab.index;
    if (idx == _activeIndex || !mounted) return;
    _activeIndex = idx;
    setState(() {});
  }

  /// 音源 TabBarView 切换监听：同步 _selectedSourceId + searchSession，
  /// 并在动画期间逐帧重建以更新子 tab 的 visible 标记（与榜单页同模式）。
  void _onSourceTabChanged() {
    if (!mounted || _sourceTab == null) return;
    final newIdx = _sourceTab!.index;
    if (newIdx != _activeSourceIndex) {
      _activeSourceIndex = newIdx;
      if (newIdx >= 0 && newIdx < _sources.length) {
        _selectedSourceId = _sources[newIdx].id;
        ref.read(searchSessionProvider.notifier).setSource(_sources[newIdx].id);
      }
    }
    setState(() {});
  }

  /// 当前活动音源索引（取动画值实现半途即触发搜索，不等国画结束）。
  int get _activeSourceIdx {
    if (_sourceTab == null || _sources.length <= 1) return 0;
    return (_sourceTab!.animation?.value ?? _activeSourceIndex.toDouble())
        .round()
        .clamp(0, _sources.length - 1);
  }

  @override
  void dispose() {
    _tab.removeListener(_onTabChanged);
    _tab.dispose();
    _sourceTab?.removeListener(_onSourceTabChanged);
    _sourceTab?.dispose();
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

  /// 从插件音源构建来源列表；无插件时返回“本地”。
  void _refreshSources() {
    final plugins = ref.read(pluginManagerProvider).sources;
    // 按用户拖拽排序展示（插件管理页顺序），未排序项用安装顺序兜底
    final enabled = sortPluginSources(plugins.where((p) => p.enabled).toList());
    debugPrint('[searchSources] enabled plugins=${enabled.length}');
    for (final p in enabled) {
      debugPrint('[searchSources]   plugin=${p.name} format=${p.format} '
          'sources=${p.sources.toList()} id=${p.id}');
    }
    final items = <_SourceItem>[];
    for (final p in enabled) {
      if (p.format == PluginFormat.musicfree) {
        items.add(_SourceItem(
            id: p.id, name: p.name, type: _SourceType.musicfree, plugin: p));
      } else if (p.format == PluginFormat.lx) {
        final lx = p.sources.where(_validLxSources.contains).toList();
        if (lx.isEmpty) continue;
        if (lx.length == 1) {
          items.add(_SourceItem(
              id: p.id,
              name: p.name,
              type: _SourceType.lx,
              plugin: p,
              lxKey: lx.first));
        } else {
          for (final key in lx) {
            items.add(_SourceItem(
                id: '${p.id}__$key',
                name: _lxSourceNames[key] ?? key,
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

    // 初始化/重建音源 TabController（参考榜单页：多音源用 TabBarView 原生
    // 横滑切换，动画与搜索并行；单音源时不用 _sourceTab）。
    _sourceTab?.removeListener(_onSourceTabChanged);
    _sourceTab?.dispose();
    if (result.length > 1) {
      _sourceTab = TabController(length: result.length, vsync: this);
      _activeSourceIndex = result.indexWhere((s) => s.id == initial);
      if (_activeSourceIndex < 0) _activeSourceIndex = 0;
      _sourceTab!.index = _activeSourceIndex;
      _sourceTab!.addListener(_onSourceTabChanged);
    } else {
      _sourceTab = null;
      _activeSourceIndex = 0;
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
    _sourceTab?.animateTo(newIdx);
  }

  Widget _buildSourceBar() {
    return SizedBox(
      height: 46,
      child: ListView(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        children: [
          for (final s in _sources)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(s.name),
                showCheckmark: false,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                selected: s.id == _selected.id,
                // 壁纸模式下抽透明：未选中透出壁纸、选中用轻量红底+细边，
                // 避免来源选择条在壁纸上堆成实色色块；普通模式走主题原样。
                backgroundColor: _wallpaper ? Colors.transparent : null,
                selectedColor: _wallpaper
                    ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.14)
                    : null,
                side: _wallpaper
                    ? BorderSide(
                        color: s.id == _selected.id
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context)
                                .colorScheme
                                .outline
                                .withValues(alpha: 0.35),
                      )
                    : null,
                onSelected: (_) => _onSourceSelected(s.id),
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
      tabs:   [
        Tab(text: tr('单曲')),
        Tab(text: tr('歌手')),
        Tab(text: tr('专辑')),
        Tab(text: tr('歌单')),
      ],
    );

    // 多音源：外层 TabBarView（_sourceTab）横滑切音源，内层 TabBarView（_tab）
    // 禁用横滑（由外层接管），内容 tab 靠点击切换。每个音源页独立加载，
    // TabBarView 原生动画与搜索并行（参考榜单页 _PeriodBoard）。
    // 单音源：单层 TabBarView（_tab），横滑切内容 tab。
    final sourceIdx = _activeSourceIdx;
    final contentIdx = _tab.index;
    final contentArea = _sources.length > 1
        ? TabBarView(
            controller: _sourceTab,
            children: [
              for (var si = 0; si < _sources.length; si++)
                TabBarView(
                  controller: _tab,
                  physics: const NeverScrollableScrollPhysics(),
                  children: [
                    _TrackTab(
                      keyword: keyword,
                      source: _sources[si],
                      visible: sourceIdx == si && contentIdx == 0,
                    ),
                    _CatalogTab(
                      kind: _CatalogKind.artist,
                      keyword: keyword,
                      source: _sources[si],
                      visible: sourceIdx == si && contentIdx == 1,
                    ),
                    _CatalogTab(
                      kind: _CatalogKind.album,
                      keyword: keyword,
                      source: _sources[si],
                      visible: sourceIdx == si && contentIdx == 2,
                    ),
                    _CatalogTab(
                      kind: _CatalogKind.playlist,
                      keyword: keyword,
                      source: _sources[si],
                      visible: sourceIdx == si && contentIdx == 3,
                    ),
                  ],
                ),
            ],
          )
        : TabBarView(
            controller: _tab,
            children: [
              _TrackTab(
                keyword: keyword,
                source: selected,
                visible: contentIdx == 0,
              ),
              _CatalogTab(
                kind: _CatalogKind.artist,
                keyword: keyword,
                source: selected,
                visible: contentIdx == 1,
              ),
              _CatalogTab(
                kind: _CatalogKind.album,
                keyword: keyword,
                source: selected,
                visible: contentIdx == 2,
              ),
              _CatalogTab(
                kind: _CatalogKind.playlist,
                keyword: keyword,
                source: selected,
                visible: contentIdx == 3,
              ),
            ],
          );

    // 内嵌模式（横屏搜索容器）：顶栏由全局横屏顶栏承接（回退/搜索/皮肤/
    // 设置四大控件所有横屏容器共享，本页无额外 tab 行、无需独立悬浮适配）。
    // 内容 tab 与来源条静态避让在全局顶栏下方，结果列表在剩余区域内滚动。
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
    // 内容初始避让量：悬浮=悬浮列高度（首行44 + 间距10 + Tab气泡48 +
    // 间距10 + 来源气泡46）；固定=GlassTopBar（含内容 tab）。
    final topInset = floating
        ? statusBar + 8 + 44 + 10 + 48 + 10
        : GlassTopBar.height(context, bottom: tabBar);

    return Scaffold(
      backgroundColor: appScaffoldBackground(context, ref),
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          // 结果列表铺满全屏：避让量注入列表滚动 padding，滚动时内容从顶栏
          // 与来源条下方穿过（悬浮穿透观感）。
          Positioned.fill(
            child: _withContentTopInset(contentArea, topInset + 46),
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
                // 来源插件切换条也包进玻璃气泡，与 Tab 气泡同材质。
                bottomPill: FloatingTabPill(height: 46, child: _buildSourceBar()),
              ),
            )
          else ...[
            // 来源切换条悬浮吸顶（不透明底色防止列表文字透叠）。
            Positioned(
              top: topInset,
              left: 0,
              right: 0,
              child: ColoredBox(
                color: Theme.of(context).scaffoldBackgroundColor,
                child: _buildSourceBar(),
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: GlassTopBar(
                leading: const BackButton(),
              // 结果页输入框只读：点击返回搜索页，不在结果页内联搜索。
              // 固定对比色搜索框：带一点透明、不随毛玻璃开关变化，与玻璃顶栏形成对比。
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
                  // 与搜索页输入框一致：高 40 容器内文字垂直居中。
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
              bottom: tabBar,
              ),
            ),
          ],
          // 搜索结果页显示迷你播放条；搜索在线页（历史+热搜）不显示。
          const BottomPlayBarSlot(),
        ],
      ),
    );
  }

  /// 给内容区（结果 tab）注入顶部避让量：列表滚动 padding.top 增加 [inset]，
  /// 内容铺满全屏滚动时从顶栏/来源条下方穿过。
  Widget _withContentTopInset(Widget contentArea, double inset) {
    return _ContentTopInsetScope(inset: inset, child: contentArea);
  }

  /// 结果页返回搜索页，在新搜索页发起新搜索。
  void _goToSearchPage() => context.pop();
}
// ==================== 默认页（搜索历史 + 大家都在搜） ====================

/// 大家都在搜：聚合所有用户搜索数据（后端 get_hot_search）。
final _hotSearchProvider = FutureProvider<List<HotSearchItem>>((ref) {
  return ref.read(accountApiProvider).fetchHotSearch(limit: 10);
});

/// 搜索默认页视图：上方搜索历史，下方"大家都在搜"；点击任一关键词即提交搜索。
/// 供竖屏搜索页与横屏搜索容器（顶栏承接输入框）复用。
class SearchIdleView extends ConsumerWidget {
  const SearchIdleView({
    super.key,
    required this.onSearch,
    this.topPadding = 4,
  });

  final void Function(String keyword) onSearch;

  /// 顶部留白：悬浮顶栏模式下由调用方传入顶栏高度，列表内容滚动时从悬浮
  /// 玻璃控件下方穿过（悬浮观感与首页/我的页一致）；默认模式保持默认值。
  final double topPadding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final history = ref.watch(searchHistoryProvider);
    final hotAsync = ref.watch(_hotSearchProvider);
    final bottomInset = MediaQuery.of(context).padding.bottom + 24;

    return ListView(
      padding: EdgeInsets.fromLTRB(16, topPadding, 16, bottomInset),
      children: [
        // —— 搜索历史 ——
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

        // —— 大家都在搜 ——
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
    // 前三名高亮。
    final hot = index < 3;
    final color = hot ? scheme.primary : scheme.onSurfaceVariant;
    // 文本大小逐名递减，突出榜首。
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
  final bool visible;

  const _TrackTab({
    required this.keyword,
    required this.source,
    required this.visible,
  });

  @override
  ConsumerState<_TrackTab> createState() => _TrackTabState();
}

/// 结果内容区顶部避让量注入：_TrackTab/_CatalogTab 的列表滚动 padding.top
/// 取该值——内容铺满全屏，滚动时从顶栏/来源条下方穿过（悬浮穿透观感）。
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
  /// 搜索失败原因（超时/插件异常等）。空串表示无错误——空结果与失败要分开
  /// 提示，否则插件挂了用户只看到"无结果"，误以为是搜不到。
  String _searchError = '';

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    // 进入结果页时子组件全新创建，需立即执行首次搜索。
    if (widget.visible && widget.keyword.trim().isNotEmpty) {
      final q = widget.keyword.trim();
      _search(q, '${widget.source.id}|$q');
    }
  }

  @override
  void didUpdateWidget(covariant _TrackTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.visible) return;
    final q = widget.keyword.trim();
    final hash = '${widget.source.id}|$q';
    if (hash != _searchedHash) _search(q, hash);
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
      // 失败必须透出原因：空结果 + 无提示会让用户以为"搜不到"，实际是
      // 插件超时/异常。记录错误供空态 UI 展示与重试。
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
      _loading = false;
    });
  }

  void _play(int index) {
    debugPrint('[search] _play called index=$index');
    FocusScope.of(context).unfocus();
    final e = _results[index];
    if (e.isLocal) {
      debugPrint('[search] _play local song');
      ref.read(libraryProvider.notifier).playList([e.localSong!], 0);
      return;
    }
    final engine = ref.read(pluginEngineProvider).valueOrNull;
    debugPrint('[search] _play engine=${engine == null ? 'NULL' : 'ok'}');
    if (engine == null) return;
    final service = PluginSearchService(engine, _plugins());
    final item = service.toQueueItem(e.pluginSource!, e.pluginResult!);
    debugPrint('[search] _play item=${item.title} path=${item.path}');
    ref.read(playerProvider.notifier).playQueue([item], startIndex: 0);
  }

  /// 打开「更多」菜单：复用长按菜单（showSongActionsSheet）。
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
      // 搜索失败与"没有找到"区分开：透出原因并给重试入口。
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
    return ListView.builder(
      padding: EdgeInsets.only(
        top: _ContentTopInsetScope.of(context),
        bottom: bottomInset,
      ),
      itemCount: _results.length,
      itemBuilder: (context, i) {
        final e = _results[i];
        if (e.isLocal) {
          final s = e.localSong!;
          return Builder(
            builder: (rowContext) {
              // 捕获封面自身 context：飞封面直接取封面 RenderBox 的全局矩形，与列表封面像素级一致。
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
                  // 等封面落地后再播放：播放条封面随落地同步更新。
                  final ok = await launchFlyCover(
                    rowContext,
                    coverContext: coverCtx,
                    coverSize: m.songCover,
                    vPad: m.vPad,
                    songPath: s.path,
                    thumbPath: s.coverThumbPath,
                    radius: m.songRadius,
                  );
                  if (ok) _play(i);
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
            // 捕获封面自身 context：飞封面直接取封面 RenderBox 的全局矩形，与列表封面像素级一致。
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
                debugPrint('[search] online row onTap i=$i');
                try {
                  // 等封面落地后再播放：播放条封面随落地同步更新。
                  final ok = await launchFlyCover(
                    rowContext,
                    coverContext: coverCtx,
                    coverSize: m.songCover,
                    vPad: m.vPad,
                    networkUrl: r.img,
                    radius: m.songRadius,
                  );
                  if (ok) _play(i);
                } catch (e, st) {
                  debugPrint('[search] launchFlyCover ERROR: $e\n$st');
                  _play(i);
                }
              },
            );
          },
        );
      },
    );
  }
}

// ==================== 歌手 / 专辑 / 歌单 tab ====================

class _CatalogTab extends ConsumerStatefulWidget {
  final _CatalogKind kind;
  final String keyword;
  final _SourceItem source;
  final bool visible;

  const _CatalogTab({
    required this.kind,
    required this.keyword,
    required this.source,
    required this.visible,
  });

  @override
  ConsumerState<_CatalogTab> createState() => _CatalogTabState();
}

class _CatalogTabState extends ConsumerState<_CatalogTab>
    with AutomaticKeepAliveClientMixin {
  List<_CatalogItem> _items = const [];
  bool _loading = false;
  String _searchedHash = '';

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
    // 进入结果页时子组件全新创建，需立即执行首次搜索。
    if (widget.visible && widget.keyword.trim().isNotEmpty) {
      final q = widget.keyword.trim();
      _search(q, '${widget.source.id}|$q');
    }
  }

  @override
  void didUpdateWidget(covariant _CatalogTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.visible) return;
    final q = widget.keyword.trim();
    final hash = '${widget.source.id}|$q';
    if (hash != _searchedHash) _search(q, hash);
  }

  List<PluginSource> _plugins() => ref.read(pluginManagerProvider).sources;

  Future<void> _search(String q, String hash) async {
    final src = widget.source;
    setState(() {
      _searchedHash = hash;
      _loading = q.isNotEmpty;
      if (q.isEmpty) _items = const [];
    });
    if (q.isEmpty) return;

    final List<_CatalogItem> out = [];
    try {
      if (src.isLocal) {
        out.addAll(_searchLocal(q));
      } else if (src.type == _SourceType.musicfree) {
        out.addAll(await _searchMusicFree(q));
      } else {
        // LX 平台：单曲内派生出歌手/专辑；歌单走各源原生歌单接口（宿主代取）。
        if (widget.kind == _CatalogKind.playlist) {
          out.addAll(await _searchLxSheets(q));
        } else {
          out.addAll(await _searchLxDerive(q));
        }
      }
    } catch (_) {
      // 单次失败保持空结果。
    }
    if (!mounted) return;
    if (_searchedHash != hash) return;
    setState(() {
      _items = out;
      _loading = false;
    });
  }

  /// 本地库索引：按当前类型过滤歌手/专辑/歌单。
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

  /// LX 平台：复用单曲搜索结果按歌手/专辑去重派生。
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

  /// LX 平台歌单搜索：宿主代取各源原生歌单接口（kw/kg/tx/wy/mg）。
  Future<List<_CatalogItem>> _searchLxSheets(String q) async {
    final source = widget.source;
    final sheets = await lxHostPlaylistSearchFallback(
      source.plugin!,
      source.lxKey ?? '',
      q,
    );
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

  void _open(_CatalogItem item) {
    FocusScope.of(context).unfocus();
    if (item.localArtist != null) {
      final a = item.localArtist!;
      Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute(
          builder: (_) => SongListPage(
            title: a.name,
            loader: () => ref.read(libraryProvider.notifier).songsByArtist(a.name),
          ),
        ),
      );
      return;
    }
    if (item.localAlbum != null) {
      final a = item.localAlbum!;
      Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute(
          builder: (_) => SongListPage(
            title: a.name,
            loader: () => ref.read(libraryProvider.notifier).songsByAlbum(a.key),
          ),
        ),
      );
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
    // LX 派生：直接播放其歌曲列表。
    if (item.isDirectPlay) {
      final service = PluginSearchService(engine, _plugins());
      final items = item.directSongs
          .map((s) => service.toQueueItem(item.directSource!, s))
          .toList();
      ref.read(playerProvider.notifier).playQueue(items, startIndex: 0);
      return;
    }
    // musicfree 在线条目：进入在线详情页。
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
    return ListView.builder(
      padding: EdgeInsets.only(
        top: _ContentTopInsetScope.of(context),
        bottom: bottomInset,
      ),
      itemCount: _items.length,
      itemBuilder: (context, i) {
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

/// 本地歌手无封面时的字母头像占位。
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