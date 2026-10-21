part of 'search_page.dart';
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

extension _SearchResultPageSources on _SearchResultPageState {
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

  _SourceItem get _selected {
    for (final s in _sources) {
      if (s.id == _selectedSourceId) return s;
    }
    return _sources.isNotEmpty
        ? _sources.first
        :   _SourceItem(
            id: 'local', name: tr('本地'), type: _SourceType.local);
  }

  Future<void> _refreshSources() async {
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
    // 网盘来源：每个已绑定且未被关闭的盘一个来源（没选目录默认全部目录，
    // 盘侧搜索失败回退全盘遍历）；同盘多账号共用一个来源。
    // 排序位 = 前方插件数（音源管理页拖拽落点），插入第一个序号 >= idx 的插件之前。
    try {
      final cloudPrefs = await PluginPreferences.getCloudSources();
      final cloudEntries = <_CloudSourceEntry>[];
      for (final p in cloudProviders) {
        if (cloudPrefs[p.id]?.enabled == false) continue;
        final accounts =
            await CloudCredentialsStore.instance.accountsFor(p.id);
        if (accounts.isEmpty) continue;
        cloudEntries.add(_CloudSourceEntry(
          sortIndex: cloudPrefs[p.id]?.sortIndex,
          item: _SourceItem(
              id: 'cloud:${p.id}',
              name: p.displayName,
              type: _SourceType.cloud,
              cloudProviderId: p.id),
        ));
      }
      if (cloudEntries.isNotEmpty) {
        cloudEntries.sort((a, b) =>
            (a.sortIndex ?? 1 << 30) - (b.sortIndex ?? 1 << 30));
        // 每个启用插件贡献的来源条数（LX 多源连续展开），得到插件序号 → 条数边界
        final perPluginCounts = <int>[];
        var ptr = 0;
        for (final p in enabled) {
          var c = 0;
          while (ptr < items.length && items[ptr].plugin?.id == p.id) {
            c++;
            ptr++;
          }
          perPluginCounts.add(c);
        }
        final merged = <_SourceItem>[];
        var itemPtr = 0;
        var cloudPtr = 0;
        for (var pi = 0; pi < perPluginCounts.length; pi++) {
          while (cloudPtr < cloudEntries.length &&
              cloudEntries[cloudPtr].sortIndex != null &&
              cloudEntries[cloudPtr].sortIndex! <= pi) {
            merged.add(cloudEntries[cloudPtr++].item);
          }
          for (var j = 0; j < perPluginCounts[pi]; j++) {
            merged.add(items[itemPtr++]);
          }
        }
        merged.addAll(items.sublist(itemPtr));
        while (cloudPtr < cloudEntries.length) {
          merged.add(cloudEntries[cloudPtr++].item);
        }
        items
          ..clear()
          ..addAll(merged);
      }
    } catch (e) {
      AppLog.warn('search', '网盘搜索来源加载失败: $e');
    }
    // 本地来源兜底：仅在没有插件/网盘等网页来源时保留（有插件时在线歌随时
    // 可播，本地入口只剩「本地音乐」页，对齐桌面端隐藏「本地」tab）
    final result = items.isNotEmpty
        ? items
        : <_SourceItem>[
            _SourceItem(id: 'local', name: tr('本地'), type: _SourceType.local),
          ];
    if (!mounted) return;
    final sessionSource = ref.read(searchSessionProvider).sourceId;
    final initial = sessionSource.isNotEmpty ? sessionSource : result.first.id;

    if (result.length > 1) {
      // PageView 需要知道初始页，否则会话恢复时选中态在第 N 页而视图停在
      // 第 0 页——点第 0 页气泡 animateToPage 同页不触发 onPageChanged，
      // 选中态永远卡在 N（表现为「点气泡无法切换列表」）。
      _pageCtrl ??= PageController(
        initialPage: result.indexWhere((s) => s.id == initial) < 0
            ? 0
            : result.indexWhere((s) => s.id == initial),
      );
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
    if (ctrl != null && ctrl.hasClients) {
      // 乐观同步选中态：animateToPage 落在当前页时 onPageChanged 不会回调
      // （如 _refreshSources 重跑后 controller 停在旧页），不能依赖回调。
      final changed = id != _selectedSourceId;
      _selectedSourceId = id;
      ref.read(searchSessionProvider.notifier).setSource(id);
      if (changed) setState(() {});
      ctrl.animateToPage(
        newIdx,
        duration: const Duration(milliseconds: 300),
        curve: Curves.fastLinearToSlowEaseIn,
      );
      return;
    }
    // PageView 未挂载（controller 无 client）时不能静默 return，否则点击
    // 气泡毫无反应；直接同步选中态，视图挂载后按 initialPage 对齐。
    _selectedSourceId = id;
    ref.read(searchSessionProvider.notifier).setSource(id);
    setState(() {});
    _ensureVisibleSource(id);
  }

  void _ensureVisibleSource(String id) {
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
}

