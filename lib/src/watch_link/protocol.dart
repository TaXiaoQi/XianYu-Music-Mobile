/// 弦予腕上链路协议（手机 ↔ 手表，RFCOMM SPP 传输层）。
///
/// 与腕上端 `XianYu-Music-Watch/lib/src/link/protocol.dart` 为同一实现的镜像
/// 拷贝（两端独立工程无法共享包依赖），修改任一侧务必同步另一侧。
///
/// 帧格式（大端）：
/// ```text
/// [4B magic "XYW1"][1B ver][1B type][2B seq][4B len][2B crc16][payload(len B)]
/// ```
/// - 头长 14 字节；`len` 为 payload 字节数（不含头）
/// - `crc16`（CCITT-FALSE，poly 0x1021/init 0xFFFF）覆盖 `ver + type + seq + len + payload`
/// - payload 为 UTF-8 JSON；单帧上限 [kMaxPayloadBytes]，超限自动分片（type=chunk）
///
/// 消息方向约定：
/// - 双向：hello / bye / ping / pong
/// - 手机→手表：state / now_playing / position
/// - 手表→手机：cmd
///
/// 扩展预留：type 0x40–0x7F 为云端兜底通道（payload 以 `cloud_` 前缀），
/// 0x80–0xFF 为鸿蒙等未来通道；未知 type 静默丢弃。
library;

import 'dart:convert';
import 'dart:typed_data';

/// 协议版本（握手按双方较小值协商）。
const int kLinkProtocolVersion = 1;

/// RFCOMM SPP 服务 UUID（手机端 accept / 手表端 connect，两端一致）。
const String kWatchLinkServiceUuid =
    'f7a24b6c-9d3e-4f8a-b1c2-2e5d8a7f6b3a';

/// 帧头 magic。
final Uint8List kFrameMagic = Uint8List.fromList([0x58, 0x59, 0x57, 0x31]); // "XYW1"

/// 帧头长度：magic(4) + ver(1) + type(1) + seq(2) + len(4) + crc16(2)。
const int kFrameHeaderBytes = 14;

/// 单帧 payload 上限（分片阈值）。
const int kMaxPayloadBytes = 4 * 1024;

/// 消息类型。
class LinkMsgType {
  static const int hello = 0x01;
  static const int bye = 0x02;
  static const int ping = 0x03;
  static const int pong = 0x04;

  /// 手机→手表。
  static const int state = 0x10;
  static const int nowPlaying = 0x11;
  static const int position = 0x12;

  /// 手表→手机。
  static const int cmd = 0x20;

  /// 分片（任何方向）。
  static const int chunk = 0x30;

  static bool known(int t) =>
      t == hello ||
      t == bye ||
      t == ping ||
      t == pong ||
      t == state ||
      t == nowPlaying ||
      t == position ||
      t == cmd ||
      t == chunk;
}

/// 播放模式（与移动端 PlayMode 语义对齐，JSON 传输用字符串）。
enum LinkPlayMode { order, shuffle, one }

LinkPlayMode linkPlayModeFromString(String? s) {
  switch (s) {
    case 'shuffle':
      return LinkPlayMode.shuffle;
    case 'one':
      return LinkPlayMode.one;
    default:
      return LinkPlayMode.order;
  }
}

String linkPlayModeToString(LinkPlayMode m) {
  switch (m) {
    case LinkPlayMode.shuffle:
      return 'shuffle';
    case LinkPlayMode.one:
      return 'one';
    case LinkPlayMode.order:
      return 'order';
  }
}

/// 手机端播放模式 int（0 顺序 / 1 单曲循环 / 2 随机）→ 协议枚举。
LinkPlayMode linkPlayModeFromInt(int m) {
  switch (m) {
    case 1:
      return LinkPlayMode.one;
    case 2:
      return LinkPlayMode.shuffle;
    default:
      return LinkPlayMode.order;
  }
}

/// 手表→手机控制命令 action。
class LinkCmdAction {
  static const String toggle = 'toggle';
  static const String next = 'next';
  static const String prev = 'prev';
  static const String like = 'like';
  static const String mode = 'mode';
  static const String seek = 'seek';
  static const String volume = 'volume'; // arg {v: 0..1}，表冠调音量
}

/// 链路消息（type + JSON payload 解码后的 map）。
class LinkMessage {
  LinkMessage(this.type, this.payload);

  final int type;
  final Map<String, dynamic> payload;

  String? action() => payload['action'] as String?;

  static LinkMessage hello({required int ver, required String role, String name = ''}) =>
      LinkMessage(LinkMsgType.hello, {'ver': ver, 'role': role, 'name': name});

