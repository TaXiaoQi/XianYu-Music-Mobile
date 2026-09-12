/// 通用 MV 模型层，对齐 BakaMusic getMvSource 返回结构。
/// 插件层（JS 注入）返回 JSON → 解析为 Dart 对象 → video_player.networkUrl 播放。
library;

/// 可用的某个 MV 画质档（探测返回 / availableVideoQualities 元素）。
class MvQuality {
  final String key;
  final String label;
  final int? width;
  final int? height;
  final int? bitrate;
  final int? size; // 字节
  final String? codec;
  final String? mimeType;

  const MvQuality({
    required this.key,
    required this.label,
    this.width,
    this.height,
    this.bitrate,
    this.size,
    this.codec,
    this.mimeType,
  });

  factory MvQuality.fromJson(Map<String, dynamic> j) => MvQuality(
        key: (j['key'] ?? j['quality'] ?? '').toString(),
        label: (j['label'] ?? j['quality'] ?? '').toString(),
        width: j['width'] as int?,
        height: j['height'] as int?,
        bitrate: j['bitrate'] as int?,
        size: j['size'] as int?,
        codec: j['codec']?.toString(),
        mimeType: j['mimeType']?.toString(),
      );
}

/// resolveMvSource 返回的 MV 播放源（对齐 BakaMusic）。
class MvSource {
  /// 在线 mp4 URL（HTTPS 优先；HTTP 暂不支持，跳过酷狗/酷我）。
  final String url;

  /// 请求 URL 时要带的 HTTP headers（Referer / User-Agent 很重要）。
  final Map<String, String> headers;

  /// 实际返回的画质（可能比请求的降级）。
  final String videoQuality;

  final String mimeType; // video/mp4
  final int? width;
  final int? height;
  final int? bitrate;

  /// 字节数；插件可能不给。
  final int? size;

  /// 该歌曲可用的全部画质档（用于弹窗 / UI 展示）。
  final List<MvQuality> availableVideoQualities;

  /// 备用 CDN 节点列表（全部走 HTTPS 才加入）。
  final List<String> backupUrls;

  /// URL 过期时间戳（插件返回的秒级时间 + 现在的秒数）。
  final DateTime? expiresAt;

  const MvSource({
    required this.url,
    this.headers = const {},
    required this.videoQuality,
    this.mimeType = 'video/mp4',
    this.width,
    this.height,
    this.bitrate,
    this.size,
    this.availableVideoQualities = const [],
    this.backupUrls = const [],
    this.expiresAt,
  });

  factory MvSource.fromJson(Map<String, dynamic> j) {
    final url = (j['url'] ?? '') as String;
    // 强制 HTTPS；HTTP URL（酷狗/酷我）由调用方决定是否跳过。
    final normalized = url.startsWith('http://') ? 'https://${url.substring(7)}' : url;

    final rawHeaders = j['headers'];
    final headers = rawHeaders is Map
        ? rawHeaders.map((k, v) => MapEntry(k.toString(), v.toString()))
        : <String, String>{};

    final qualities = (j['availableVideoQualities'] as List<dynamic>? ?? const [])
        .map((e) => MvQuality.fromJson(e as Map<String, dynamic>))
        .toList();

    final backups = (j['backupUrls'] as List<dynamic>? ?? const [])
        .whereType<String>()
        .where((u) => u.startsWith('https://'))
        .toList();

    return MvSource(
      url: normalized,
      headers: headers,
      videoQuality: (j['videoQuality'] ?? '').toString(),
      mimeType: (j['mimeType'] ?? 'video/mp4').toString(),
      width: j['width'] as int?,
      height: j['height'] as int?,
      bitrate: j['bitrate'] as int?,
      size: j['size'] as int?,
      availableVideoQualities: qualities,
      backupUrls: backups,
      expiresAt: (j['expiresAt'] as int?) != null
          ? DateTime.fromMillisecondsSinceEpoch((j['expiresAt'] as int) * 1000)
          : null,
    );
  }

  bool get isExpired =>
      expiresAt != null && expiresAt!.isBefore(DateTime.now().subtract(const Duration(seconds: 30)));
}

/// 兜底：插件没返回 MV 时的错误结构（调用方检查 url 为空就显示"此歌曲无 MV"）。
const MvSource emptyMvSource = MvSource(url: '', videoQuality: '');

/// 从插件引擎调用 `getMvSource`，返回 Dart 侧 [MvSource]。
///
/// 插件实现由 JS 注入（对齐 Zencok/baka-plugins 的 `getMvSource`）。
/// 如果插件没实现 MV 能力或解析失败，返回 [emptyMvSource]（url 为空）。
///
/// [song] 是在线歌曲对象，需要包含至少 mv / mvVid / id 这些字段（具体 key 由插件决定）。
/// [quality] 是请求的画质档位，如 '1080p' / '720p' / '480p'；为 null 时插件自己选默认。
Future<MvSource> resolveMvSource({
  required Map<String, dynamic> song,
  String? quality,
  required Future<Map<String, dynamic>?> Function({
    required String fn,
    required Map<String, dynamic> args,
  }) pluginCall,
}) async {
  // 歌曲没有 MV id → 直接返回空
  final hasMv = song['mv'] != null ||
      song['mvVid'] != null ||
      song['mvId'] != null ||
      song['vid'] != null;
  if (!hasMv) return emptyMvSource;

  final args = <String, dynamic>{
    'song': song,
    if (quality != null && quality.isNotEmpty) 'quality': quality,
  };

  final result = await pluginCall(fn: 'getMvSource', args: args);
  if (result == null || result.isEmpty) return emptyMvSource;
  final url = result['url'];
  if (url == null || url.toString().isEmpty) return emptyMvSource;

  // HTTP 源 → 跳过（酷狗/酷我）
  if (url.toString().startsWith('http://')) return emptyMvSource;

  try {
    return MvSource.fromJson(result);
  } catch (_) {
    return emptyMvSource;
  }
}

/// 根据可用画质档 + 回退行为选出实际可用的一档（对齐 BakaMusic pickQqMvStream）。
String pickMvQuality({
  required List<String> available,
  required String requested,
  String fallbackBehavior = 'lower',
}) {
  if (available.isEmpty) return requested;
  if (available.contains(requested)) return requested;

  int parseHeight(String q) {
    final m = RegExp(r'(\d+)p', caseSensitive: false).firstMatch(q);
    if (m != null) return int.parse(m.group(1)!);
    if (q == 'uhd' || q == '4k') return 2160;
    return 0;
  }

  final target = parseHeight(requested);
  final sorted = [...available]
    ..sort((a, b) => parseHeight(a).compareTo(parseHeight(b)));

  if (fallbackBehavior == 'higher') {
    for (final q in sorted) {
      if (parseHeight(q) >= target) return q;
    }
    return sorted.last;
  }
  // lower（默认）
  String? best;
  for (final q in sorted) {
    if (parseHeight(q) <= target) best = q;
  }
  return best ?? sorted.first;
}
