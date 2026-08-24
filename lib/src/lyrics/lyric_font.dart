import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// 自定义歌词字体管理：选择 .ttf/.otf 文件 → 复制到应用文档目录 → 用
/// [FontLoader] 注册唯一 family，供歌词渲染引用。
///
/// 每次导入使用时间戳生成独立 family（避免同 family 重复注册报错），
/// 卸载时仅清空设置引用，不显式注销字体（Flutter 无公开卸载 API）。
class LyricFontManager {
  static const _familyPrefix = 'XianYuLyricFont';
  static const allowedExtensions = ['ttf', 'otf'];

  /// 已注册的 family 集合（同 family 只注册一次）。
  static final Set<String> _registered = {};

  /// 选择并导入字体文件。导入成功后通过 onApplied 回调写入设置，返回 family 名；
  /// 用户取消选择返回 null；校验/复制失败抛出异常。
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

    // 统一复制到应用文档目录（content URI / 无 path 场景由 file_picker 提供字节）。
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

  /// 应用启动时重新加载已保存的自定义字体（若文件仍存在）。
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