// 引擎异常类型与音质降级解析（part 拆分自 plugin_engine.dart，实现顶层化，PluginEngine 类内保留薄别名）
part of 'plugin_engine.dart';

class PluginEngineException implements Exception {
  final String message;
  PluginEngineException(this.message);

  @override
  String toString() => message;
}

class LxSongLevelError extends PluginEngineException {
  LxSongLevelError(super.message);
}

bool isSongLevelError(String message) {
  const patterns = [
    r'歌曲不存在',
    r'歌曲已下架',
    r'已?下架',
    r'版权.{0,4}(限制|保护|原因)',
    r'需要?登录',
    r'地区限制',
    r'需要?\s*(VIP|会员|付费)',
    r'VIP歌曲',
    r'会员歌曲',
    r'付费歌曲',
    r'无版权',
    r'暂无版权',
  ];
  for (final pattern in patterns) {
    if (RegExp(pattern, caseSensitive: false).hasMatch(message)) return true;
  }
  return false;
}

bool isUnsupportedQualityError(String message) {
  return RegExp(
    r'不支持.*音质|音质.*不支持|quality.*not\s+support|not\s+support.*quality',
    caseSensitive: false,
  ).hasMatch(message);
}

/// 从「不支持的音质: 192k」这类报错里解析出插件自报**支持的档位**。
///
/// 部分音源（HYW、QQ 等）拒绝某个档位时会把可用的档位一并列出，例如：
/// `不支持的音质: 192k，支持的音质: 128k, 320k, flac, flac24bit, hires, ...`
/// 拿到这份清单就能直接跳到可用档位，不必再按梯形逐档发起网络往返
/// （日志中同一首歌被 192k 连续拒绝数次即由此而来）。
List<String> parseSupportedQualities(String message) {
  // 必须排除「不支持的音质: 192k」这半句——否则被拒绝的档位也会被当成
  // 可用档位（曾实测把 192k 解析进清单）。(?<!不) 只匹配肯定表述。
  final m = RegExp(
    r'(?<!不)支持(?:的)?音质[:：]?\s*([^\n]*)',
    caseSensitive: false,
  ).firstMatch(message);
  if (m == null) return const [];
  final raw = m.group(1) ?? '';
  final found = <String>[];
  final seen = <String>{};
  for (final token in raw.split(RegExp(r'[,，、/\s]+'))) {
    final q = token.trim().toLowerCase();
    if (q.isEmpty) continue;
    if (!PluginEngine.qualityLadder.contains(q)) continue;
    if (seen.add(q)) found.add(q);
  }
  return found;
}

/// 按用户偏好从插件自报的可用档位里挑一个：优先不低于偏好（升档），
/// 没有更高的则退回其中最高档（降档）。保持用户偏好语义不变，
/// 只是把「该音源实际能给的档位」映射出来。
String? pickSupportedQuality(
  String preferred,
  String fallback,
  List<String> supported,
) {
  if (supported.isEmpty) return null;
  final byRank = supported.toSet().toList()
    ..sort((a, b) =>
        PluginEngine.qualityLadder.indexOf(a) -
        PluginEngine.qualityLadder.indexOf(b));
  final prefRank = PluginEngine.qualityLadder.indexOf(preferred);
  if (prefRank < 0) return byRank.last;
  if (fallback == 'higher') {
    for (final q in byRank) {
      if (PluginEngine.qualityLadder.indexOf(q) > prefRank) return q;
    }
  } else {
    for (final q in byRank.reversed) {
      if (PluginEngine.qualityLadder.indexOf(q) < prefRank) return q;
    }
  }
  // 偏好方向没有可用档位（如偏好已是最低档却仍被拒）：退到最高可用档，
  // 保证能出声优于严格贴合偏好方向
  return byRank.last;
}
