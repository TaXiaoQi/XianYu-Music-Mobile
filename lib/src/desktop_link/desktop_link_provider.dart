// 桌面联动：移动端作 TCP client，经桌面控制通道（WatchLink 同款帧协议）遥控桌面端。
// 发现：SSDP M-SEARCH 搜自家 ST（urn:xianyu-music:control:1，纯 Dart RawDatagramSocket）
// + TCP 直连扫描 /24 兜底（组播被吞的环境仍可发现），手动 IP:端口 再兜底；
// 鉴权：首配 6 位配对码换 token，安全存储持久化
// （Keystore/Keychain，不可用时回退 SharedPreferences 并自动迁移旧明文键），
// 启动自动重连（指数退避），10s 心跳保活。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/application_logger.dart';
import '../core/secure_store.dart';
import '../i18n/i18n.dart';
import '../watch_link/protocol.dart';

/// 桌面端 SSDP 通告的服务类型（与桌面 control_channel/discovery.rs 对齐）。
const String kDesktopLinkControlSt = 'urn:xianyu-music:control:1';

const String _prefsHostKey = 'desktopLink.host';
const String _prefsPortKey = 'desktopLink.port';
const String _prefsTokenKey = 'desktopLink.token';

const Duration _handshakeTimeout = Duration(seconds: 10);
const Duration _heartbeatInterval = Duration(seconds: 10);
const Duration _connectTimeout = Duration(seconds: 5);
const Duration _maxBackoff = Duration(seconds: 60);
const Duration _scanWindow = Duration(milliseconds: 2500);

enum DesktopLinkPhase { idle, connecting, pairing, connected, reconnecting }

/// SSDP 扫描发现的桌面端候选。
class DesktopCandidate {
  const DesktopCandidate({required this.host, required this.port, required this.name});

  final String host;
  final int port;
  final String name;
}

class DesktopLinkState {
  const DesktopLinkState({
    this.phase = DesktopLinkPhase.idle,
    this.scanning = false,
    this.scanResults = const [],
    this.desktopName = '',
    this.host = '',
    this.port = 0,
    this.hasSavedTarget = false,
    this.message = '',
    this.remotePlaying = false,
    this.remoteVolume = 0,
    this.remoteTitle = '',
    this.remoteArtist = '',
    this.remotePosition = 0,
    this.remoteDuration = 0,
  });

  final DesktopLinkPhase phase;
  final bool scanning;
  final List<DesktopCandidate> scanResults;
  final String desktopName;
  final String host;
  final int port;
  final bool hasSavedTarget;
  /// 用户可读的最近一次错误/提示（已 tr 本地化）。
  final String message;

  // 远端（桌面端）播放状态，由 state/nowPlaying/position 帧驱动。
  final bool remotePlaying;
  final double remoteVolume;
  final String remoteTitle;
  final String remoteArtist;
  final double remotePosition;
  final double remoteDuration;

  DesktopLinkState copyWith({
    DesktopLinkPhase? phase,
    bool? scanning,
    List<DesktopCandidate>? scanResults,
    String? desktopName,
    String? host,
    int? port,
    bool? hasSavedTarget,
    String? message,
    bool? remotePlaying,
    double? remoteVolume,
    String? remoteTitle,
    String? remoteArtist,
    double? remotePosition,
    double? remoteDuration,
  }) =>
      DesktopLinkState(
        phase: phase ?? this.phase,
        scanning: scanning ?? this.scanning,
        scanResults: scanResults ?? this.scanResults,
        desktopName: desktopName ?? this.desktopName,
        host: host ?? this.host,
        port: port ?? this.port,
        hasSavedTarget: hasSavedTarget ?? this.hasSavedTarget,
        message: message ?? this.message,
        remotePlaying: remotePlaying ?? this.remotePlaying,
        remoteVolume: remoteVolume ?? this.remoteVolume,
        remoteTitle: remoteTitle ?? this.remoteTitle,
        remoteArtist: remoteArtist ?? this.remoteArtist,
        remotePosition: remotePosition ?? this.remotePosition,
        remoteDuration: remoteDuration ?? this.remoteDuration,
      );
}

class DesktopLinkNotifier extends StateNotifier<DesktopLinkState> {
  DesktopLinkNotifier() : super(const DesktopLinkState()) {
    _bootstrap();
  }

