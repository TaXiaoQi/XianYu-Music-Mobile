import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/application_logger.dart';
import '../core/settings.dart';
import '../rust/api.dart';
import '../widgets/app_toast.dart';
import '../navigation/routes.dart';
import '../i18n/i18n.dart';
import 'player_provider.dart';

/// DLNA 投屏编排（Riverpod StateNotifier）。
///
/// - 发送端（DMC）：连接设备后，起播/切歌经 [PlayerNotifier] 的 cast 门控
///   调 [castMedia] 投到电视，本地引擎静默；1s 轮询电视传输状态回填进度，
///   兼任音量联动与远程直链 TTL 续投。
/// - 接收端（DMR）：渲染器开关由设置页控制（[applyRendererSetting]）；
///   Dart 侧长轮询 `dlna_dmr_next_command` 派发指令到本地播放器，
///   500ms 周期把本地播放快照回传 Rust（SOAP 状态应答）。
class CastState {
  /// idle 未连接 / connecting 连接中 / casting 投屏中。
  final String phase;

  /// 当前投屏设备（DlnaDevice JSON 原文，供命令透传）。
  final String? deviceJson;
  final String deviceName;
  final String deviceModel;
  final double tvPosition;
  final double tvDuration;

  /// UPnP 传输状态：PLAYING / PAUSED_PLAYBACK / STOPPED / NO_MEDIA_PRESENT。
  final String tvState;

  /// 渲染器（接收端）运行状态。
  final bool rendererRunning;
  final int rendererPort;
  final String rendererName;

  const CastState({
    this.phase = 'idle',
    this.deviceJson,
    this.deviceName = '',
    this.deviceModel = '',
    this.tvPosition = 0,
    this.tvDuration = 0,
    this.tvState = 'STOPPED',
    this.rendererRunning = false,
    this.rendererPort = 0,
    this.rendererName = '',
  });

  bool get isCasting => phase == 'casting' && deviceJson != null;

  /// 保留渲染器状态、清空投屏状态。
  CastState dropCast() => CastState(
        rendererRunning: rendererRunning,
        rendererPort: rendererPort,
        rendererName: rendererName,
      );

  CastState copyWith({
    String? phase,
    String? deviceJson,
    String? deviceName,
    String? deviceModel,
    double? tvPosition,
    double? tvDuration,
    String? tvState,
    bool? rendererRunning,
    int? rendererPort,
    String? rendererName,
  }) {
    return CastState(
      phase: phase ?? this.phase,
      deviceJson: deviceJson ?? this.deviceJson,
      deviceName: deviceName ?? this.deviceName,
      deviceModel: deviceModel ?? this.deviceModel,
      tvPosition: tvPosition ?? this.tvPosition,
      tvDuration: tvDuration ?? this.tvDuration,
      tvState: tvState ?? this.tvState,
      rendererRunning: rendererRunning ?? this.rendererRunning,
      rendererPort: rendererPort ?? this.rendererPort,
      rendererName: rendererName ?? this.rendererName,
    );
  }
}

/// 远程直链 TTL 主动续投阈值（毫秒，直链 10min 过期，提前 1.5min 续）。
const int _ttlRefreshMs = 510000;

/// 局域网组播锁 MethodChannel（SSDP 发现必需，渲染器开启期间持续持有）。
const MethodChannel _dlnaChannel = MethodChannel('xianyu/dlna');

/// 渲染器 UDN 持久化 key：跨重启保持设备身份稳定（局域网控制端缓存不失效）。
const String _kRendererUdn = 'dlna.renderer.udn';

class CastNotifier extends StateNotifier<CastState> {
  CastNotifier(this._ref) : super(const CastState());

  final Ref _ref;

  Timer? _pollTimer;
  Timer? _reportTimer;
  bool _dmrLoopRunning = false;
  int _consecutiveErrors = 0;
  int _lastVolumeSent = -1;

  // 投屏媒体上下文（TTL 续投用）。
  String _mediaToken = '';
  String _mediaUrl = '';
  Map<String, String> _mediaHeaders = {};
  bool _mediaIsRemote = false;
  int _resolvedAtMs = 0;

  // ---------------- 设备发现 ----------------

  /// 扫描局域网 DLNA 渲染器，返回设备 JSON 列表（含友好名/型号/控制端点）。
  Future<List<Map<String, dynamic>>> scanDevices({int timeoutMs = 2500}) async {
    final json = await dlnaSearchDevices(timeoutMs: BigInt.from(timeoutMs));
    final list = jsonDecode(json) as List;
    return list
        .map((e) => (e as Map).cast<String, dynamic>())
        .where((e) => (e['friendly_name'] as String? ?? '').isNotEmpty)
        .toList();
  }

  // ---------------- 发送端（DMC） ----------------