  static LinkMessage state({
    required bool isPlaying,
    required LinkPlayMode playMode,
    required bool liked,
    double? volume,
  }) =>
      LinkMessage(LinkMsgType.state, {
        'isPlaying': isPlaying,
        'playMode': linkPlayModeToString(playMode),
        'liked': liked,
        'volume': ?volume,
      });

  static LinkMessage nowPlaying({
    required String id,
    required String title,
    required String artist,
    required String album,
    String? cover,
    required double duration,
  }) =>
      LinkMessage(LinkMsgType.nowPlaying, {
        'id': id,
        'title': title,
        'artist': artist,
        'album': album,
        'cover': cover,
        'duration': duration,
      });

  static LinkMessage position({required double pos, required double duration}) =>
      LinkMessage(LinkMsgType.position, {'pos': pos, 'duration': duration});

  static LinkMessage cmd(String action, [Map<String, dynamic>? arg]) =>
      LinkMessage(LinkMsgType.cmd, {'action': action, 'arg': ?arg});

  Map<String, dynamic> toJson() => {'type': type, 'payload': payload};

  @override
  String toString() => 'LinkMessage(type=0x${type.toRadixString(16)}, payload=$payload)';
}

/// CRC16-CCITT-FALSE（poly 0x1021，init 0xFFFF）。
int crc16CcittFalse(List<int> bytes) {
  var crc = 0xFFFF;
  for (final b in bytes) {
    crc ^= b << 8;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 0x8000) != 0 ? ((crc << 1) ^ 0x1021) & 0xFFFF : (crc << 1) & 0xFFFF;
    }
  }
  return crc;
}

int _readU16(Uint8List b, int o) => (b[o] << 8) | b[o + 1];

