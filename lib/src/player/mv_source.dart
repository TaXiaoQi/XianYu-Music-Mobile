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
        // JS 桥数值可能以 double/num 形态到达，强转 int? 会炸掉整个解析
        width: (j['width'] as num?)?.toInt(),
        height: (j['height'] as num?)?.toInt(),
        bitrate: (j['bitrate'] as num?)?.toInt(),
        size: (j['size'] as num?)?.toInt(),
        codec: j['codec']?.toString(),
        mimeType: j['mimeType']?.toString(),
      );
}

/// resolveMvSource 返回的 MV 播放源（对齐 BakaMusic）。
class MvSource {
  /// 在线 mp4 URL。按 Baka 约定保留插件/宿主返回的原样直链：酷狗 CDN
  /// 的 HTTPS 证书与域名不匹配（Baka 保留 HTTP），明文流量已在
  /// network_security_config 放行，不再强制升级 https。
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

    final rawHeaders = j['headers'];
    final headers = rawHeaders is Map
        ? rawHeaders.map((k, v) => MapEntry(k.toString(), v.toString()))
        : <String, String>{};

    // Baka 契约：userAgent 可与 headers 分开返回（对齐桌面端
    // mergedPluginHeaders——headers 未带 UA 时合并进 headers）。
    final ua = j['userAgent']?.toString() ?? '';
    if (ua.isNotEmpty &&
        !headers.keys.any((k) => k.toLowerCase() == 'user-agent')) {
      headers['User-Agent'] = ua;
    }

    final qualities = (j['availableVideoQualities'] as List<dynamic>? ?? const [])
        .map((e) => MvQuality.fromJson(e as Map<String, dynamic>))
        .toList();

    final backups = (j['backupUrls'] as List<dynamic>? ?? const [])
        .whereType<String>()
        .where((u) => u.startsWith('http://') || u.startsWith('https://'))
        .take(4) // Baka 契约 backupUrls ≤ 4
        .toList();

    // Baka 契约 expiresAt 为 Unix 毫秒；旧插件可能返回秒——按量级区分。
    final expiresAtMs = (j['expiresAt'] as num?)?.toInt();
    final expiresAt = expiresAtMs == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(
            expiresAtMs >= 1000000000000 ? expiresAtMs : expiresAtMs * 1000,
          );

    return MvSource(
      url: url,
      headers: headers,
      videoQuality: (j['videoQuality'] ?? '').toString(),
      mimeType: (j['mimeType'] ?? 'video/mp4').toString(),
      width: (j['width'] as num?)?.toInt(),
      height: (j['height'] as num?)?.toInt(),
      bitrate: (j['bitrate'] as num?)?.toInt(),
      size: (j['size'] as num?)?.toInt(),
      availableVideoQualities: qualities,
      backupUrls: backups,
      expiresAt: expiresAt,
    );
  }

  bool get isExpired =>
      expiresAt != null && expiresAt!.isBefore(DateTime.now().subtract(const Duration(seconds: 30)));
}

/// 兜底：插件没返回 MV 时的错误结构（调用方检查 url 为空就显示"此歌曲无 MV"）。
const MvSource emptyMvSource = MvSource(url: '', videoQuality: '');

