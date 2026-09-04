// 歌曲分享服务（移动端）。
//
// - 调用服务端 `create_share` 生成分享链接（落地页 /s/{shareId} 不做网页播放，仅拉起客户端）。
// - 播放时预加载分享链接：同一首歌只生成一次并缓存，避免用户点分享时才等网络。
// - 签名请求在 Rust 侧完成，这里通过 requestAction 转发给服务端。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_provider.dart';
import '../core/settings.dart';
import '../player/player_provider.dart';
import '../plugin/plugin_provider.dart';

/// 面向 UI 的分享服务实例（预加载 + 取缓存 + 生成分享链接）。
final shareServiceProvider = Provider<ShareService>((ref) => ShareService(ref));

class ShareService {
  ShareService(this._ref);

  final Ref _ref;

  /// path -> 已生成的分享链接
  final Map<String, String> _cache = {};
  /// path -> 正在生成中的 future（避免并发重复请求）
  final Map<String, Future<String>> _pending = {};

  /// 当前缓存中是否已有该歌曲的分享链接。
  bool hasCached(QueueItem? song) {
    if (song == null) return false;
    final url = _cache[song.path];
    return url != null && url.isNotEmpty;
  }

  /// 取已生成好的分享链接；没有则返回 null。
  String? cached(QueueItem? song) {
    if (song == null) return null;
    return _cache[song.path];
  }

  /// 获取（必要时创建）指定歌曲的分享链接；已缓存或已在生成中则复用。
  Future<String> create(QueueItem song) async {
    final key = song.path;
    final cachedUrl = _cache[key];
    if (cachedUrl != null && cachedUrl.isNotEmpty) return cachedUrl;
    final pending = _pending[key];
    if (pending != null) return pending;

    final future = resolveCover(song)
        .then((cover) => _ref
            .read(authProvider.notifier)
            .requestAction('create_share', _buildBody(song, cover),
                fetchTimeoutMs: 15000))
        .then((data) {
      final url = (data['share_url'] ?? '').toString();
      _cache[key] = url;
      _pending.remove(key);
      return url;
    }).catchError((Object e) {
      _pending.remove(key);
      throw e;
    });

    _pending[key] = future;
    return future;
  }

  /// 上报一次真实「点分享」动作（fire-and-forget，失败静默）：
  /// 仅在用户真正点击分享时调用，切歌预加载不触发，供仪表台分享统计去虚高。
  void reportShareAction() {
    _ref
        .read(authProvider.notifier)
        .requestAction('report_share_action', {})
        .catchError((Object _) => <String, dynamic>{});
  }