  /// 连接设备：记下设备并静默本地引擎（后续由用户点播/切歌自动跟投）。
  Future<void> connect(Map<String, dynamic> dev) async {
    state = state.copyWith(
      phase: 'connecting',
      deviceJson: jsonEncode(dev),
      deviceName: dev['friendly_name'] as String? ?? 'DLNA',
      deviceModel: dev['model_name'] as String? ?? '',
    );
    try {
      final player = _ref.read(playerProvider.notifier);
      if (_ref.read(playerProvider).isPlaying) {
        await player.pauseLocalEngine();
      }
      _consecutiveErrors = 0;
      state = state.copyWith(
        phase: 'casting',
        tvPosition: 0,
        tvDuration: 0,
        tvState: 'NO_MEDIA_PRESENT',
      );
      _startPolling();
    } catch (e) {
      state = state.dropCast();
      rethrow;
    }
  }

  /// 断开投屏（[stopTv] 为 true 时向电视发 Stop）。
  Future<void> disconnect({bool stopTv = true}) async {
    _stopPolling();
    final dev = state.deviceJson;
    state = state.dropCast();
    if (dev != null && stopTv) {
      try {
        await dlnaCastStop(deviceJson: dev);
      } catch (_) {}
    }
  }

  /// 投递一首已解析好的媒体到电视（SetAVTransportURI + Play，可带起始位置）。
  ///
  /// 由 [PlayerNotifier] 的 cast 门控在解析直链后调用；调用方需保证本地
  /// 引擎已静默（[PlayerNotifier.pauseLocalEngine]）。
  Future<void> castMedia({
    required String title,
    required String artist,
    required String album,
    required String url,
    required bool isRemote,
    Map<String, String> headers = const {},
    int durationMs = 0,
    double startAtSecs = 0,
    String? coverUrl,
  }) async {
    final dev = state.deviceJson;
    if (dev == null) throw StateError(tr('未连接投屏设备'));
    _mediaIsRemote = isRemote;
    _mediaUrl = url;
    _mediaHeaders = headers;
    _resolvedAtMs = DateTime.now().millisecondsSinceEpoch;

    final mediaJson = isRemote
        ? jsonEncode(<String, dynamic>{
            'kind': 'remote',
            'url': url,
            'headers': headers,
            'resolved_at_ms': _resolvedAtMs,
          })
        : jsonEncode(<String, dynamic>{'kind': 'local', 'path': url});
    final cover = (coverUrl != null && coverUrl.startsWith('http'))
        ? jsonEncode(<String, dynamic>{'kind': 'cover', 'url': coverUrl})
        : null;
    final infoJson = await dlnaCastSetUri(
      deviceJson: dev,
      mediaJson: mediaJson,
      coverJson: cover,
      title: title,
      artist: artist,
      album: album,
      durationMs: BigInt.from(durationMs < 0 ? 0 : durationMs),
    );
    final info = jsonDecode(infoJson) as Map<String, dynamic>;
    _mediaToken = info['media_token'] as String? ?? '';

    await dlnaCastPlay(deviceJson: dev);
    // 恢复播放（toggle）或带起始位置投歌时，投完先 seek。
    final startSec = startAtSecs < 0 ? 0.0 : startAtSecs;
    if (startSec > 0.5) {
      try {
        await dlnaCastSeek(deviceJson: dev, secs: startSec);
      } catch (_) {}
    }
    _lastVolumeSent = -1;
    _consecutiveErrors = 0;
    state = state.copyWith(
      phase: 'casting',
      tvPosition: startSec,
      tvDuration: durationMs / 1000.0,
      tvState: 'PLAYING',
    );
    _startPolling();
  }

  Future<void> castResume() async {
    final dev = state.deviceJson;
    if (dev == null) return;
    try {
      await dlnaCastPlay(deviceJson: dev);
    } catch (_) {}
  }

  Future<void> castPause() async {
    final dev = state.deviceJson;
    if (dev == null) return;
    try {
      await dlnaCastPause(deviceJson: dev);
    } catch (_) {}
  }

  Future<void> castSeek(double secs) async {
    final dev = state.deviceJson;
    if (dev == null) return;
    await dlnaCastSeek(deviceJson: dev, secs: secs < 0 ? 0 : secs);
    await _pollOnce();
  }

  /// 音量联动：设置页/播放条音量变化时同步到电视（轮询周期内检测差量）。
  Future<void> _pushVolumeIfChanged() async {
    final dev = state.deviceJson;
    if (dev == null) return;
    final vol = _ref.read(volumeProvider);
    final percent = (vol.clamp(0.0, 1.0) * 100).round();
    if (percent == _lastVolumeSent) return;
    _lastVolumeSent = percent;
    try {
      await dlnaCastSetVolume(deviceJson: dev, percent: percent);
    } catch (_) {}
  }

