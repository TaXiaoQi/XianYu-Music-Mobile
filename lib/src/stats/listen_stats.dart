import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 本地听歌时长统计（日/周/总），用于排行榜上报。
///
/// 与桌面端 statisticsApi.getListenDurations 对齐：
/// - 日榜按自然日累计，跨天自动清零
/// - 周榜按 ISO 周累计，跨周自动清零
/// - 总榜永久累计
class ListenStats {
  static const _dailyKey = 'listen_stats_daily';
  static const _weeklyKey = 'listen_stats_weekly';
  static const _totalKey = 'listen_stats_total';
  static const _dailyDateKey = 'listen_stats_daily_date';
  static const _weeklyKeyKey = 'listen_stats_weekly_key';

  int _daily = 0;
  int _weekly = 0;
  int _total = 0;
  bool _loaded = false;

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final today = _dateKey(DateTime.now());
      final dailyDate = prefs.getString(_dailyDateKey) ?? '';
      _daily = dailyDate == today ? (prefs.getInt(_dailyKey) ?? 0) : 0;

      final weekKey = _weekKey(DateTime.now());
      final storedWeek = prefs.getString(_weeklyKeyKey) ?? '';
      _weekly = storedWeek == weekKey ? (prefs.getInt(_weeklyKey) ?? 0) : 0;

      _total = prefs.getInt(_totalKey) ?? 0;
    } catch (_) {}
  }

  /// 累计听歌时长（秒）。播放器每秒调用一次。
  Future<void> addDuration(int seconds) async {
    if (seconds <= 0) return;
    await _ensureLoaded();
    _daily += seconds;
    _weekly += seconds;
    _total += seconds;
    try {
      final prefs = await SharedPreferences.getInstance();
      final now = DateTime.now();
      await prefs.setString(_dailyDateKey, _dateKey(now));
      await prefs.setInt(_dailyKey, _daily);
      await prefs.setString(_weeklyKeyKey, _weekKey(now));
      await prefs.setInt(_weeklyKey, _weekly);
      await prefs.setInt(_totalKey, _total);
    } catch (_) {}
  }

  /// 获取三个周期的听歌时长（秒）。
  Future<Map<String, int>> getDurations() async {
    await _ensureLoaded();
    return {'daily': _daily, 'weekly': _weekly, 'total': _total};
  }

  /// 清空本地统计（服务端下发重置信号时使用）。
  Future<void> reset() async {
    _daily = 0;
    _weekly = 0;
    _total = 0;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_dailyKey, 0);
      await prefs.setInt(_weeklyKey, 0);
      await prefs.setInt(_totalKey, 0);
    } catch (_) {}
  }

  String _dateKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// ISO 周键：所在周的周一日期。
  String _weekKey(DateTime d) {
    final monday = d.subtract(Duration(days: d.weekday - 1));
    return _dateKey(monday);
  }
}

final listenStatsProvider = Provider<ListenStats>((ref) => ListenStats());
