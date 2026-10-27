part of 'favorites_page.dart';

// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

enum _FavSort { none, title, artist, album, addedAt }

String _favSortLabel(_FavSort s) => switch (s) {
      _FavSort.none => tr('默认排序'),
      _FavSort.title => tr('按 A-Z'),
      _FavSort.artist => tr('按歌手'),
      _FavSort.album => tr('按专辑'),
      _FavSort.addedAt => tr('按添加时间'),
    };

List<FavoriteEntry> _filterSortFavorites(
    (List<FavoriteEntry>, String, int, bool) args) {
  final (entries, query, sortIdx, asc) = args;
  List<FavoriteEntry> result = entries;
  if (query.isNotEmpty) {
    result = result
        .where((e) =>
            e.title.toLowerCase().contains(query) ||
            e.artist.toLowerCase().contains(query) ||
            e.album.toLowerCase().contains(query))
        .toList();
  }
  final copy = [...result];
  // 排序键预计算：中文按拼音 A-Z
  final titleKeys = {for (final e in copy) e.path: pinyinSortKey(e.title)};
  final artistKeys = {for (final e in copy) e.path: pinyinSortKey(e.artist)};
  final albumKeys = {for (final e in copy) e.path: pinyinSortKey(e.album)};
  switch (_FavSort.values[sortIdx]) {
    case _FavSort.title:
      copy.sort((a, b) =>
          asc ? titleKeys[a.path]!.compareTo(titleKeys[b.path]!) : titleKeys[b.path]!.compareTo(titleKeys[a.path]!));
    case _FavSort.artist:
      copy.sort((a, b) {
        final c = asc
            ? artistKeys[a.path]!.compareTo(artistKeys[b.path]!)
            : artistKeys[b.path]!.compareTo(artistKeys[a.path]!);
        return c != 0
            ? c
            : (asc
                  ? titleKeys[a.path]!.compareTo(titleKeys[b.path]!)
                  : titleKeys[b.path]!.compareTo(titleKeys[a.path]!));
      });
    case _FavSort.album:
      copy.sort((a, b) {
        final c = asc
            ? albumKeys[a.path]!.compareTo(albumKeys[b.path]!)
            : albumKeys[b.path]!.compareTo(albumKeys[a.path]!);
        return c != 0
            ? c
            : (asc
                  ? titleKeys[a.path]!.compareTo(titleKeys[b.path]!)
                  : titleKeys[b.path]!.compareTo(titleKeys[a.path]!));
      });
    case _FavSort.addedAt:
      // 默认新→旧（desc）；翻转后旧→新
      copy.sort((a, b) =>
          asc ? a.addedAt.compareTo(b.addedAt) : b.addedAt.compareTo(a.addedAt));
    case _FavSort.none:
      // 默认排序反向：收藏序倒序展示
      if (!asc) {
        // 原地倒序（兼容未提供 List.reverse 的 Dart SDK）
        for (var i = 0, j = copy.length - 1; i < j; i++, j--) {
          final tmp = copy[i];
          copy[i] = copy[j];
          copy[j] = tmp;
        }
      }
  }
  return copy;
}

extension _FavoritesPageSearchSort on _FavoritesPageState {
  void _onCriteriaChanged() {
    setState(() {});
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 160), _runFilter);
  }

  void _applySort(_FavSort type, bool asc) {
    _sort = type;
    _sortAsc = asc;
    unawaited(PageSortPrefs.save('favorites', type.index, asc));
    _onCriteriaChanged();
  }

  Future<void> _runFilter() async {
    final gen = ++_req;
    final entries = ref.read(favoritesProvider).entries;
    // 面板态搜索词来自壳层全局顶栏（竖屏路由态用页内搜索框 _query），
    // 头部排序下拉与壳层搜索词统一走 filter+sort 合并管线
    final paneMode = widget.paneEmbedded ||
        ref.read(landscapeLibraryProvider) != null;
    final q = paneMode
        ? ref.read(landscapeLibraryQueryProvider).trim().toLowerCase()
        : _query;
    final out = await compute(
      _filterSortFavorites,
      (entries, q, _sort.index, _sortAsc),
    );
    if (!mounted || gen != _req) return;
    setState(() => _result = out);
  }

  void _clearSearch() {
    _searchCtrl.clear();
    setState(() => _query = '');
    _debounce?.cancel();
    _runFilter();
  }

  Widget _buildSearchField(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return SizedBox(
      height: 40,
      child: TextField(
        controller: _searchCtrl,
        onChanged: (v) {
          _query = v.trim().toLowerCase();
          _onCriteriaChanged();
        },
        textInputAction: TextInputAction.search,
        style: TextStyle(fontSize: 14.5, color: scheme.onSurface),
        decoration: InputDecoration(
          hintText: tr('搜索歌曲、歌手、专辑'),
          hintStyle:
              TextStyle(fontSize: 14.5, color: scheme.onSurfaceVariant),
          prefixIcon: Icon(Icons.search, size: 20, color: scheme.onSurfaceVariant),
          prefixIconConstraints:
              const BoxConstraints(minWidth: 40, minHeight: 40),
          suffixIcon: _query.isNotEmpty
              ? InkWell(
                  onTap: _clearSearch,
                  child: Icon(Icons.close,
                      size: 18, color: scheme.onSurfaceVariant),
                )
              : null,
          suffixIconConstraints:
              const BoxConstraints(minWidth: 40, minHeight: 40),
          isDense: true,
          filled: true,
          fillColor: isDark
              ? const Color(0x14FFFFFF)
              : const Color(0x14000000),
          contentPadding:
              const EdgeInsets.symmetric(vertical: 0, horizontal: 8),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(20),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }
}

/// 有方向语义的排序类型（默认排序 = 收藏序，降序即倒序展示）
bool _favSortDirectional(_FavSort s) => true;

/// 添加时间默认新→旧（desc），其余默认升序
bool _favSortDefaultAsc(_FavSort s) => s == _FavSort.addedAt ? false : true;

/// 排序下拉选项（锚定菜单用）
List<SortOption<_FavSort>> _favSortOptions() => [
      for (final s in _FavSort.values)
        SortOption(value: s, label: _favSortLabel(s)),
    ];
