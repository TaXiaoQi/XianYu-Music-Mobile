// 网盘页：以在线搜索结果页样式列全部已绑定网盘的音频文件。
//
// 来源栏 = 全部已绑定网盘（相对顺序沿用音源管理页的 sortIndex）；每个
// 来源首次展示时全量遍历（已选文件夹范围，未选 = 全盘）并写入缓存，
// 重进页面/切回来源直接读缓存不重拉；右上角「刷新」强制重拉当前来源
// 并更新缓存。行样式与搜索结果页网盘条目一致（封面懒探测 + 点击播放
// 整列 + 封面飞入）。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../src/cloud/cloud_credentials_store.dart';
import '../../src/cloud/cloud_filename.dart';
import '../../src/cloud/cloud_folder_selection_store.dart';
import '../../src/cloud/cloud_head_meta.dart';
import '../../src/cloud/cloud_provider.dart';
import '../../src/cloud/cloud_registry.dart';
import '../../src/cloud/cloud_scoped_query.dart';
import '../../src/core/app_colors.dart';
import '../../src/core/application_logger.dart';
import '../../src/core/settings.dart';
import '../../src/navigation/shell.dart'
    show
        landscapeLibraryQueryProvider,
        landscapeDetailProvider,
        LandscapeCloudGroupDetail,
        LandscapeCloudManageDetail;
import '../../src/player/player_provider.dart';
import '../../src/responsive/landscape.dart';
import '../../src/plugin/plugin_preferences.dart';
import '../../src/widgets/floating_search_bar.dart';
import '../../src/widgets/custom_background.dart';
import '../../src/widgets/flying_cover.dart';
import '../../src/widgets/glass_appbar.dart';
import '../../src/widgets/list_metrics.dart';
import '../../src/widgets/online_cover.dart';
import '../../src/widgets/press_scale.dart';
import '../../src/widgets/song_list_view.dart';
import '../../src/widgets/source_tag.dart';
import '../../src/i18n/i18n.dart';

/// 单个网盘来源的全量音频缓存状态。
class CloudDiskSourceState {
  /// 正在拉取（首次或刷新中；刷新时保留旧列表展示）。
  final bool loading;

  /// 成功拉完过一次（含空结果）：重进页面不重拉。
  final bool loaded;
  final String? error;
  final List<QueueItem> items;

  const CloudDiskSourceState({
    this.loading = false,
    this.loaded = false,
    this.error,
    this.items = const [],
  });
}

/// 网盘页全量列表缓存（keep-alive：路由退场后保留，重进直接读）。
final cloudDiskCacheProvider =
    NotifierProvider<CloudDiskCache, Map<String, CloudDiskSourceState>>(
      CloudDiskCache.new,
    );

class CloudDiskCache extends Notifier<Map<String, CloudDiskSourceState>> {
  @override
  Map<String, CloudDiskSourceState> build() => {};

  /// 拉取某网盘全部音频并入缓存；非 force 时已加载/加载中直接跳过。
  Future<void> load(String providerId, {bool force = false}) async {
    final cur = state[providerId];
    if (cur != null && cur.loading) return;
    if (!force && cur != null && cur.loaded) return;
    state = {
      ...state,
      providerId: CloudDiskSourceState(
        loading: true,
        loaded: cur?.loaded ?? false,
        items: cur?.items ?? const [],
      ),
    };
    try {
      final provider = cloudProviderById(providerId);
      if (provider == null) throw StateError(tr('该网盘暂未支持'));
      final accounts = await CloudCredentialsStore.instance.accountsFor(
        providerId,
      );
      if (accounts.isEmpty) throw StateError(tr('网盘账号未绑定或已失效'));
      final acc = accounts.first;
      // 已选文件夹 → 只遍历选定范围；未选 → 全盘遍历
      final roots = await CloudFolderSelectionStore.instance.pathsFor(
        providerId,
        acc.accountId,
      );
      final files = await cloudListAllAudio(
        provider: provider,
        cred: acc.cred,
        selectedRoots: roots,
      );
      final items = <QueueItem>[];
      for (final f in files) {
        final ctx = CloudPlayContext(
          provider: providerId,
          accountId: acc.accountId,
          file: f,
        );
        final parts = parseCloudFileName(f.name);
        items.add(
          cloudPlayQueueItem(
            ctx,
            title: parts.title,
            artist: parts.artist ?? provider.displayName,
          ),
        );
      }
      state = {
        ...state,
        providerId: CloudDiskSourceState(loaded: true, items: items),
      };
    } catch (e) {
      AppLog.warn('cloud', '网盘全量加载失败 provider=$providerId: $e');
      state = {
        ...state,
        providerId: CloudDiskSourceState(
          loaded: cur?.loaded ?? false,
          error: '$e',
          items: cur?.items ?? const [],
        ),
      };
    }
  }

