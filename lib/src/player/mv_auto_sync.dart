library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../core/application_logger.dart';
import '../rust/api.dart';
import 'mv_source.dart';

/// 最近一次起播的音频源（由 player_provider 的 `_GatedAudioPlayer` 在
/// setUrl / setFilePath 时捕获），供 MV 频谱对齐取当前歌曲的真实音源。
class LastAudioSource {
  LastAudioSource._();

  /// 网络起播 URL（在线直链或本地代理 URL）。
  static String? url;

  /// 本地文件起播路径（本地歌曲 / 解密缓存 / 远程缓存）。
  static String? filePath;

  /// 该 URL 对应的请求头（在线直链场景）。
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

/// 频谱对齐结果。
class MvAutoSyncResult {
  final int offsetMs;

  final double confidence;

  const MvAutoSyncResult(this.offsetMs, this.confidence);
}

/// 按歌曲身份缓存的频谱对齐偏移（进程内，一次分析终身受益）。
final Map<String, int> mvSyncOffsetCache = <String, int>{};

int? mvCachedSyncOffset(String identity) => mvSyncOffsetCache[identity];

/// 全局单飞：同一时刻只跑一个频谱分析（下载 + 解码都不便宜）。
String? _activeSyncIdentity;

/// 从本地代理 URL（`http://127.0.0.1:port/token/audio?u=<encoded>`）
/// 还原真实音源 URL；非代理 URL 原样返回。
String? _realUrlFromProxy(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return null;
  final u = uri.queryParameters['u'];
  return (u != null && u.startsWith('http')) ? u : null;
}

/// 分析指定歌曲与 MV 源的频谱偏移，成功且可信时写入缓存并返回结果。
///
/// - [identity]：歌曲身份（缓存 key，复用 MvNotifier 的 `_songIdentity`）。
/// - [resolveSource]：按画质解析 MV 源（会依次尝试候选画质）。
/// - [qualities]：候选画质列表（如 `['360P', '480P', '720P']`）。
/// - [songPath]：本地歌曲文件路径（为空则走 [songUrl] 下载）。
/// - [songUrl] / [songHeaders]：在线歌曲的真实直链与请求头。
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
    // 1. 解析并下载低画质 MV（音轨与高清一致，8~20MB）。
    String? mvPath;
    MvSource? mvSrc;
    for (final q in qualities) {
      final src = await resolveSource(q);
      if (src == null || src.url.isEmpty) continue;
      mvSrc = src;
      // 主地址失败再试备用地址（与播放器的多候选兜底一致）。
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

    // 2. 取歌曲音频：本地文件直接用；在线歌曲下载直链（最多 110s 参与
    //    分析，但为兼容 moov 在尾部的 m4a 只能整文件下载）。
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

    // 3. 调 Rust 做包络互相关。
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

/// 用 Rust 下载器把 URL 流式写入应用缓存（跟随重定向 + 带请求头），
/// 返回缓存路径；失败返回 null。
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

/// 应用缓存根目录（downloadVideoToCache 约定传入 getApplicationCacheDirectory）。
Future<String?> mvSyncCacheDir() async {
  try {
    return (await getApplicationCacheDirectory()).path;
  } catch (_) {
    return null;
  }
}
