import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';
import 'player_provider.dart';

/// 蓝牙音频设备（车机 / 蓝牙音箱）连接监听：驱动两个自动化——
/// · 「自动跟随蓝牙接入」：连上车机自动开启蓝牙歌词，断开自动恢复；
/// · 「蓝牙接入自动续播」：连上车机后自动恢复播放（仅暂停态触发，
///   正在播放不干预；toggle 内置应用重启后的上次播放会话恢复）。
///
/// 仅边沿触发，不覆盖用户手动开关：
/// · 连接沿：蓝牙歌词未开时自动打开（记 _autoEnabledByUs）；
/// · 断开沿：仅当本次连接是本控制器自动打开时才收回；
/// · 自动模式关闭时立即遗忘自动打开标记，之后不再改动任何状态。
class BluetoothAudioWatcher {
  BluetoothAudioWatcher(this._container);

  final ProviderContainer _container;

  static const EventChannel _channel = EventChannel('xianyu/bluetooth_audio');

  StreamSubscription<dynamic>? _sub;
  bool _autoEnabledByUs = false;

  void init() {
    // 蓝牙不可用的设备（平板/模拟器）原生通道照常注册，事件恒 disconnected
    _sub = _channel.receiveBroadcastStream().listen(_onEvent,
        onError: (Object e) {});
  }

  void _onEvent(dynamic event) {
    if (event is! Map || event['connected'] is! bool) return;
    final connected = event['connected'] as bool;
    final s = _container.read(settingsProvider).valueOrNull;
    if (s == null) return;
    // 「自动跟随蓝牙接入」：连接沿自动开歌词，断开沿仅收回自动开启的部分
    if (s.bluetoothLyricsAutoEnabled) {
      final notifier = _container.read(settingsProvider.notifier);
      if (connected && !s.bluetoothLyricsEnabled) {
        _autoEnabledByUs = true;
        unawaited(notifier.setBluetoothLyricsEnabled(true));
      } else if (!connected && _autoEnabledByUs) {
        _autoEnabledByUs = false;
        unawaited(notifier.setBluetoothLyricsEnabled(false));
      }
    } else {
      _autoEnabledByUs = false;
    }

    // 「蓝牙接入自动续播」：连接沿且暂停态才触发（正在播放不干预；
    // 冷启动场景 toggle 内置上次播放会话恢复）
    if (connected && s.bluetoothAutoResumeEnabled) {
      final player = _container.read(playerProvider);
      if (!player.isPlaying) {
        unawaited(
          _container
              .read(playerProvider.notifier)
              .toggle(origin: 'btAutoResume'),
        );
      }
    }
  }

  void dispose() {
    _sub?.cancel();
    _sub = null;
  }
}

final bluetoothAudioWatcherProvider = Provider<BluetoothAudioWatcher>((ref) {
  final controller = BluetoothAudioWatcher(ref.container);
  ref.onDispose(controller.dispose);
  return controller;
});
