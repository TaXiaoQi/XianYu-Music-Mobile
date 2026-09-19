library;

class MvQuality {
  final String key;
  final String label;
  final int? width;
  final int? height;
  final int? bitrate;
  final int? size;
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
        width: (j['width'] as num?)?.toInt(),
        height: (j['height'] as num?)?.toInt(),
        bitrate: (j['bitrate'] as num?)?.toInt(),
        size: (j['size'] as num?)?.toInt(),
        codec: j['codec']?.toString(),
        mimeType: j['mimeType']?.toString(),
      );
}

class MvSource {
  final String url;

  final Map<String, String> headers;

  final String videoQuality;

  final String mimeType;
  final int? width;
  final int? height;
  final int? bitrate;

  final int? size;

  final List<MvQuality> availableVideoQualities;

  final List<String> backupUrls;

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
        .take(4)
        .toList();

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

const MvSource emptyMvSource = MvSource(url: '', videoQuality: '');
