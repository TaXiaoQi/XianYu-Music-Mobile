import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';
import '../player/player_provider.dart';
import 'lyric_model.dart';
import 'lyrics_repository.dart';
import '../i18n/i18n.dart';

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

  String? _lastPushedLine;
  String? _lastPushedMeta;

  void init() {
    I18n.modeVersion.addListener(_onLanguageChanged);
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
    I18n.modeVersion.removeListener(_onLanguageChanged);
    _settingsSub?.close();
    _playerSub?.close();
    _cancel();
  }

  void _onLanguageChanged() {
    if (!_enabled) return;
    _lyrics = const [];
    _lastPushedLine = null;
    _lastPushedMeta = null;
    _fetchLyrics(_container.read(playerProvider).current);
  }

  // ---- 设置变化 ----

  bool _btEnabled(AppSettings s) => s.statusBarLyricsEnabled || s.bluetoothLyricsEnabled;

  void _onSettingsChanged(AppSettings s) {
    final enabled = _btEnabled(s);
    if (enabled && !_enabled) {
      _enabled = true;
      final state = _container.read(playerProvider);
      _onPlaybackChanged(state);
    } else if (!enabled && _enabled) {
      _enabled = false;
      _cancel();
    } else if (_enabled) {
      // 两个出口单独关闭时也要收回对应的展示（通知栏/媒体会话标题）
      if (!s.statusBarLyricsEnabled) _channel.invokeMethod('cancel');
      if (!s.bluetoothLyricsEnabled) _restoreTitle();
    }
  }

  // ---- 播放状态变化 ----

  void _onPlaybackChanged(PlaybackState state) {
    final s = _container.read(settingsProvider).valueOrNull;
    if (s == null || !_btEnabled(s)) return;

    final item = state.current;
    if (item == null || !state.isPlaying) {
      _lastPushedLine = null;
      _cancel();
      return;
    }

    final key = '${item.path}|${item.title}|${item.artist}';
    if (key != _songKey) {
      _songKey = key;
      _lyrics = const [];
      _lastPushedLine = null;
      // 切歌即恢复真实标题，避免旧歌末句歌词残留到新媒体会话元数据
      if (s.bluetoothLyricsEnabled) _restoreTitle();
      _fetchLyrics(item);
      return;
    }
    _pushActiveLine(item, state.position);
  }

  Future<void> _fetchLyrics(QueueItem? item) async {
    final token = ++_fetchToken;
    if (item == null) return;
    final lines = await _container.read(lyricsRepositoryProvider).fetchLyrics(item);
    if (token != _fetchToken) return;
    _lyrics = lines;
    final state = _container.read(playerProvider);
    if (state.current != null &&
        '${state.current!.path}|${state.current!.title}|${state.current!.artist}' ==
            _songKey) {
      _pushActiveLine(item, state.position);
    }
  }

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
    final s = _container.read(settingsProvider).valueOrNull;
    if (s?.statusBarLyricsEnabled == true) {
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
    // 蓝牙歌词：写入媒体会话元数据标题，车机经蓝牙 AVRCP 读取显示
    if (s?.bluetoothLyricsEnabled == true) {
      audioHandler?.setBluetoothLyric(line, songPath: item.path);
    }
  }

  void _restoreTitle() {
    final item = _container.read(playerProvider).current;
    if (item != null) {
      audioHandler?.setBluetoothLyric(null, songPath: item.path);
    }
  }

  void _cancel() {
    _channel.invokeMethod('cancel');
    _restoreTitle();
  }
}

final statusBarLyricsControllerProvider = Provider<StatusBarLyricsController>((ref) {
  final controller = StatusBarLyricsController(ref.container);
  ref.onDispose(controller.dispose);
  return controller;
});