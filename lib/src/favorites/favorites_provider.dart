import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 收藏歌曲路径集合。
///
/// 移动端后端未提供收藏增删接口，收藏列表在 Dart 侧用 SharedPreferences
/// 维护为一组文件路径，与 Rust 的 `statsGetFavoriteSongPathsView(favoritePaths:)`
/// 等视图接口对接。
class FavoritesNotifier extends StateNotifier<Set<String>> {
  FavoritesNotifier() : super(const {}) {
    _load();
  }

  static const _key = 'favoritePaths';

  Future<SharedPreferences> _prefs() => SharedPreferences.getInstance();

  Future<void> _load() async {
    final prefs = await _prefs();
    state = (prefs.getStringList(_key) ?? const []).toSet();
  }

  bool isFavorite(String path) => state.contains(path);

  /// 切换收藏状态，返回切换后的结果（true 表示已收藏）。
  Future<bool> toggle(String path) async {
    final next = state.toSet();
    final added = !next.remove(path);
    if (added) next.add(path);
    state = next;
    final prefs = await _prefs();
    await prefs.setStringList(_key, next.toList());
    return added;
  }
}

final favoritesProvider =
    StateNotifierProvider<FavoritesNotifier, Set<String>>((ref) {
  return FavoritesNotifier();
});