  FrameDecoder _decoder = FrameDecoder();
  final int Function() _nextSeq = makeSeqGenerator();

  Socket? _socket;
  StreamSubscription<Uint8List>? _socketSub;
  Timer? _heartbeat;
  Timer? _handshakeTimer;
  Timer? _reconnectTimer;
  int _backoffStep = 0;

  /// 主动断开/忘记后不再自动重连，直到下一次显式 connect。
  bool _suppressReconnect = false;

  Future<void> _bootstrap() async {
    final prefs = await SharedPreferences.getInstance();
    final host = prefs.getString(_prefsHostKey) ?? '';
    final port = prefs.getInt(_prefsPortKey) ?? 0;
    if (host.isEmpty || port <= 0) return;
    state = state.copyWith(hasSavedTarget: true);
    // 启动自动重连（静默，不打扰用户）
    unawaited(connect(host: host, port: port, silent: true));
  }

  // ---------------- 连接 ----------------

  /// 连接桌面端。已持有 token 则直接鉴权；否则需 [pairingCode] 首配。
  /// [silent] 为启动自动重连：失败走静默退避，不覆盖用户可见文案。
  Future<void> connect({
    required String host,
    required int port,
    String? pairingCode,
    bool silent = false,
  }) async {
    if (state.phase == DesktopLinkPhase.connected && host == state.host && port == state.port) {
      return;
    }
    _teardown(keepTarget: true);
    _suppressReconnect = false;
    state = state.copyWith(
      phase: DesktopLinkPhase.connecting,
      host: host,
      port: port,
      message: silent ? state.message : '',
    );

    final token = pairingCode == null || pairingCode.isEmpty
        ? await SecureStore.read(_prefsTokenKey, legacyPrefsKey: _prefsTokenKey)
        : null;

    try {
      final socket = await Socket.connect(
        host,
        port,
        timeout: _connectTimeout,
      );
      if (_suppressReconnect || state.phase == DesktopLinkPhase.idle) {
        socket.destroy();
        return;
      }
      _socket = socket;
      _decoder = FrameDecoder();
      _socketSub = socket.listen(
        _onData,
        onError: (_) => _onLinkLost(),
        onDone: _onLinkLost,
      );
      state = state.copyWith(
        phase: DesktopLinkPhase.connecting,
        host: host,
        port: port,
        hasSavedTarget: true,
      );
      await _saveTarget(host, port);

      final hello = LinkMessage.hello(
        ver: kLinkProtocolVersion,
        role: 'remote',
        name: '弦予音乐',
      );
      if (pairingCode != null && pairingCode.isNotEmpty) {
        hello.payload['pairing_code'] = pairingCode;
      } else if (token != null && token.isNotEmpty) {
        hello.payload['token'] = token;
      }
      _send(hello);
      _handshakeTimer = Timer(_handshakeTimeout, () {
        if (state.phase != DesktopLinkPhase.connected) {
          _onLinkLost();
        }
      });
    } catch (e) {
      if (silent) {
        _scheduleReconnect();
      } else {
        state = state.copyWith(
          phase: DesktopLinkPhase.idle,
          message: tr('连接失败，请检查地址与网络'),
        );
      }
    }
  }

  void _onData(Uint8List bytes) {
    for (final msg in _decoder.feed(bytes)) {
      _onMessage(msg);
    }
  }

