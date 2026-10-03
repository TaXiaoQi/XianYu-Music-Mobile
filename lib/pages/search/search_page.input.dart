part of 'search_page.dart';
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

extension _SearchPageInput on _SearchPageState {
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
    } catch (e) { AppLog.warn('search', '搜索建议查询失败: $e'); }

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
}