int _readU32(Uint8List b, int o) =>
    (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

void _writeU16(Uint8List b, int o, int v) {
  b[o] = (v >> 8) & 0xFF;
  b[o + 1] = v & 0xFF;
}

void _writeU32(Uint8List b, int o, int v) {
  b[o] = (v >> 24) & 0xFF;
  b[o + 1] = (v >> 16) & 0xFF;
  b[o + 2] = (v >> 8) & 0xFF;
  b[o + 3] = v & 0xFF;
}

/// 编码一条消息为帧字节流；payload 超过 [kMaxPayloadBytes] 时自动按
/// chunk 帧（`{"cid":..,"total":n,"idx":i,"type":..,"data":"<utf8 片段>"}`）分片。
/// 返回的每条记录为完整一帧（含帧头）。
List<Uint8List> encodeFrames(LinkMessage msg, {required int Function() nextSeq}) {
  final jsonBytes = utf8.encode(jsonEncode(msg.payload));

  // 不超限：单帧直出。
  if (jsonBytes.length <= kMaxPayloadBytes) {
    return [_encodeOne(msg.type, nextSeq(), jsonBytes)];
  }

  // 分片：按 UTF-8 安全边界切块（避免截断多字节字符）。
  final chunks = _splitUtf8Safe(jsonBytes, kMaxPayloadBytes - 512);
  final cid = DateTime.now().microsecondsSinceEpoch & 0xFFFFFFFF;
  final frames = <Uint8List>[];
  final seqBase = nextSeq();
  for (var i = 0; i < chunks.length; i++) {
    final payload = jsonEncode({
      'cid': cid,
      'total': chunks.length,
      'idx': i,
      'type': msg.type,
      'data': utf8.decode(chunks[i], allowMalformed: false),
    });
    frames.add(_encodeOne(LinkMsgType.chunk, (seqBase + i) & 0xFFFF, utf8.encode(payload)));
  }
  return frames;
}

Uint8List _encodeOne(int type, int seq, List<int> jsonBytes) {
  if (jsonBytes.length > kMaxPayloadBytes) {
    throw ArgumentError('payload too large: ${jsonBytes.length}');
  }
  final frame = Uint8List(kFrameHeaderBytes + jsonBytes.length);
  frame.setRange(0, 4, kFrameMagic);
  frame[4] = kLinkProtocolVersion;
  frame[5] = type;
  _writeU16(frame, 6, seq & 0xFFFF);
  _writeU32(frame, 8, jsonBytes.length);
  frame.setRange(kFrameHeaderBytes, frame.length, jsonBytes);
  final crcInput = frame.sublist(4); // ver..payload
  _writeU16(frame, 12, crc16CcittFalse(crcInput));
  return frame;
}

/// 按 UTF-8 字符边界切分字节序列。
List<Uint8List> _splitUtf8Safe(Uint8List bytes, int maxChunk) {
  final out = <Uint8List>[];
  var start = 0;
  while (start < bytes.length) {
    var end = start + maxChunk < bytes.length ? start + maxChunk : bytes.length;
    if (end < bytes.length) {
      // 回退到当前块末尾完整 UTF-8 序列边界。
      while (end > start && (bytes[end] & 0xC0) == 0x80) {
        end--;
      }
    }
    out.add(Uint8List.sublistView(bytes, start, end));
    start = end;
  }
  return out;
}

/// 流式帧解码器：喂入任意分段的字节流，吐出完整消息（含 chunk 重组）。
class FrameDecoder {
  final _buf = BytesBuffer();
  final _chunks = <int, _ChunkSession>{};

  /// 喂入字节，返回解出的完整消息（顺序保证）。
  List<LinkMessage> feed(List<int> bytes) {
    _buf.add(bytes);
    final out = <LinkMessage>[];
    while (true) {
      final data = _buf.asBytes();
      // 找 magic。
      var magicIdx = _findMagic(data);
      if (magicIdx < 0) {
        // 保留末尾可能半个 magic 的尾巴。
        final keep = data.length < 4 ? data.length : 3;
        _buf.clear();
        if (keep > 0) _buf.add(data.sublist(data.length - keep));
        break;
      }
      if (magicIdx > 0) {
        // 丢弃 magic 前的脏数据。
        final rest = data.sublist(magicIdx);
        _buf.clear();
        _buf.add(rest);
        continue;
      }
      if (data.length < kFrameHeaderBytes) break;
      final len = _readU32(data, 8);
      if (len > kMaxPayloadBytes) {
        // 非法长度：丢掉 magic 继续找。
        _buf.clear();
        _buf.add(data.sublist(4));
        continue;
      }
      if (data.length < kFrameHeaderBytes + len) break;
      final frame = data.sublist(0, kFrameHeaderBytes + len);
      _buf.clear();
      _buf.add(data.sublist(kFrameHeaderBytes + len));

      final msg = _decodeFrame(frame);
      if (msg != null) out.add(msg);
    }
    return out;
  }

  LinkMessage? _decodeFrame(Uint8List frame) {
    final type = frame[5];
    final len = _readU32(frame, 8);
    final expectCrc = _readU16(frame, 12);
    // CRC 覆盖 ver..payload 但不含 CRC 字段自身：编码时该字段为 0，
    // 校验时先把副本中对应字节（ver 起偏移 8-9）清零再计算。
    final check = Uint8List.fromList(frame.sublist(4, kFrameHeaderBytes + len));
    check[8] = 0;
    check[9] = 0;
    final actualCrc = crc16CcittFalse(check);
    if (expectCrc != actualCrc) return null; // CRC 错误静默丢弃
    if (!LinkMsgType.known(type)) return null; // 未知类型静默丢弃
    final payload = utf8.decode(
      frame.sublist(kFrameHeaderBytes, kFrameHeaderBytes + len),
      allowMalformed: false,
    );
    if (type == LinkMsgType.chunk) return _reassembleChunk(payload);
    return LinkMessage(type, jsonDecode(payload) as Map<String, dynamic>);
  }

  LinkMessage? _reassembleChunk(String payload) {
    final map = jsonDecode(payload) as Map<String, dynamic>;
    final cid = map['cid'] as int;
    final total = map['total'] as int;
    final idx = map['idx'] as int;
    final innerType = map['type'] as int;
    final data = map['data'] as String;
    final session = _chunks.putIfAbsent(cid, () => _ChunkSession(total, innerType));
    session.parts[idx] = data;
    if (session.parts.length == total) {
      _chunks.remove(cid);
      final joined = session.parts.keys
          .toList()
        ..sort();
      final full = joined.map((i) => session.parts[i]!).join();
      return LinkMessage(
        session.innerType,
        jsonDecode(full) as Map<String, dynamic>,
      );
    }
    return null;
  }

  static int _findMagic(Uint8List d) {
    outer:
    for (var i = 0; i + 4 <= d.length; i++) {
      for (var j = 0; j < 4; j++) {
        if (d[i + j] != kFrameMagic[j]) continue outer;
      }
      return i;
    }
    return -1;
  }
}

class _ChunkSession {
  _ChunkSession(this.total, this.innerType);
  final int total;
  final int innerType;
  final Map<int, String> parts = {};
}

/// 简单字节缓冲（避免频繁 sublist 拷贝语义错误）。
class BytesBuffer {
  final List<int> _data = [];

  void add(List<int> bytes) => _data.addAll(bytes);

  Uint8List asBytes() => Uint8List.fromList(_data);

  void clear() => _data.clear();

  int get length => _data.length;
}

/// 简单自增序列号发生器。
int Function() makeSeqGenerator() {
  var seq = 0;
  return () {
    seq = (seq + 1) & 0xFFFF;
    return seq;
  };
}
