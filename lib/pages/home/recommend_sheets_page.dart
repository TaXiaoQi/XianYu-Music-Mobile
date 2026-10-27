import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../src/core/app_colors.dart';
import '../../src/core/application_logger.dart';
import '../../src/core/settings.dart';
import '../../src/navigation/shell.dart';
import '../../src/plugin/plugin_catalog.dart';
import '../../src/plugin/plugin_models.dart';
import '../../src/plugin/plugin_provider.dart';
import '../../src/widgets/glass_appbar.dart';
import '../../src/widgets/floating_search_bar.dart';
import '../../src/widgets/online_cover.dart';
import '../../src/widgets/press_scale.dart';
import '../../src/widgets/stagger_in.dart';
import 'online_detail_page.dart';
import '../../src/i18n/i18n.dart';

class RecommendSheetsPage extends ConsumerStatefulWidget {
  const RecommendSheetsPage({super.key, this.embedded = false});

  final bool embedded;

  @override
  ConsumerState<RecommendSheetsPage> createState() =>
      _RecommendSheetsPageState();
}

/// 推荐歌单来源条目：LX 源按内部平台拆分（与榜单页同款模式），
/// lxKey 为空表示 MF 源或单平台 LX 源
class _RecSource {
  final PluginSource plugin;
  final String? lxKey;
  final String name;

  const _RecSource(this.plugin, this.lxKey, this.name);

  String get id => lxKey == null ? plugin.id : '${plugin.id}__$lxKey';
}

