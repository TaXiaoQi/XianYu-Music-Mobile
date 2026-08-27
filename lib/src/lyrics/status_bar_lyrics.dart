import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';
import '../player/player_provider.dart';
import 'lyric_model.dart';
import 'lyrics_repository.dart';
import '../i18n/i18n.dart';

/// 状态栏/通知栏歌词控制器。
///
/// 数据流：Flutter 侧持有播放状态与歌词（复用 [LyricsRepository]），
/// 每当当前歌词行变化时，经 MethodChannel 推送给原生把一个「歌词通知」，
/// 让歌词出现在系统通知栏/锁屏（部分车机/蓝牙联屏靠读通知文本实现）。
///
/// 与 [FloatingLyricsController] 完全独立：它只关心活动歌词行的文本，
/// 不做卡拉OK逐字，也不占据后台悬浮窗权限，仅用普通通知。
class StatusBarLyricsController {
  StatusBarLyricsController(this._container);

  final ProviderContainer _container;

  static const MethodChannel _channel = MethodChannel('xianyu/status_lyric');

  ProviderSubscription<AsyncValue<AppSettings>>? _settingsSub;
  ProviderSubscription<PlaybackState>? _playerSub;
  bool _enabled = false;

  String? _songKey;
  List<LyricLine> _lyrics = const [];
  int _fetchToken = 0;

  /// 已推送的歌词行文本（+ 歌曲标识），行变化时才更新通知，避免高频刷新。
  String? _lastPushedLine;
  String? _lastPushedMeta;

  void init() {
    _settingsSub = _container.listen(settingsProvider, (prev, next) {
      final s = next.valueOrNull;
      if (s == null) return;
      _onSettingsChanged(s);
    });
    _playerSub = _container.listen(playerProvider, (prev, next) {
      _onPlaybackChanged(next);
    });
  }

  void dispose() {
    _settingsSub?.close();
    _playerSub?.close();
    _cancel();
  }

  // ---- 设置变化 ----

  void _onSettingsChanged(AppSettings s) {
    final enabled = s.statusBarLyricsEnabled;
    if (enabled && !_enabled) {
      _enabled = true;
      // 开启瞬间立即推算一次当前歌曲/歌词，无需等播放状态翻转。
      final state = _container.read(playerProvider);
      _onPlaybackChanged(state);
    } else if (!enabled && _enabled) {
      _enabled = false;
      _cancel();
    }
  }

  // ---- 播放状态变化 ----

  void _onPlaybackChanged(PlaybackState state) {
    final s = _container.read(settingsProvider).valueOrNull;
    if (s == null || !s.statusBarLyricsEnabled) return;

    final item = state.current;
    if (item == null || !state.isPlaying) {
      // 无歌或已暂停：隐藏通知栏歌词（连暂停也收起，避免残留误导）。
      _lastPushedLine = null;
      _cancel();
      return;
    }

    final key = '${item.path}|${item.title}|${item.artist}';
    if (key != _songKey) {
      _songKey = key;
      _lyrics = const [];
      _lastPushedLine = null;
      _fetchLyrics(item);
      return; // 歌词未就绪前不推送，等 _fetchLyrics 完成后首推。
    }
    _pushActiveLine(item, state.position);
  }

  Future<void> _fetchLyrics(QueueItem? item) async {
    final token = ++_fetchToken;
    if (item == null) return;
    final lines = await _container.read(lyricsRepositoryProvider).fetchLyrics(item);
    if (token != _fetchToken) return; // 已切歌，丢弃过期结果。
    _lyrics = lines;
    final state = _container.read(playerProvider);
    if (state.current != null &&
        '${state.current!.path}|${state.current!.title}|${state.current!.artist}' ==
            _songKey) {
      _pushActiveLine(item, state.position);
    }
  }

  /// 由播放进度推算当前歌词行并推送（仅行变化时更新通知）。
  void _pushActiveLine(QueueItem item, double positionSecs) {
    if (_lyrics.isEmpty) return;
    final posMs = (positionSecs * 1000).round();
    String? line;
    for (final l in _lyrics) {
      if (posMs >= l.timeMs && posMs < l.endTimeMs) {
        line = l.text;
        break;
      }
    }
    line ??= tr('歌词滚动中…');
    final meta = '${item.title}|${item.artist}';
    if (line == _lastPushedLine && meta == _lastPushedMeta) return;
    _lastPushedLine = line;
    _lastPushedMeta = meta;
    _push(line, item);
  }

  // ---- 推送原生 ----

  void _push(String line, QueueItem item) {
    _channel.invokeMethod('show', {
      'title': item.title,
      'artist': item.artist,
      'lyric': line,
      if (item.coverPath != null && item.coverPath!.isNotEmpty)
        'coverPath': item.coverPath,
      if (item.coverUrl != null && item.coverUrl!.isNotEmpty)
        'coverUrl': item.coverUrl,
    });
  }

  void _cancel() {
    _channel.invokeMethod('cancel');
  }
}

/// 状态栏歌词控制器 provider：首次读取时创建（init 由 main 显式调用）。
final statusBarLyricsControllerProvider = Provider<StatusBarLyricsController>((ref) {
  final controller = StatusBarLyricsController(ref.container);
  ref.onDispose(controller.dispose);
  return controller;
});