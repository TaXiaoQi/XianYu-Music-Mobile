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
}

