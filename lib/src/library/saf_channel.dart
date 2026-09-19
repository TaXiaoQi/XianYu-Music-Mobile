import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../rust/api.dart';

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

class MediaFolderInfo {
  final String path;
  final int count;
  const MediaFolderInfo({required this.path, required this.count});

  factory MediaFolderInfo.fromJson(Map<String, dynamic> j) => MediaFolderInfo(
        path: j['path'] as String? ?? '',
        count: (j['count'] as num?)?.toInt() ?? 0,
      );
}

class SafChannel {
  static const _channel = MethodChannel('xianyu/saf');

  static bool get isSupported => Platform.isAndroid;

  static Future<int> androidSdkInt() async {
    if (!isSupported) return 0;
    return await _channel.invokeMethod<int>('getSdkInt') ?? 0;
  }

  static Future<String?> chooseFolderTree({bool persist = true}) async {
    if (!isSupported) return null;
    final raw = await _channel.invokeMethod<String>('chooseFolderTree', {
      'persist': persist,
    });
    return (raw == null || raw.isEmpty) ? null : raw;
  }

  static Future<void> persistPermission(String treeUri) async {
    if (!isSupported) return;
    await _channel.invokeMethod('persistPermission', {'uri': treeUri});
  }

  static Future<bool> isTreePersisted(String treeUri) async {
    if (!isSupported) return false;
    return await _channel.invokeMethod<bool>('isTreePersisted',
            {'uri': treeUri}) ??
        false;
  }

  static Future<bool> isTreeAvailable(String treeUri) async {
    if (!isSupported) return false;
    return await _channel.invokeMethod<bool>('isTreeAvailable',
            {'uri': treeUri}) ??
        false;
  }

  static Future<void> releasePermission(String treeUri) async {
    if (!isSupported) return;
    await _channel.invokeMethod('releasePermission', {'uri': treeUri});
  }

  static Future<String> friendlyTreeName(String treeUri) async {
    if (!isSupported) return treeUri;
    return await _channel.invokeMethod<String>('friendlyTreeName',
            {'uri': treeUri}) ??
        treeUri;
  }

  static Future<List<MediaFolderInfo>> listMediaAudioFolders() async {
    if (!isSupported) return const [];
    final raw =
        await _channel.invokeMethod<String>('listMediaAudioFolders') ?? '[]';
    return (jsonDecode(raw) as List)
        .map((e) => MediaFolderInfo.fromJson(e as Map<String, dynamic>))
        .toList();
  }

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

  static Future<int> openFd(String treeUri, String docId) async {
    if (!isSupported) return -1;
    return await _channel
            .invokeMethod<int>('openFd', {'uri': treeUri, 'docId': docId}) ??
        -1;
  }

  static Future<String> createTreeFile(
    String treeUri,
    String fileName,
    String content,
  ) async {
    if (!isSupported) return '';
    return await _channel.invokeMethod<String>('createTreeFile', {
          'uri': treeUri,
          'fileName': fileName,
          'content': content,
        }) ??
        '';
  }

  static Future<void> closeFd(int fd) async {
    if (!isSupported) return;
    await _channel.invokeMethod('closeFd', {'fd': fd});
  }

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

  static final Map<String, String> _playbackCopies = {};
  static const _maxPlaybackCopies = 3;

  static void clearScannedCopiesRoot(String tempRoot) {
    final dir = Directory(tempRoot);
    if (!dir.existsSync()) return;
    try {
      for (final e in dir.listSync()) {
        if (e is File) e.deleteSync();
      }
    } catch (_) {}
  }

  static Future<String> ensureLocalPlaybackCopy(
    String songPath,
    String tempRoot,
  ) async {
    if (!isSafPath(songPath)) return songPath;

    final cached = _playbackCopies.remove(songPath);
    if (cached != null && File(cached).existsSync()) {
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
    if (_playbackCopies.isEmpty) {
      try {
        for (final e in dir.listSync()) {
          if (e is File) e.deleteSync();
        }
      } catch (_) {}
    }
    final copied = await copyTreeDocToInternal(treeUri, docId, dir.path);
    if (copied.isEmpty) return songPath;

    _playbackCopies[songPath] = copied;
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

  static String treeRootDocId(String treeUri) {
    final uri = Uri.parse(treeUri);
    final seg = uri.pathSegments.isNotEmpty ? uri.pathSegments.last : '';
    return Uri.decodeComponent(seg);
  }

  static String treeRootPath(String treeUri) =>
      '$treeUri/document/${treeRootDocId(treeUri)}';

  static String songPath(String treeUri, String docId) =>
      '$treeUri/document/$docId';

  static bool isSafPath(String pathOrUri) => pathOrUri.startsWith('content://');

  static bool isSafTree(String pathOrUri) =>
      isSupported && pathOrUri.startsWith('content://');
}