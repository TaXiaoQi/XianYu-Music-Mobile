import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_provider.dart';
import '../core/settings.dart';
import '../favorites/favorites_provider.dart';
import '../player/player_provider.dart';

/// 手表联动服务。
///
/// 通过服务端中转（非蓝牙直连）实现手表 → 手机的控制链路：
/// - presence 心跳（`watch_phone_ping`）：登录且开启联动时周期性上报当前播放
///   信息，手表端据此判断手机在线并展示正在播放的曲目。
/// - 命令轮询（`watch_poll_command`）：拉取本账号手表下发的控制命令（播放/暂停/
///   上下首/收藏/跳转等）并依次执行。
///
/// 手机端只作为「被控端」接入；手表端纯 Dart 侧通过 `requestAction` 走同一套接口。
class WatchControlService {
  WatchControlService(this._ref);
  final Ref _ref;

  Timer? _pingTimer;
  Timer? _pollTimer;
  bool _publishing = false;
  bool _polling = false;
  String? _deviceId;

  AuthState get _authState => _ref.read(authProvider);
  AuthNotifier get _auth => _ref.read(authProvider.notifier);

  bool get _loggedIn =>
      _authState.isLoggedIn &&
      (_authState.user?.ciyuanxiId?.isNotEmpty ?? false);

  bool get _enabled =>
      _ref.read(settingsProvider).valueOrNull?.watchLinkageEnabled ?? true;

  /// 启动调度：每 10s 一次心跳，每 3s 一次命令轮询。
  void start() {
    _pingTimer ??=
        Timer.periodic(const Duration(seconds: 10), (_) => _publishPresence());
    _pollTimer ??=
        Timer.periodic(const Duration(seconds: 3), (_) => _pollCommands());
    // 启动立即各跑一次，缩短首次反映/连接时间。
    _publishPresence();
    _pollCommands();
  }

  void dispose() {
    _pingTimer?.cancel();
    _pingTimer = null;
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<String> _phoneDeviceId() async =>
      _deviceId ??= await _auth.deviceId();

  /// 上报当前播放信息（presence）。
  Future<void> _publishPresence() async {
    if (_publishing || !_loggedIn || !_enabled) return;
    _publishing = true;
    try {
      final cur = _ref.read(playerProvider).current;
      final fav = cur == null ? false : _ref.read(favoritesProvider).contains(cur.path);
      await _auth.requestAction('watch_phone_ping', {
        'ciyuanxi_id': _authState.user!.ciyuanxiId!,
        'device_id': await _phoneDeviceId(),
        'device_model': _deviceModel(),
        'app_version': _appVersion,
        'playing_title': cur?.title ?? '',
        'playing_artist': (cur?.artist ?? '').join(' / '),
        'playing_album': cur?.album ?? '',
        'playing_cover': _coverUrl(cur),
        'is_playing': _ref.read(playerProvider).isPlaying ? 1 : 0,
        'is_favorite': fav ? 1 : 0,
      }, fetchTimeoutMs: 8000);
    } catch (_) {
      // 心跳失败静默：网络抖动时不打断正常播放。
    } finally {
      _publishing = false;
    }
  }

  /// 轮询本账号手表下发的命令并执行。
  Future<void> _pollCommands() async {
    if (_polling || !_loggedIn || !_enabled) return;
    _polling = true;
    try {
      final data = await _auth.requestAction('watch_poll_command', {
        'ciyuanxi_id': _authState.user!.ciyuanxiId!,
      }, fetchTimeoutMs: 8000);
      final commands = (data['commands'] as List?) ?? const [];
      for (final raw in commands) {
        if (raw is! Map) continue;
        final op = (raw['op'] as String?) ?? '';
        final payload = raw['payload'];
        try {
          await _executeOp(op, payload is Map ? payload : null);
        } catch (_) {
          // 单条命令失败不中断后续命令。
        }
      }
    } catch (_) {
      // 轮询失败静默，下个周期重试。
    } finally {
      _polling = false;
    }
  }

  Future<void> _executeOp(String op, Map? payload) async {
    final notifier = _ref.read(playerProvider.notifier);
    switch (op) {
      case 'toggle':
        await notifier.toggle();
      case 'play':
        await notifier.resumeFromSystem();
      case 'pause':
        await notifier.pauseFromSystem();
      case 'next':
        await notifier.next();
      case 'prev':
        await notifier.previous();
      case 'favorite':
      case 'un_favorite':
        await _setFavorite(op == 'favorite');
      case 'seek':
        final secs = _num(payload, 'position', 'secs');
        if (secs != null) await notifier.seek(secs);
      case 'play_mode':
        // 仅循环切换（无精确档位设置接口，避免误操作）。
        await notifier.cyclePlayMode();
    }
  }

  /// 收藏/取消收藏为幂等操作：按目标状态判断是否需要切换。
  Future<void> _setFavorite(bool wantFav) async {
    final cur = _ref.read(playerProvider).current;
    if (cur == null) return;
    final currentlyFav = _ref.read(favoritesProvider).contains(cur.path);
    if (currentlyFav != wantFav) {
      await _ref.read(playerProvider.notifier).toggleFavoriteFromSystem();
    }
  }

  num? _num(Map? payload, String... keys) {
    if (payload == null) return null;
    for (final k in keys) {
      final v = payload[k];
      if (v is num) return v;
    }
    return null;
  }

  String _coverUrl(playerState) => '';
}

final watchControlProvider = Provider<WatchControlService>((ref) {
  final service = WatchControlService(ref);
  ref.onDispose(service.dispose);
  return service;
});