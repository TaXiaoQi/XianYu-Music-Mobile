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
import '../../src/cloud/cloud_scan_cache_store.dart';
import '../../src/cloud/cloud_scoped_query.dart';
import '../../src/cloud/cloud_types.dart';
import '../../src/core/app_colors.dart';
import '../../src/core/application_logger.dart';
import '../../src/core/page_sort_prefs.dart';
import '../../src/core/pinyin_key.dart';
import '../../src/core/settings.dart';
import '../../src/navigation/shell.dart'
    show
        landscapeLibraryQueryProvider,
        landscapeDetailProvider,
        LandscapeCloudGroupDetail,
        LandscapeCloudManageDetail;
import '../../src/download/download_provider.dart';
import '../../src/player/player_provider.dart';
import '../../src/responsive/landscape.dart';
import '../../src/plugin/plugin_preferences.dart';
import '../../src/widgets/app_toast.dart';
import '../../src/widgets/batch_action_bar.dart';
import '../../src/widgets/floating_search_bar.dart';
import '../../src/widgets/custom_background.dart';
import '../../src/widgets/flying_cover.dart';
import '../../src/widgets/glass_appbar.dart';
import '../../src/widgets/list_metrics.dart';
import '../../src/widgets/online_cover.dart';
import '../../src/widgets/floating_letter_index.dart';
import '../../src/widgets/press_scale.dart';
import '../../src/widgets/sort_dropdown.dart';
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
      // 多账号按绑定顺序逐个尝试：旧账号失效/无文件则换下一个；
      // 先查 24h 落盘缓存（重启免重扫，对应移动端「扫完重启就空」反馈）。
      Object? lastError;
      for (final acc in accounts) {
        if (!force) {
          final cached = await CloudScanCacheStore.instance
              .loadFresh(providerId, acc.accountId);
          if (cached != null) {
            state = {
              ...state,
              providerId: CloudDiskSourceState(
                loaded: true,
                items: cached.files.map((f) => _queueItem(providerId, acc.accountId, provider, f)).toList(),
              ),
            };
            return;
          }
        }
        try {
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
          await CloudScanCacheStore.instance.save(providerId, acc.accountId, files);
          state = {
            ...state,
            providerId: CloudDiskSourceState(
              loaded: true,
              items: files.map((f) => _queueItem(providerId, acc.accountId, provider, f)).toList(),
            ),
          };
          return;
        } catch (e) {
          // 该账号遍历失败（凭据失效/风控）：单账号向上抛，多账号换下一个
          lastError = e;
          if (accounts.length == 1) rethrow;
        }
      }
      throw lastError ?? StateError(tr('网盘账号未绑定或已失效'));
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

/// 网盘文件 → 播放队列条目（缓存命中与实扫共用）。
QueueItem _queueItem(
  String providerId,
  String accountId,
  CloudProvider provider,
  CloudFile f,
) {
  final ctx = CloudPlayContext(
    provider: providerId,
    accountId: accountId,
    file: f,
  );
  final parts = parseCloudFileName(f.name);
  return cloudPlayQueueItem(
    ctx,
    title: parts.title,
    artist: parts.artist ?? provider.displayName,
  );
}

class CloudDiskPage extends ConsumerStatefulWidget {
  const CloudDiskPage({super.key, this.paneEmbedded = false});

  /// 横屏音乐库面板专用：内嵌右侧容器。去 GlassTopBar（返回/搜索由壳层
  /// 全局顶栏承担，搜索词与本地/收藏面板同源 landscapeLibraryQueryProvider），
  /// 头部为面板式「全部/歌手/专辑」tab 行（右侧排序/批量入口 + 刷新钮）+
  /// 来源 pill 行
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

  // 排序/批量：与本地页同款入口，作用于「全部」列表（歌手/专辑分组自带
  // 排序不受影响）；批量动作 = 播放 + 下载（收藏/歌单按本地 path 匹配，
  // 云端条目不参与，避免数据错位）
  final SongBatchController _batch = SongBatchController();
  _CloudSort _sort = _CloudSort.none;
  bool _sortAsc = true;

  // 去重开关：与本地页同款（歌名+歌手重复只留首条），仅影响展示
  bool _hideDuplicates = false;

  void _toggleDedup() => setState(() => _hideDuplicates = !_hideDuplicates);

