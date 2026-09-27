library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../core/application_logger.dart';
import '../rust/api.dart';
import 'mv_source.dart';

class LastAudioSource {
  LastAudioSource._();

  static String? url;

  static String? filePath;

  static Map<String, String>? headers;

  static void recordUrl(String u, Map<String, String>? h) {
    url = u;
    filePath = null;
    headers = (h == null || h.isEmpty) ? null : h;
  }

  static void recordFilePath(String p) {
    filePath = p;
    url = null;
    headers = null;
  }
}

class MvAutoSyncResult {
  final int offsetMs;

  final double confidence;

  const MvAutoSyncResult(this.offsetMs, this.confidence);
}

final Map<String, int> mvSyncOffsetCache = <String, int>{};

int? mvCachedSyncOffset(String identity) => mvSyncOffsetCache[identity];

String? _activeSyncIdentity;

String? _realUrlFromProxy(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return null;
  final u = uri.queryParameters['u'];
  return (u != null && u.startsWith('http')) ? u : null;
}

Future<MvAutoSyncResult?> analyzeMvSyncForSong({
  required String identity,
  required Future<MvSource?> Function(String quality) resolveSource,
  required List<String> qualities,
  required String cacheDir,
  String? songPath,
  String? songUrl,
  Map<String, String>? songHeaders,
}) async {
  if (identity.isEmpty) return null;
  if (mvSyncOffsetCache.containsKey(identity)) {
    return MvAutoSyncResult(
      mvSyncOffsetCache[identity]!,
      1.0,
    );
  }
  if (_activeSyncIdentity != null) {
    AppLog.debug('mv', '[autoSync] skip: analyzing $_activeSyncIdentity');
    return null;
  }
  _activeSyncIdentity = identity;
  final List<String> downloaded = <String>[];
  try {
    String? mvPath;
    MvSource? mvSrc;
    for (final q in qualities) {
      final src = await resolveSource(q);
      if (src == null || src.url.isEmpty) continue;
      mvSrc = src;
      for (final u in [src.url, ...src.backupUrls]) {
        mvPath = await _downloadToCache(
          cacheDir,
          u,
          src.headers,
          downloaded,
        );
        if (mvPath != null) break;
      }
      if (mvPath != null) break;
      AppLog.warn('mv', '[autoSync] MV $q 下载失败，尝试下一档');
    }
    if (mvPath == null || mvSrc == null) {
      AppLog.warn('mv', '[autoSync] 无可用 MV 源，跳过分析');
      return null;
    }

    String? songFile;
    if (songPath != null && songPath.isNotEmpty) {
      final f = File(songPath);
      if (f.existsSync() && f.lengthSync() > 0) {
        songFile = songPath;
      }
    }
    if (songFile == null) {
      final realUrl = _realUrlFromProxy(songUrl ?? '') ?? songUrl;
      if (realUrl == null ||
          !(realUrl.startsWith('http://') || realUrl.startsWith('https://'))) {
        AppLog.warn('mv', '[autoSync] 无可分析音源，跳过分析');
        return null;
      }
      songFile = await _downloadToCache(
        cacheDir,
        realUrl,
        songHeaders,
        downloaded,
      );
    }
    if (songFile == null) {
      AppLog.warn('mv', '[autoSync] 歌曲音频下载失败，跳过分析');
      return null;
    }

    final raw = await analyzeMvSync(mvPath: mvPath, songPath: songFile)
        .timeout(const Duration(minutes: 5));
    final json = jsonDecode(raw);
    if (json is! Map || json['ok'] != true) {
      AppLog.warn('mv',
          '[autoSync] 分析失败: ${json is Map ? json['reason'] : raw}');
      return null;
    }
    final offsetMs = (json['offsetMs'] as num?)?.toInt() ?? 0;
    final confidence = (json['confidence'] as num?)?.toDouble() ?? 0.0;
    if (json['trustworthy'] != true) {
      AppLog.info('mv',
          '[autoSync] 置信度不足(${confidence.toStringAsFixed(3)})，保持环形映射');
      return null;
    }
    mvSyncOffsetCache[identity] = offsetMs;
    AppLog.info('mv',
        '[autoSync] ok offset=${offsetMs}ms conf=${confidence.toStringAsFixed(3)} '
        'mv=${mvSrc.videoQuality}');
    return MvAutoSyncResult(offsetMs, confidence);
  } catch (e) {
    AppLog.warn('mv', '[autoSync] 异常: $e');
    return null;
  } finally {
    if (_activeSyncIdentity == identity) {
      _activeSyncIdentity = null;
    }
    for (final p in downloaded) {
      unawaited(
        removeCachedBackgroundVideo(cacheDir: cacheDir, path: p)
            .catchError((_) {}),
      );
    }
  }
}

