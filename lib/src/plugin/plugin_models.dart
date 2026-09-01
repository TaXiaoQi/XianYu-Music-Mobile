import 'dart:convert';
import '../i18n/i18n.dart';

/// 插件格式：LX（落雪）或 MusicFree。
enum PluginFormat {
  lx('lx'),
  musicfree('musicfree');

  final String value;
  const PluginFormat(this.value);

  static PluginFormat fromValue(String? v) =>
      v == 'musicfree' ? PluginFormat.musicfree : PluginFormat.lx;
}

/// 插件源信息（与桌面端 PluginSource 对齐）。
class PluginSource {
  final String id;
  final String name;
  final PluginFormat format;
  final String version;
  final String author;
  final String description;
  final String filePath;
  final int importedAt;
  bool enabled;
  final List<String> sources;
  final bool isBuiltin;
  /// 用户自定义排序权重（数值越小越靠前），对齐桌面端 sortOrder。
  final int? sortOrder;

  PluginSource({
    required this.id,
    required this.name,
    required this.format,
    this.version = '',
    this.author = '',
    this.description = '',
    this.filePath = '',
    required this.importedAt,
    this.enabled = true,
    this.sources = const [],
    this.isBuiltin = false,
    this.sortOrder,
  });

  PluginSource copyWith({
    bool? enabled,
    String? version,
    List<String>? sources,
    int? sortOrder,
    bool clearSortOrder = false,
  }) {
    return PluginSource(
      id: id,
      name: name,
      format: format,
      version: version ?? this.version,
      author: author,
      description: description,
      filePath: filePath,
      importedAt: importedAt,
      enabled: enabled ?? this.enabled,
      sources: sources ?? this.sources,
      isBuiltin: isBuiltin,
      sortOrder: clearSortOrder ? null : (sortOrder ?? this.sortOrder),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'format': format.value,
        'version': version,
        'author': author,
        'description': description,
        'filePath': filePath,
        'importedAt': importedAt,
        'enabled': enabled,
        'sources': sources,
        'isBuiltin': isBuiltin,
        'sortOrder': sortOrder,
      };

  factory PluginSource.fromJson(Map<String, dynamic> json) => PluginSource(
        id: json['id'] as String,
        name: json['name'] as String? ?? '',
        format: PluginFormat.fromValue(json['format'] as String?),
        version: json['version'] as String? ?? '',
        author: json['author'] as String? ?? '',
        description: json['description'] as String? ?? '',
        filePath: json['filePath'] as String? ?? '',
        importedAt: (json['importedAt'] as num?)?.toInt() ?? 0,
        enabled: json['enabled'] as bool? ?? true,
        sources: (json['sources'] as List?)?.cast<String>() ?? const [],
        isBuiltin: json['isBuiltin'] as bool? ?? false,
        sortOrder: (json['sortOrder'] as num?)?.toInt(),
      );
}

/// 按用户自定义 sortOrder 稳定排序（数值越小越靠前；未排序项以原数组顺序兜底）。
/// 与桌面端 sortPlugins 保持一致，供插件页/搜索页/音源榜单页复用。
List<PluginSource> sortPluginSources(List<PluginSource> sources) {
  final indexed = <(PluginSource, int)>[];
  for (var i = 0; i < sources.length; i++) {
    indexed.add((sources[i], i));
  }
  indexed.sort((x, y) {
    final cmp = (x.$1.sortOrder ?? 0).compareTo(y.$1.sortOrder ?? 0);
    if (cmp != 0) return cmp;
    return x.$2.compareTo(y.$2);
  });
  return indexed.map((e) => e.$1).toList();
}

/// 引擎日志条目（Rust 侧 EngineLog，camelCase）。
class EngineLog {
  final String level;
  final String message;
  final int callId;

  EngineLog({required this.level, required this.message, required this.callId});

  factory EngineLog.fromJson(Map<String, dynamic> json) => EngineLog(
        level: json['level'] as String? ?? 'log',
        message: json['message'] as String? ?? '',
        callId: (json['callId'] as num?)?.toInt() ?? 0,
      );
}

/// 引擎加载结果（Rust 侧 EngineLoadResult，camelCase）。
class EngineLoadResult {
  final bool ok;
  final String? error;
  final Map<String, dynamic>? metadata;
  final List<EngineLog> logs;

  EngineLoadResult({
    required this.ok,
    this.error,
    this.metadata,
    this.logs = const [],
  });

  factory EngineLoadResult.fromJson(Map<String, dynamic> json) =>
      EngineLoadResult(
        ok: json['ok'] as bool? ?? false,
        error: json['error'] as String?,
        metadata: json['metadata'] is Map<String, dynamic>
            ? (json['metadata'] as Map).cast<String, dynamic>()
            : null,
        logs: (json['logs'] as List?)
                ?.map((e) => EngineLog.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
      );

  static EngineLoadResult fromJsonString(String json) {
    try {
      return EngineLoadResult.fromJson(
          jsonDecode(json) as Map<String, dynamic>);
    } catch (_) {
      return EngineLoadResult(ok: false, error: tr('引擎返回解析失败'));
    }
  }
}

/// 引擎调用结果（Rust 侧 EngineCallResult，camelCase）。
class EngineCallResult {
  final bool ok;
  final String? error;
  final dynamic data;
  final List<EngineLog> logs;

