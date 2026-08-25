// 歌曲分享服务（移动端）。
//
// - 调用服务端 `create_share` 生成分享链接（落地页 /s/{shareId} 不做网页播放，仅拉起客户端）。
// - 播放时预加载分享链接：同一首歌只生成一次并缓存，避免用户点分享时才等网络。
// - 签名请求在 Rust 侧完成，这里通过 requestAction 转发给服务端。
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_provider.dart';
import '../player/player_provider.dart';

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

    final future = _ref
        .read(authProvider.notifier)
        .requestAction('create_share', _buildBody(song), fetchTimeoutMs: 15000)
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
  Map<String, dynamic> _buildBody(QueueItem song) {
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

    String cover = song.coverUrl ?? online?['picture']?.toString() ?? '';
    if (cover.isNotEmpty && !_isHttp(cover)) cover = '';

    return <String, dynamic>{
      'song_name': song.title,
      'singer': song.artist,
      'cover_url': cover,
      'song_id': song.path,
      'hash': hash,
      'duration_ms': song.durationMs,
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

  static bool _isHttp(String s) => s.startsWith('http://') || s.startsWith('https://');
}