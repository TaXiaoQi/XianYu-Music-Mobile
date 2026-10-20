part of 'search_page.dart';

// ==================== 来源模型 ====================

enum _SourceType { local, musicfree, lx, cloud }

class _SourceItem {
  final String id;
  final String name;
  final _SourceType type;
  final PluginSource? plugin;
  final String? lxKey;

  /// 网盘来源（type == cloud）的注册 id（cloud_registry）。
  final String? cloudProviderId;

  const _SourceItem({
    required this.id,
    required this.name,
    required this.type,
    this.plugin,
    this.lxKey,
    this.cloudProviderId,
  });

  bool get isLocal => type == _SourceType.local;
}

/// 网盘来源待插入条目：sortIndex 为前方插件数（null=末尾）。
class _CloudSourceEntry {
  final int? sortIndex;
  final _SourceItem item;

  const _CloudSourceEntry({required this.sortIndex, required this.item});
}

const _validLxSources = {'kw', 'kg', 'tx', 'wy', 'mg'};
// 平台显示名与榜单页共用（lxPlatformDisplayNames），tr() 每次求值保运行时切语言
Map<String, String> get _lxSourceNames => lxPlatformDisplayNames();

// ==================== 结果模型 ====================

class _TrackEntry {
  final bool isLocal;
  final Song? localSong;
  final PluginSource? pluginSource;
  final PluginSearchResult? pluginResult;

  /// 网盘条目（cloud 来源）：预构造的可播放 QueueItem，
  /// title/artist 兼作展示字段（title=解析歌名、artist=解析歌手或盘名）。
  final QueueItem? cloudItem;

  const _TrackEntry({
    required this.isLocal,
    this.localSong,
    this.pluginSource,
    this.pluginResult,
    this.cloudItem,
  });
}

enum _CatalogKind { artist, album, playlist }

String _formatPlayCount(num n) {
  if (n >= 100000000) {
    return tr('{n}亿', {'n': (n / 100000000).toStringAsFixed(1)});
  }
  if (n >= 10000) return tr('{n}万', {'n': (n / 10000).toStringAsFixed(1)});
  return '$n';
}

class _CatalogItem {
  final String kind;
  final String title;
  final String subtitle;
  final String? coverUrl;
  final String sourceTag;
  final ArtistInfo? localArtist;
  final AlbumInfo? localAlbum;
  final ImportedPlaylist? localPlaylist;
  final PluginSource? onlinePlugin;
  final Map<String, dynamic>? onlineRaw;
  final PluginSource? directSource;
  final List<PluginSearchResult> directSongs;

  _CatalogItem({
    required this.kind,
    required this.title,
    this.subtitle = '',
    this.coverUrl,
    required this.sourceTag,
    this.localArtist,
    this.localAlbum,
    this.localPlaylist,
    this.onlinePlugin,
    this.onlineRaw,
    this.directSource,
    List<PluginSearchResult>? directSongs,
  }) : directSongs = directSongs ?? [];

  bool get isLocalEntry =>
      localArtist != null || localAlbum != null || localPlaylist != null;
  bool get isDirectPlay => directSource != null && directSongs.isNotEmpty;
}