class _RecommendSheetsPageState extends ConsumerState<RecommendSheetsPage>
    with HidesShellChrome, HideMiniBar {
  // 进入歌单详情页（online-detail）时恢复播放条：
  // 详细页是常规浏览页，不该被本页的黑名单连坐
  @override
  bool get hideMiniBarWhenCovered => false;

  List<_RecSource> _sources = const [];
  String? _selectedId;
  PageController? _pageCtrl;
  final Map<String, List<MfSheetItem>> _sheetsCache = {};
  final Set<String> _loadingIds = {};
  final Set<String> _failedIds = {};
  bool _checking = true;
  final Map<String, GlobalKey> _chipKeys = {};

  /// 榜单页同款卡片按行入场（base 200ms / 行 140ms / 600ms）
  late final StaggerWindow _stagger = StaggerWindow(
    baseDelayMs: 200,
    staggerMs: 140,
    rowMs: 600,
    durationMs: 600,
    maxRows: 7,
    onClosed: () {
      if (mounted) setState(() {});
    },
  );

  @override
  void initState() {
    super.initState();
    _detectSources();
  }

  @override
  void dispose() {
    _pageCtrl?.dispose();
    _stagger.dispose();
    super.dispose();
  }

  Future<void> _detectSources() async {
    setState(() => _checking = true);
    final engine = await ref.read(pluginEngineProvider.future);
    final sources = sortPluginSources(
        ref.read(pluginManagerProvider).sources.where((s) => s.enabled).toList());
    final catalog = PluginCatalogService(engine, sources);
    final supported = <_RecSource>[];
    for (final s in catalog.musicFreeSources) {
      if (await catalog.supportsRecommendSheets(s)) {
        supported.add(_RecSource(s, null, s.name));
      }
    }
    // 推荐歌单数据由 lx_recommend_sheets 元数据兜底模块保证能力，
    // 按内部平台拆分为多个来源（与榜单页同款）
    const lxKeys = {'wy', 'kg', 'kw', 'tx'};
    for (final s in catalog.lxToplistSources) {
      final keys = s.sources.where(lxKeys.contains).toSet();
      if (keys.length <= 1) {
        final key = keys.isEmpty ? null : keys.first;
        supported.add(_RecSource(s, key, s.name));
      } else {
        for (final key in keys) {
          supported.add(_RecSource(s, key, lxPlatformDisplayName(key)));
        }
      }
    }
    if (!mounted) return;
    setState(() {
      _sources = supported;
      _checking = false;
      if (supported.isNotEmpty) {
        _pageCtrl = PageController();
        _selectedId = supported.first.id;
        for (final s in supported) {
          _chipKeys[s.id] ??= GlobalKey();
        }
      }
    });
    if (supported.isNotEmpty) {
      _loadSheets(supported.first);
    }
  }

  Future<void> _loadSheets(_RecSource source) async {
    if (_sheetsCache.containsKey(source.id) ||
        _loadingIds.contains(source.id)) {
      return;
    }
    setState(() => _loadingIds.add(source.id));
    AppLog.info('plugin',
        '[RecSheets] ${source.name} 开始加载 (lxKey=${source.lxKey ?? "-"})');
    try {
      final engine = await ref.read(pluginEngineProvider.future);
      final catalog = PluginCatalogService(engine,
          ref.read(pluginManagerProvider).sources);
      final sheets =
          await catalog.getRecommendSheets(source.plugin, lxKey: source.lxKey);
      AppLog.info('plugin', '[RecSheets] ${source.name} 返回 ${sheets.length} 条');
      if (!mounted) return;
      setState(() {
        _sheetsCache[source.id] = sheets;
        _loadingIds.remove(source.id);
      });
      if (sheets.isNotEmpty) _stagger.start();
    } catch (e, st) {
      // 任何一次加载异常都不能让转圈态永久卡死：标记失败，切 chip/点击可重试
      AppLog.warn('plugin', '[RecSheets] ${source.name} 推荐歌单加载失败: $e\n$st');
      if (!mounted) return;
      setState(() {
        _failedIds.add(source.id);
        _loadingIds.remove(source.id);
      });
    }
  }

  void _retrySheets(_RecSource source) {
    setState(() => _failedIds.remove(source.id));
    _loadSheets(source);
  }

  void _selectSource(int index) {
    final ctrl = _pageCtrl;
    if (ctrl == null || !ctrl.hasClients) return;
    ctrl.animateToPage(
      index,
      duration: const Duration(milliseconds: 300),
      curve: Curves.fastLinearToSlowEaseIn,
    );
  }

  void _onPageChanged(int index) {
    final s = _sources[index];
    if (s.id == _selectedId) return;
    setState(() => _selectedId = s.id);
    _loadSheets(s);
    final ctx = _chipKeys[s.id]?.currentContext;
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
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final statusBar = MediaQuery.paddingOf(context).top;
    final embedded = widget.embedded;
    final floating = !embedded &&
        (ref.watch(settingsProvider
                .select((s) => s.valueOrNull?.floatingSearchBar ?? false)) ==
            true);
    final wallpaperGap = ref.watch(wallpaperActiveProvider) ? 8.0 : 0.0;
    final chromeBottom = _sources.isEmpty
        ? null
        : PreferredSizeProxy(
            height: 40 + wallpaperGap,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(height: wallpaperGap),
                _buildSourceBar(),
              ],
            ),
          );
    final contentTop =
        floating ? statusBar + 8 + 48 + 10 + 40 + 6 : null;

    return Scaffold(
      backgroundColor: appScaffoldBackground(context, ref),
      body: Stack(
        children: [
          if (floating)
            Positioned.fill(child: _buildBody(scheme, contentTop: contentTop))
          else
            Padding(
              padding: EdgeInsets.only(
                  top: embedded
                      ? 0
                      : GlassTopBar.height(context, bottom: chromeBottom)),
              child: Column(
                children: [
                  if (embedded && _sources.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: _buildSourceBar(),
                    ),
                  Expanded(child: _buildBody(scheme)),
                ],
              ),
            ),
          if (floating)
            Positioned(
              top: statusBar + 8 + 48 + 10,
              left: 12,
              right: 12,
              child: _buildSourceBar(floating: true),
            ),
          if (!embedded)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: GlassTopBar(
                leading: IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => context.pop(),
                ),
                title: Text(tr('推荐歌单')),
                bottom: floating ? null : chromeBottom,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSourceBar({bool floating = false}) {
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding: EdgeInsets.symmetric(horizontal: floating ? 2 : 14),
        children: [
          for (final s in _sources)
            Padding(
              key: _chipKeys[s.id],
              padding: const EdgeInsets.only(right: 8),
              child: FloatingSourcePill(
                name: s.name,
                selected: _selectedId == s.id,
                onTap: () => _selectSource(_sources.indexOf(s)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBody(ColorScheme scheme, {double? contentTop}) {
    if (_checking) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(strokeWidth: 2),
            const SizedBox(height: 12),
            Text(
              tr('正在检测可用音源…'),
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }
    if (_sources.isEmpty) {
      return _empty(
        scheme,
        Icons.extension_outlined,
        tr('暂无支持推荐歌单的插件\n请先在「插件管理」安装音源插件'),
      );
    }
    final ctrl = _pageCtrl;
    if (ctrl == null || !ctrl.hasClients && _selectedId == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    return PageView.builder(
      controller: ctrl,
      itemCount: _sources.length,
      onPageChanged: _onPageChanged,
      itemBuilder: (context, i) =>
          _buildSourcePage(scheme, _sources[i], contentTop: contentTop),
    );
  }

  Widget _buildSourcePage(
    ColorScheme scheme,
    _RecSource source, {
    double? contentTop,
  }) {
    final sheets = _sheetsCache[source.id];
    if (sheets == null) {
      if (_failedIds.contains(source.id)) {
        return _empty(
          scheme,
          Icons.error_outline,
          tr('推荐歌单加载失败\n点击重试'),
          onTap: () => _retrySheets(source),
        );
      }
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(strokeWidth: 2),
            const SizedBox(height: 12),
            Text(
              tr('正在加载推荐歌单…'),
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }
    if (sheets.isEmpty) {
      return _empty(scheme, Icons.library_music_outlined, tr('该音源暂无推荐歌单\n试试切换其他音源'));
    }
    final isEmbedded = widget.embedded;
    // 滚动立即停掉入场动画（榜单页同款），避免滚动中段的卡片带着大延迟闪现
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.depth == 0) _stagger.stop();
        return false;
      },
      child: LayoutBuilder(
        builder: (context, cons) {
          // 竖屏固定 3 列（与榜单页同款节奏按行错峰）；
          // 横屏嵌入网格列数动态，按 maxCrossAxisExtent 92 估算
          final cols = isEmbedded
              ? (cons.maxWidth / 92).ceil().clamp(1, 8)
              : 3;
          return GridView.builder(
            padding: EdgeInsets.fromLTRB(
              14,
              contentTop ?? 8,
              14,
              MediaQuery.of(context).padding.bottom + 24,
            ),
            gridDelegate: isEmbedded
                ? const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 92,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 10,
                    childAspectRatio: 0.7,
                  )
                : const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 0.72,
                  ),
            itemCount: sheets.length,
            itemBuilder: (context, i) {
              final s = sheets[i];
              final card = InkWell(
                borderRadius: BorderRadius.circular(isEmbedded ? 10 : 12),
                onTap: () => _openSheet(s),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius:
                            BorderRadius.circular(isEmbedded ? 10 : 12),
                        child: OnlineCover(
                          url: s.coverUrl,
                          size: isEmbedded ? 92 : 200,
                          radius: isEmbedded ? 10 : 12,
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      s.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: isEmbedded ? 12 : 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (s.subtitle.isNotEmpty)
                      Text(
                        s.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 11, color: scheme.onSurfaceVariant),
                      ),
                  ],
                ),
              );
              return _stagger.wrap(i ~/ cols, PressableScale(child: card));
            },
          );
        },
      ),
    );
  }

  void _openSheet(MfSheetItem s) {
    context.push('/online-detail',
        extra: OnlineDetailArgs(
          type: OnlineDetailType.playlist,
          pluginId: s.pluginId,
          title: s.title,
          subtitle: s.subtitle,
          coverUrl: s.coverUrl,
          raw: s.raw,
        ));
  }

  Widget _empty(ColorScheme scheme, IconData icon, String message,
      {VoidCallback? onTap}) {
    final child = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 52, color: scheme.onSurfaceVariant.withValues(alpha: 0.4)),
        const SizedBox(height: 12),
        Text(
          message,
          textAlign: TextAlign.center,
          style: TextStyle(
              fontSize: 13, height: 1.6, color: scheme.onSurfaceVariant),
        ),
      ],
    );
    return Center(
      child: onTap == null
          ? child
          : PressableScale(
              child: InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(12),
                child: child,
              ),
            ),
    );
  }
}