  /// 解绑/来源消失后清理对应缓存。
  void prune(Set<String> aliveIds) {
    if (state.keys.any((k) => !aliveIds.contains(k))) {
      state = {
        for (final e in state.entries)
          if (aliveIds.contains(e.key)) e.key: e.value,
      };
    }
  }
}

class CloudDiskPage extends ConsumerStatefulWidget {
  const CloudDiskPage({super.key, this.paneEmbedded = false});

  /// 横屏音乐库面板专用：内嵌右侧容器。去 GlassTopBar（返回/搜索由壳层
  /// 全局顶栏承担，搜索词与本地/收藏面板同源 landscapeLibraryQueryProvider），
  /// 头部为面板式「全部/歌手/专辑」tab 行 + 刷新钮 + 来源 pill 行
  final bool paneEmbedded;

  @override
  ConsumerState<CloudDiskPage> createState() => _CloudDiskPageState();
}

class _CloudDiskPageState extends ConsumerState<CloudDiskPage>
    with SingleTickerProviderStateMixin {
  List<CloudProvider> _sources = const [];
  String _selectedId = '';
  PageController? _pageCtrl;
  final Map<String, GlobalKey> _sourceKeys = {};

  // 「全部/歌手/专辑」视图切换：与本地页同款分段 tab，装在来源行上方
  late final TabController _viewTabCtrl;

  // 顶栏搜索：客户端过滤当前网盘已缓存列表（歌名/歌手/专辑包含匹配）
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';

  void _onSearchChanged(String v) => setState(() => _query = v.trim());

  void _clearSearch() {
    _searchCtrl.clear();
    setState(() => _query = '');
  }

  @override
  void initState() {
    super.initState();
    _viewTabCtrl = TabController(length: 3, vsync: this)
      ..addListener(() {
        if (mounted) setState(() {});
      });
    // 首帧用已就绪的绑定列表（异步加载完成由 build 内 listen 补触发）
    _applySources(
      ref.read(boundCloudProvidersProvider).valueOrNull ?? const [],
    );
  }

  @override
  void dispose() {
    _pageCtrl?.dispose();
    _viewTabCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _applySources(List<CloudProvider> bound) async {
    // 相对顺序沿用音源管理页的拖拽排序（sortIndex 越小越靠前）
    final prefs = await PluginPreferences.getCloudSources();
    final indexed = <(int, CloudProvider)>[
      for (var i = 0; i < bound.length; i++)
        (prefs[bound[i].id]?.sortIndex ?? (1 << 30) + i, bound[i]),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    final sources = indexed.map((e) => e.$2).toList();
    if (!mounted) return;
    ref
        .read(cloudDiskCacheProvider.notifier)
        .prune(sources.map((p) => p.id).toSet());
    setState(() {
      _sources = sources;
      if (!sources.any((p) => p.id == _selectedId)) {
        _selectedId = sources.isEmpty ? '' : sources.first.id;
      }
      for (final p in sources) {
        _sourceKeys[p.id] ??= GlobalKey();
      }
      _sourceKeys.removeWhere((id, _) => !sources.any((p) => p.id == id));
      // 来源集合变化即重建控制器对齐选中页（绑定/解绑是低频操作）
      _pageCtrl?.dispose();
      _pageCtrl = null;
      if (sources.length > 1) {
        final idx = sources.indexWhere((p) => p.id == _selectedId);
        _pageCtrl = PageController(initialPage: idx < 0 ? 0 : idx);
      }
    });
    if (_selectedId.isNotEmpty) {
      unawaited(ref.read(cloudDiskCacheProvider.notifier).load(_selectedId));
    }
  }

  void _onPageChanged(int index) {
    if (!mounted || index < 0 || index >= _sources.length) return;
    final id = _sources[index].id;
    if (id == _selectedId) return;
    setState(() => _selectedId = id);
    unawaited(ref.read(cloudDiskCacheProvider.notifier).load(id));
    _ensureVisible(id);
  }

  void _onSourceTap(String id) {
    final idx = _sources.indexWhere((p) => p.id == id);
    if (idx < 0) return;
    if (id != _selectedId) {
      setState(() => _selectedId = id);
      unawaited(ref.read(cloudDiskCacheProvider.notifier).load(id));
      final ctrl = _pageCtrl;
      if (ctrl != null && ctrl.hasClients) {
        ctrl.animateToPage(
          idx,
          duration: const Duration(milliseconds: 300),
          curve: Curves.fastLinearToSlowEaseIn,
        );
      }
    }
    _ensureVisible(id);
  }

  void _ensureVisible(String id) {
    final ctx = _sourceKeys[id]?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 300),
        curve: Curves.fastLinearToSlowEaseIn,
        alignment: 0.5,
      );
    }
  }

  // 与本地页顶栏同款的搜索输入框
  Widget _buildSearchField(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return SizedBox(
      height: 40,
      child: TextField(
        controller: _searchCtrl,
        onChanged: _onSearchChanged,
        textInputAction: TextInputAction.search,
        style: TextStyle(fontSize: 14.5, color: scheme.onSurface),
        decoration: InputDecoration(
          hintText: tr('搜索歌曲、歌手、专辑'),
          hintStyle: TextStyle(fontSize: 14.5, color: scheme.onSurfaceVariant),
          prefixIcon: Icon(
            Icons.search,
            size: 20,
            color: scheme.onSurfaceVariant,
          ),
          prefixIconConstraints: const BoxConstraints(
            minWidth: 40,
            minHeight: 40,
          ),
          suffixIcon: _query.isNotEmpty
              ? InkWell(
                  onTap: _clearSearch,
                  child: Icon(
                    Icons.close,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  ),
                )
              : null,
          suffixIconConstraints: const BoxConstraints(
            minWidth: 40,
            minHeight: 40,
          ),
          isDense: true,
          filled: true,
          fillColor: isDark ? const Color(0x14FFFFFF) : const Color(0x14000000),
          contentPadding: const EdgeInsets.symmetric(
            vertical: 0,
            horizontal: 8,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(20),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 绑定/解绑实时跟随（登录页完成返回、设置页解绑）
    ref.listen(boundCloudProvidersProvider, (_, next) {
      _applySources(next.valueOrNull ?? const []);
    });
    final scheme = Theme.of(context).colorScheme;
    final cur = _selectedId.isEmpty
        ? null
        : ref.watch(cloudDiskCacheProvider)[_selectedId];
    final refreshing = cur?.loading ?? false;
    final inPane = widget.paneEmbedded;
    // 面板态搜索词来自壳层全局顶栏（与本地/收藏面板同一 provider）；
    // 路由态用页内顶栏搜索框
    final query = inPane
        ? ref.watch(landscapeLibraryQueryProvider).trim()
        : _query;

    // 分段 tab 计数：对当前来源已缓存全量统计（歌手按解析艺术家去重，
    // 专辑空名归并为「未知专辑」）
    final curItems = cur?.items ?? const <QueueItem>[];
    final unknownAlbum = tr('未知专辑');
    final artistCount = {for (final it in curItems) it.artist}.length;
    final albumCount = {
      for (final it in curItems) it.album.isEmpty ? unknownAlbum : it.album,
    }.length;

    final tabs = [
      Tab(text: '全部 ${curItems.length}'),
      Tab(text: '歌手 $artistCount'),
      Tab(text: '专辑 $albumCount'),
    ];
    final viewTabBar = TabBar(
      controller: _viewTabCtrl,
      isScrollable: false,
      tabs: tabs,
    );
    // 面板态 tab：与本地页面板同款（左对齐滚动、指示器随标签宽）
    final paneTabBar = TabBar(
      controller: _viewTabCtrl,
      isScrollable: true,
      tabAlignment: TabAlignment.start,
      indicatorSize: TabBarIndicatorSize.label,
      labelPadding: const EdgeInsets.symmetric(horizontal: 10),
      tabs: tabs,
    );

    if (inPane) {
      final floating = ref.watch(
        settingsProvider.select(
          (s) => s.valueOrNull?.floatingSearchBar ?? false,
        ),
      );
      final statusBar = MediaQuery.paddingOf(context).top;
      final paneTop = floating ? statusBar + 66 : 0.0;
      final hasSources = _sources.isNotEmpty;
      // 面板头部 = tab 行 48（右侧刷新）+ 来源行 48；无来源时不占头部
      final contentTop = hasSources
          ? paneTop + (floating ? 10 : 4) + 96 + 8
          : paneTop;
      return Scaffold(
        backgroundColor: appScaffoldBackground(context, ref),
        resizeToAvoidBottomInset: false,
        body: Stack(
          children: [
            Padding(
              padding: EdgeInsets.only(top: contentTop),
              child: _buildBody(query),
            ),
            if (hasSources)
              Positioned(
                top: paneTop,
                left: floating ? 12 : 0,
                right: floating ? 12 : 0,
                child: _buildPaneHeader(
                  context,
                  paneTabBar,
                  floating,
                  refreshing: refreshing,
                ),
              ),
          ],
        ),
      );
    }

    // 悬浮态：与在线搜索结果页同款 chrome（搜索胶囊 + 红色刷新钮 + tab
    // 胶囊 + 来源 pill 行）。不能靠 GlassTopBar 自动转悬浮——它会把 96 高
    // 的 bottom 整体塞进悬浮 chrome，来源行高度对不上溢出 2px
    final floating = ref.watch(
      settingsProvider.select((s) => s.valueOrNull?.floatingSearchBar ?? false),
    );
    if (floating) {
      final statusBar = MediaQuery.paddingOf(context).top;
      final hasSources = _sources.isNotEmpty;
      // 行高口径对齐搜索结果页：搜索行 44 + tab 胶囊 48 + 来源行 40，行距 10
      final contentTop =
          statusBar + 8 + 44 + (hasSources ? 10 + 48 + 10 + 40 : 0) + 6;
      return Scaffold(
        backgroundColor: appScaffoldBackground(context, ref),
        resizeToAvoidBottomInset: false,
        body: Stack(
          children: [
            Padding(
              padding: EdgeInsets.only(top: contentTop),
              child: _buildBody(query),
            ),
            Positioned(
              top: statusBar + 8,
              left: 12,
              right: 12,
              child: FloatingSearchTopBar(
                onBack: () => context.pop(),
                field: hasSources
                    ? FloatingGlassSearchField(
                        controller: _searchCtrl,
                        onChanged: _onSearchChanged,
                        showClear: _query.isNotEmpty,
                        onClear: _clearSearch,
                        hint: tr('搜索歌曲、歌手、专辑'),
                      )
                    : FloatingGlassSurface(
                        child: SizedBox(
                          height: 44,
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 18,
                              ),
                              child: Text(
                                tr('网盘'),
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: scheme.onSurface,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                action: hasSources
                    ? _buildRefreshAction(refreshing, floating: true)
                    : null,
                tabPill: hasSources ? FloatingTabPill(child: viewTabBar) : null,
                bottomPill: hasSources
                    ? _buildSourceBar(horizontalPadding: 2)
                    : null,
              ),
            ),
          ],
        ),
      );
    }

    // 头部 bottom = 分段 tab 行 + 来源 pill 行（顺序对齐搜索结果页）
    final headerBottom = _sources.isEmpty
        ? null
        : PreferredSizeProxy(
            height: 96,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(height: 48, child: viewTabBar),
                SizedBox(
                  height: 48,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: _buildSourceBar(),
                  ),
                ),
              ],
            ),
          );

    final contentTop = headerBottom == null
        ? GlassTopBar.height(context)
        : GlassTopBar.height(context, bottom: headerBottom);

    return Scaffold(
      backgroundColor: appScaffoldBackground(context, ref),
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          Padding(
            padding: EdgeInsets.only(top: contentTop),
            child: _buildBody(query),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: GlassTopBar(
              leading: const BackButton(),
              titleSpacing: 4,
              title: _sources.isEmpty
                  ? Text(tr('网盘'))
                  : _buildSearchField(context),
              actions: [
                if (_sources.isNotEmpty)
                  _buildRefreshAction(refreshing, floating: false),
              ],
              bottom: headerBottom,
            ),
          ),
        ],
      ),
    );
  }

  /// 来源 pill 横滑行：固定态内边距 14、悬浮态 2、面板态 6（对齐各行头）
  Widget _buildSourceBar({double horizontalPadding = 14}) {
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
        children: [
          for (final p in _sources)
            Padding(
              key: _sourceKeys[p.id],
              padding: const EdgeInsets.only(right: 8),
              child: FloatingSourcePill(
                name: p.displayName,
                selected: p.id == _selectedId,
                onTap: () => _onSourceTap(p.id),
              ),
            ),
        ],
      ),
    );
  }

  /// 红色圆形刷新钮（固定态/悬浮态/面板态共用）；floating 走玻璃胶囊钮
  Widget _buildRefreshAction(bool refreshing, {required bool floating}) {
    final scheme = Theme.of(context).colorScheme;
    final loading = SizedBox(
      width: 18,
      height: 18,
      child: CircularProgressIndicator(
        strokeWidth: 2,
        color: floating ? scheme.primary : scheme.onPrimary,
      ),
    );
    if (floating) {
      return PressableScale(
        pressScale: 0.88,
        child: BiliPaiIconButton(
          icon: refreshing ? null : Icons.refresh,
          iconChild: refreshing ? loading : null,
          tooltip: tr('刷新'),
          color: scheme.primary,
          onTap: refreshing
              ? null
              : () => ref
                    .read(cloudDiskCacheProvider.notifier)
                    .load(_selectedId, force: true),
        ),
      );
    }
    return PressableScale(
      pressScale: 0.88,
      child: IconButton(
        tooltip: tr('刷新'),
        icon: refreshing ? loading : const Icon(Icons.refresh),
        style: IconButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
        ),
        onPressed: refreshing
            ? null
            : () => ref
                  .read(cloudDiskCacheProvider.notifier)
                  .load(_selectedId, force: true),
      ),
    );
  }

  /// 面板头部：tab 行（左对齐滚动 tab + 右侧红色圆形刷新钮，与本地页
  /// 面板头部同款 Row 结构）+ 来源 pill 横滑行；固定态整体带底部分隔线，
  /// 悬浮态 tab 行套玻璃面、来源行裸排（pill 自带玻璃）
  Widget _buildPaneHeader(
    BuildContext context,
    Widget tabBar,
    bool floating, {
    required bool refreshing,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final tabRow = SizedBox(
      height: 48,
      child: Row(
        children: [
          Expanded(
            child: Theme(
              data: Theme.of(context).copyWith(
                tabBarTheme: TabBarThemeData(dividerColor: Colors.transparent),
              ),
              child: Padding(
                padding: const EdgeInsets.only(left: 4, right: 8),
                child: tabBar,
              ),
            ),
          ),
          _buildRefreshAction(refreshing, floating: false),
          const SizedBox(width: 6),
        ],
      ),
    );
    // 来源 pill 行：与路由态头部 bottom 同款横滑行（内边距对齐 tab 行）
    final sourcesRow = SizedBox(
      height: 48,
      child: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: _buildSourceBar(horizontalPadding: 6),
      ),
    );
    if (floating) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FloatingGlassSurface(child: tabRow),
          sourcesRow,
        ],
      );
    }
    return Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: scheme.onSurface.withValues(alpha: 0.06)),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [tabRow, sourcesRow],
      ),
    );
  }

  Widget _buildBody(String query) {
    if (_sources.isEmpty) {
      final scheme = Theme.of(context).colorScheme;
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_outlined,
              size: 48,
              color: scheme.onSurface.withValues(alpha: 0.25),
            ),
            const SizedBox(height: 12),
            Text(
              tr('尚未绑定网盘'),
              style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () {
                // 横屏：内嵌右容器详情面板；竖屏走路由
                if (useLandscape(ref)) {
                  ref.read(landscapeDetailProvider.notifier).state =
                      const LandscapeCloudManageDetail();
                } else {
                  context.push('/cloud');
                }
              },
              child: Text(tr('去绑定')),
            ),
          ],
        ),
      );
    }
    final ctrl = _pageCtrl;
    if (ctrl == null) {
      return _CloudSourceList(
        provider: _sources.first,
        query: query,
        viewTab: _viewTabCtrl.index,
      );
    }
    return PageView.builder(
      controller: ctrl,
      onPageChanged: _onPageChanged,
      itemCount: _sources.length,
      itemBuilder: (context, i) => _CloudSourceList(
        provider: _sources[i],
        query: query,
        viewTab: _viewTabCtrl.index,
      ),
    );
  }
}