Future<MvAutoSyncResult?> analyzeMvLocalForSong({
  required String identity,
  required Future<MvSource?> Function(String quality) resolveSource,
  required List<String> qualities,
  required String cacheDir,
  required double songPosSec,
  required double songDurationSec,
  double windowSec = 15.0,
  String? songPath,
  String? songUrl,
  Map<String, String>? songHeaders,
}) async {
  if (identity.isEmpty) return null;
  if (mvSyncOffsetCache.containsKey(identity)) {
    return MvAutoSyncResult(mvSyncOffsetCache[identity]!, 1.0);
  }
  if (_activeSyncIdentity != null) {
    AppLog.debug('mv', '[autoSync.local] skip: analyzing $_activeSyncIdentity');
    return null;
  }
  _activeSyncIdentity = identity;
  final List<String> downloaded = <String>[];
  try {
    String? mvPath;
    MvSource? mvSrc;
    for (final q in qualities) {
      final src = await resolveSource(q);
      if (src == null || src.url.isEmpty) continue;
      mvSrc = src;
      for (final u in [src.url, ...src.backupUrls]) {
        mvPath = await _downloadToCache(cacheDir, u, src.headers, downloaded);
        if (mvPath != null) break;
      }
      if (mvPath != null) break;
      AppLog.warn('mv', '[autoSync.local] MV $q 下载失败，尝试下一档');
    }
    if (mvPath == null || mvSrc == null) {
      AppLog.warn('mv', '[autoSync.local] 无可用 MV 源，跳过分析');
      return null;
    }

    String? songFile;
    if (songPath != null && songPath.isNotEmpty) {
      final f = File(songPath);
      if (f.existsSync() && f.lengthSync() > 0) songFile = songPath;
    }
    if (songFile == null) {
      final realUrl = _realUrlFromProxy(songUrl ?? '') ?? songUrl;
      if (realUrl == null ||
          !(realUrl.startsWith('http://') || realUrl.startsWith('https://'))) {
        AppLog.warn('mv', '[autoSync.local] 无可分析音源，跳过分析');
        return null;
      }
      songFile = await _downloadToCache(
          cacheDir, realUrl, songHeaders, downloaded);
    }
    if (songFile == null) {
      AppLog.warn('mv', '[autoSync.local] 歌曲音频下载失败，跳过分析');
      return null;
    }

    final raw = await analyzeMvSyncLocal(
      mvPath: mvPath,
      songPath: songFile,
      songPosSec: songPosSec,
      songDurSec: songDurationSec,
      windowSec: windowSec,
    ).timeout(const Duration(minutes: 5));
    final json = jsonDecode(raw);
    if (json is! Map || json['ok'] != true) {
      AppLog.warn('mv',
          '[autoSync.local] 分析失败: ${json is Map ? json['reason'] : raw}');
      return null;
    }
    final offsetMs = (json['offsetMs'] as num?)?.toInt() ?? 0;
    final confidence = (json['confidence'] as num?)?.toDouble() ?? 0.0;
    if (json['trustworthy'] != true) {
      AppLog.info('mv',
          '[autoSync.local] 置信度不足(${confidence.toStringAsFixed(3)})，保持环形映射');
      return null;
    }
    mvSyncOffsetCache[identity] = offsetMs;
    AppLog.info('mv',
        '[autoSync.local] ok offset=${offsetMs}ms conf=${confidence.toStringAsFixed(3)} '
        'anchor=${songPosSec.toStringAsFixed(1)}s mv=${mvSrc.videoQuality}');
    return MvAutoSyncResult(offsetMs, confidence);
  } catch (e) {
    AppLog.warn('mv', '[autoSync.local] 异常: $e');
    return null;
  } finally {
    if (_activeSyncIdentity == identity) {
      _activeSyncIdentity = null;
    }
    for (final p in downloaded) {
      unawaited(
        removeCachedBackgroundVideo(cacheDir: cacheDir, path: p)
            .catchError((_) {}),
      );
    }
  }
}

Future<String?> _downloadToCache(
  String cacheDir,
  String url,
  Map<String, String>? headers,
  List<String> downloaded,
) async {
  String result = '';
  try {
    result = await downloadVideoToCache(
      cacheDir: cacheDir,
      url: url,
      headers: (headers == null || headers.isEmpty) ? null : headers,
    );
  } catch (e) {
    AppLog.warn('mv', '[autoSync] 下载失败 $e');
    return null;
  }
  if (result.isEmpty) return null;
  downloaded.add(result);
  return result;
}

Future<String?> mvSyncCacheDir() async {
  try {
    return (await getApplicationCacheDirectory()).path;
  } catch (_) {
    return null;
  }
}
