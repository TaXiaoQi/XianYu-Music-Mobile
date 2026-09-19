import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../core/db_path.dart';
import '../core/settings.dart';
import '../favorites/favorites_provider.dart';
import '../library/saf_channel.dart';
import '../lyrics/lyric_model.dart';
import '../lyrics/lyrics_repository.dart';
import '../online/cover_proxy.dart';
import '../rust/api.dart';
import 'player_provider.dart';

class PlayerWidgetController {
  PlayerWidgetController(this._container);

  final ProviderContainer _container;

  static const MethodChannel _channel = MethodChannel('xianyu/player_widget');

  ProviderSubscription<PlaybackState>? _playerSub;
  Timer? _heartbeat;
  bool _disposed = false;
  String? _lastCover;
  String? _lastSignature;
  String? _prevPath;
  List<LyricLine> _lyrics = const [];
  int _lyricToken = 0;
  int _coverDir = 1;
  bool _coverLoading = false;
  int _coverToken = 0;
  int _lastCoverTryAt = 0;

  void init() {
    _channel.setMethodCallHandler(_onControl);
    _playerSub = _container.listen(playerProvider, (_, next) => _onPlayback(next));
    _container.listen(favoritesProvider, (_, _) {
      if (_disposed) return;
      final item = _container.read(playerProvider).current;
      if (item != null) _applyState(_container.read(playerProvider));
    });
    _container.listen(settingsProvider, (_, _) {
      if (_disposed) return;
      final s = _container.read(playerProvider);
      if (s.current != null) _applyState(s);
    });
    _heartbeat = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_disposed) return;
      final s = _container.read(playerProvider);
      final item = s.current;
      if (item == null) return;
      if (_coverLoading) return;
      if ((_lastCover ?? '').isEmpty) {
        if (DateTime.now().millisecondsSinceEpoch - _lastCoverTryAt >= 10000) {
          _loadCover(item);
        }
        return;
      }
      if (s.isPlaying) _pushState(s, _lastCover);
    });
  }

  void dispose() {
    _disposed = true;
    _heartbeat?.cancel();
    _playerSub?.close();
    _channel.setMethodCallHandler(null);
  }

  // ---- 小组件按钮控制 ----

  Future<dynamic> _onControl(MethodCall call) async {
    final notifier = _container.read(playerProvider.notifier);
    switch (call.method) {
      case 'toggle':
        notifier.toggle();
      case 'previous':
        notifier.previous();
      case 'next':
        notifier.next();
      case 'cyclePlayMode':
        notifier.cyclePlayMode();
      case 'toggleFavorite':
        notifier.toggleFavoriteFromSystem();
      case 'toggleFloatingLyrics':
        final cur =
            _container.read(settingsProvider).valueOrNull?.floatingLyricsEnabled ?? false;
        await _container.read(settingsProvider.notifier).setFloatingLyricsEnabled(!cur);
    }
    return null;
  }

  // ---- 播放状态 -> 组件 ----

  void _onPlayback(PlaybackState s) {
    final item = s.current;
    final songChanged = item != null && item.path != _prevPath;
    if (songChanged) {
      final prevIdx = s.queue.indexWhere((q) => q.path == _prevPath);
      final newIdx = s.queue.indexWhere((q) => q.path == item.path);
      _coverDir = (prevIdx >= 0 && newIdx < prevIdx) ? -1 : 1;
      _prevPath = item.path;
      _lastCover = null;
      _loadCover(item);
      _loadLyrics(item);
    }
    _applyState(s);
  }

  Future<void> _loadLyrics(QueueItem? item) async {
    final token = ++_lyricToken;
    if (item == null) {
      _lyrics = const [];
      return;
    }
    final lines = await _container.read(lyricsRepositoryProvider).fetchLyrics(item);
    if (_disposed || token != _lyricToken) return;
    _lyrics = lines;
    _applyState(_container.read(playerProvider));
  }

  String? _currentLyric(PlaybackState s) {
    if (_lyrics.isEmpty) return null;
    final line = TimingNavigator(_lyrics).find((s.position * 1000).round());
    return line?.text;
  }

  void _applyState(PlaybackState s) {
    if (_coverLoading) return;
    final item = s.current;
    final fav = item != null && _container.read(favoritesProvider).contains(item.path);
    final lyric = _currentLyric(s) ?? '';
    final floatingLyrics =
        _container.read(settingsProvider).valueOrNull?.floatingLyricsEnabled ?? false;
    final sig = '${item?.path}|${item?.title}|${item?.artist}|${s.isPlaying}'
        '|${s.playMode}|$fav|$floatingLyrics|$lyric';
    if (sig == _lastSignature) return;
    _lastSignature = sig;
    _pushState(s, _lastCover);
  }

  Future<void> _loadCover(QueueItem? item) async {
    if (item == null || _disposed) return;
    final t = ++_coverToken;
    _coverLoading = true;
    _lastCoverTryAt = DateTime.now().millisecondsSinceEpoch;
    final path = await _coverPath(item);
    if (_disposed || t != _coverToken) return;
    _coverLoading = false;
    _lastCover = path;
    _pushState(_container.read(playerProvider), path);
  }

  Future<String?> _coverPath(QueueItem item) async {
    try {
      final dbPath = await _container.read(dbPathProvider.future);
      final cacheRoot = await _container.read(coverCacheRootProvider.future);
      var p = await getSongCover(
          dbPath: dbPath, cacheRoot: cacheRoot, path: item.path);
      if (p.isEmpty && SafChannel.isSafPath(item.path)) {
        final healed = await SafChannel.extractCoverToCache(item.path, cacheRoot);
        if (healed.isNotEmpty) {
          p = await getSongCover(
              dbPath: dbPath, cacheRoot: cacheRoot, path: item.path);
        }
      }
      if (p.isEmpty) {
        final url = item.coverUrl ?? '';
        if (url.isNotEmpty) {
          p = await _downloadOnlineCover(cacheRoot, url) ?? '';
        }
      }
      return p.isEmpty ? null : p;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _downloadOnlineCover(String cacheRoot, String url) async {
    final digest = md5.convert(utf8.encode(url)).toString();
    try {
      final reused = _findCoverFile(cacheRoot, digest);
      if (reused != null) return reused;
      final bytes = await CoverProxy.fetch(url);
      if (bytes == null || bytes.isEmpty) return null;
      final ext = _imageExt(bytes);
      if (ext == null) return null;
      final path = '$cacheRoot/${digest}_widget$ext';
      await File(path).writeAsBytes(bytes, flush: true);
      return path;
    } catch (_) {
      return null;
    }
  }

  String? _findCoverFile(String cacheRoot, String digest) {
    try {
      final dir = Directory(cacheRoot);
      if (!dir.existsSync()) return null;
      for (final e in dir.listSync(followLinks: false)) {
        if (e is File && p.basename(e.path).startsWith('${digest}_widget')) {
          return e.path;
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  String? _imageExt(Uint8List b) {
    if (b.length < 12) return null;
    if (b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return '.jpg';
    if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) return '.png';
    if (b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 &&
        b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50) {
      return '.webp';
    }
    if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x38) return '.gif';
    return null;
  }

  Future<void> _pushState(PlaybackState s, String? cover) async {
    if (_disposed) return;
    final item = s.current;
    final progress = s.duration > 0
        ? ((s.position / s.duration) * 100).clamp(0, 100).round()
        : 0;
    final favorite =
        item != null && _container.read(favoritesProvider).contains(item.path);
    final lyric = _currentLyric(s) ?? '';
    final floatingLyrics =
        _container.read(settingsProvider).valueOrNull?.floatingLyricsEnabled ?? false;
    final json = jsonEncode({
      'title': item?.title ?? '',
      'artist': item?.artist ?? '',
      'lyric': lyric,
      'playing': s.isPlaying,
      'progress': progress,
      'playMode': s.playMode,
      'favorite': favorite,
      'floatingLyrics': floatingLyrics,
      'position': s.position.round(),
      'duration': s.duration.round(),
      'coverPath': cover ?? '',
      'coverDir': _coverDir,
    });
    try {
      await _channel.invokeMethod('setState', {'json': json});
    } catch (_) {}
    try {
      await _channel.invokeMethod('update');
    } catch (_) {}
  }
}

final playerWidgetControllerProvider = Provider<PlayerWidgetController>((ref) {
  final controller = PlayerWidgetController(ref.container);
  ref.onDispose(controller.dispose);
  return controller;
});