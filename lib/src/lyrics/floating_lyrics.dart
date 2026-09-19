import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';
import '../i18n/i18n.dart';
import '../player/player_provider.dart';
import 'lyric_model.dart';
import 'lyrics_repository.dart';

class FloatingLyricsController {
  FloatingLyricsController(this._container);

  final ProviderContainer _container;

  static const MethodChannel _channel = MethodChannel('xianyu/floating_lyrics');
  static const MethodChannel _events =
      MethodChannel('xianyu/floating_lyrics_events');

  static const List<int> quickColors = [
    0xFFFFFFFF,
    0xFFBFBFBF,
    0xFF91CDFF,
    0xFFA6EBCB,
    0xFFB388FF,
    0xFFFFBCD6,
    0xFFFFE096,
  ];

  ProviderSubscription<AsyncValue<AppSettings>>? _settingsSub;
  ProviderSubscription<PlaybackState>? _playerSub;
  bool _enabled = false;
  int _lastPushedPosMs = -1;
  bool _lastPushedPlaying = false;
  String? _songKey;
  List<LyricLine> _lyrics = const [];
  int _fetchToken = 0;

  void init() {
    _events.setMethodCallHandler(_onEvent);
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
    _events.setMethodCallHandler(null);
    I18n.modeVersion.removeListener(_onLanguageChanged);
    _settingsSub?.close();
    _playerSub?.close();
  }

  void _onLanguageChanged() {
    if (!_enabled) return;
    _lyrics = const [];
    _fetchLyrics(_container.read(playerProvider).current);
  }

  // ---- 设置变化 ----

  void _onSettingsChanged(AppSettings s) {
    final enabled = s.floatingLyricsEnabled;
    if (enabled && !_enabled) {
      _enabled = true;
      _pushSettings(s);
      _pushLyrics(s);
      _pushPlayback(s);
      _show();
    } else if (!enabled && _enabled) {
      _enabled = false;
      _hide();
    } else if (enabled) {
      _pushSettings(s);
      if (s.floatingLyricsLocked) _setLocked(true);
    }
  }

  // ---- 播放状态变化 ----

  void _onPlaybackChanged(PlaybackState state) {
    final s = _container.read(settingsProvider).valueOrNull;
    if (s == null || !s.floatingLyricsEnabled) return;

    final item = state.current;
    final key = item == null
        ? null
        : '${item.path}|${item.title}|${item.artist}';
    if (key != _songKey) {
      _songKey = key;
      _lyrics = const [];
      _fetchLyrics(item);
    }
    _pushPlayback(s);
  }

  Future<void> _fetchLyrics(QueueItem? item) async {
    final token = ++_fetchToken;
    if (item == null) {
      _pushLyricsJson('');
      return;
    }
    final lines = await _container.read(lyricsRepositoryProvider).fetchLyrics(item);
    if (token != _fetchToken) return;
    _lyrics = lines;
    _pushLyricsJson(serializeLyricsForOverlay(lines));
  }

  // ---- 推送原生 ----

  Future<void> _show() async {
    final granted = await _isPermissionGranted();
    if (!granted) return;
    await _channel.invokeMethod('show');
    final s = _container.read(settingsProvider).valueOrNull;
    if (s != null) {
      _pushSettings(s);
      _pushLyrics(s);
      _pushPlayback(s);
    }
  }

  Future<void> _hide() async {
    await _channel.invokeMethod('hide');
  }

  void _pushSettings(AppSettings s) {
    _channel.invokeMethod('setSettings', {
      'json': jsonEncode({
        'textColor': s.floatingLyricsTextColor,
        'opacity': s.floatingLyricsOpacity,
        'fontScale': s.floatingLyricsFontScale,
        'secondaryScale': s.floatingLyricsSecondaryScale,
        'showTranslation': s.floatingLyricsShowTranslation,
        'showRomanization': s.floatingLyricsShowRomanization,
        'showBackground': s.floatingLyricsShowBackground,
        'hideWhenPaused': s.floatingLyricsHideWhenPaused,
        'hideInLandscape': s.floatingLyricsHideInLandscape,
        'widthPercent': s.floatingLyricsWidthPercent,
        'useLyricFont': s.floatingLyricsUseLyricFont,
        'lyricFontPath': s.lyricFontPath,
        'locked': s.floatingLyricsLocked,
        'x': s.floatingLyricsX,
        'y': s.floatingLyricsY,
      }),
    });
  }