class _CloudSourceList extends ConsumerWidget {
  const _CloudSourceList({
    required this.provider,
    this.query = '',
    this.viewTab = 0,
  });

  final CloudProvider provider;

  /// 顶栏搜索词：非空时对已缓存列表做客户端过滤（歌名/歌手/专辑包含匹配）
  final String query;

  /// 分段视图：0=全部，1=歌手分组，2=专辑分组
  final int viewTab;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(cloudDiskCacheProvider)[provider.id];
    final scheme = Theme.of(context).colorScheme;
    final bottomPad =
        (ref.watch(playerProvider.select((s) => s.current != null))
            ? 92.0
            : 16.0) +
        MediaQuery.of(context).padding.bottom;

    if (st == null || (st.loading && st.items.isEmpty)) {
      return const Center(child: CircularProgressIndicator());
    }
    if (st.error != null && st.items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(st.error!),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () => ref
                  .read(cloudDiskCacheProvider.notifier)
                  .load(provider.id, force: true),
              icon: const Icon(Icons.refresh),
              label: Text(tr('重试')),
            ),
          ],
        ),
      );
    }
    if (st.items.isEmpty) {
      return Center(
        child: Text(
          tr('该网盘暂无音频文件'),
          style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant),
        ),
      );
    }
    // 搜索过滤：只过滤展示，不动缓存；播放队列 = 过滤后的列表
    final q = query.toLowerCase();
    final items = q.isEmpty
        ? st.items
        : st.items
              .where(
                (it) =>
                    it.title.toLowerCase().contains(q) ||
                    it.artist.toLowerCase().contains(q) ||
                    it.album.toLowerCase().contains(q),
              )
              .toList();
    if (items.isEmpty) {
      return Center(
        child: Text(
          tr('没有找到相关歌曲'),
          style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant),
        ),
      );
    }
    // 歌手/专辑分组视图：按解析字段聚组，点进组看该组全部歌曲
    if (viewTab == 1 || viewTab == 2) {
      final unknownAlbum = tr('未知专辑');
      final groups = <String, List<QueueItem>>{};
      for (final it in items) {
        final key = viewTab == 1
            ? it.artist
            : (it.album.isEmpty ? unknownAlbum : it.album);
        (groups[key] ??= []).add(it);
      }
      final names = groups.keys.toList()
        ..sort((a, b) {
          final c = groups[b]!.length.compareTo(groups[a]!.length);
          return c != 0 ? c : a.compareTo(b);
        });
      return ListView.builder(
        padding: EdgeInsets.only(bottom: bottomPad),
        itemCount: names.length,
        itemBuilder: (context, i) {
          final name = names[i];
          final groupItems = groups[name]!;
          return _CloudGroupRow(
            name: name,
            count: groupItems.length,
            isArtist: viewTab == 1,
            onTap: () {
              // 横屏：下钻内嵌右容器二级面板；竖屏走原命令式路由
              if (useLandscape(ref)) {
                ref.read(landscapeDetailProvider.notifier).state =
                    LandscapeCloudGroupDetail(title: name, items: groupItems);
                return;
              }
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) =>
                      CloudGroupSongsPage(title: name, items: groupItems),
                ),
              );
            },
          );
        },
      );
    }
    return ListView.builder(
      padding: EdgeInsets.only(bottom: bottomPad),
      itemCount: items.length,
      itemBuilder: (context, i) => _CloudTrackRow(items: items, index: i),
    );
  }
}

