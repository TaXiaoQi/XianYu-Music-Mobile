/// 备份容器文件解析：从 ZIP / lxmc(gzip) 等压缩容器中提取 JSON 备份文本。
///
/// 与桌面端 zipReader.ts + preparePluginBackupFileContent 对齐：
/// - `.json`/`.txt`：直接按 UTF-8 明文读取
/// - `.zip`：解析 PKZIP，优先取其中的 `.json` 文件，其次 `.lxmc`（gzip），
///   再尝试按内容识别无扩展名的 JSON，最后兜底取唯一文件
/// - `.lxmc`：洛雪音乐备份，gzip 压缩的 JSON，解压后读取
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import '../i18n/i18n.dart';

/// 按扩展名/魔数从字节中提取备份 JSON 文本。扩展名未知时自动探测。
String extractBackupJsonBytes(List<int> rawBytes, String fileName) {
  final bytes = Uint8List.fromList(rawBytes);
  final lowerExt = _extensionOf(fileName);
  final isZip = lowerExt == 'zip' ||
      (bytes.length >= 4 && bytes[0] == 0x50 && bytes[1] == 0x4b);
  final isGzip = lowerExt == 'lxmc' ||
      (bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b);

  if (isZip) return _extractJsonFromZip(bytes);

  if (isGzip) {
    final inflated = _gunzip(bytes);
    return utf8.decode(inflated);
  }

  return utf8.decode(bytes);
}

/// 从本地文件读取并解压出备份 JSON 文本。
Future<String> extractBackupJsonFromFile(String path) async {
  final bytes = await File(path).readAsBytes();
  return extractBackupJsonBytes(bytes, path);
}

/// 从 URL 拉取的字节中解压出备份 JSON 文本。
String extractBackupJsonFromUrlBytes(List<int> bytes, String url) =>
    extractBackupJsonBytes(bytes, _extNameFromUrl(url));

String _extensionOf(String fileName) {
  final idx = fileName.lastIndexOf('.');
  return idx < 0 ? '' : fileName.substring(idx + 1).toLowerCase();
}

String _extNameFromUrl(String url) {
  var path = url.split('?').first;
  return _extensionOf(path);
}

List<int> _gunzip(List<int> bytes) {
  try {
    return GZipCodec().decode(bytes);
  } on FormatException {
    throw FormatException(tr('lxmc 备份解压失败：不是有效的 gzip 数据'));
  }
}

// ============================================================
// 最小 ZIP 解析（PKZIP），压缩方法支持 Stored(0) / Deflated(8)
// ============================================================

const _eocdSignature = 0x06054b50;
const _cdSignature = 0x02014b50;
const _lfhSignature = 0x04034b50;
const _zip64EocdLocatorSignature = 0x07064b50;
const _zip64EocdSignature = 0x06064b50;

int _u16(Uint8List d, int o) => d[o] | (d[o + 1] << 8);

int _u32(Uint8List d, int o) =>
    (d[o] | (d[o + 1] << 8) | (d[o + 2] << 16) | (d[o + 3] << 24)) & 0xFFFFFFFF;

int _u64(Uint8List d, int o) {
  final lo = _u32(d, o);
  final hi = _u32(d, o + 4);
  return hi * 0x100000000 + lo;
}

class _ZipEntry {
  final String name;
  final int compressionMethod;
  final int compressedSize;
  final int localHeaderOffset;

  _ZipEntry({
    required this.name,
    required this.compressionMethod,
    required this.compressedSize,
    required this.localHeaderOffset,
  });
}

int _findEocd(Uint8List d) {
  const minEocdSize = 22;
  const maxCommentSize = 65535;
  final searchStart = (d.length - minEocdSize - maxCommentSize).clamp(0, d.length);
  for (var i = d.length - minEocdSize; i >= searchStart; i--) {
    if (_u32(d, i) == _eocdSignature) return i;
  }
  return -1;
}