  void _pushLyrics(AppSettings s) {
    _pushLyricsJson(serializeLyricsForOverlay(_lyrics));
  }

  void _pushLyricsJson(String json) {
    _channel.invokeMethod('setLyrics', {'json': json});
  }

  void _pushPlayback(AppSettings s) {
    final state = _container.read(playerProvider);
    final posMs = (state.position * 1000).round();
    final playing = state.isPlaying;
    if (posMs == _lastPushedPosMs && playing == _lastPushedPlaying) return;
    _lastPushedPosMs = posMs;
    _lastPushedPlaying = playing;
    _channel.invokeMethod('setPlayback', {
      'positionMs': posMs,
      'isPlaying': playing,
    });
  }

  void _setLocked(bool locked) {
    _channel.invokeMethod('setLocked', {'locked': locked});
  }

  Future<bool> _isPermissionGranted() async {
    try {
      final v = await _channel.invokeMethod<bool>('isPermissionGranted');
      return v ?? false;
    } catch (_) {
      return false;
    }
  }

  // ---- 原生事件回调 ----

  Future<dynamic> _onEvent(MethodCall call) async {
    switch (call.method) {
      case 'onTogglePlayback':
        _container.read(playerProvider.notifier).toggle();
      case 'onPrevious':
        _container.read(playerProvider.notifier).previous();
      case 'onNext':
        _container.read(playerProvider.notifier).next();
      case 'onClose':
        await _container
            .read(settingsProvider.notifier)
            .setFloatingLyricsEnabled(false);
      case 'onLock':
        await _container
            .read(settingsProvider.notifier)
            .setFloatingLyricsLocked(true);
      case 'onUnlock':
        await _container
            .read(settingsProvider.notifier)
            .setFloatingLyricsLocked(false);
      case 'onFontSmaller':
        await _adjustFontScale(-10);
      case 'onFontLarger':
        await _adjustFontScale(10);
      case 'onColorCycle':
        await _cycleColor();
      case 'onPositionChanged':
        final x = (call.arguments as Map?)?.cast<String, dynamic>()['x'] as int?;
        final y = (call.arguments as Map?)?.cast<String, dynamic>()['y'] as int?;
        if (x != null && y != null) {
          await _container
              .read(settingsProvider.notifier)
              .setFloatingLyricsPosition(x, y);
        }
    }
    return null;
  }

  Future<void> _adjustFontScale(int delta) async {
    final n = _container.read(settingsProvider.notifier);
    final s = _container.read(settingsProvider).valueOrNull;
    if (s == null) return;
    final next = (s.floatingLyricsFontScale + delta).clamp(40, 250);
    await n.setFloatingLyricsFontScale(next);
  }

  Future<void> _cycleColor() async {
    final n = _container.read(settingsProvider.notifier);
    final s = _container.read(settingsProvider).valueOrNull;
    if (s == null) return;
    final idx = quickColors.indexOf(s.floatingLyricsTextColor);
    final next = quickColors[(idx + 1) % quickColors.length];
    await n.setFloatingLyricsTextColor(next);
  }

  // ---- 供设置页使用的静态能力 ----

  static Future<bool> isPermissionGranted() async {
    try {
      final v = await _channel.invokeMethod<bool>('isPermissionGranted');
      return v ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> openPermissionSettings() async {
    try {
      await _channel.invokeMethod('openPermissionSettings');
    } catch (_) {}
  }

  static Future<void> resetPosition() async {
    try {
      await _channel.invokeMethod('resetPosition');
    } catch (_) {}
  }
}

final floatingLyricsControllerProvider =
    Provider<FloatingLyricsController>((ref) {
  final controller = FloatingLyricsController(ref.container);
  ref.onDispose(controller.dispose);
  return controller;
});
