part of 'plugin_catalog.dart';

class MfSheetItem {
  final String id;
  final String title;
  final String artist;
  final String? coverUrl;
  final int? playCount;
  final int? trackCount;
  final String platform;
  final String pluginId;
  final bool isTopList;
  final bool isAlbum;
  final Map<String, dynamic> raw;

  const MfSheetItem({
    required this.id,
    required this.title,
    this.artist = '',
    this.coverUrl,
    this.playCount,
    this.trackCount,
    this.platform = '',
    required this.pluginId,
    this.isTopList = false,
    this.isAlbum = false,
    required this.raw,
  });

  String get subtitle {
    final parts = <String>[
      if (artist.isNotEmpty) artist,
      if (trackCount != null && trackCount! > 0) tr('{n} 首', {'n': trackCount!}),
      if (playCount != null && playCount! > 0) _formatCount(playCount!),
    ];
    return parts.join(' · ');
  }

  static String _formatCount(int n) {
    if (n >= 100000000) return tr('{n}亿', {'n': (n / 100000000).toStringAsFixed(1)});
    if (n >= 10000) return tr('{n}万', {'n': (n / 10000).toStringAsFixed(1)});
    return '$n';
  }
}

class MfArtistItem {
  final String id;
  final String name;
  final String? avatarUrl;
  final String platform;
  final String pluginId;
  final Map<String, dynamic> raw;

  const MfArtistItem({
    required this.id,
    required this.name,
    this.avatarUrl,
    this.platform = '',
    required this.pluginId,
    required this.raw,
  });
}

class MfAlbumItem {
  final String id;
  final String name;
  final String artist;
  final String? coverUrl;
  final String platform;
  final String pluginId;
  final Map<String, dynamic> raw;

  const MfAlbumItem({
    required this.id,
    required this.name,
    this.artist = '',
    this.coverUrl,
    this.platform = '',
    required this.pluginId,
    required this.raw,
  });
}
