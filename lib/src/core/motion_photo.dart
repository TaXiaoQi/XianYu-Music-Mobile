import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

Future<String?> extractMotionPhotoVideo(File jpg, String destPath) async {
  try {
    final raf = await jpg.open();
    try {
      final len = await raf.length();
      // 动态照片本质是 JPEG(头两字节 0xFFD8)内嵌 MP4；
      // HEIF/HEIC 同为 ISOBMFF 容器且也含 mdat，若不先按 JPEG SOI 拦截，
      // 会把 HEIC 照片误判成动态照片、抽出坏视频，拖垮普通照片选择。
      if (len < 2) return null;
      await raf.setPosition(0);
      final head = await raf.read(2);
      if (head.length < 2 || head[0] != 0xff || head[1] != 0xd8) return null;
      final candidates = await _findFtypCandidates(raf, len);
      for (final offset in candidates) {
        final end = await _walkMp4Boxes(raf, len, offset);
        if (end != null && end - offset >= 32768) {
          final copied = await _copyRange(raf, offset, end, destPath);
          if (copied != null) return copied;
        }
      }
      return null;
    } finally {
      await raf.close();
    }
  } catch (_) {
    try {
      final f = File(destPath);
      if (await f.exists()) await f.delete();
    } catch (_) {}
    return null;
  }
}

Future<List<int>> _findFtypCandidates(RandomAccessFile raf, int len) async {
  final chunk = 1 << 20;
  final overlap = 12;
  final buf = Uint8List(chunk + overlap);
  final out = <int>[];
  var base = 0;
  var skip = 0;
  while (base < len && out.length < 8) {
    await raf.setPosition(base);
    final n = await raf.readInto(buf);
    if (n <= 4) break;
    final limit = n - 4;
    for (var i = math.max(skip, 4); i <= limit; i++) {
      if (buf[i] == 0x66 &&
          buf[i + 1] == 0x74 &&
          buf[i + 2] == 0x79 &&
          buf[i + 3] == 0x70) {
        final sizeField =
            (buf[i - 4] << 24) | (buf[i - 3] << 16) | (buf[i - 2] << 8) |
            buf[i - 1];
        if (sizeField >= 8 && sizeField <= 512) {
          // i 指向 'ftyp' 的 'f'，size 字段在其前 4 字节，box 起始须减 4，
          // 否则 _walkMp4Boxes 把 'ftyp' 当大小字段解析出超大值而直接 break
          out.add(base + i - 4);
          if (out.length >= 8) break;
        }
      }
    }
    // 末尾不足 overlap 时 n - overlap <= 0，base 不会前进会死循环，须 break
    final next = base + n - overlap;
    if (next <= base) break;
    base = next;
    skip = overlap;
  }
  return out;
}

Future<int?> _walkMp4Boxes(RandomAccessFile raf, int len, int start) async {
  var pos = start;
  var end = -1;
  var sawMedia = false;
  final head = Uint8List(8);
  while (true) {
    final remaining = len - pos;
    if (remaining < 8) break;
    await raf.setPosition(pos);
    final n = await raf.readInto(head);
    if (n < 8) break;
    var typeOk = true;
    for (var k = 4; k < 8; k++) {
      if (head[k] < 0x20 || head[k] > 0x7e) {
        typeOk = false;
        break;
      }
    }
    if (!typeOk) break;
    final t = String.fromCharCodes(head.sublist(4, 8));
    var size =
        (head[0] << 24) | (head[1] << 16) | (head[2] << 8) | head[3];
    if (size == 0) {
      pos = len;
      end = len;
      break;
    }
    if (size == 1) {
      final n2 = await raf.readInto(head);
      if (n2 < 8) break;
      final hi =
          (head[0] << 24) | (head[1] << 16) | (head[2] << 8) | head[3];
      final lo =
          (head[4] << 24) | (head[5] << 16) | (head[6] << 8) | head[7];
      if (hi != 0) break;
      size = lo;
    }
    if (size < 8 || pos + size > len) break;
    if (t == 'mdat' || t == 'moov') sawMedia = true;
    pos += size;
    end = pos;
    if (pos >= len) break;
  }
  if (!sawMedia || end < 0 || end <= start) return null;
  return end;
}

Future<String?> _copyRange(
  RandomAccessFile raf,
  int start,
  int end,
  String destPath,
) async {
  final out = await File(destPath).open(mode: FileMode.write);
  try {
    final buf = Uint8List(1 << 20);
    await raf.setPosition(start);
    var remaining = end - start;
    while (remaining > 0) {
      final n = await raf.readInto(buf, 0, math.min(buf.length, remaining));
      if (n <= 0) break;
      await out.writeFrom(buf, 0, n);
      remaining -= n;
    }
  } finally {
    await out.close();
  }
  final f = File(destPath);
  if (await f.length() <= 0) {
    try {
      await f.delete();
    } catch (_) {}
    return null;
  }
  return destPath;
}
