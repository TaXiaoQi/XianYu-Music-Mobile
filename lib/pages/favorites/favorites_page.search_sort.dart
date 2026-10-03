part of 'favorites_page.dart';

// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

enum _FavSort { none, title, artist, album, addedAt }

String _favSortLabel(_FavSort s) => switch (s) {
      _FavSort.none => tr('默认排序'),
      _FavSort.title => tr('按标题'),
      _FavSort.artist => tr('按歌手'),
      _FavSort.album => tr('按专辑'),
      _FavSort.addedAt => tr('按添加时间'),
    };

List<FavoriteEntry> _filterSortFavorites(
    (List<FavoriteEntry>, String, int) args) {
  final (entries, query, sortIdx) = args;
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
  switch (_FavSort.values[sortIdx]) {
    case _FavSort.title:
      copy.sort((a, b) => a.title.compareTo(b.title));
    case _FavSort.artist:
      copy.sort((a, b) {
        final c = a.artist.compareTo(b.artist);
        return c != 0 ? c : a.title.compareTo(b.title);
      });
    case _FavSort.album:
      copy.sort((a, b) {
        final c = a.album.compareTo(b.album);
        return c != 0 ? c : a.title.compareTo(b.title);
      });
    case _FavSort.addedAt:
      copy.sort((a, b) => b.addedAt.compareTo(a.addedAt));
    case _FavSort.none:
      break;
  }
  return copy;
}

class _SortItem extends StatelessWidget {
  const _SortItem({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  color: selected ? scheme.primary : scheme.onSurface,
                ),
              ),
            ),
            if (selected)
              Icon(Icons.check, size: 18, color: scheme.primary),
          ],
        ),
      ),
    );
  }
}

extension _FavoritesPageSearchSort on _FavoritesPageState {
  void _onCriteriaChanged() {
    setState(() {});
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 160), _runFilter);
  }

  Future<void> _runFilter() async {
    final gen = ++_req;
    final entries = ref.read(favoritesProvider).entries;
    final out = await compute(
      _filterSortFavorites,
      (entries, _query, _sort.index),
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

  Future<void> _openSortMenu(BuildContext context) async {
    final v = await showSheetDialog<_FavSort>(
      context,
      (ctx) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
              child: Text(
                tr('排序方式'),
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            for (final s in _FavSort.values)
              _SortItem(
                label: _favSortLabel(s),
                selected: s == _sort,
                onTap: () => Navigator.pop(ctx, s),
              ),
            const SizedBox(height: 4),
          ],
        ),
      ),
      maxWidth: 240,
    );
    if (v != null) {
      _sort = v;
      _onCriteriaChanged();
    }
  }
}