class _CloudTrackRow extends ConsumerWidget {
  const _CloudTrackRow({required this.items, required this.index});

  final List<QueueItem> items;
  final int index;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final item = items[index];
    final scheme = Theme.of(context).colorScheme;
    final m = ListMetrics.ofRef(ref);
    final meta = ref.watch(cloudHeadMetaProvider)[item.path];
    if (meta == null) {
      // 懒调度头部元数据探测（幂等/限并发）：滚动进视口才排队，避免全量
      // 列表一次性发起大量探测；provider 常驻，notifier 生命周期长于行
      final ctx = CloudPlayContext.tryParse(item.cloudInfoJson);
      final notifier = ref.read(cloudHeadMetaProvider.notifier);
      if (ctx != null) {
        unawaited(Future.microtask(() => notifier.scheduleCloudContext(ctx)));
      }
    }
    BuildContext? coverCtx;
    return PressableScale(
      child: CoverRow(
        cover: Builder(
          builder: (c) {
            coverCtx = c;
            return OnlineCover(
              url: item.coverUrl,
              filePath: meta?.coverPath,
              size: m.songCover,
              radius: m.songRadius,
            );
          },
        ),
        title: Text(
          item.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: m.titleSize, fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          [
            item.artist,
            item.album,
            if (meta?.durationSecs != null) _fmtDuration(meta!.durationSecs!),
          ].where((s) => s.isNotEmpty).join(' · '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: m.subtitleSize,
            color: scheme.onSurfaceVariant,
          ),
        ),
        verticalPadding: m.vPad,
        trailing: SongTrailingMeta(
          path: item.path,
          isOnline: true,
          durationText: meta?.durationSecs != null
              ? _fmtDuration(meta!.durationSecs!)
              : null,
          fontSize: m.subtitleSize,
        ),
        onTap: () async {
          final ok = await launchFlyCover(
            context,
            coverContext: coverCtx,
            coverSize: m.songCover,
            vPad: m.vPad,
            songPath: item.path,
            networkUrl: item.coverUrl,
            thumbPath: meta?.coverPath,
            radius: m.songRadius,
          );
          if (ok && context.mounted) {
            ref
                .read(playerProvider.notifier)
                .playQueue(items, startIndex: index);
          }
        },
      ),
    );
  }
}