  /// 解析分享封面 URL：在线封面（http(s)）直接用；
  /// 本地封面读取本地文件上传到服务端，返回可被落地页访问的 HTTPS URL。
  /// 失败静默返回空串（分享仍可进行，仅无封面）。
  /// 供分享链接生成与 QQ 分享共用（QQ 分享只需 http(s) 封面缩略图）。
  Future<String> resolveCover(QueueItem song) async {
    final online = _decodeMap(song.onlineSongJson);
    final onlineCover = online?['picture']?.toString() ?? '';
    final coverUrl = song.coverUrl ?? '';
    if (coverUrl.isNotEmpty && _isRemoteHttp(coverUrl)) return coverUrl;
    if (onlineCover.isNotEmpty && _isRemoteHttp(onlineCover)) return onlineCover;
    try {
      final path = song.coverPath;
      if (path == null || path.isEmpty || path.startsWith('content://')) {
        return '';
      }
      final file = File(_stripFileScheme(path));
      if (!await file.exists()) return '';
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty || bytes.length > 5 * 1024 * 1024) return '';
      final dataUrl = 'data:${_mimeFromPath(path)};base64,${base64Encode(bytes)}';
      final data = await _ref
          .read(authProvider.notifier)
          .requestAction('upload_cover', {'image_data': dataUrl},
              fetchTimeoutMs: 20000);
      return (data['cover_url'] ?? '').toString();
    } catch (_) {
      return '';
    }
  }

  static String _stripFileScheme(String path) {
    if (path.startsWith('file://')) return path.substring('file://'.length);
    return path;
  }

  static String _mimeFromPath(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    return 'image/jpeg';
  }

  /// 预加载当前歌曲分享链接（fire-and-forget，失败静默，勿阻塞播放）。
  void preload(QueueItem? song) {
    if (song == null) return;
    final key = song.path;
    if (_cache.containsKey(key) || _pending.containsKey(key)) return;
    create(song).catchError((Object _) => '');
  }

  /// 构造 create_share 请求体（统一契约：与桌面端 buildShareBody 同构）。
  ///
  /// hash 是卡片拉起客户端的核心定位键：优先 hash，其次 songmid/mid，
  /// 保证两端同一首歌生成一致的深链。
  /// song_id 为本地主键优先、否则来源 path 的稳定标识。
  /// cover 为已解析的封面 URL（在线 http(s) 或本地上传后的 HTTPS URL）。
  Map<String, dynamic> _buildBody(QueueItem song, String cover) {
    final online = _decodeMap(song.onlineSongJson);
    final musicInfo = online?['musicInfo'];
    final infoMap = musicInfo is Map ? musicInfo.cast<String, dynamic>() : null;

    String hash = '';
    // 优先 hash，其次 songmid/mid（对齐桌面端 getSongHash）
    final hashChain = <Object? Function()>[
      () => online?['hash'] ?? infoMap?['hash'],
      () => online?['songmid'] ?? infoMap?['songmid'],
      () => online?['mid'] ?? infoMap?['mid'],
    ];
    for (final sup in hashChain) {
      final v = sup();
      if (v != null) {
        hash = v.toString();
        break;
      }
    }

    // 来源信息：按播放协议提取——lx://<source>/<songmid> → 音源 key
    // （kw/wy/kg/tx/mg），plugin://<pluginId>/<songmid> → 插件声明的平台 key，
    // 本地歌曲标记为 local（与桌面端 getSongSource 同构）。
    // 服务端透传进深链，客户端据此显示来源并选择播放路径。
    // 注意：插件 path 首段是 sha256（与安装实例绑定，跨端必不同），深链必须
    // 携带语义化平台 key，接收端才能按平台跨设备匹配插件并正确展示来源。
    String source = 'local';
    if (song.isOnline) {
      if (song.path.startsWith('lx://')) {
        source = song.path.substring('lx://'.length).split('/').first;
      } else if (song.path.startsWith('plugin://')) {
        final pid = song.path.substring('plugin://'.length).split('/').first;
        var platform = '';
        for (final p in _ref.read(pluginManagerProvider).sources) {
          if (p.id == pid) {
            if (p.sources.isNotEmpty) platform = p.sources.first;
            if (platform.isEmpty) platform = p.name;
            break;
          }
        }
        source = platform.isNotEmpty ? platform : pid;
      }
      if (source.isEmpty) {
        final onlineSource =
            online?['source']?.toString() ?? infoMap?['source']?.toString();
        source = (song.source?.isNotEmpty ?? false)
            ? song.source!
            : (onlineSource?.isNotEmpty ?? false)
                ? onlineSource!
                : 'local';
      }
    }

    // 分享链接有效时长（分钟）：读取客户端设置，钳制到 5~24*60，缺省 2 小时。
    final settings = _ref.read(settingsProvider).valueOrNull;
    final rawMinutes = settings?.shareLinkValidityMinutes ?? 120;
    final expireMinutes = rawMinutes.clamp(5, 24 * 60);

    return <String, dynamic>{
      'song_name': song.title,
      'singer': song.artist,
      'cover_url': cover,
      'song_id': song.path,
      'hash': hash,
      'duration_ms': song.durationMs,
      'source': source,
      'expire_minutes': expireMinutes,
    };
  }

  static Map<String, dynamic>? _decodeMap(String? json) {
    if (json == null || json.isEmpty) return null;
    try {
      final v = jsonDecode(json);
      return v is Map ? v.cast<String, dynamic>() : null;
    } catch (_) {
      return null;
    }
  }

  /// 是否可被外部访问的远程封面：http(s) 且排除本地/回环/asset 地址，
  /// 避免本地封面被误判为在线封面而跳过上传。
  static bool _isRemoteHttp(String s) {
    if (!(s.startsWith('http://') || s.startsWith('https://'))) return false;
    final lower = s.toLowerCase();
    return !(lower.contains('asset.localhost') ||
        lower.contains('localhost') ||
        lower.contains('127.0.0.1'));
  }
}