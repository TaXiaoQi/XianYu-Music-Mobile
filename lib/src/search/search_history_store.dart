import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 本地搜索历史持久化。
class SearchHistoryStore {
  static const _key = 'xianyu_search_history_v1';
  static const int maxItems = 10;

  Future<List<String>> loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_key) ?? const [];
  }

  Future<List<String>> saveAll(List<String> items) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_key, items);
    return items;
  }
}

/// 搜索历史状态（最新在前，去重，最多 [SearchHistoryStore.maxItems] 条）。
class SearchHistoryNotifier extends StateNotifier<List<String>> {
  SearchHistoryNotifier() : super(const []) {
    _init();
  }

  final SearchHistoryStore _store = SearchHistoryStore();

  Future<void> _init() async {
    state = await _store.loadAll();
  }

  Future<void> add(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;
    final filtered = state
        .where((e) => e != trimmed)
        .take(SearchHistoryStore.maxItems - 1)
        .toList();
    state = await _store.saveAll([trimmed, ...filtered]);
  }

  Future<void> remove(String query) async {
    state =
        await _store.saveAll(state.where((e) => e != query).toList());
  }

  Future<void> clear() async {
    state = await _store.saveAll(const []);
  }
}

final searchHistoryProvider =
    StateNotifierProvider<SearchHistoryNotifier, List<String>>(
  (ref) => SearchHistoryNotifier(),
);