  EngineCallResult({
    required this.ok,
    this.error,
    this.data,
    this.logs = const [],
  });

  factory EngineCallResult.fromJson(Map<String, dynamic> json) =>
      EngineCallResult(
        ok: json['ok'] as bool? ?? false,
        error: json['error'] as String?,
        data: json['data'],
        logs: (json['logs'] as List?)
                ?.map((e) => EngineLog.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
      );

  static EngineCallResult fromJsonString(String json) {
    try {
      return EngineCallResult.fromJson(
          jsonDecode(json) as Map<String, dynamic>);
    } catch (_) {
      return EngineCallResult(ok: false, error: tr('引擎返回解析失败'));
    }
  }
}

/// LX 插件声明的音源信息。
class LxSourceInfo {
  final String type;
  final String? name;
  final List<String> actions;
  final List<String> qualitys;

  LxSourceInfo({
    required this.type,
    this.name,
    this.actions = const [],
    this.qualitys = const [],
  });

  factory LxSourceInfo.fromJson(Map<String, dynamic> json) => LxSourceInfo(
        type: json['type'] as String? ?? 'music',
        name: json['name'] as String?,
        actions: (json['actions'] as List?)?.cast<String>() ?? const [],
        qualitys: (json['qualitys'] as List?)?.cast<String>() ?? const [],
      );
}

/// LX 插件初始化信息（initInfo）。
class LxInitInfo {
  final Map<String, LxSourceInfo> sources;

  LxInitInfo({this.sources = const {}});

  factory LxInitInfo.fromJson(Map<String, dynamic> json) {
    final raw = json['sources'];
    final map = <String, LxSourceInfo>{};
    if (raw is Map) {
      raw.forEach((key, value) {
        if (value is Map<String, dynamic>) {
          map[key.toString()] = LxSourceInfo.fromJson(value);
        }
      });
    }
    return LxInitInfo(sources: map);
  }
}

/// 搜索结果条目（插件搜索返回，兼容桌面端 PluginSearchResult）。
class PluginSearchResult {
  final String name;
  final String singer;
  final String albumName;
  final String? albumId;
  final String songmid;
  final String source;
  final String interval;
  final String? img;
  final String? hash;
  final String? strMediaMid;
  final dynamic songId;
  final String? albumMid;
  final String? copyrightId;
  final List<Map<String, dynamic>> types;
  final Map<String, dynamic>? lxTypes;
  /// MusicFree 插件搜索返回的原始条目（含 title/artist/id 及平台私有字段）。
  /// 播放直链解析 getMediaSource 需透传该原始对象，仅补充 platform。
  final Map<String, dynamic>? rawData;

  PluginSearchResult({
    required this.name,
    required this.singer,
    required this.albumName,
    this.albumId,
    required this.songmid,
    required this.source,
    this.interval = '',
    this.img,
    this.hash,
    this.strMediaMid,
    this.songId,
    this.albumMid,
    this.copyrightId,
    this.types = const [],
    this.lxTypes,
    this.rawData,
  });

  PluginSearchResult copyWith({String? interval, String? img}) =>
      PluginSearchResult(
        name: name,
        singer: singer,
        albumName: albumName,
        albumId: albumId,
        songmid: songmid,
        source: source,
        interval: interval ?? this.interval,
        img: img ?? this.img,
        hash: hash,
        strMediaMid: strMediaMid,
        songId: songId,
        albumMid: albumMid,
        copyrightId: copyrightId,
        types: types,
        lxTypes: lxTypes,
        rawData: rawData,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'singer': singer,
        'albumName': albumName,
        'albumId': albumId,
        'songmid': songmid,
        'source': source,
        'interval': interval,
        'img': img,
        'hash': hash,
        'strMediaMid': strMediaMid,
        'songId': songId,
        'albumMid': albumMid,
        'copyrightId': copyrightId,
        'types': types,
        '_types': lxTypes,
        'rawData': rawData,
      };

  factory PluginSearchResult.fromJson(Map<String, dynamic> json) =>
      PluginSearchResult(
        name: json['name'] as String? ?? '',
        singer: json['singer'] as String? ?? '',
        albumName: json['albumName'] as String? ?? '',
        albumId: json['albumId'] as String?,
        songmid: json['songmid'] as String? ?? '',
        source: json['source'] as String? ?? '',
        interval: json['interval'] as String? ?? '',
        img: json['img'] as String?,
        hash: json['hash'] as String?,
        strMediaMid: json['strMediaMid'] as String?,
        songId: json['songId'],
        albumMid: json['albumMid'] as String?,
        copyrightId: json['copyrightId'] as String?,
        types: (json['types'] as List?)
                ?.map((e) => (e as Map).cast<String, dynamic>())
                .toList() ??
            const [],
        lxTypes: json['_types'] is Map
            ? (json['_types'] as Map).cast<String, dynamic>()
            : null,
        rawData: json['rawData'] is Map
            ? (json['rawData'] as Map).cast<String, dynamic>()
            : null,
      );
}
