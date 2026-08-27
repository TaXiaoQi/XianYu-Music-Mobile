import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/db_path.dart';
import '../core/settings.dart';
import '../favorites/favorites_provider.dart';
import '../library/saf_channel.dart';
import '../lyrics/lyric_model.dart';
import '../lyrics/lyrics_repository.dart';
import '../rust/api.dart';
import 'player_provider.dart';

/// Android 桌面播放小组件桥。
///
/// 数据流：Flutter 持有播放状态，随歌曲/播放/模式变化与周期心跳，把
/// 歌名/歌手/播放态/进度/循环模式/封面本地缩略图路径写入 SharedPreferences，
/// 再经原生通道触发 AppWidget 刷新（AppWidgetProvider 读取 prefs 渲染）。
/// 小组件按钮经 AppWidgetProvider 调同一 MethodChannel
/// （'xianyu/player_widget'）回调本类，由本类驱动播放器控制。
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

  void init() {
    _channel.setMethodCallHandler(_onControl);
    _playerSub = _container.listen(playerProvider, (_, next) => _onPlayback(next));
    // 收藏变更也要刷新组件图标（播放状态可能未变）。
    _container.listen(favoritesProvider, (_, _) {
      if (_disposed) return;
      final item = _container.read(playerProvider).current;
      if (item != null) _applyState(_container.read(playerProvider));
    });
    // 桌面歌词开关变化 → 刷新组件图标。
    _container.listen(settingsProvider, (_, _) {
      if (_disposed) return;
      final s = _container.read(playerProvider);
      if (s.current != null) _applyState(s);
    });
    _heartbeat = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_disposed) return;
      final s = _container.read(playerProvider);
      final item = s.current;
      if (item != null && s.isPlaying) _pushState(s, _lastCover);
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
    if (_disposed || token != _lyricToken) return; // 已切歌/销毁，丢弃过期结果。
    _lyrics = lines;
    _applyState(_container.read(playerProvider));
  }

  String? _currentLyric(PlaybackState s) {
    if (_lyrics.isEmpty) return null;
    final line = TimingNavigator(_lyrics).find((s.position * 1000).round());
    return line?.text;
  }

  /// 歌词卡组件的五行窗口：当前行固定居中（index 2），上下各两行邻行。
  /// 前奏期（定位失败）当前行为空、后续行依次上移，越界补空串。
  List<String> _lyricWindow(PlaybackState s) {
    if (_lyrics.isEmpty) return const [];
    final ms = (s.position * 1000).round();
    final idx = TimingNavigator(_lyrics).findIndex(ms);
    return List.generate(5, (i) {
      final j = idx + i - 2;
      return (j >= 0 && j < _lyrics.length) ? _lyrics[j].text : '';
    });
  }

  void _applyState(PlaybackState s) {
    final item = s.current;
    final fav = item != null && _container.read(favoritesProvider).contains(item.path);
    final lyric = _currentLyric(s) ?? '';
    final window = _lyricWindow(s);
    final floatingLyrics =
        _container.read(settingsProvider).valueOrNull?.floatingLyricsEnabled ?? false;
    final sig = '${item?.path}|${item?.title}|${item?.artist}|${s.isPlaying}'
        '|${s.playMode}|$fav|$floatingLyrics|$lyric|${window.join('|')}';
    if (sig == _lastSignature) return;
    _lastSignature = sig;
    _pushState(s, _lastCover);
  }

  Future<void> _loadCover(QueueItem? item) async {
    if (item == null || _disposed) return;
    final path = await _coverPath(item);
    if (_disposed) return;
    _lastCover = path;
    _pushState(_container.read(playerProvider), path);
  }

  Future<String?> _coverPath(QueueItem item) async {
    try {
      final dbPath = await _container.read(dbPathProvider.future);
      final cacheRoot = await _container.read(coverCacheRootProvider.future);
      // 组件用高清封面（与播放详情页同源 800px），低清缩略图在大尺寸组件上会糊。
      var p = await getSongCover(
          dbPath: dbPath, cacheRoot: cacheRoot, path: item.path);
      if (p.isEmpty && SafChannel.isSafPath(item.path)) {
        final healed = await SafChannel.extractCoverToCache(item.path, cacheRoot);
        if (healed.isNotEmpty) {
          p = await getSongCover(
              dbPath: dbPath, cacheRoot: cacheRoot, path: item.path);
        }
      }
      // 在线歌：封面 URL 也能经 Rust 缓存成本地高清路径。
      if (p.isEmpty) {
        final url = item.coverUrl ?? '';
        if (url.isNotEmpty) {
          p = await getSongCover(
              dbPath: dbPath, cacheRoot: cacheRoot, path: url);
        }
      }
      return p.isEmpty ? null : p;
    } catch (_) {
      return null;
    }
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
    final window = _lyricWindow(s);
    final floatingLyrics =
        _container.read(settingsProvider).valueOrNull?.floatingLyricsEnabled ?? false;
    final json = jsonEncode({
      'title': item?.title ?? '',
      'artist': item?.artist ?? '',
      'lyric': lyric,
      'lyricWindow': window,
      'playing': s.isPlaying,
      'progress': progress,
      'playMode': s.playMode,
      'favorite': favorite,
      'floatingLyrics': floatingLyrics,
      'position': s.position.round(),
      'duration': s.duration.round(),
      'coverPath': cover ?? '',
    });
    try {
      // 状态经原生通道落盘到确定性 key(player_widget/state)，再触发组件刷新。
      await _channel.invokeMethod('setState', {'json': json});
    } catch (_) {}
    try {
      await _channel.invokeMethod('update');
    } catch (_) {}
  }
}

/// 桌面播放小组件桥 provider：监听由 main 显式 init。
final playerWidgetControllerProvider = Provider<PlayerWidgetController>((ref) {
  final controller = PlayerWidgetController(ref.container);
  ref.onDispose(controller.dispose);
  return controller;
});