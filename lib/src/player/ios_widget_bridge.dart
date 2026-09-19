import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../core/db_path.dart';
import '../library/saf_channel.dart';
import '../lyrics/lyric_model.dart';
import '../lyrics/lyrics_repository.dart';
import '../online/cover_proxy.dart';
import '../rust/api.dart';
import 'player_provider.dart';

class IosWidgetController {
  IosWidgetController(this._container);

  final ProviderContainer _container;

  static const MethodChannel _channel = MethodChannel('xianyu/ios_widget');

  ProviderSubscription<PlaybackState>? _playerSub;
  bool _disposed = false;
  String? _prevPath;
  String? _lastSignature;
  String? _lastSentCover;
  List<LyricLine> _lyrics = const [];
  int _lyricToken = 0;
  DateTime _lastLyricPushAt = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _lyricThrottle;

  void init() {
    _channel.setMethodCallHandler(_onNativeCall);
    _playerSub = _container.listen(playerProvider, (_, next) => _onPlayback(next));
    _consumePendingCommand();
  }

  void dispose() {
    _disposed = true;
    _lyricThrottle?.cancel();
    _playerSub?.close();
    _channel.setMethodCallHandler(null);
  }

  // ---- 原生 → Dart ----

  Future<dynamic> _onNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'command':
      case 'onCommand':
        final args = call.arguments;
        final action = args is Map ? args['action'] as String? : null;
        if (action != null) await _handleAction(action);
    }
    return null;
  }

  Future<void> _consumePendingCommand() async {
    try {
      final pending = await _channel.invokeMethod<String>('takePendingCommand');
      if (pending != null && pending.isNotEmpty && !_disposed) {
        await _handleAction(pending);
      }
    } catch (_) {}
  }

  Future<void> _handleAction(String action) async {
    final notifier = _container.read(playerProvider.notifier);
    switch (action) {
      case 'toggle':
        notifier.toggle();
      case 'previous':
        notifier.previous();
      case 'next':
        notifier.next();
    }
  }

  // ---- 播放状态 → 小组件 / Live Activity ----

  Future<void> _onPlayback(PlaybackState s) async {
    final item = s.current;
    if (item == null) {
      if (_prevPath != null) {
        _prevPath = null;
        _lastSignature = null;
        _lastSentCover = null;
        _lyrics = const [];
        try {
          await _channel.invokeMethod('clear');
        } catch (_) {}
      }
      return;
    }
    if (item.path != _prevPath) {
      _prevPath = item.path;
      _lastSignature = null;
      _lastSentCover = null;
      _loadLyrics(item);
      _loadCover(item);
    }
    _applyState(s);
  }

  Future<void> _loadLyrics(QueueItem item) async {
    final token = ++_lyricToken;
    try {
      final lines = await _container.read(lyricsRepositoryProvider).fetchLyrics(item);
      if (_disposed || token != _lyricToken) return;
      _lyrics = lines;
    } catch (_) {
      if (_disposed || token != _lyricToken) return;
      _lyrics = const [];
    }
    _applyState(_container.read(playerProvider));
  }

  String? _currentLyric(PlaybackState s) {
    if (_lyrics.isEmpty) return null;
    final line = TimingNavigator(_lyrics).find((s.position * 1000).round());
    return line?.text;
  }

  void _applyState(PlaybackState s) {
    if (_disposed || _coverLoading) return;
    final item = s.current;
    if (item == null) return;
    final lyric = _currentLyric(s) ?? '';
    final sig = '${item.path}|${item.title}|${item.artist}|${s.isPlaying}|$lyric';
    if (sig == _lastSignature) return;
    _lastSignature = sig;
    _pushState(s, lyric);
  }

  Future<void> _pushState(PlaybackState s, String lyric) async {
    final now = DateTime.now();
    final elapsed = now.difference(_lastLyricPushAt);
    if (elapsed < const Duration(seconds: 1)) {
      _lyricThrottle ??= Timer(const Duration(seconds: 1) - elapsed, () {
        _lyricThrottle = null;
        if (_disposed) return;
        final latest = _container.read(playerProvider);
        final latestLyric = _currentLyric(latest) ?? '';
        final latestSig =
            '${latest.current?.path}|${latest.current?.title}|${latest.current?.artist}|${latest.isPlaying}|$latestLyric';
        if (latestSig != _lastSignature) {
          _lastSignature = latestSig;
          _pushState(latest, latestLyric);
        }
      });
      return;
    }
    _lastLyricPushAt = now;
    final coverToSend = _lastCover != _lastSentCover ? _lastCover : null;
    _lastSentCover = _lastCover;
    try {
      await _channel.invokeMethod('setState', {
        'title': s.current?.title ?? '',
        'artist': s.current?.artist ?? '',
        'lyric': lyric,
        'playing': s.isPlaying,
        'position': s.position,
        'duration': s.duration,
        'coverPath': coverToSend,
        'songChanged': false,
      });
    } catch (_) {}
  }

  // ---- 封面加载（与 Android 桥同源逻辑：本地 → SAF 兜底 → 在线代理落盘）----

  bool _coverLoading = false;
  int _coverToken = 0;
  String? _lastCover;

  Future<void> _loadCover(QueueItem item) async {
    final t = ++_coverToken;
    _coverLoading = true;
    final path = await _coverPath(item);
    if (_disposed || t != _coverToken) return;
    _coverLoading = false;
    _lastCover = path;
    _applyState(_container.read(playerProvider));
  }

  Future<String?> _coverPath(QueueItem item) async {
    try {
      final dbPath = await _container.read(dbPathProvider.future);
      final cacheRoot = await _container.read(coverCacheRootProvider.future);
      var path = await getSongCover(dbPath: dbPath, cacheRoot: cacheRoot, path: item.path);
      if (path.isEmpty && SafChannel.isSafPath(item.path)) {
        final healed = await SafChannel.extractCoverToCache(item.path, cacheRoot);
        if (healed.isNotEmpty) {
          path = await getSongCover(dbPath: dbPath, cacheRoot: cacheRoot, path: item.path);
        }
      }
      if (path.isEmpty) {
        final url = item.coverUrl ?? '';
        if (url.isNotEmpty) {
          path = await _downloadOnlineCover(cacheRoot, url) ?? '';
        }
      }
      return path.isEmpty ? null : path;
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
      final path = '$cacheRoot/${digest}_ioswidget$ext';
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
        if (e is File && p.basename(e.path).startsWith('${digest}_ioswidget')) {
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
}

final iosWidgetControllerProvider = Provider<IosWidgetController>((ref) {
  final controller = IosWidgetController(ref.container);
  ref.onDispose(controller.dispose);
  return controller;
});
