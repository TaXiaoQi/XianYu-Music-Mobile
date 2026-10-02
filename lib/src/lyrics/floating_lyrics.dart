import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';
import '../i18n/i18n.dart';
import '../player/mv_provider.dart';
import '../player/player_provider.dart';
import 'lyric_model.dart';
import 'lyrics_repository.dart';

class FloatingLyricsController with WidgetsBindingObserver {
  FloatingLyricsController(this._container);

  final ProviderContainer _container;

  static const MethodChannel _channel = MethodChannel('xianyu/floating_lyrics');
  static const MethodChannel _events =
      MethodChannel('xianyu/floating_lyrics_events');

  ProviderSubscription<AsyncValue<AppSettings>>? _settingsSub;
  ProviderSubscription<PlaybackState>? _playerSub;

  ProviderSubscription<bool>? _mvSub;
  bool _mvActive = false;

  bool _enabled = false;
  bool _pendingEnableViaSettings = false;
  int _lastPushedPosMs = -1;
  bool _lastPushedPlaying = false;
  String? _songKey;
  List<LyricLine> _lyrics = const [];
  int _fetchToken = 0;

  void init() {
    WidgetsBinding.instance.addObserver(this);
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
    _mvSub = _container.listen(
      mvProvider.select((state) => state.requested),
      (prev, next) => _onMvChanged(next),
    );
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _events.setMethodCallHandler(null);
    I18n.modeVersion.removeListener(_onLanguageChanged);
    _settingsSub?.close();
    _playerSub?.close();
    _mvSub?.close();
  }

  void _onLanguageChanged() {
    if (!_enabled) return;
    _lyrics = const [];
    _fetchLyrics(_container.read(playerProvider).current);
  }

  // ---- 设置变化 ----

  void _onSettingsChanged(AppSettings s) {
    final enabled = s.floatingLyricsEnabled && !_mvActive;
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

  // ---- MV 变化 ----

  void _onMvChanged(bool active) {
    if (_mvActive == active) return;
    _mvActive = active;
    final s = _container.read(settingsProvider).valueOrNull;
    final want = (s?.floatingLyricsEnabled ?? false) && !active;
    if (want == _enabled) return;
    _enabled = want;
    if (want) {
      _show();
    } else {
      _hide();
    }
  }

  // ---- 播放状态变化 ----

  void _onPlaybackChanged(PlaybackState state) {
    final s = _container.read(settingsProvider).valueOrNull;
    if (s == null || !s.floatingLyricsEnabled || _mvActive) return;

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
        'unplayedColor': s.floatingLyricsUnplayedColor,
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
      case 'onLock':
        await _container
            .read(settingsProvider.notifier)
            .setFloatingLyricsLocked(true);
      case 'onUnlock':
        await _container
            .read(settingsProvider.notifier)
            .setFloatingLyricsLocked(false);
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

  // ---- 供设置页使用的静态能力 ----

  /// 未授权时的开启流程：跳系统设置授权页但不立即切换开关；回到前台后
  /// 复检权限——已授权才真正开启，被拦截/未授权则保持关闭
  Future<void> requestEnableViaSettings() async {
    _pendingEnableViaSettings = true;
    await openPermissionSettings();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !_pendingEnableViaSettings) {
      return;
    }
    _pendingEnableViaSettings = false;
    _confirmPendingEnable();
  }

  Future<void> _confirmPendingEnable() async {
    final granted = await isPermissionGranted();
    if (!granted) return;
    await _container
        .read(settingsProvider.notifier)
        .setFloatingLyricsEnabled(true);
  }

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
