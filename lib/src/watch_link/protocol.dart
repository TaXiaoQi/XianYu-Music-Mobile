library;

import 'dart:convert';
import 'dart:typed_data';

const int kLinkProtocolVersion = 1;

const String kWatchLinkServiceUuid =
    'f7a24b6c-9d3e-4f8a-b1c2-2e5d8a7f6b3a';

final Uint8List kFrameMagic = Uint8List.fromList([0x58, 0x59, 0x57, 0x31]);

const int kFrameHeaderBytes = 14;

const int kMaxPayloadBytes = 4 * 1024;

class LinkMsgType {
  static const int hello = 0x01;
  static const int bye = 0x02;
  static const int ping = 0x03;
  static const int pong = 0x04;

  static const int state = 0x10;
  static const int nowPlaying = 0x11;
  static const int position = 0x12;

  static const int lyric = 0x13;

  static const int precache = 0x14;

  static const int cmd = 0x20;

  static const int backupFile = 0x21;

  static const int backupAck = 0x22;

  static const int chunk = 0x30;

  static const int cloudBind = 0x41;

  static bool known(int t) =>
      t == hello ||
      t == bye ||
      t == ping ||
      t == pong ||
      t == state ||
      t == nowPlaying ||
      t == position ||
      t == lyric ||
      t == precache ||
      t == cmd ||
      t == backupFile ||
      t == backupAck ||
      t == chunk ||
      t == cloudBind;
}

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

class LinkCmdAction {
  static const String toggle = 'toggle';
  static const String next = 'next';
  static const String prev = 'prev';
  static const String like = 'like';
  static const String dislike = 'dislike';
  static const String mode = 'mode';
  static const String seek = 'seek';
  static const String volume = 'volume';
}

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
    String? coverData,
    required double duration,
    bool daily = false,
  }) =>
      LinkMessage(LinkMsgType.nowPlaying, {
        'id': id,
        'title': title,
        'artist': artist,
        'album': album,
        'cover': cover,
        'coverData': ?coverData,
        'duration': duration,
        'daily': daily,
      });

  static LinkMessage position({required double pos, required double duration}) =>
      LinkMessage(LinkMsgType.position, {'pos': pos, 'duration': duration});

  static LinkMessage lyric({required String id, required String payload}) =>
      LinkMessage(LinkMsgType.lyric, {
        'lyric': {
          'id': id,
          'payload': payload,
        },
      });

  static LinkMessage precache({
    required String id,
    String? coverData,
    String? lyricPayload,
  }) =>
      LinkMessage(LinkMsgType.precache, {
        'precache': {
          'id': id,
          'cover': ?coverData,
          'lyric': ?lyricPayload,
        },
      });

  static LinkMessage cmd(String action, [Map<String, dynamic>? arg]) =>
      LinkMessage(LinkMsgType.cmd, {'action': action, 'arg': ?arg});

  static LinkMessage backupFile({
    required String name,
    required String content,
  }) => LinkMessage(LinkMsgType.backupFile, {
    'name': name,
    'size': utf8.encode(content).length,
    'backup': content,
  });

  static LinkMessage backupAck({required String result}) =>
      LinkMessage(LinkMsgType.backupAck, {'result': result});

  static LinkMessage cloudBind({required String key, String? url}) =>
      LinkMessage(LinkMsgType.cloudBind, {
        'cloud_bind': {
          'key': key,
          'url': ?url,
        },
      });

  Map<String, dynamic> toJson() => {'type': type, 'payload': payload};

  @override
  String toString() => 'LinkMessage(type=0x${type.toRadixString(16)}, payload=$payload)';
}

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

List<Uint8List> encodeFrames(LinkMessage msg, {required int Function() nextSeq}) {
  final jsonBytes = utf8.encode(jsonEncode(msg.payload));

  if (jsonBytes.length <= kMaxPayloadBytes) {
    return [_encodeOne(msg.type, nextSeq(), jsonBytes)];
  }

  var chunkSize = kMaxPayloadBytes - 512;
  var chunks = _splitUtf8Safe(jsonBytes, chunkSize);
  while (_chunkFramesOverflow(chunks)) {
    chunkSize = chunkSize ~/ 2;
    chunks = _splitUtf8Safe(jsonBytes, chunkSize);
  }
  final cid = DateTime.now().microsecondsSinceEpoch & 0xFFFFFFFF;
  final frames = <Uint8List>[];
  final seqBase = nextSeq();
  for (var i = 0; i < chunks.length; i++) {
    frames.add(_encodeOne(
      LinkMsgType.chunk,
      (seqBase + i) & 0xFFFF,
      utf8.encode(_chunkPayloadJson(chunks[i], cid, chunks.length, i, msg.type)),
    ));
  }
  return frames;
}

String _chunkPayloadJson(Uint8List chunk, int cid, int total, int idx, int type) =>
    jsonEncode({
      'cid': cid,
      'total': total,
      'idx': idx,
      'type': type,
      'data': utf8.decode(chunk, allowMalformed: false),
    });

bool _chunkFramesOverflow(List<Uint8List> chunks) => chunks.any((c) =>
    utf8.encode(_chunkPayloadJson(c, 0, chunks.length, 0, 0)).length >
    kMaxPayloadBytes);

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
  final crcInput = frame.sublist(4);
  _writeU16(frame, 12, crc16CcittFalse(crcInput));
  return frame;
}

List<Uint8List> _splitUtf8Safe(Uint8List bytes, int maxChunk) {
  final out = <Uint8List>[];
  var start = 0;
  while (start < bytes.length) {
    var end = start + maxChunk < bytes.length ? start + maxChunk : bytes.length;
    if (end < bytes.length) {
      while (end > start && (bytes[end] & 0xC0) == 0x80) {
        end--;
      }
    }
    out.add(Uint8List.sublistView(bytes, start, end));
    start = end;
  }
  return out;
}

class FrameDecoder {
  final _buf = BytesBuffer();
  final _chunks = <int, _ChunkSession>{};

  List<LinkMessage> feed(List<int> bytes) {
    _buf.add(bytes);
    final out = <LinkMessage>[];
    while (true) {
      final data = _buf.asBytes();
      var magicIdx = _findMagic(data);
      if (magicIdx < 0) {
        final keep = data.length < 4 ? data.length : 3;
        _buf.clear();
        if (keep > 0) _buf.add(data.sublist(data.length - keep));
        break;
      }
      if (magicIdx > 0) {
        final rest = data.sublist(magicIdx);
        _buf.clear();
        _buf.add(rest);
        continue;
      }
      if (data.length < kFrameHeaderBytes) break;
      final len = _readU32(data, 8);
      if (len > kMaxPayloadBytes) {
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
    final check = Uint8List.fromList(frame.sublist(4, kFrameHeaderBytes + len));
    check[8] = 0;
    check[9] = 0;
    final actualCrc = crc16CcittFalse(check);
    if (expectCrc != actualCrc) return null;
    if (!LinkMsgType.known(type)) return null;
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

class BytesBuffer {
  final List<int> _data = [];

  void add(List<int> bytes) => _data.addAll(bytes);

  Uint8List asBytes() => Uint8List.fromList(_data);

  void clear() => _data.clear();

  int get length => _data.length;
}

int Function() makeSeqGenerator() {
  var seq = 0;
  return () {
    seq = (seq + 1) & 0xFFFF;
    return seq;
  };
}
