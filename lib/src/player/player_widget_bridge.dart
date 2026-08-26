import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/db_path.dart';
import '../library/saf_channel.dart';
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

  void init() {
    _channel.setMethodCallHandler(_onControl);
    _playerSub = _container.listen(playerProvider, (_, next) => _onPlayback(next));
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
    }
    _applyState(s);
  }

  void _applyState(PlaybackState s) {
    final item = s.current;
    final sig = '${item?.path}|${item?.title}|${item?.artist}|${s.isPlaying}|${s.playMode}';
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
      var p = await getSongCoverThumbnail(
          dbPath: dbPath, cacheRoot: cacheRoot, path: item.path);
      if (p.isEmpty && SafChannel.isSafPath(item.path)) {
        final healed = await SafChannel.extractCoverToCache(item.path, cacheRoot);
        if (healed.isNotEmpty) {
          p = await getSongCoverThumbnail(
              dbPath: dbPath, cacheRoot: cacheRoot, path: item.path);
        }
      }
      // 在线歌：封面 URL 也能经 Rust 缓存成本地缩略图路径。
      if (p.isEmpty) {
        final url = item.coverUrl ?? '';
        if (url.isNotEmpty) {
          p = await getSongCoverThumbnail(
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
    final json = jsonEncode({
      'title': item?.title ?? '',
      'artist': item?.artist ?? '',
      'playing': s.isPlaying,
      'progress': progress,
      'playMode': s.playMode,
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