  /// 切来源/切视图即退出批量（选中集合不跨来源/视图残留）
  void _exitBatchIfNeeded() {
    if (_batch.batchMode) {
      _batch.exit();
      if (mounted) setState(() {});
    }
  }

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
        _exitBatchIfNeeded();
        if (mounted) setState(() {});
      });
    // 首帧用已就绪的绑定列表（异步加载完成由 build 内 listen 补触发）
    _applySources(
      ref.read(boundCloudProvidersProvider).valueOrNull ?? const [],
    );
    // 恢复上次排序档/方向（退出页面不再回落默认）
    unawaited(_loadSortPrefs());
  }

  Future<void> _loadSortPrefs() async {
    final (idx, asc) = await PageSortPrefs.load('cloud-disk');
    if (!mounted) return;
    setState(() {
      _sort = _CloudSort.values[idx.clamp(0, _CloudSort.values.length - 1)];
      _sortAsc = asc;
    });
  }

  @override
  void dispose() {
    _pageCtrl?.dispose();
    _viewTabCtrl.dispose();
    _searchCtrl.dispose();
    _batch.dispose();
    super.dispose();
  }

  /// 应用排序（锚定下拉选中后回调），作用于「全部」列表
  void _applySort(_CloudSort type, bool asc) {
    if (type == _sort && asc == _sortAsc) return;
    setState(() {
      _sort = type;
      _sortAsc = asc;
    });
    unawaited(PageSortPrefs.save('cloud-disk', type.index, asc));
  }

  /// 进入/退出批量模式（操作行右按钮）
  void _toggleBatch() {
    setState(() {
      if (_batch.batchMode) {
        _batch.exit();
      } else {
        _batch.enter();
      }
    });
  }

  /// 批量模式下拦截系统返回：先退批量再退页（与本地页同款）
  Widget withBatchPop(Widget child) => PopScope(
    canPop: !_batch.batchMode,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop) {
        setState(() => _batch.exit());
      }
    },
    child: child,
  );

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
    _exitBatchIfNeeded();
    setState(() => _selectedId = id);
    unawaited(ref.read(cloudDiskCacheProvider.notifier).load(id));
    _ensureVisible(id);
  }

  void _onSourceTap(String id) {
    final idx = _sources.indexWhere((p) => p.id == id);
    if (idx < 0) return;
    if (id != _selectedId) {
      _exitBatchIfNeeded();
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
    // 均分 tab（isScrollable: false）：悬浮面板态在 FloatingTabPill 内
    // 呈现收藏页同款胶囊选中块，路由态顶栏 bottom 同款
    final viewTabBar = TabBar(
      controller: _viewTabCtrl,
      isScrollable: false,
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
      return withBatchPop(
        Scaffold(
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
                    viewTabBar,
                    floating,
                    refreshing: refreshing,
                    query: query,
                  ),
                ),
            ],
          ),
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
      return withBatchPop(
        Scaffold(
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
                  tabPill: hasSources
                      ? FloatingTabPill(child: viewTabBar)
                      : null,
                  bottomPill: hasSources
                      ? _buildSourceBar(horizontalPadding: 2)
                      : null,
                ),
              ),
            ],
          ),
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

    return withBatchPop(
      Scaffold(
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

  /// 刷新入口：面板 tab 行内为普通图标（内嵌胶囊条不画红底），
  /// floating 走玻璃胶囊钮（竖屏路由态顶栏）
  Widget _buildRefreshAction(bool refreshing, {required bool floating}) {
    final scheme = Theme.of(context).colorScheme;
    final loading = SizedBox(
      width: 18,
      height: 18,
      child: CircularProgressIndicator(
        strokeWidth: 2,
        color: scheme.primary,
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
    // 面板 tab 行内嵌玻璃胶囊条：普通图标，不再画红色圆底
    return PressableScale(
      pressScale: 0.88,
      child: IconButton(
        tooltip: tr('刷新'),
        icon: refreshing ? loading : const Icon(Icons.refresh),
        onPressed: refreshing
            ? null
            : () => ref
                  .read(cloudDiskCacheProvider.notifier)
                  .load(_selectedId, force: true),
      ),
    );
  }

  /// 面板头部：tab 行（均分 tab + 胶囊选中块，与收藏页面板同款；右侧
  /// 排序/批量入口 + 普通刷新图标）+ 来源 pill 横滑行；排序/批量从列表内
  /// 操作行上移至此（tab 右、刷新左），仅「全部」视图非搜索态显示；
  /// 固定态整体带底部分隔线，悬浮态 tab 行套收藏页同款玻璃胶囊条、
  /// 来源行裸排（pill 自带玻璃）
  Widget _buildPaneHeader(
    BuildContext context,
    Widget tabBar,
    bool floating, {
    required bool refreshing,
    required String query,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final showSortEntry = _viewTabCtrl.index == 0 && query.isEmpty;
    // 监听批量控制器：底部操作条「完成」退出时头部勾选态图标同步刷新
    final tabActions = ListenableBuilder(
      listenable: _batch,
      builder: (context, _) {
        final inBatch = _batch.batchMode;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showSortEntry) ...[
              Tooltip(
                message: _hideDuplicates
                    ? tr('已隐藏重复歌曲')
                    : tr('隐藏重复歌曲'),
                child: IconButton(
                  icon: Icon(
                    _hideDuplicates ? Icons.flip_to_front : Icons.flip_to_back,
                    color: _hideDuplicates ? scheme.primary : null,
                  ),
                  onPressed: _toggleDedup,
                ),
              ),
              IconButton(
                tooltip: inBatch ? tr('完成') : tr('批量'),
                onPressed: _toggleBatch,
                icon: Icon(
                  inBatch ? Icons.check_rounded : Icons.checklist_rounded,
                  size: 22,
                  color: inBatch ? scheme.primary : null,
                ),
              ),
              // 桌面端同款锚定排序下拉（非居中弹窗）
              SortMenuButton<_CloudSort>(
                options: [
                  for (final s in _CloudSort.values)
                    SortOption(value: s, label: _cloudSortLabel(s)),
                ],
                current: _sort,
                ascending: _sortAsc,
                isDirectional: _cloudSortDirectional,
                defaultAscending: _cloudSortDefaultAsc,
                onChanged: _applySort,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 8,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.sort, size: 18, color: scheme.onSurfaceVariant),
                      const SizedBox(width: 2),
                      if (_sort != _CloudSort.none)
                        Icon(
                          Icons.arrow_drop_down,
                          size: 18,
                          color: scheme.onSurfaceVariant,
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
    // tab 行内容（不带高度）：悬浮态交给 FloatingTabPill 控高并注入胶囊
    // 指示块主题，内层严禁再包 Theme 覆盖 tabBarTheme——copyWith 传
    // tabBarTheme 是整体替换、且 Theme.of 在外层 context 立即求值，
    // 会抹掉胶囊回落下划线；固定态无胶囊可保，仅去 divider
    final tabBarRow = Row(
      children: [
        Expanded(
          child: floating
              ? tabBar
              : Theme(
                  data: Theme.of(context).copyWith(
                    tabBarTheme:
                        Theme.of(context).tabBarTheme.copyWith(
                              dividerColor: Colors.transparent,
                            ),
                  ),
                  child: tabBar,
                ),
        ),
        tabActions,
        _buildRefreshAction(refreshing, floating: false),
        const SizedBox(width: 4),
      ],
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
          // 与收藏页面板同款胶囊条：均分 tab + 胶囊选中块
          // （批量/排序/刷新内嵌条内，不另加气泡）
          FloatingTabPill(child: tabBarRow),
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
        children: [
          SizedBox(height: 48, child: tabBarRow),
          sourcesRow,
        ],
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
        sort: _sort,
        sortAsc: _sortAsc,
        hideDuplicates: _hideDuplicates,
        inPane: widget.paneEmbedded,
        onSortChanged: _applySort,
        onToggleDedup: _toggleDedup,
        onToggleBatch: _toggleBatch,
        batch: _batch,
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
        sort: _sort,
        sortAsc: _sortAsc,
        hideDuplicates: _hideDuplicates,
        inPane: widget.paneEmbedded,
        onSortChanged: _applySort,
        onToggleDedup: _toggleDedup,
        onToggleBatch: _toggleBatch,
        batch: _batch,
      ),
    );
  }
}

class _CloudSourceList extends ConsumerWidget {
  const _CloudSourceList({
    required this.provider,
    this.query = '',
    this.viewTab = 0,
    this.sort = _CloudSort.none,
    this.sortAsc = true,
    this.hideDuplicates = false,
    this.inPane = false,
    this.onSortChanged,
    this.onToggleDedup,
    this.onToggleBatch,
    this.batch,
  });

  final CloudProvider provider;

  /// 顶栏搜索词：非空时对已缓存列表做客户端过滤（歌名/歌手/专辑包含匹配）
  final String query;

  /// 分段视图：0=全部，1=歌手分组，2=专辑分组
  final int viewTab;

  /// 「全部」列表排序（与本地页同款菜单）；分组视图自带排序不受影响
  final _CloudSort sort;

  /// 排序方向（true=升序）
  final bool sortAsc;

  /// 去重开关（歌名+歌手重复只留首条，与本地页同款）
  final bool hideDuplicates;

  /// 横屏面板态：排序/批量入口上移到面板头部 tab 行，列表内不再带操作行
  final bool inPane;

  /// 排序变更回调（操作行左入口下拉选中）
  final void Function(_CloudSort type, bool asc)? onSortChanged;

  /// 切换去重显示（操作行按钮）
  final VoidCallback? onToggleDedup;

  /// 进入/退出批量模式（操作行右按钮）
  final VoidCallback? onToggleBatch;

  /// 批量多选控制器（页面级共享，切来源/切视图由页面侧退出）
  final SongBatchController? batch;

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
    // 搜索过滤：只过滤展示，不动缓存；播放队列 = 过滤后的列表。
    // 一律拷贝后再排序/去重——直接持 st.items 原列表排序是既有行为，
    // 但去重若 removeWhere 到原列表会永久删缓存条目，开关关不掉
    final q = query.toLowerCase();
    final filtered = q.isEmpty
        ? st.items
        : st.items
              .where(
                (it) =>
                    it.title.toLowerCase().contains(q) ||
                    it.artist.toLowerCase().contains(q) ||
                    it.album.toLowerCase().contains(q),
              )
              .toList();
    final items = [...filtered];
    if (hideDuplicates) {
      final seen = <String>{};
      items.removeWhere((it) {
        final key = '${it.title.toLowerCase()}|${it.artist.toLowerCase()}';
        if (seen.contains(key)) return true;
        seen.add(key);
        return false;
      });
    }
    if (items.isEmpty) {
      return Center(
        child: Text(
          tr('没有找到相关歌曲'),
          style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant),
        ),
      );
    }
    _sortQueueItems(items, sort, sortAsc);
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
    // 「全部」列表：排序/批量操作行仅竖屏路由态随列表滚动（面板态入口
    // 已上移头部 tab 行）；搜索态不显示；批量模式底栏挂本页 Stack 底部；
    // ListenableBuilder 驱动勾选态/计数实时刷新（buildAll 每次重求值）
    Widget buildAll() {
      final batchMode = batch?.batchMode ?? false;
      final m = ListMetrics.ofRef(ref);
      final rowExtent = m.songCover + 2 * m.vPad;
      // A-Z 排序且非搜索态：右侧悬浮字母索引（滑动滑入，停 2s 滑出）
      final azSort = q.isEmpty &&
          (sort == _CloudSort.title ||
              sort == _CloudSort.artist ||
              sort == _CloudSort.album);
      final showToolbarRow = q.isEmpty && !inPane;
      final list = ListView.builder(
        padding: EdgeInsets.only(bottom: bottomPad),
        itemCount: items.length + (showToolbarRow ? 1 : 0),
        itemBuilder: (context, i) {
          if (showToolbarRow && i == 0) {
            return _CloudToolbarRow(
              sort: sort,
              sortAsc: sortAsc,
              hideDuplicates: hideDuplicates,
              onSortChanged: onSortChanged,
              onToggleDedup: onToggleDedup,
              batchMode: batchMode,
              onToggleBatch: onToggleBatch,
            );
          }
          final index = showToolbarRow ? i - 1 : i;
          return _CloudTrackRow(
            items: items,
            index: index,
            batch: batchMode ? batch : null,
          );
        },
      );
      return Stack(
      children: [
        if (azSort)
          _CloudScrollHost(
            builder: (context, ctrl) => FloatingLetterIndex(
              controller: ctrl,
              itemExtent: rowExtent,
              topInset: 44,
              letters: [
                for (final it in items)
                  letterOfPinyinKey(
                    sort == _CloudSort.artist
                        ? it.artist
                        : sort == _CloudSort.album
                            ? it.album
                            : it.title,
                  ),
              ],
              child: list,
            ),
          )
        else
          list,
        if (batch != null && batchMode)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: BatchActionBar(
              selectedCount: batch!.selectedCount,
              totalCount: items.length,
              showPlay: true,
              showDownload: true,
              showRemove: false,
              onSelectAll: () =>
                  batch!.toggleSelectAll(items.map((e) => e.path).toSet()),
              onPlay: () {
                final picked = [
                  for (final it in items)
                    if (batch!.isSelected(it.path)) it,
                ];
                ref
                    .read(playerProvider.notifier)
                    .playQueue(picked, startIndex: 0);
                batch!.exit();
              },
              onDownload: () async {
                final dn = ref.read(downloadProvider.notifier);
                if (!await dn.requireDownloadDir(context)) return;
                final picked = [
                  for (final it in items)
                    if (batch!.isSelected(it.path)) it,
                ];
                var queued = 0;
                for (final it in picked) {
                  try {
                    await dn.downloadCloud(it);
                    queued++;
                  } catch (_) {}
                }
                batch!.exit();
                if (context.mounted && queued > 0) {
                  showXianYuToast(
                    context,
                    tr('已加入下载队列 {n} 首', {'n': queued}),
                  );
                }
              },
              onRemove: () {},
              onDone: batch!.exit,
            ),
          ),
      ],
      );
    }

    if (batch != null) {
      return ListenableBuilder(
        listenable: batch!,
        builder: (_, _) => buildAll(),
      );
    }
    return buildAll();
  }
}

/// 网盘列表滚动控制器托底：Stateful 持有 ScrollController 生命周期，
/// 供悬浮字母索引与列表共用（_CloudSourceList 本身保持无状态）
class _CloudScrollHost extends StatefulWidget {
  const _CloudScrollHost({required this.builder});

  final Widget Function(BuildContext context, ScrollController controller)
      builder;

  @override
  State<_CloudScrollHost> createState() => _CloudScrollHostState();
}

class _CloudScrollHostState extends State<_CloudScrollHost> {
  late final ScrollController _ctrl = ScrollController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _ctrl);
}

class _CloudTrackRow extends ConsumerWidget {
  const _CloudTrackRow({
    required this.items,
    required this.index,
    this.batch,
  });

  final List<QueueItem> items;
  final int index;

  /// 非空 = 批量模式：行首勾选框、点击行切换选中（播放业务让位）
  final SongBatchController? batch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final item = items[index];
    final scheme = Theme.of(context).colorScheme;
    final m = ListMetrics.ofRef(ref);
    final meta = ref.watch(cloudHeadMetaProvider)[item.path];
    final batchMode = batch != null && batch!.batchMode;
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
    final row = CoverRow(
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
        if (batchMode) {
          batch!.toggle(item.path);
          return;
        }
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
    );
    if (batchMode) {
      // wrapBatchRow 自带按压反馈，行不再包 PressableScale 防双缩放
      return wrapBatchRow(
        context,
        row: row,
        selected: batch!.isSelected(item.path),
        onToggle: () => batch!.toggle(item.path),
      );
    }
    return PressableScale(child: row);
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

/// 「全部」列表排序方式（云端条目无入库时间，省去 addedAt）
enum _CloudSort { none, title, artist, album }

String _cloudSortLabel(_CloudSort s) => switch (s) {
  _CloudSort.none => tr('默认排序'),
  _CloudSort.title => tr('按 A-Z'),
  _CloudSort.artist => tr('按歌手'),
  _CloudSort.album => tr('按专辑'),
};

/// 有方向语义的排序类型（默认排序 = 网盘原始序，降序即倒序展示）
bool _cloudSortDirectional(_CloudSort s) => true;

/// 云端排序类型默认升序
bool _cloudSortDefaultAsc(_CloudSort s) => true;

/// 网盘列表排序（中文按拼音 A-Z；歌手/专辑序内再按标题稳定排）
void _sortQueueItems(List<QueueItem> items, _CloudSort sort, bool asc) {
  // 排序键预计算：中文按拼音 A-Z（QueueItem 无稳定唯一键，按对象身份建表）
  final titleKeys = Map<QueueItem, String>.fromIterables(
      items, [for (final it in items) pinyinSortKey(it.title)]);
  final artistKeys = Map<QueueItem, String>.fromIterables(
      items, [for (final it in items) pinyinSortKey(it.artist)]);
  final albumKeys = Map<QueueItem, String>.fromIterables(
      items, [for (final it in items) pinyinSortKey(it.album)]);
  switch (sort) {
    case _CloudSort.none:
      // 默认排序反向：网盘原始序倒序展示
      if (!asc) {
        final reversed = items.reversed.toList();
        items
          ..clear()
          ..addAll(reversed);
      }
    case _CloudSort.title:
      items.sort(
        (a, b) => asc
            ? titleKeys[a]!.compareTo(titleKeys[b]!)
            : titleKeys[b]!.compareTo(titleKeys[a]!),
      );
    case _CloudSort.artist:
      items.sort((a, b) {
        final c = asc
            ? artistKeys[a]!.compareTo(artistKeys[b]!)
            : artistKeys[b]!.compareTo(artistKeys[a]!);
        return c != 0
            ? c
            : (asc
                  ? titleKeys[a]!.compareTo(titleKeys[b]!)
                  : titleKeys[b]!.compareTo(titleKeys[a]!));
      });
    case _CloudSort.album:
      items.sort((a, b) {
        final c = asc
            ? albumKeys[a]!.compareTo(albumKeys[b]!)
            : albumKeys[b]!.compareTo(albumKeys[a]!);
        return c != 0
            ? c
            : (asc
                  ? titleKeys[a]!.compareTo(titleKeys[b]!)
                  : titleKeys[b]!.compareTo(titleKeys[a]!));
      });
  }
}

/// 「全部」列表顶部操作行：左侧排序入口 + 右侧批量按钮（与本地页同款），
/// 随列表滚动；仅竖屏路由态使用（横屏面板态入口在头部 tab 行）；
/// 歌手/专辑分组视图与搜索态不显示
class _CloudToolbarRow extends StatelessWidget {
  const _CloudToolbarRow({
    required this.sort,
    required this.sortAsc,
    required this.batchMode,
    this.hideDuplicates = false,
    this.onSortChanged,
    this.onToggleDedup,
    this.onToggleBatch,
  });

  final _CloudSort sort;

  /// 排序方向（true=升序）
  final bool sortAsc;

  final bool batchMode;

  /// 去重开关态（与本地页同款图标：重复歌曲只留首条）
  final bool hideDuplicates;

  final void Function(_CloudSort type, bool asc)? onSortChanged;
  final VoidCallback? onToggleDedup;
  final VoidCallback? onToggleBatch;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final subColor = scheme.onSurfaceVariant;
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          const SizedBox(width: 8),
          // 桌面端同款锚定排序下拉（非居中弹窗）
          SortMenuButton<_CloudSort>(
            options: [
              for (final s in _CloudSort.values)
                SortOption(value: s, label: _cloudSortLabel(s)),
            ],
            current: sort,
            ascending: sortAsc,
            isDirectional: _cloudSortDirectional,
            defaultAscending: _cloudSortDefaultAsc,
            onChanged: (t, a) => onSortChanged?.call(t, a),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.sort_rounded, size: 18, color: subColor),
                  const SizedBox(width: 4),
                  Text(
                    _cloudSortLabel(sort),
                    style: TextStyle(fontSize: 13, color: subColor),
                  ),
                  Icon(Icons.expand_more, size: 16, color: subColor),
                ],
              ),
            ),
          ),
          const Spacer(),
          if (onToggleDedup != null)
            Tooltip(
              message: hideDuplicates
                  ? tr('已隐藏重复歌曲')
                  : tr('隐藏重复歌曲'),
              child: IconButton(
                icon: Icon(
                  hideDuplicates ? Icons.flip_to_front : Icons.flip_to_back,
                  color: hideDuplicates ? scheme.primary : subColor,
                ),
                onPressed: onToggleDedup,
              ),
            ),
          IconButton(
            tooltip: batchMode ? tr('完成') : tr('批量'),
            onPressed: onToggleBatch,
            icon: Icon(
              batchMode ? Icons.check_rounded : Icons.checklist_rounded,
              size: 22,
              color: batchMode ? scheme.primary : subColor,
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }
}
