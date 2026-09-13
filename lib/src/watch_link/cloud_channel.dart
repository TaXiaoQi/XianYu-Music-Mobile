import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 手机端云端中继事件。
class CloudLinkEvent {
  const CloudLinkEvent._(this.kind, {this.peerName = ''});

  /// 手表已上线（可推送状态帧）。
  static const ready = 'ready';

  /// 手表离线（连接仍在，等待手表重连）。
  static const peerLost = 'peer_lost';

  /// 本连接被同 key 的新连接替换（服务端踢旧留新）。
  static const replaced = 'replaced';

  /// 底层连接断开（网络故障/服务端不可达）。
  static const closed = 'closed';

  final String kind;
  final String peerName;
}

/// 手机端云端中继客户端（对应服务端 `/watch-relay`，role=phone）。
///
/// 与手表端 `XianYu-Music-Watch/lib/src/link/cloud_client.dart` 为同一协议的对端：
/// XYW1 帧字节原样走 WS Binary；WS Text 仅承载链路控制（hello/ready/peer_lost/replaced）。
/// 重连节奏由上层 `watch_link_provider` 控制（5s→60s 退避）。
class WatchCloudChannel {
  WebSocket? _ws;
  StreamSubscription<dynamic>? _sub;
  bool _closed = true;

  final _rawCtrl = StreamController<Uint8List>.broadcast();
  final _eventCtrl = StreamController<CloudLinkEvent>.broadcast();

  /// 手表经云端送来的 XYW1 帧字节流。
  Stream<Uint8List> get onRaw => _rawCtrl.stream;

  /// 链路事件。
  Stream<CloudLinkEvent> get onEvent => _eventCtrl.stream;

  bool get isConnected => !_closed && _ws != null;

  /// 连接中继服务（role=phone）。成败经 [onEvent] 回传。
  Future<void> connect({
    required String url,
    required String key,
    String name = '弦予音乐',
  }) async {
    await close();
    _closed = false;
    try {
      final ws = await WebSocket.connect(url).timeout(
            const Duration(seconds: 8),
            onTimeout: () => throw TimeoutException('relay connect timeout'),
          );
      _ws = ws;
      ws.add(jsonEncode({
        'op': 'hello',
        'role': 'phone',
        'key': key,
        'name': name,
      }));
      _sub = ws.listen(
        (data) {
          if (data is String) {
            _onText(data);
          } else if (data is List<int> && data.isNotEmpty) {
            _rawCtrl.add(data is Uint8List ? data : Uint8List.fromList(data));
          }
        },
        onError: (_) => close(),
        onDone: () {
          _eventCtrl.add(const CloudLinkEvent._(CloudLinkEvent.closed));
          close();
        },
        cancelOnError: true,
      );
    } catch (_) {
      _eventCtrl.add(const CloudLinkEvent._(CloudLinkEvent.closed));
      _closed = true;
      _ws = null;
    }
  }

  void _onText(String text) {
    try {
      final map = jsonDecode(text) as Map<String, dynamic>;
      switch (map['op']) {
        case 'ready':
          _eventCtrl.add(CloudLinkEvent._(
            CloudLinkEvent.ready,
            peerName: (map['peer'] as String?) ?? '',
          ));
        case 'peer_lost':
          _eventCtrl.add(const CloudLinkEvent._(CloudLinkEvent.peerLost));
        case 'replaced':
          _eventCtrl.add(const CloudLinkEvent._(CloudLinkEvent.replaced));
          close();
        default:
          break;
      }
    } catch (_) {}
  }

  /// 发送 XYW1 帧字节（WS Binary）。
  Future<void> send(Uint8List bytes) async {
    final ws = _ws;
    if (ws == null || _closed) return;
    try {
      ws.add(bytes);
    } catch (_) {}
  }

  /// 关闭连接（幂等）。
  Future<void> close() async {
    _closed = true;
    await _sub?.cancel();
    _sub = null;
    final ws = _ws;
    _ws = null;
    try {
      await ws?.close();
    } catch (_) {}
  }
}
