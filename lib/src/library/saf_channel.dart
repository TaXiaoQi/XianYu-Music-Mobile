import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

/// SAF 选中的音频文件条目（由 Android 侧递归枚举得到）。
class SafAudioFile {
  final String docId;
  final String name;
  final String ext;
  final int size;
  const SafAudioFile({
    required this.docId,
    required this.name,
    required this.ext,
    required this.size,
  });

  factory SafAudioFile.fromJson(Map<String, dynamic> j) => SafAudioFile(
        docId: j['docId'] as String? ?? '',
        name: j['name'] as String? ?? '',
        ext: j['ext'] as String? ?? '',
        size: (j['size'] as num?)?.toInt() ?? 0,
      );
}

/// Android 存储访问框架（SAF）桥接：用户选目录树 → 递归枚举音频 → fd 打开。
class SafChannel {
  static const _channel = MethodChannel('xianyu/saf');

  static bool get isSupported => Platform.isAndroid;

  /// 让用户选择目录树，返回持久化的 `content://…/tree/…` URI（取消返回 null）。
  static Future<String?> chooseFolderTree() async {
    if (!isSupported) return null;
    final raw = await _channel.invokeMethod<String>('chooseFolderTree');
    return (raw == null || raw.isEmpty) ? null : raw;
  }

  static Future<void> persistPermission(String treeUri) async {
    if (!isSupported) return;
    await _channel.invokeMethod('persistPermission', {'uri': treeUri});
  }

  /// 递归枚举 tree 下白名单扩展名的音频文件。
  static Future<List<SafAudioFile>> listAudioTree(
    String treeUri,
    List<String> extensions,
  ) async {
    if (!isSupported) return const [];
    final raw = await _channel
            .invokeMethod<String>('listAudioTree', {
          'uri': treeUri,
          'extensions': extensions,
        }) ??
        '[]';
    final list = (jsonDecode(raw) as List);
    return list
        .map((e) => SafAudioFile.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 打开 tree 下的某 document，返回其 fd（需 finally 调用 [closeFd]）。
  static Future<int> openFd(String treeUri, String docId) async {
    if (!isSupported) return -1;
    return await _channel
            .invokeMethod<int>('openFd', {'uri': treeUri, 'docId': docId}) ??
        -1;
  }

  static Future<void> closeFd(int fd) async {
    if (!isSupported) return;
    await _channel.invokeMethod('closeFd', {'fd': fd});
  }

  /// tree URI 的根 documentId（如 `primary:Music`），用于入库匹配。
  static String treeRootDocId(String treeUri) {
    final uri = Uri.parse(treeUri);
    final seg = uri.pathSegments.isNotEmpty ? uri.pathSegments.last : '';
    return Uri.decodeComponent(seg);
  }

  /// 目录根的文档类访问路径：`{treeUri}/document/{rootDocId}`。
  /// 作为文件夹树根节点 path，可被 descendent 路径匹配命中其下全部歌曲。
  static String treeRootPath(String treeUri) =>
      '$treeUri/document/${treeRootDocId(treeUri)}';

  /// 把某文档合成可访问、可匹配的歌曲 path：`{treeUri}/document/{docId}`。
  /// 该 path 以 `content://` 开头（SAF 场景可被 just_audio 直接播放），
  /// docId 部分是未编码的 `primary:Volume/相对/路径`，可被斜杠路径匹配。
  static String songPath(String treeUri, String docId) =>
      '$treeUri/document/$docId';

  /// 判断某条路径是否 SAF 文档类路径（song.path / 文件夹根节点）。
  static bool isSafPath(String pathOrUri) => pathOrUri.startsWith('content://');

  /// 判断某条扫描目录是否 SAF tree。
  static bool isSafTree(String pathOrUri) =>
      isSupported && pathOrUri.startsWith('content://');
}