  // ---------------- 状态轮询 ----------------

  void _startPolling() {
    if (_pollTimer != null) return;
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(_pollOnce());
    });
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<void> _pollOnce() async {
    final dev = state.deviceJson;
    if (dev == null) {
      _stopPolling();
      return;
    }
    try {
      final stJson = await dlnaCastGetState(deviceJson: dev);
      final st = jsonDecode(stJson) as Map<String, dynamic>;
      _consecutiveErrors = 0;
      final pos = (st['position_secs'] as num? ?? 0).toDouble();
      final dur = (st['duration_secs'] as num? ?? 0).toDouble();
      final tvState = st['state'] as String? ?? 'STOPPED';
      final playing = tvState == 'PLAYING';
      state = state.copyWith(
        tvPosition: pos < 0 ? 0 : pos,
        tvDuration: dur < 0 ? 0 : dur,
        tvState: tvState,
      );
      // 回填播放页/播放条进度（本地引擎静默，进度以电视为准）。
      _ref.read(playerProvider.notifier).syncCastPosition(pos, dur, playing);
      unawaited(_pushVolumeIfChanged());

      // [TTL 续投] 远程直链接近过期时热替换注册表上游（电视不断流）。
      if (_mediaIsRemote &&
          _mediaToken.isNotEmpty &&
          DateTime.now().millisecondsSinceEpoch - _resolvedAtMs >
              _ttlRefreshMs) {
        try {
          final refreshed = await dlnaUpdateMediaToken(
            token: _mediaToken,
            payloadJson: jsonEncode(<String, dynamic>{
              'kind': 'remote',
              'url': _mediaUrl,
              'headers': _mediaHeaders,
              'resolved_at_ms': DateTime.now().millisecondsSinceEpoch,
            }),
          );
          if (refreshed) _resolvedAtMs = DateTime.now().millisecondsSinceEpoch;
        } catch (_) {}
      }
    } catch (e) {
      _consecutiveErrors += 1;
      if (_consecutiveErrors >= 6) {
        AppLog.warn('dlna', '投屏设备连接断开: $e');
        _stopPolling();
        state = state.dropCast();
        final overlay = appNavigatorKey.currentState?.overlay;
        if (overlay != null) {
          showXianYuToastByOverlay(overlay, tr('投屏设备连接已断开'));
        }
      }
    }
  }

  // ---------------- 接收端（DMR） ----------------

  /// 渲染器 UDN 持久化：跨重启保持设备身份稳定（局域网控制端缓存不失效）。
  Future<String> _rendererUdn() async {
    final prefs = await SharedPreferences.getInstance();
    var udn = prefs.getString(_kRendererUdn);
    if (udn == null || udn.isEmpty) {
      final rnd = Random();
      String hex4() =>
          (rnd.nextInt(0x10000) | 0x10000).toRadixString(16).substring(1);
      String hex8() =>
          (rnd.nextInt(0x100000000) | 0x100000000).toRadixString(16).substring(1);
      udn = 'uuid:${hex8()}-${hex4()}-4${hex4().substring(1)}'
          '-${['8', '9', 'a', 'b'][rnd.nextInt(4)]}${hex4().substring(1)}'
          '-${hex8()}${hex4()}';
      await prefs.setString(_kRendererUdn, udn);
    }
    return udn;
  }

  /// 依据设置项同步渲染器启停（启动恢复 + 设置页开关共用；名称变更时幂等重建）。
  Future<void> applyRendererSetting() async {
    final s = _ref.read(settingsProvider).valueOrNull;
    final enabled = s?.dlnaRendererEnabled ?? false;
    final name = (s?.dlnaRendererName ?? '').trim().isEmpty
        ? tr('弦予音乐')
        : (s?.dlnaRendererName ?? '').trim();
    try {
      if (enabled) {
        // 已在运行即跳过（设置加载/变化会多次触发本方法；名称变更走 rebuild）。
        if (state.rendererRunning) return;
        final port = await _enableRenderer(name);
        state = state.copyWith(
          rendererRunning: true,
          rendererPort: port,
          rendererName: name,
        );
      } else {
        if (!state.rendererRunning) return;
        await _disableRenderer();
        state = state.copyWith(rendererRunning: false, rendererPort: 0);
      }
    } catch (e) {
      AppLog.error('dlna', '渲染器启停失败: $e');
      state = state.copyWith(rendererRunning: false, rendererPort: 0);
    }
  }

  /// 名称变更时幂等重建（仅运行中调用有意义）。
  Future<void> rebuildRendererIfRunning() async {
    if (!state.rendererRunning) return;
    try {
      await _disableRenderer();
    } catch (_) {}
    await applyRendererSetting();
  }

  Future<int> _enableRenderer(String name) async {
    // Android 组播锁：SSDP NOTIFY/应答依赖组播接收，开启期间持续持有。
    try {
      await _dlnaChannel.invokeMethod<void>('acquireMulticast');
    } catch (_) {}
    final udn = await _rendererUdn();
    final port = await dlnaEnableRenderer(friendlyName: name, udn: udn);
    unawaited(_dmrLoop());
    _startReportTimer();
    return port;
  }

  Future<void> _disableRenderer() async {
    _stopReportTimer();
    await dlnaDisableRenderer();
    try {
      await _dlnaChannel.invokeMethod<void>('releaseMulticast');
    } catch (_) {}
  }

  /// 长轮询 DMR 指令循环（渲染器运行期间常驻）。
  Future<void> _dmrLoop() async {
    if (_dmrLoopRunning) return;
    _dmrLoopRunning = true;
    try {
      while (state.rendererRunning) {
        String? cmdJson;
        try {
          cmdJson = await dlnaDmrNextCommand(timeoutMs: BigInt.from(15000));
        } catch (_) {
          // Rust 调用失败（引擎重启等）：稍后重试。
          await Future<void>.delayed(const Duration(seconds: 2));
          continue;
        }
        if (cmdJson == null) continue;
        try {
          await _handleDmrCommand(cmdJson);
        } catch (e) {
          AppLog.warn('dlna', 'DMR 指令执行失败: $e');
        }
      }
    } finally {
      _dmrLoopRunning = false;
    }
  }

  Future<void> _handleDmrCommand(String cmdJson) async {
    final cmd = jsonDecode(cmdJson) as Map<String, dynamic>;
    final type = cmd['type'] as String? ?? '';
    switch (type) {
      case 'loadUri':
        // 仅接受 http(s) 直链（第三方音源直链均为该形态）。
        final uri = (cmd['uri'] as String? ?? '').trim();
        if (!uri.startsWith('http://') && !uri.startsWith('https://')) return;
        final player = _ref.read(playerProvider.notifier);
        // 他端投入本端时若正投给电视，先断开投屏，转为本地播放。
        if (state.isCasting) await disconnect(stopTv: false);
        await player.playExternalUri(
          uri: uri,
          title: cmd['title'] as String? ?? '',
          artist: cmd['artist'] as String? ?? '',
          album: cmd['album'] as String? ?? '',
          durationMs: (cmd['duration_ms'] as num? ?? 0).toInt(),
        );
        break;
      case 'play':
      case 'pause':
      case 'stop':
      case 'seek':
      case 'setVolume':
      case 'setMute':
        // 本端正作为遥控器投给电视时，忽略入站传输/音量指令（避免双端互相拉扯）。
        if (state.isCasting) return;
        final player = _ref.read(playerProvider.notifier);
        switch (type) {
          case 'play':
            await player.resumeFromSystem();
            break;
          case 'pause':
          case 'stop':
            await player.pauseFromSystem();
            break;
          case 'seek':
            final secs = (cmd['secs'] as num? ?? 0).toDouble();
            if (secs > 0) await player.seek(secs);
            break;
          case 'setVolume':
            final percent = (cmd['percent'] as num? ?? 0).clamp(0, 100).toInt();
            await _ref.read(settingsProvider.notifier).setVolume(percent / 100.0);
            break;
          case 'setMute':
            // 本端无独立静音通道：静音=0 音量，取消静音恢复 100。
            await _ref
                .read(settingsProvider.notifier)
                .setVolume((cmd['on'] as bool? ?? false) ? 0.0 : 1.0);
            break;
        }
        break;
    }
  }

  /// 500ms 周期把本地播放快照回传 Rust（DMR SOAP GetPosition/GetTransport 应答）。
  void _startReportTimer() {
    if (_reportTimer != null) return;
    _reportTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      unawaited(_reportPlayback());
    });
  }

  void _stopReportTimer() {
    _reportTimer?.cancel();
    _reportTimer = null;
  }

  Future<void> _reportPlayback() async {
    final st = _ref.read(playerProvider);
    final String reportState;
    if (st.current == null) {
      reportState = 'no_media';
    } else if (st.isPlaying) {
      reportState = 'playing';
    } else {
      reportState = 'paused';
    }
    final vol = _ref.read(volumeProvider);
    try {
      await dlnaDmrReportPlayback(
        state: reportState,
        positionSecs: st.position,
        durationSecs: st.duration,
        volumePercent: (vol.clamp(0.0, 1.0) * 100).round(),
        muted: false,
      );
    } catch (_) {}
  }

  @override
  void dispose() {
    _stopPolling();
    _stopReportTimer();
    super.dispose();
  }
}

final dlnaCastProvider =
    StateNotifierProvider<CastNotifier, CastState>((ref) => CastNotifier(ref));
