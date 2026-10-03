part of 'search_page.dart';

// ==================== 在线搜索会话 ====================

class SearchSession {
  final String query;
  final String sourceId;
  const SearchSession({this.query = '', this.sourceId = ''});
}

final searchSessionProvider =
    NotifierProvider<SearchSessionNotifier, SearchSession>(
        SearchSessionNotifier.new);

class SearchSessionNotifier extends Notifier<SearchSession> {
  @override
  SearchSession build() => const SearchSession();

  void startSearch(String query, String sourceId) =>
      state = SearchSession(query: query, sourceId: sourceId);

  void setSource(String id) =>
      state = SearchSession(query: state.query, sourceId: id);
}

// ==================== 横屏搜索容器 ====================

final landscapeSearchOpenProvider = StateProvider<bool>((ref) => false);

final landscapeSearchResultsProvider = StateProvider<bool>((ref) => false);

final landscapeSearchCtrlProvider = Provider<TextEditingController>((ref) {
  final ctrl = TextEditingController();
  ref.onDispose(ctrl.dispose);
  return ctrl;
});

final landscapeSearchFocusProvider = Provider<FocusNode>((ref) {
  final node = FocusNode();
  ref.onDispose(node.dispose);
  return node;
});

void closeLandscapeSearch(WidgetRef ref) {
  ref.read(landscapeSearchOpenProvider.notifier).state = false;
  ref.read(landscapeSearchResultsProvider.notifier).state = false;
}

void submitLandscapeSearch(WidgetRef ref, String raw) {
  final q = raw.trim();
  if (q.isEmpty) return;
  FocusManager.instance.primaryFocus?.unfocus();
  ref.read(landscapeSearchCtrlProvider).text = q;
  ref.read(searchHistoryProvider.notifier).add(q);
  final sourceId = ref.read(searchSessionProvider).sourceId;
  ref.read(searchSessionProvider.notifier).startSearch(q, sourceId);
  ref.read(landscapeSearchResultsProvider.notifier).state = true;
}