Map<String, List<int>> _parseZip(Uint8List data) {
  final result = <String, List<int>>{};

  final eocdOffset = _findEocd(data);
  if (eocdOffset == -1) {
    throw   FormatException(tr('ZIP 中未找到 End of Central Directory Record'));
  }

  var totalEntries = _u16(data, eocdOffset + 10);
  var cdOffset = _u32(data, eocdOffset + 16);

  // ZIP64：EOCD 字段为 0xFFFF/0xFFFFFFFF 时从 ZIP64 EOCD 读取。
  if (totalEntries == 0xFFFF || cdOffset == 0xFFFFFFFF) {
    if (eocdOffset >= 20 &&
        _u32(data, eocdOffset - 20) == _zip64EocdLocatorSignature) {
      final zip64EocdOffset = _u64(data, eocdOffset - 12);
      if (_u32(data, zip64EocdOffset) == _zip64EocdSignature) {
        if (totalEntries == 0xFFFF) {
          totalEntries = _u64(data, zip64EocdOffset + 24);
        }
        if (cdOffset == 0xFFFFFFFF) {
          cdOffset = _u64(data, zip64EocdOffset + 48);
        }
      }
    }
  }

  var offset = cdOffset;
  final entries = <_ZipEntry>[];
  for (var i = 0; i < totalEntries; i++) {
    if (_u32(data, offset) != _cdSignature) {
      throw FormatException('ZIP 中无效的 Central Directory 条目 #$i');
    }
    final compressionMethod = _u16(data, offset + 10);
    var compressedSize = _u32(data, offset + 20);
    final filenameLength = _u16(data, offset + 28);
    final extraFieldLength = _u16(data, offset + 30);
    final commentLength = _u16(data, offset + 32);
    var localHeaderOffset = _u32(data, offset + 42);

    final nameBytes = data.sublist(offset + 46, offset + 46 + filenameLength);
    final name = utf8.decode(nameBytes, allowMalformed: true);

    // 解析 ZIP64 扩展字段（extra field ID = 0x0001）。
    if (compressedSize == 0xFFFFFFFF || localHeaderOffset == 0xFFFFFFFF) {
      var extraOffset = offset + 46 + filenameLength;
      final extraEnd = extraOffset + extraFieldLength;
      while (extraOffset + 4 <= extraEnd) {
        final fieldId = _u16(data, extraOffset);
        final fieldSize = _u16(data, extraOffset + 2);
        if (fieldId == 0x0001) {
          var p = extraOffset + 4;
          if (_u32(data, offset + 24) == 0xFFFFFFFF) p += 8;
          if (compressedSize == 0xFFFFFFFF) {
            compressedSize = _u64(data, p);
            p += 8;
          }
          if (localHeaderOffset == 0xFFFFFFFF) {
            localHeaderOffset = _u64(data, p);
          }
          break;
        }
        extraOffset += 4 + fieldSize;
      }
    }

    offset += 46 + filenameLength + extraFieldLength + commentLength;

    if (name.endsWith('/')) continue;

    entries.add(_ZipEntry(
      name: name,
      compressionMethod: compressionMethod,
      compressedSize: compressedSize,
      localHeaderOffset: localHeaderOffset,
    ));
  }

  for (final entry in entries) {
    if (_u32(data, entry.localHeaderOffset) != _lfhSignature) {
      throw FormatException('ZIP 中无效的 Local File Header: ${entry.name}');
    }
    final filenameLength = _u16(data, entry.localHeaderOffset + 26);
    final extraFieldLength = _u16(data, entry.localHeaderOffset + 28);
    final dataOffset = entry.localHeaderOffset + 30 + filenameLength + extraFieldLength;
    final compressedData =
        data.sublist(dataOffset, dataOffset + entry.compressedSize);

    List<int> fileData;
    if (entry.compressionMethod == 0) {
      fileData = compressedData;
    } else if (entry.compressionMethod == 8) {
      fileData = ZLibCodec(raw: true).decode(compressedData);
    } else {
      throw FormatException(
          'ZIP 不支持的压缩方法 ${entry.compressionMethod} (${entry.name})');
    }
    result[entry.name] = fileData;
  }

  return result;
}

String _extractJsonFromZip(Uint8List data) {
  final entries = _parseZip(data);
  final files = entries.keys.where((f) => !f.endsWith('/')).toList();

  // 1. 优先取 .json 文件。
  for (final name in entries.keys) {
    if (name.toLowerCase().endsWith('.json')) {
      return utf8.decode(entries[name]!);
    }
  }

  // 2. 取 .lxmc 文件（gzip 压缩的 JSON，如洛雪备份打包进 ZIP）。
  for (final name in entries.keys) {
    if (name.toLowerCase().endsWith('.lxmc')) {
      try {
        return utf8.decode(_gunzip(entries[name]!));
      } catch (_) {
        // 解压失败继续尝试其他文件。
      }
    }
  }

  // 3. 内容检测：任何以 { 或 [ 开头的文件（可能是无扩展名的 JSON）。
  for (final fileData in entries.values) {
    final text = utf8.decode(fileData, allowMalformed: true);
    final trimmed = text.trimLeft();
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      return text;
    }
  }

  // 4. 只有一个文件时，无论扩展名都按 JSON 返回。
  if (files.length == 1) {
    return utf8.decode(entries[files.first]!);
  }

  // 5. 友好错误，列出文件帮助排查。
  final fileList = files.isNotEmpty ? files.map((f) => '"$f"').join(', ') : tr('(空)');
  throw FormatException('ZIP 中未找到可识别的备份文件。包含: $fileList');
}