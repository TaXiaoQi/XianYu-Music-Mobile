import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

class IosPickedFolder {
  final String path;
  final String bookmark;
  const IosPickedFolder({required this.path, required this.bookmark});
}

/// iOS 文件夹书签：文档选择器选一次目录 → 原生侧生成 security-scoped
/// bookmark（持久授权凭证），本类负责把书签按扫描目录路径持久化到
/// Application Support，并在扫描/播放前拉起访问授权。
///
/// 授权生命周期：startAccessing 是进程级作用域，拉起后保持到进程结束，
/// Rust 扫描器与播放器即可直接按路径读取沙盒外目录；冷启动时由
/// [restoreAccess] 依据登记的扫描目录重建。
class IosFolderChannel {
  IosFolderChannel._();

  static final IosFolderChannel instance = IosFolderChannel._();

  static const MethodChannel _ch = MethodChannel('xianyu/ios_folder');
  static const String _fileName = 'ios_folder_bookmarks.json';

  final Set<String> _started = <String>{};
  final Map<String, String> _resolved = <String, String>{};
  Map<String, String>? _bookmarks;

  Future<Map<String, String>> _load() async {
    final cached = _bookmarks;
    if (cached != null) return cached;
    try {
      final support = await getApplicationSupportDirectory();
      final f = File('${support.path}/$_fileName');
      _bookmarks = f.existsSync()
          ? Map<String, String>.from(jsonDecode(await f.readAsString()) as Map)
          : <String, String>{};
    } catch (_) {
      _bookmarks = <String, String>{};
    }
    return _bookmarks!;
  }

  Future<void> _save() async {
    final support = await getApplicationSupportDirectory();
    final f = File('${support.path}/$_fileName');
    await f.writeAsString(jsonEncode(_bookmarks ?? <String, String>{}));
  }

  /// 弹出系统目录选择器，返回所选目录与其持久授权书签。
  Future<IosPickedFolder?> pickFolder() async {
    final r = await _ch.invokeMethod<Map<dynamic, dynamic>>('pickFolder');
    if (r == null) return null;
    final path = r['path'] as String?;
    final bookmark = r['bookmark'] as String?;
    if (path == null || bookmark == null) return null;
    return IosPickedFolder(path: path, bookmark: bookmark);
  }

  Future<void> setBookmark(String path, String bookmark) async {
    final m = await _load();
    m[path] = bookmark;
    await _save();
  }

  Future<void> removeBookmark(String path) async {
    final m = await _load();
    if (m.remove(path) != null) await _save();
  }

  String? _bookmarkFor(Map<String, String> m, String path) {
    if (m.containsKey(path)) return m[path];
    // 前缀匹配：登记路径可能带子目录（真实挂载路径与展示路径存在差异）
    for (final e in m.entries) {
      if (path.startsWith('${e.key}/')) return e.value;
    }
    return null;
  }

  /// 扫描/播放前确保目录可访问；返回建议使用的路径（书签解析后的真实
  /// 路径可能与登记路径不同）。无书签 → 原样返回（沙盒目录无需授权）；
  /// 书签解析失败 → null（调用方按「授权失效」处理）。
  Future<String?> ensureAccess(String path) async {
    if (!Platform.isIOS) return path;
    final m = await _load();
    final bookmark = _bookmarkFor(m, path);
    if (bookmark == null) return path;
    if (_started.contains(bookmark)) return _resolved[bookmark] ?? path;
    try {
      final r = await _ch.invokeMethod<Map<dynamic, dynamic>>(
        'startAccess',
        {'bookmark': bookmark},
      );
      if (r == null) return null;
      _started.add(bookmark);
      final resolved = r['path'] as String?;
      if (resolved != null && resolved != path) {
        // 真实路径漂移（iCloud 重新挂载等）：换用解析路径并同步书签 key
        _resolved[bookmark] = resolved;
        m[resolved] = bookmark;
        await _save();
        return resolved;
      }
      _resolved[bookmark] = path;
      return path;
    } on PlatformException {
      return null;
    }
  }

  /// 冷启动恢复：对登记的扫描目录逐个拉起访问授权（不阻塞调用方）。
  Future<void> restoreAccess(Iterable<String> paths) async {
    for (final path in paths) {
      try {
        await ensureAccess(path);
      } catch (_) {
        // 单个目录恢复失败不影响其它目录
      }
    }
  }
}