String _fmtDuration(int secs) {
  final m = secs ~/ 60;
  final s = secs % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}

/// 歌手/专辑分组行：图标块 + 名称 + 曲目数，点进组内歌曲列表。
class _CloudGroupRow extends StatelessWidget {
  const _CloudGroupRow({
    required this.name,
    required this.count,
    required this.isArtist,
    required this.onTap,
  });

  final String name;
  final int count;
  final bool isArtist;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PressableScale(
      child: ListTile(
        onTap: onTap,
        leading: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: scheme.primary.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            isArtist ? Icons.person_outline : Icons.album_outlined,
            color: scheme.primary,
            size: 22,
          ),
        ),
        title: Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          '$count 首',
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
        trailing: Icon(
          Icons.chevron_right,
          size: 20,
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// 组内歌曲列表页（歌手/专辑下钻）：行样式与主列表一致，播放队列 = 该组。
/// 横屏下面板内嵌（paneEmbedded，由 _LandscapeDetailPane 承载返回与标题），
/// 竖屏走命令式路由全屏页。
class CloudGroupSongsPage extends ConsumerWidget {
  const CloudGroupSongsPage({
    super.key,
    required this.title,
    required this.items,
    this.paneEmbedded = false,
  });

  final String title;
  final List<QueueItem> items;
  final bool paneEmbedded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bottomPad =
        (ref.watch(playerProvider.select((s) => s.current != null))
            ? 92.0
            : 16.0) +
        MediaQuery.of(context).padding.bottom;
    final list = ListView.builder(
      padding: EdgeInsets.only(bottom: bottomPad),
      itemCount: items.length,
      itemBuilder: (context, i) => _CloudTrackRow(items: items, index: i),
    );
    if (paneEmbedded) {
      // 面板态：外层 FlatTopBar 占位，内容铺满
      return Scaffold(
        backgroundColor: appScaffoldBackground(context, ref),
        body: list,
      );
    }
    // 命令式路由（MaterialPageRoute）不经过 go_router 的 RoutePageBackdrop
    // 挂载点，页面透明 Scaffold 转场时会透出下层的网盘页——此处自垫底图
    //（不传 location，回落全局壁纸语义，与本地页下钻观感一致）
    return RoutePageBackdrop(
      child: Scaffold(
        backgroundColor: appScaffoldBackground(context, ref),
        body: Stack(
          children: [
            Padding(
              padding: EdgeInsets.only(top: GlassTopBar.height(context)),
              child: list,
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: GlassTopBar(
                leading: const BackButton(),
                title: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
