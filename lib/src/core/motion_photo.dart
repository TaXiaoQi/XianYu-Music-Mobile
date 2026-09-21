import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

Future<String?> extractMotionPhotoVideo(File jpg, String destPath) async {
  try {
    final raf = await jpg.open();
    try {
      final len = await raf.length();
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
          out.add(base + i);
          if (out.length >= 8) break;
        }
      }
    }
    base += n - overlap;
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
