import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

class LyricFontManager {
  static const _familyPrefix = 'XianYuLyricFont';
  static const allowedExtensions = ['ttf', 'otf'];

  static final Set<String> _registered = {};

  static Future<String?> importCustomFont({
    required Future<void> Function(String name, String path) onApplied,
  }) async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: allowedExtensions,
    );
    if (files.isEmpty) return null;

    final file = files.first;
    final ext = file.name.contains('.')
        ? file.name.split('.').last.toLowerCase()
        : '';
    if (!allowedExtensions.contains(ext)) {
      throw Exception(
          '仅支持 ${allowedExtensions.map((e) => '.$e').join(' / ')} 字体文件');
    }

    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/lyric_fonts');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final name = _safeFileName(file.name);
    final dest = File('${dir.path}/$name');

    final bytes = await file.readAsBytes();
    await dest.writeAsBytes(bytes, flush: true);

    final family = '$_familyPrefix${DateTime.now().millisecondsSinceEpoch}';
    await _register(dest.path, family);
    await onApplied(family, dest.path);
    return family;
  }

  static Future<void> loadSavedFont(String name, String path) async {
    if (name.isEmpty || path.isEmpty) return;
    final file = File(path);
    if (!await file.exists()) return;
    await _register(path, name);
  }

  static Future<void> _register(String path, String family) async {
    if (_registered.contains(family)) return;
    final bytes = await File(path).readAsBytes();
    final loader = FontLoader(family)
      ..addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
    await loader.load();
    _registered.add(family);
  }

  static String _safeFileName(String raw) {
    final cleaned = raw.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    return cleaned.isEmpty ? 'lyric_font' : cleaned;
  }
}