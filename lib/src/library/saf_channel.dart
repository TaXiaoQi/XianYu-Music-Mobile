import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../rust/api.dart';

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

/// MediaStore 聚合出的音频目录（path 为真实绝对路径，可直接入库扫描）。
class MediaFolderInfo {
  final String path;
  final int count;
  const MediaFolderInfo({required this.path, required this.count});

  factory MediaFolderInfo.fromJson(Map<String, dynamic> j) => MediaFolderInfo(
        path: j['path'] as String? ?? '',
        count: (j['count'] as num?)?.toInt() ?? 0,
      );
}

/// Android 存储访问框架（SAF）桥接：用户选目录树 → 递归枚举音频 → fd 打开。
class SafChannel {
  static const _channel = MethodChannel('xianyu/saf');

  static bool get isSupported => Platform.isAndroid;

  /// 当前设备的 Android API level（非 Android 返回 0）。
  /// 存储权限按版本细分申请时使用（13+ 为 READ_MEDIA_AUDIO，以下为
  /// READ_EXTERNAL_STORAGE）。
  static Future<int> androidSdkInt() async {
    if (!isSupported) return 0;
    return await _channel.invokeMethod<int>('getSdkInt') ?? 0;
  }

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

  /// 该目录的授权是否仍在系统持久化名单中（重启后依然有效的前提）。
  static Future<bool> isTreePersisted(String treeUri) async {
    if (!isSupported) return false;
    return await _channel.invokeMethod<bool>('isTreePersisted',
            {'uri': treeUri}) ??
        false;
  }

  /// 目录当前是否真正可读（持久化名单命中 + 根节点探测成功）。
  /// 清除数据 / 系统撤销授权 / SD 卡拔出都会返回 false。
  static Future<bool> isTreeAvailable(String treeUri) async {
    if (!isSupported) return false;
    return await _channel.invokeMethod<bool>('isTreeAvailable',
            {'uri': treeUri}) ??
        false;
  }

  /// 释放目录的持久化授权（移除扫描目录时调用，避免耗尽系统名额）。
  static Future<void> releasePermission(String treeUri) async {
    if (!isSupported) return;
    await _channel.invokeMethod('releasePermission', {'uri': treeUri});
  }

  /// tree URI 的用户可读名（如 `内部存储/Music`）。
  static Future<String> friendlyTreeName(String treeUri) async {
    if (!isSupported) return treeUri;
    return await _channel.invokeMethod<String>('friendlyTreeName',
            {'uri': treeUri}) ??
        treeUri;
  }

  /// 经 MediaStore 枚举设备上包含音频的真实目录（需已授予音乐读取权限）。
  ///
  /// 音乐权限只授一次即可全局枚举，应用内目录选择器以此构建目录树，
  /// 添加目录不再弹系统 SAF 授权框。
  static Future<List<MediaFolderInfo>> listMediaAudioFolders() async {
    if (!isSupported) return const [];
    final raw =
        await _channel.invokeMethod<String>('listMediaAudioFolders') ?? '[]';
    return (jsonDecode(raw) as List)
        .map((e) => MediaFolderInfo.fromJson(e as Map<String, dynamic>))
        .toList();
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

  /// 把 tree 下某 document 的内容复制到应用内部目录，返回真实文件路径。
  static Future<String> copyTreeDocToInternal(
    String treeUri,
    String docId,
    String destDir,
  ) async {
    if (!isSupported) return '';
    return await _channel.invokeMethod<String>('copyTreeDocToInternal', {
          'uri': treeUri,
          'docId': docId,
          'destDir': destDir,
        }) ??
        '';
  }

  /// SAF 歌曲播放副本缓存：content 路径 → 本地真实文件（LRU，保留最近
  /// [_maxPlaybackCopies] 份，切回最近播过的歌无需重新复制）。
  static final Map<String, String> _playbackCopies = {};
  static const _maxPlaybackCopies = 3;

  /// 扫描前清空物化副本缓存目录的残留文件（兼容旧版本整库物化的遗留）。
  static void clearScannedCopiesRoot(String tempRoot) {
    final dir = Directory(tempRoot);
    if (!dir.existsSync()) return;
    try {
      for (final e in dir.listSync()) {
        if (e is File) e.deleteSync();
      }
    } catch (_) {}
  }

  /// 把 `{treeUri}/document/{docId}` 形式的歌曲路径物化为可被 just_audio
  /// 直接播放的本地真实文件（content URI 播放不可靠）。非 SAF 路径原样返回。
  static Future<String> ensureLocalPlaybackCopy(
    String songPath,
    String tempRoot,
  ) async {
    if (!isSafPath(songPath)) return songPath;

    final cached = _playbackCopies.remove(songPath);
    if (cached != null && File(cached).existsSync()) {
      // 命中：移回 LRU 尾部（最近使用）。
      _playbackCopies[songPath] = cached;
      return cached;
    }

    final marker = '/document/';
    final idx = songPath.indexOf(marker);
    if (idx < 0) return songPath;
    final treeUri = songPath.substring(0, idx);
    final docId = songPath.substring(idx + marker.length);

    final dir = Directory(tempRoot);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    // 本会话首次物化：清理上次会话遗留的副本文件，避免跨会话累积占盘。
    if (_playbackCopies.isEmpty) {
      try {
        for (final e in dir.listSync()) {
          if (e is File) e.deleteSync();
        }
      } catch (_) {}
    }
    final copied = await copyTreeDocToInternal(treeUri, docId, dir.path);
    if (copied.isEmpty) return songPath; // 复制失败，回退直接以 content 播放。

    _playbackCopies[songPath] = copied;
    // LRU 淘汰：超出保留份数时删除最旧的副本文件。
    while (_playbackCopies.length > _maxPlaybackCopies) {
      final oldestKey = _playbackCopies.keys.first;
      final oldest = _playbackCopies.remove(oldestKey);
      if (oldest != null && oldest != copied) {
        try {
          final f = File(oldest);
          if (f.existsSync()) f.deleteSync();
        } catch (_) {}
      }
    }
    return copied;
  }

  /// 封面自愈：列表/播放页发现某 SAF 歌曲无缓存封面时，重新打开 fd 提取
  /// 内嵌封面并写入封面缓存，返回缩略图路径（无封面/失败返回空串）。
  static Future<String> extractCoverToCache(
    String songPath,
    String cacheRoot,
  ) async {
    if (!isSupported || !isSafPath(songPath)) return '';
    final marker = '/document/';
    final idx = songPath.indexOf(marker);
    if (idx < 0) return '';
    final treeUri = songPath.substring(0, idx);
    final docId = songPath.substring(idx + marker.length);

    final fd = await openFd(treeUri, docId);
    if (fd < 0) return '';
    try {
      return await extractSongCoverThumbnailFromFd(
        cacheRoot: cacheRoot,
        path: songPath,
        fd: fd,
      );
    } catch (_) {
      return '';
    } finally {
      await closeFd(fd);
    }
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