  void _onMessage(LinkMessage msg) {
    switch (msg.type) {
      case LinkMsgType.hello:
        final auth = (msg.payload['auth'] as String?) ?? '';
        if (auth == 'ok') {
          _handshakeTimer?.cancel();
          _handshakeTimer = null;
          final token = msg.payload['token'] as String?;
          if (token != null && token.isNotEmpty) {
            _saveToken(token);
          }
          state = state.copyWith(
            phase: DesktopLinkPhase.connected,
            desktopName: (msg.payload['name'] as String?) ?? '',
            message: '',
          );
          _backoffStep = 0;
          _startHeartbeat();
        } else {
          _handshakeTimer?.cancel();
          _handshakeTimer = null;
          _teardown(keepTarget: true);
          // token 失效（被忘记/被挤掉），要求重新配对
          _clearToken();
          state = state.copyWith(
            phase: DesktopLinkPhase.pairing,
            message: tr('需要配对码，请在桌面端「设置 → 桌面联动」查看'),
          );
        }
      case LinkMsgType.ping:
        _send(LinkMessage(LinkMsgType.pong, {'t': msg.payload['t']}));
      case LinkMsgType.pong:
        break;
      case LinkMsgType.state:
        state = state.copyWith(
          remotePlaying: msg.payload['isPlaying'] == true,
          remoteVolume: _asDouble(msg.payload['volume']),
        );
      case LinkMsgType.nowPlaying:
        state = state.copyWith(
          remoteTitle: (msg.payload['title'] as String?) ?? '',
          remoteArtist: (msg.payload['artist'] as String?) ?? '',
          remoteDuration: _asDouble(msg.payload['duration']),
          remotePosition: 0,
        );
      case LinkMsgType.position:
        state = state.copyWith(
          remotePosition: _asDouble(msg.payload['pos']),
          remoteDuration: _asDouble(msg.payload['duration']),
        );
      case LinkMsgType.bye:
        _onLinkLost();
      default:
        break;
    }
  }

  // ---------------- 心跳与重连 ----------------

