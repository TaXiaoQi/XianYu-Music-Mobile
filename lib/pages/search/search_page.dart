import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../src/auth/account_api.dart';
import '../../src/core/app_colors.dart';
import '../../src/core/db_path.dart';
import '../../src/favorites/favorites_provider.dart';
import '../../src/library/library_provider.dart';
import '../../src/navigation/shell.dart';
import '../../src/player/player_provider.dart';
import '../../src/plugin/plugin_catalog.dart';
import '../../src/plugin/plugin_models.dart';
import '../../src/plugin/plugin_provider.dart';
import '../../src/plugin/plugin_search.dart';
import '../../src/playlist/playlist_provider.dart';
import '../../src/playlist/playlist_store.dart';
import '../../src/widgets/app_toast.dart';
import '../../src/rust/api.dart';
import '../../src/search/search_history_store.dart';
import '../../src/widgets/cover_image.dart';
import '../../src/widgets/flying_cover.dart';
import '../../src/widgets/glass_appbar.dart';
import '../../src/widgets/list_metrics.dart';
import '../../src/widgets/mini_player_bar.dart';
import '../../src/widgets/online_cover.dart';
import '../../src/widgets/song_actions_sheet.dart';
import '../../src/widgets/song_list_view.dart';
import '../home/online_detail_page.dart';
import '../library/song_list_page.dart';

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
const _lxSourceNames = <String, String>{
  'kw': '小蜗音乐',
  'kg': '小枸音乐',
  'tx': '小秋音乐',
  'wy': '小芸音乐',
  'mg': '小蜜音乐',
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

// ==================== 搜索页 ====================

/// 搜索页：合并后的单一在线搜索页。顶部 4 个内容 tab（单曲/歌手/专辑/歌单），
/// tab 下方为来源切换条；来源仅由插件音源构建，无插件时降级为“本地”索引音乐库。
class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage>
    with SingleTickerProviderStateMixin, HidesShellChrome {
  final TextEditingController _ctrl = TextEditingController();
  late final TabController _tab;

  /// idle：默认空白页（搜索历史 + 大家都在搜）；results：搜索结果页。
  _SearchMode _mode = _SearchMode.idle;
  /// 已提交、用于驱动结果页的关键词。
  String _searchedQuery = '';

  bool get _inResults => _mode == _SearchMode.results;

  List<_SourceItem> _sources = const [];
  String _selectedSourceId = '';

  // 输入统计：1.5s 无新输入后批量上报新增字符数。
  int _pendingCharCount = 0;
  int _lastQueryLength = 0;
  Timer? _inputFlushTimer;

  int _activeIndex = 0;

  @override
  void initState() {
    super.initState();
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

  @override
  void dispose() {
    _tab.removeListener(_onTabChanged);
    _inputFlushTimer?.cancel();
    _tab.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  _SourceItem get _selected {
    for (final s in _sources) {
      if (s.id == _selectedSourceId) return s;
    }
    return _sources.isNotEmpty
        ? _sources.first
        : const _SourceItem(
            id: 'local', name: '本地', type: _SourceType.local);
  }

  /// 从插件音源构建来源列表；无插件时返回“本地”。
  void _refreshSources() {
    final plugins = ref.read(pluginManagerProvider).sources;
    // 按用户拖拽排序展示（插件管理页顺序），未排序项用安装顺序兜底
    final enabled = sortPluginSources(plugins.where((p) => p.enabled).toList());
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
        ? const [
            _SourceItem(id: 'local', name: '本地', type: _SourceType.local)
          ]
        : items;
    // 若不触发重建，列表不会更新；若当前选中项失效则落回第一项。
    if (!mounted) return;
    setState(() {
      _sources = result;
      if (result.every((s) => s.id != _selectedSourceId)) {
        _selectedSourceId = result.first.id;
      }
    });
  }

  void _onSourceSelected(String id) {
    if (id == _selectedSourceId) return;
    setState(() => _selectedSourceId = id);
    // 子 tab 通过 didUpdateWidget 感知来源变化并重搜（仅可见 tab）。
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

  /// 提交搜索：加入历史并切换到结果页（仅点击搜索按钮 / 键盘确认 / 点历史或热搜触发）。
  void _submitSearch(String raw) {
    final q = raw.trim();
    if (q.isEmpty) return;
    FocusScope.of(context).unfocus();
    if (_ctrl.text != q) _ctrl.text = q;
    ref.read(searchHistoryProvider.notifier).add(q);
    _tab.index = 0;
    setState(() {
      _searchedQuery = q;
      _mode = _SearchMode.results;
    });
  }

  void _clearInput() {
    if (_ctrl.text.isNotEmpty) _ctrl.clear();
    setState(() {
      _mode = _SearchMode.idle;
      _searchedQuery = '';
    });
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
    final selected = _selected;
    final inResults = _inResults;

    final tabBar = inResults
        ? TabBar(
            controller: _tab,
            tabs: const [
              Tab(text: '单曲'),
              Tab(text: '歌手'),
              Tab(text: '专辑'),
              Tab(text: '歌单'),
            ],
          )
        : null;

    return Scaffold(
      backgroundColor: appSurfaceBg(context),
      // 键盘弹/收时不让 Scaffold 按 viewInsets 逐帧缩放 body：内容不再每帧
      // 重排重绘，顶栏 BackdropFilter 背光也不会被压缩变化反复重采样，
      // 彻底消除输入法动画掉帧（键盘从底部覆盖，结果列表可滚动查看）。
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          Padding(
            padding: EdgeInsets.only(
              top: GlassTopBar.height(context, bottom: tabBar),
            ),
            child: inResults
                ? Column(
                    children: [
                      _buildSourceBar(),
                      Expanded(
                        child: TabBarView(
                          controller: _tab,
                          children: [
                            _TrackTab(
                              keyword: _searchedQuery,
                              source: selected,
                              visible: _tab.index == 0,
                            ),
                            _CatalogTab(
                              kind: _CatalogKind.artist,
                              keyword: _searchedQuery,
                              source: selected,
                              visible: _tab.index == 1,
                            ),
                            _CatalogTab(
                              kind: _CatalogKind.album,
                              keyword: _searchedQuery,
                              source: selected,
                              visible: _tab.index == 2,
                            ),
                            _CatalogTab(
                              kind: _CatalogKind.playlist,
                              keyword: _searchedQuery,
                              source: selected,
                              visible: _tab.index == 3,
                            ),
                          ],
                        ),
                      ),
                    ],
                  )
                : _IdleBody(onSearch: _submitSearch),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: GlassTopBar(
              leading: const BackButton(),
              title: TextField(
                controller: _ctrl,
                autofocus: true,
                textInputAction: TextInputAction.search,
                onChanged: _onChanged,
                onSubmitted: (q) => _submitSearch(q),
                decoration: InputDecoration(
                  hintText: '搜索音乐、歌手、专辑、歌单',
                  border: InputBorder.none,
                  suffixIcon: _ctrl.text.isEmpty && !_inResults
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear, size: 20),
                          onPressed: _clearInput,
                        ),
                ),
              ),
              actions: [
                IconButton(
                  tooltip: '搜索',
                  icon: const Icon(Icons.search),
                  style: IconButton.styleFrom(
                    backgroundColor: scheme.primary,
                    foregroundColor: scheme.onPrimary,
                  ),
                  onPressed: () => _submitSearch(_ctrl.text),
                ),
              ],
              bottom: tabBar,
            ),
          ),
          // 搜索结果页显示迷你播放条；搜索在线页（历史+热搜）不显示。
          if (inResults)
            const MiniPlayerBar(),
        ],
      ),
    );
  }
}

