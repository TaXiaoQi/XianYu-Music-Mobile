import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_provider.dart';
import '../core/settings.dart';
import '../player/player_provider.dart';
import '../plugin/plugin_provider.dart';

final shareServiceProvider = Provider<ShareService>((ref) => ShareService(ref));

class ShareService {
  ShareService(this._ref);

  final Ref _ref;

  final Map<String, String> _cache = {};
  final Map<String, Future<String>> _pending = {};

  bool hasCached(QueueItem? song) {
    if (song == null) return false;
    final url = _cache[song.path];
    return url != null && url.isNotEmpty;
  }

  String? cached(QueueItem? song) {
    if (song == null) return null;
    return _cache[song.path];
  }

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

  void reportShareAction() {
    _ref
        .read(authProvider.notifier)
        .requestAction('report_share_action', {})
        .catchError((Object _) => <String, dynamic>{});
  }

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

  void preload(QueueItem? song) {
    if (song == null) return;
    final key = song.path;
    if (_cache.containsKey(key) || _pending.containsKey(key)) return;
    create(song).catchError((Object _) => '');
  }

  Map<String, dynamic> _buildBody(QueueItem song, String cover) {
    final online = _decodeMap(song.onlineSongJson);
    final musicInfo = online?['musicInfo'];
    final infoMap = musicInfo is Map ? musicInfo.cast<String, dynamic>() : null;

    String hash = '';
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

  static bool _isRemoteHttp(String s) {
    if (!(s.startsWith('http://') || s.startsWith('https://'))) return false;
    final lower = s.toLowerCase();
    return !(lower.contains('asset.localhost') ||
        lower.contains('localhost') ||
        lower.contains('127.0.0.1'));
  }
}