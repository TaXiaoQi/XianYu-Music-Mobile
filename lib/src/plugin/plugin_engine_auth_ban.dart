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

/// 能力型报错（账号/卡密不支持某平台或音质）：与鉴权无关，不计入鉴权熔断。
/// 否则「卡密不支持该平台或音质」连打 5 次会把卡密实际可用的平台也一并
/// 熔断 30s+（2.0.6-beta7 反馈「洛雪流畅、弦予卡的要命」根因之一）。
bool _pluginIsCapabilityMessage(String msg) => RegExp(
        r'不支持该平台|不支持.{0,8}音质|音质.{0,8}不支持|无此音质|未开放平台',
        caseSensitive: false)
    .hasMatch(msg);

/// 平台级能力缺失（该平台所有档位都不可用）：卡密不支持 kw 只应禁 kw，
/// 不能牵连 tx/kg。
bool _pluginIsPlatformUnsupportedMessage(String msg) =>
    RegExp(r'不支持该平台|未开放平台', caseSensitive: false).hasMatch(msg);

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
  if (_pluginIsCapabilityMessage(msg)) return;
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

// ==================== 确定性失败负缓存 ====================
// 封 IP / 插件实例缺失等重试注定同样失败的错误：按插件记 60s 冷却，窗口内
// 请求直接短路（此前每首歌会按音质阶梯 × 兜底插件逐级重打数百次）。
// 任一成功响应即解除（插件恢复/实例重新加载完成）。
final Map<String, DateTime> pluginDeterministicBannedUntil = {};
const Duration _deterministicBanTtl = Duration(seconds: 60);

// 平台/平台+档位级能力缺失：卡密不支持 kw 只禁 kw，档位不支持只禁该档位
// 组合，60s 冷却内同组合请求短路，不再逐档位逐插件空转。
final Map<String, DateTime> pluginCapabilityBannedUntil = {};
const Duration _capabilityBanTtl = Duration(seconds: 60);

bool _pluginIsDeterministicFailureMessage(String msg) =>
    RegExp(r'block\s*ip|插件实例不存在', caseSensitive: false).hasMatch(msg);

bool _pluginIsDeterministicBanned(String pluginId) {
  final until = pluginDeterministicBannedUntil[pluginId];
  if (until == null) return false;
  if (DateTime.now().isAfter(until)) {
    pluginDeterministicBannedUntil.remove(pluginId);
    return false;
  }
  return true;
}

void _pluginMarkDeterministicFailure(String pluginId, String msg) {
  if (!_pluginIsDeterministicFailureMessage(msg)) return;
  if (_pluginIsDeterministicBanned(pluginId)) return;
  pluginDeterministicBannedUntil[pluginId] =
      DateTime.now().add(_deterministicBanTtl);
  final brief = msg.length > 40 ? '${msg.substring(0, 40)}…' : msg;
  AppLog.warn('plugin',
      '[$pluginId] 确定性失败（$brief），${_deterministicBanTtl.inSeconds} 秒内跳过该插件');
}

void _pluginClearDeterministicBan(String pluginId) {
  pluginDeterministicBannedUntil.remove(pluginId);
}

bool _pluginIsCapabilityBanned(
    String pluginId, String platform, String quality) {
  final now = DateTime.now();
  pluginCapabilityBannedUntil
      .removeWhere((_, until) => now.isAfter(until));
  if (pluginCapabilityBannedUntil.containsKey('$pluginId|$platform')) {
    return true;
  }
  if (quality.isNotEmpty &&
      pluginCapabilityBannedUntil
          .containsKey('$pluginId|$platform|$quality')) {
    return true;
  }
  return false;
}

void _pluginMarkCapabilityFailure(
    String pluginId, String platform, String quality, String msg) {
  if (platform.isEmpty) return;
  // 平台级优先判定：卡密类报错常写「不支持该平台或音质」，两者都能匹配，
  // 按平台级处理（该平台全部档位短路），档位级仅兜纯音质报错
  final key = _pluginIsPlatformUnsupportedMessage(msg)
      ? '$pluginId|$platform'
      : (quality.isNotEmpty &&
              (isUnsupportedQualityError(msg) ||
                  RegExp(r'无此音质', caseSensitive: false).hasMatch(msg)))
          ? '$pluginId|$platform|$quality'
          : '';
  if (key.isEmpty || pluginCapabilityBannedUntil.containsKey(key)) return;
  pluginCapabilityBannedUntil[key] = DateTime.now().add(_capabilityBanTtl);
  final brief = msg.length > 40 ? '${msg.substring(0, 40)}…' : msg;
  AppLog.warn('plugin',
      '[$pluginId] 能力缺失（$brief），${_capabilityBanTtl.inSeconds} 秒内跳过同平台/档位请求');
}