  void _startHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(_heartbeatInterval, (_) {
      _send(LinkMessage(LinkMsgType.ping,
          {'t': DateTime.now().millisecondsSinceEpoch}));
    });
  }

  void _onLinkLost() {
    _handshakeTimer?.cancel();
    _handshakeTimer = null;
    _heartbeat?.cancel();
    _heartbeat = null;
    _socketSub?.cancel();
    _socketSub = null;
    _socket?.destroy();
    _socket = null;
    if (_suppressReconnect || !mounted) return;
    if (state.phase == DesktopLinkPhase.idle) return;
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    final hadConnected = state.desktopName.isNotEmpty;
    state = state.copyWith(
      phase: DesktopLinkPhase.reconnecting,
      message: hadConnected ? state.message : '',
    );
    _reconnectTimer?.cancel();
    final delay = Duration(
      seconds: (2 << _backoffStep.clamp(0, 5)).clamp(2, _maxBackoff.inSeconds),
    );
    _backoffStep += 1;
    _reconnectTimer = Timer(delay, () {
      if (_suppressReconnect || !mounted) return;
      unawaited(connect(
        host: state.host,
        port: state.port,
        silent: true,
      ));
    });
  }

  // ---------------- 遥控指令 ----------------

  void sendCmd(String action, [Map<String, dynamic>? arg]) {
    if (state.phase != DesktopLinkPhase.connected) return;
    _send(LinkMessage.cmd(action, arg));
  }

  /// 腕上中继入口：把腕表遥控指令原样转发给桌面端。
  bool relayCmd(LinkMessage cmdMsg) {
    if (state.phase != DesktopLinkPhase.connected) return false;
    _send(cmdMsg);
    return true;
  }

  // ---------------- 发现 ----------------

  Future<void> scan() async {
    if (state.scanning) return;
    state = state.copyWith(scanning: true, scanResults: const []);
    try {
      // SSDP 组播与 TCP 直连扫描并行；部分手机/路由会吞组播（Android 组播
      // 路由、AP 隔离、双频不互转），TCP 直连完全不依赖组播，必有一条走通。
      final both = await Future.wait<List<DesktopCandidate>>([
        _ssdpScan(),
        _tcpSweep(),
      ]);
      final found = <String, DesktopCandidate>{};
      for (final c in both.expand((l) => l)) {
        found['${c.host}:${c.port}'] = c;
      }
      final results = found.values.toList()
        ..sort((a, b) => a.name.compareTo(b.name));
      state = state.copyWith(scanning: false, scanResults: results);
    } catch (_) {
      state = state.copyWith(
        scanning: false,
        message: tr('扫描失败，请确认手机与电脑在同一网络'),
      );
    }
  }

  /// SSDP 组播发现（读 XY-CONTROL/XY-NAME 自定义头识别本家族桌面端）。
  Future<List<DesktopCandidate>> _ssdpScan() async {
    RawDatagramSocket? socket;
    try {
      socket = await _bindScanSocket();
      final found = <String, DesktopCandidate>{};
      final packet = _mSearchPacket();
      final target = InternetAddress('239.255.255.250');
      final sub = socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final dg = socket!.receive();
        if (dg == null) return;
        final candidate = _parseSsdpReply(utf8.decode(dg.data, allowMalformed: true));
        if (candidate != null) {
          found['${candidate.host}:${candidate.port}'] = candidate;
        }
      });
      // 发两轮提升可靠性（SSDP 是 UDP，允许丢包）
      socket.send(utf8.encode(packet), target, 1900);
      Timer(const Duration(milliseconds: 400), () {
        try {
          socket?.send(utf8.encode(packet), target, 1900);
        } catch (e) {
          AppLog.debug('link', 'SSDP 二次探测发送失败: $e');
        }
      });
      await Future<void>.delayed(_scanWindow);
      sub.cancel();
      return found.values.toList();
    } catch (_) {
      return const [];
    } finally {
      socket?.close();
    }
  }

  /// 优先绑到 WLAN 所在私网地址：Android 上绑 anyIPv4 时组播常从蜂窝接口
  /// 发出导致 M-SEARCH 出不了局域网，绑具体地址强制走对网卡。
  Future<RawDatagramSocket> _bindScanSocket() async {
    final lan = await _privateLanAddress();
    if (lan != null) {
      try {
        return await RawDatagramSocket.bind(InternetAddress(lan), 0);
      } catch (_) {
        // 个别机型拒绝绑具体地址，回退通配
      }
    }
    return RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  }

  /// 本机私网 IPv4（10.x / 172.16-31.x / 192.168.x），无则 null。
  Future<String?> _privateLanAddress() async {
    try {
      final list = await NetworkInterface.list(
        includeLoopback: false,
        includeLinkLocal: false,
        type: InternetAddressType.IPv4,
      );
      for (final addr in list.expand((i) => i.addresses)) {
        final o = addr.address.split('.');
        if (o.length != 4) continue;
        final a = int.tryParse(o[0]) ?? 0;
        final b = int.tryParse(o[1]) ?? -1;
        final priv = a == 10 ||
            (a == 172 && b >= 16 && b <= 31) ||
            (a == 192 && b == 168);
        if (priv) return addr.address;
      }
    } catch (_) {}
    return null;
  }

  /// TCP 直连扫描兜底：对所在 /24 私网逐个连桌面控制端口（9979 主端口；
  /// 端口顺延属罕见场景，仍由 SSDP/手动连接覆盖），并发探测约 1s。
  Future<List<DesktopCandidate>> _tcpSweep() async {
    final lan = await _privateLanAddress();
    if (lan == null) return const [];
    final o = lan.split('.').map(int.parse).toList();
    final probes = <Future<DesktopCandidate?>>[];
    for (var i = 1; i <= 254; i++) {
      probes.add(_probeDesktop('${o[0]}.${o[1]}.${o[2]}.$i', 9979));
    }
    final out = <DesktopCandidate>[];
    for (final c in await Future.wait(probes)) {
      if (c != null) out.add(c);
    }
    return out;
  }

  /// 探测单个地址：TCP 连上后发无凭据 hello，凭桌面端握手应答识别。
  /// 未配对探测只收到 auth=bad_token 的 hello 即被断开，不留任何状态。
  Future<DesktopCandidate?> _probeDesktop(String host, int port) async {
    Socket? sock;
    try {
      sock = await Socket.connect(
        host,
        port,
        timeout: const Duration(milliseconds: 350),
      );
      final decoder = FrameDecoder();
      final reply = Completer<LinkMessage?>();
      final sub = sock.listen((data) {
        if (reply.isCompleted) return;
        for (final msg in decoder.feed(data)) {
          if (msg.type == LinkMsgType.hello && !reply.isCompleted) {
            reply.complete(msg);
          }
        }
      }, onDone: () {
        if (!reply.isCompleted) reply.complete(null);
      }, onError: (_) {
        if (!reply.isCompleted) reply.complete(null);
      });
      final gen = makeSeqGenerator();
      for (final frame in encodeFrames(
        LinkMessage.hello(ver: kLinkProtocolVersion, role: 'remote', name: '弦予音乐'),
        nextSeq: gen,
      )) {
        sock.add(frame);
      }
      final msg = await reply.future
          .timeout(const Duration(milliseconds: 800), onTimeout: () => null);
      sub.cancel();
      if (msg == null) return null;
      final name = (msg.payload['name'] as String?) ?? '';
      return DesktopCandidate(
        host: host,
        port: port,
        name: name.isEmpty ? '$host:$port' : name,
      );
    } catch (_) {
      return null;
    } finally {
      sock?.destroy();
    }
  }

  String _mSearchPacket() =>
      'M-SEARCH * HTTP/1.1\r\n'
      'HOST: 239.255.255.250:1900\r\n'
      'MAN: "ssdp:discover"\r\n'
      'MX: 2\r\n'
      'ST: $kDesktopLinkControlSt\r\n'
      '\r\n';

  DesktopCandidate? _parseSsdpReply(String reply) {
    if (!reply.startsWith('HTTP/1.1 200')) return null;
    String? control;
    String? name;
    for (final line in reply.split('\r\n')) {
      final idx = line.indexOf(':');
      if (idx <= 0) continue;
      final key = line.substring(0, idx).trim().toUpperCase();
      final value = line.substring(idx + 1).trim();
      if (key == 'XY-CONTROL') {
        control = value;
      } else if (key == 'XY-NAME') {
        name = value;
      }
    }
    if (control == null || control.isEmpty) return null;
    final parts = control.split(':');
    if (parts.length < 2) return null;
    final host = parts[0];
    final port = int.tryParse(parts[1]);
    if (host.isEmpty || port == null || port <= 0) return null;
    return DesktopCandidate(
      host: host,
      port: port,
      name: (name == null || name.isEmpty) ? '$host:$port' : name,
    );
  }

  // ---------------- 断开/忘记 ----------------

  /// 主动断开（不自动重连）。
  void disconnect() {
    _suppressReconnect = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _send(LinkMessage(LinkMsgType.bye, {}));
    _teardown(keepTarget: true);
    state = state.copyWith(
      phase: DesktopLinkPhase.idle,
      desktopName: '',
      remoteTitle: '',
      remoteArtist: '',
      remotePosition: 0,
      remoteDuration: 0,
      remotePlaying: false,
    );
  }

  /// 忘记配对：清空 host/port/token 并断开。
  Future<void> forgetTarget() async {
    disconnect();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsHostKey);
    await prefs.remove(_prefsPortKey);
    await _clearToken();
    state = state.copyWith(
      hasSavedTarget: false,
      host: '',
      port: 0,
      desktopName: '',
    );
  }

  // ---------------- 内部 ----------------

  void _send(LinkMessage msg) {
    final socket = _socket;
    if (socket == null) return;
    try {
      for (final frame in encodeFrames(msg, nextSeq: _nextSeq)) {
        socket.add(frame);
      }
    } catch (_) {
      _onLinkLost();
    }
  }

  Future<void> _saveTarget(String host, int port) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsHostKey, host);
    await prefs.setInt(_prefsPortKey, port);
  }

  Future<void> _saveToken(String token) async {
    await SecureStore.write(_prefsTokenKey, token);
  }

  Future<void> _clearToken() async {
    await SecureStore.delete(_prefsTokenKey, legacyPrefsKey: _prefsTokenKey);
  }

  /// 关闭链路；[keepTarget] 表示保留已保存的连接目标（重连场景）。
  void _teardown({required bool keepTarget}) {
    _heartbeat?.cancel();
    _heartbeat = null;
    _handshakeTimer?.cancel();
    _handshakeTimer = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _socketSub?.cancel();
    _socketSub = null;
    _socket?.destroy();
    _socket = null;
    if (!keepTarget) {
      state = state.copyWith(hasSavedTarget: false, host: '', port: 0);
    }
  }

  double _asDouble(Object? v) =>
      v is num ? v.toDouble() : 0;

  @override
  void dispose() {
    _suppressReconnect = true;
    _send(LinkMessage(LinkMsgType.bye, {}));
    _teardown(keepTarget: false);
    super.dispose();
  }
}

final desktopLinkProvider =
    StateNotifierProvider<DesktopLinkNotifier, DesktopLinkState>((ref) {
  return DesktopLinkNotifier();
});
