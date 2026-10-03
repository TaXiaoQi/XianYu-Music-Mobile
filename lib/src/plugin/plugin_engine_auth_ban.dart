// 鉴权失效熔断（part 拆分自 plugin_engine.dart，实现顶层化，PluginEngine 类内保留薄别名）
part of 'plugin_engine.dart';

// Map 为可变单例：PluginEngine 类内 _authBannedUntil/_authFailStreak 别名引用同一对象。
final Map<String, DateTime> pluginAuthBannedUntil = {};
final Map<String, int> pluginAuthFailStreak = {};
const Duration _authBanTtlBase = Duration(seconds: 30);
const Duration _authBanTtlMax = Duration(minutes: 5);
const int _authBanThreshold = 5;

Duration _pluginBanTtlFor(int streak) {
  final doublings = (streak - _authBanThreshold).clamp(0, 8);
  final secs = _authBanTtlBase.inSeconds << doublings;
  return secs >= _authBanTtlMax.inSeconds ? _authBanTtlMax : Duration(seconds: secs);
}

String _pluginBanWaitLabel(DateTime until) {
  final secs = until.difference(DateTime.now()).inSeconds.clamp(1, 3600);
  if (secs < 60) return '$secs 秒';
  return '${(secs / 60).ceil()} 分钟';
}

bool _pluginIsAuthFailureMessage(String msg) =>
    RegExp(r'API密钥|API\s*key|api[_\s-]?secret|卡密|\b40[13]\b|鉴权失效已临时熔断',
            caseSensitive: false)
        .hasMatch(msg);

bool _pluginIsAuthBanned(String pluginId) {
  final until = pluginAuthBannedUntil[pluginId];
  if (until == null) return false;
  if (DateTime.now().isAfter(until)) {
    pluginAuthBannedUntil.remove(pluginId);
    pluginAuthFailStreak[pluginId] = 0;
    return false;
  }
  return true;
}

void _pluginMarkAuthFailure(String pluginId, String msg) {
  if (_pluginIsAuthBanned(pluginId)) return;
  final streak = (pluginAuthFailStreak[pluginId] ?? 0) + 1;
  pluginAuthFailStreak[pluginId] = streak;
  if (streak >= _authBanThreshold) {
    final ttl = _pluginBanTtlFor(streak);
    pluginAuthBannedUntil[pluginId] = DateTime.now().add(ttl);
    AppLog.warn('plugin',
        '[$pluginId] 鉴权连续失败 $streak 次，熔断 ${_pluginBanWaitLabel(pluginAuthBannedUntil[pluginId]!)}: $msg');
  }
}
