import 'package:shared_preferences/shared_preferences.dart';

/// 列表页排序偏好持久化（我的页二级列表：本地/收藏/最近/网盘）。
///
/// 页面排序档此前只存 State，退出页面即丢（重进回落默认排序）；
/// 这里按页面 key 落盘「排序档下标 + 升降序」，进页恢复、改档即存。
/// 读侧带会话缓存，避免每次进页都等一次 prefs IO。
class PageSortPrefs {
  PageSortPrefs._();

  static final Map<String, (int, bool)> _cache = {};

  static String _idxKey(String key) => 'page_sort.$key.idx';
  static String _ascKey(String key) => 'page_sort.$key.asc';

  /// 读取页面排序偏好；无记录时返回 (defaultIdx, defaultAsc)。
  /// idx 越界由调用方按各自枚举长度 clamp（这里不知道枚举长度）。
  static Future<(int, bool)> load(
    String key, {
    int defaultIdx = 0,
    bool defaultAsc = true,
  }) async {
    final hit = _cache[key];
    if (hit != null) return hit;
    final prefs = await SharedPreferences.getInstance();
    final v = (
      prefs.getInt(_idxKey(key)) ?? defaultIdx,
      prefs.getBool(_ascKey(key)) ?? defaultAsc,
    );
    _cache[key] = v;
    return v;
  }

  static Future<void> save(String key, int idx, bool asc) async {
    _cache[key] = (idx, asc);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_idxKey(key), idx);
    await prefs.setBool(_ascKey(key), asc);
  }
}