// ==================== 默认页（搜索历史 + 大家都在搜） ====================

enum _SearchMode { idle, results }

/// 大家都在搜：聚合所有用户搜索数据（后端 get_hot_search）。
final _hotSearchProvider = FutureProvider<List<HotSearchItem>>((ref) {
  return ref.read(accountApiProvider).fetchHotSearch(limit: 10);
});

/// 默认空白页：上方搜索历史，下方"大家都在搜"；点击任一关键词即提交搜索。
class _IdleBody extends ConsumerWidget {
  const _IdleBody({required this.onSearch});

  final void Function(String keyword) onSearch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final history = ref.watch(searchHistoryProvider);
    final hotAsync = ref.watch(_hotSearchProvider);
    final bottomInset = MediaQuery.of(context).padding.bottom + 24;

    return ListView(
      padding: EdgeInsets.fromLTRB(16, 4, 16, bottomInset),
      children: [
        // —— 搜索历史 ——
        Row(
          children: [
            Icon(Icons.history, size: 18, color: scheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Text(
              '搜索历史',
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
                    '清空',
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
              '暂无搜索历史',
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
              '大家都在搜',
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
              '${item.count}人搜',
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
        '暂无热搜',
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

class _TrackTabState extends ConsumerState<_TrackTab>
    with AutomaticKeepAliveClientMixin {
  List<_TrackEntry> _results = const [];
  bool _loading = false;
  String _searchedHash = '';

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
    } catch (_) {
      // 单次失败保持空结果，由 UI 展示提示。
    }
    if (!mounted) return;
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
        context, wasFav ? '已取消收藏：${item.title}' : '已收藏：${item.title}');
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
      return _emptyHint('输入关键词搜索音乐', scheme, source: widget.source.name);
    }
    if (_loading && _results.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_results.isEmpty) {
      return _emptyHint('没有找到相关歌曲', scheme, source: widget.source.name);
    }

    final bottomInset = 92.0 + MediaQuery.of(context).padding.bottom;
    return ListView.builder(
      padding: EdgeInsets.only(bottom: bottomInset),
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
                  [s.artist, s.album, '本地']
                      .where((x) => x.isNotEmpty)
                      .join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: m.subtitleSize, color: scheme.onSurfaceVariant),
                ),
                verticalPadding: m.vPad,
                onTap: () {
                  launchFlyCover(
                    rowContext,
                    coverContext: coverCtx,
                    coverSize: m.songCover,
                    vPad: m.vPad,
                    songPath: s.path,
                    thumbPath: s.coverThumbPath,
                    radius: m.songRadius,
                  );
                  _play(i);
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
                  tooltip: '收藏',
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
                  tooltip: '更多',
                  onPressed: () => _openActions(i),
                ),
              ],
            ),
            onLongPress: () => _openActions(i),
            onTap: () {
                debugPrint('[search] online row onTap i=$i');
                try {
                  launchFlyCover(
                    rowContext,
                    coverContext: coverCtx,
                    coverSize: m.songCover,
                    vPad: m.vPad,
                    networkUrl: r.img,
                    radius: m.songRadius,
                  );
                } catch (e, st) {
                  debugPrint('[search] launchFlyCover ERROR: $e\n$st');
                }
                _play(i);
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
        _CatalogKind.artist => '歌手',
        _CatalogKind.album => '专辑',
        _CatalogKind.playlist => '歌单',
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
        // LX 平台：单曲内派生出歌手/专辑；歌单无目录搜索能力。
        if (widget.kind == _CatalogKind.playlist) {
          out.clear();
        } else {
          out.addAll(await _searchLxDerive(q));
        }
      }
    } catch (_) {
      // 单次失败保持空结果。
    }
    if (!mounted) return;
    setState(() {
      _items = out;
      _loading = false;
    });
  }

  /// 本地库索引：按当前类型过滤歌手/专辑/歌单。
  List<_CatalogItem> _searchLocal(String q) {
    final lower = q.toLowerCase();
    final tag = '本地';
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
                subtitle: '${a.count} 首',
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
                subtitle: '${a.artist} · ${a.count} 首',
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
                subtitle: '${p.songs.length} 首',
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
      return _emptyHint('输入关键词搜索$name', scheme, source: widget.source.name);
    }
    if (_loading && _items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_items.isEmpty) {
      return _emptyHint('没有找到相关$name', scheme, source: widget.source.name);
    }

    final bottomInset = 92.0 + MediaQuery.of(context).padding.bottom;
    return ListView.builder(
      padding: EdgeInsets.only(bottom: bottomInset),
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
    {required String source}) {
  return Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.search_off, size: 40, color: scheme.outline),
        const SizedBox(height: 12),
        Text(message, style: TextStyle(color: scheme.onSurfaceVariant)),
        const SizedBox(height: 4),
        Text(
          '结果来自 $source',
          style: TextStyle(fontSize: 12, color: scheme.outline),
        ),
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