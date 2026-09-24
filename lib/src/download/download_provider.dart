import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import 'download_notification_service.dart';
import 'media_store_writer.dart';
import '../widgets/app_toast.dart';
import '../core/db_path.dart';
import '../core/application_logger.dart';
import '../core/platform_caps.dart';
import '../core/settings.dart';
import '../player/player_provider.dart';
import '../player/media_url.dart';
import '../player/mv_source.dart';
import '../player/online_quality_probe.dart';
import '../plugin/plugin_engine.dart';
import '../plugin/plugin_models.dart';
import '../plugin/plugin_provider.dart';
import '../lyrics/lyrics_repository.dart';
import '../rust/api.dart';
import '../i18n/i18n.dart';

enum DownloadStatus { waiting, downloading, done, failed }

class DownloadTask {
  final String songPath;
  final String title;
  final String artist;
  final String album;
  final String quality;
  final String? coverUrl;
  final String? source;
  final String? onlineSongJson;
  final String? onlineInfoJson;
  final DownloadStatus status;
  final String? error;
  final String? filePath;
  final int startedAt;
  final int progressPercent;

  const DownloadTask({
    required this.songPath,
    required this.title,
    required this.artist,
    required this.album,
    required this.quality,
    this.coverUrl,
    this.source,
    this.onlineSongJson,
    this.onlineInfoJson,
    this.status = DownloadStatus.downloading,
    this.error,
    this.filePath,
    required this.startedAt,
    this.progressPercent = 0,
  });

  DownloadTask copyWith({
    DownloadStatus? status,
    String? error,
    String? filePath,
    int? progressPercent,
  }) {
    return DownloadTask(
      songPath: songPath,
      title: title,
      artist: artist,
      album: album,
      quality: quality,
      coverUrl: coverUrl,
      source: source,
      onlineSongJson: onlineSongJson,
      onlineInfoJson: onlineInfoJson,
      status: status ?? this.status,
      error: error ?? this.error,
      filePath: filePath ?? this.filePath,
      startedAt: startedAt,
      progressPercent: progressPercent ?? this.progressPercent,
    );
  }
}

class DownloadHistoryEntry {
  final String songPath;
  final String filePath;
  final String fileName;
  final String quality;
  final int downloadedAt;
  final String? title;
  final String? artist;

  const DownloadHistoryEntry({
    required this.songPath,
    required this.filePath,
    required this.fileName,
    required this.quality,
    required this.downloadedAt,
    this.title,
    this.artist,
  });

  Map<String, dynamic> toJson() => {
        'songPath': songPath,
        'filePath': filePath,
        'fileName': fileName,
        'quality': quality,
        'downloadedAt': downloadedAt,
        if (title != null) 'title': title,
        if (artist != null) 'artist': artist,
      };

  factory DownloadHistoryEntry.fromJson(Map<String, dynamic> j) =>
      DownloadHistoryEntry(
        songPath: j['songPath'] as String? ?? '',
        filePath: j['filePath'] as String? ?? '',
        fileName: j['fileName'] as String? ?? '',
        quality: j['quality'] as String? ?? '',
        downloadedAt: (j['downloadedAt'] as num?)?.toInt() ?? 0,
        title: j['title'] as String?,
        artist: j['artist'] as String?,
      );

  QueueItem toQueueItem() => QueueItem(
        path: filePath,
        title: title ?? fileName,
        artist: artist ?? '',
        album: '',
      );
}

class DownloadState {
  final List<DownloadTask> tasks;
  final List<DownloadHistoryEntry> history;
  final bool loading;

  const DownloadState({
    this.tasks = const [],
    this.history = const [],
    this.loading = false,
  });

  DownloadState copyWith({
    List<DownloadTask>? tasks,
    List<DownloadHistoryEntry>? history,
    bool? loading,
  }) {
    return DownloadState(
      tasks: tasks ?? this.tasks,
      history: history ?? this.history,
      loading: loading ?? this.loading,
    );
  }
}

class DownloadManager extends StateNotifier<DownloadState> {
  DownloadManager(this._ref) : super(const DownloadState()) {
    _loadHistory();
  }

  final Ref _ref;

  final List<DownloadTask> _pending = [];
  int _active = 0;

  Future<void> _loadHistory() async {
    try {
      final dataDir = await _ref.read(appDataDirProvider.future);
      final json = await readDownloadHistory(dataDir: dataDir);
      final map = jsonDecode(json) as Map<String, dynamic>;
      final history = map.values
          .whereType<Map>()
          .map((e) => DownloadHistoryEntry.fromJson(e.cast<String, dynamic>()))
          .toList()
        ..sort((a, b) => b.downloadedAt.compareTo(a.downloadedAt));
      state = state.copyWith(history: history, loading: false);
    } catch (_) {
      state = state.copyWith(loading: false);
    }
  }

  Future<String> _downloadDir() async {
    if (Platform.isIOS || PlatformCaps.isOhos) {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(docs.path, 'Downloads'));
      if (!dir.existsSync()) dir.createSync(recursive: true);
      return dir.path;
    }
    final settings = _ref.read(settingsProvider).valueOrNull;
    final custom = settings?.downloadPath ?? '';
    if (custom.isNotEmpty) return custom;
    try {
      final d = await getDownloadsDirectory();
      if (d != null) return d.path;
    } catch (_) {}
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'Downloads'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir.path;
  }

  bool get hasCustomDownloadDir =>
      (!Platform.isAndroid && !Platform.isIOS) ||
      (_ref.read(settingsProvider).valueOrNull?.downloadPath ?? '').isNotEmpty;

  Future<String> downloadMvVideo({
    required QueueItem item,
    required MvSource source,
    required String qualityKey,
  }) async {
    final settings = _ref.read(settingsProvider).valueOrNull;
    final dir = await _downloadDir();
    final base = await buildDownloadBasename(
      title: item.title,
      artist: item.artist,
      album: item.album,
      fileNameStyle: settings?.downloadFileNameStyle ?? 'artist-title',
    );
    final destPath = await resolveDownloadPath(
      directory: dir,
      fileName: '$base ($qualityKey).mp4',
      overwriteExisting: settings?.overwriteExisting ?? false,
    );
    final headersJson = jsonEncode(source.headers);
    Object? lastError;
    for (final candidate in [source.url, ...source.backupUrls]) {
      try {
        await downloadOnlineSong(
          url: candidate,
          destPath: destPath,
          headersJson: headersJson,
        );
        return destPath;
      } catch (e) {
        lastError = e;
        ApplicationLogManager.instance
            .warn('下载', 'MV 直链下载失败，尝试备用链：$e');
      }
    }
    throw lastError ?? StateError(tr('MV 下载失败'));
  }

  Future<bool> requireDownloadDir(BuildContext context) async {
    if (Platform.isIOS || PlatformCaps.isOhos) return true;
    if (!hasCustomDownloadDir) {
      showXianYuToast(context, tr('请先前往设置下载目录'));
      return false;
    }
    if (Platform.isAndroid) {
      final status = await Permission.manageExternalStorage.status;
      if (!context.mounted) return false;
      if (!status.isGranted) {
        showXianYuToast(
            context, tr('未授予所有文件访问权限，将尝试兼容模式写入'));
      }
    }
    return true;
  }

  Future<void> download(QueueItem item, {String? quality}) async {
    if (!item.isOnline) return;
    if (!hasCustomDownloadDir) return;
    if (state.tasks.any((t) =>
        t.songPath == item.path &&
        (t.status == DownloadStatus.waiting ||
            t.status == DownloadStatus.downloading))) {
      return;
    }

    final settings = _ref.read(settingsProvider).valueOrNull;
    final q = quality ??
        settings?.downloadQuality ??
        item.onlineQuality ??
        '320k';

    final task = DownloadTask(
      songPath: item.path,
      title: item.title,
      artist: item.artist,
      album: item.album,
      quality: q,
      coverUrl: item.coverUrl,
      source: item.source,
      onlineSongJson: item.onlineSongJson,
      onlineInfoJson: item.onlineInfoJson,
      status: DownloadStatus.waiting,
      startedAt: DateTime.now().millisecondsSinceEpoch,
    );
    state = state.copyWith(
        tasks: [task, ...state.tasks.where((t) => t.songPath != item.path)]);
    _pending.add(task);
    _drain();
  }

  Future<bool> isAlreadyDownloaded(String songPath) async {
    final matched = state.history
        .where((h) => h.songPath == songPath && h.filePath.isNotEmpty)
        .toList()
      ..sort((a, b) => b.downloadedAt.compareTo(a.downloadedAt));
    for (final h in matched) {
      try {
        if (await File(h.filePath).exists()) return true;
      } catch (_) {}
    }
    return false;
  }

  void _drain() {
    final settings = _ref.read(settingsProvider).valueOrNull;
    final limit = (settings?.downloadConcurrency ?? 3).clamp(1, 5);
    while (_active < limit && _pending.isNotEmpty) {
      final task = _pending.removeAt(0);
      _active++;
      _updateTask(task.songPath, status: DownloadStatus.downloading);
      _execute(task);
    }
  }

  Future<void> _execute(DownloadTask task) async {
    try {
      _updateTask(task.songPath, status: DownloadStatus.downloading, progressPercent: 15);
      final (filePath, usedQuality) =
          await _performDownload(task, _ref.read(settingsProvider).valueOrNull);
      final entry = DownloadHistoryEntry(
        songPath: task.songPath,
        filePath: filePath,
        fileName: fileNameFromPath(filePath),
        quality: usedQuality,
        downloadedAt: DateTime.now().millisecondsSinceEpoch,
        title: task.title,
        artist: task.artist,
      );
      await _recordHistory(entry);
      _updateTask(task.songPath, status: DownloadStatus.done, filePath: filePath, progressPercent: 100);
    } catch (e) {
      _updateTask(
          task.songPath,
          status: DownloadStatus.failed,
          error: e is PluginEngineException
              ? e.message
              : tr('下载失败：{e}', {'e': e.toString()}));
    } finally {
      _active--;
      _drain();
    }
  }

  Future<(String, String)> _performDownload(
      DownloadTask task, AppSettings? settings) async {
    final item = QueueItem(
      path: task.songPath,
      title: task.title,
      artist: task.artist,
      album: task.album,
      coverUrl: task.coverUrl,
      source: task.source,
      onlineSongJson: task.onlineSongJson,
      onlineInfoJson: task.onlineInfoJson,
    );
    final songJson = item.onlineSongJson ?? item.onlineInfoJson;
    if (songJson == null || songJson.isEmpty) {
      throw StateError(tr('在线歌曲信息缺失'));
    }
    final parsed = jsonDecode(songJson) as Map<String, dynamic>;

    var usedQuality = task.quality;
    String? url;
    Map<String, String>? urlHeaders;
    String? ekey;
    for (final q in _qualityCandidates(
        task.quality, settings?.downloadQualityFallbackBehavior ?? 'lower')) {
      ResolvedMediaUrl? tried;
      try {
        tried = parsed.containsKey('pluginId')
            ? await _resolvePluginUrl(parsed, q)
            : await _resolveLxUrl(songJson, q);
      } on PluginEngineException catch (e) {
        // 鉴权失效（卡密/401）时终止下载任务，不再逐档空转
        if (PluginEngine.isAuthFailureMessage(e.message)) rethrow;
        continue;
      }
      if (tried == null) continue;
      final u = tried.url;
      final reported = tried.quality ?? q;
      final effective = resolveActualQuality(reported, u);
      if (effective != reported) {
        continue;
      }
      url = u;
      urlHeaders = tried.headers;
      ekey = tried.ekey;
      usedQuality = effective;
      break;
    }
    if (url == null) throw StateError(tr('直链解析失败'));

    final dlHeaders = await withBilibiliStreamCookie(
      url,
      normalizeMediaRequestHeaders(url, urlHeaders),
      dataDir: _ref.read(appDataDirProvider.future),
    );
    final headersJson = jsonEncode(dlHeaders ?? <String, String>{});

    _updateTask(task.songPath, progressPercent: 40);

    final dir = await _downloadDir();
    final destPath = await resolveDownloadFullPath(
      directory: dir,
      title: item.title,
      artist: item.artist,
      album: item.album,
      url: url,
      quality: usedQuality,
      keepSourceFilename: settings?.keepSourceFilename ?? false,
      fileNameStyle: settings?.downloadFileNameStyle ?? 'artist-title',
      overwriteExisting: settings?.overwriteExisting ?? false,
    );

    _updateTask(task.songPath, progressPercent: 60);

    var finalPath = destPath;
    try {
      await downloadOnlineSong(
        url: url,
        destPath: destPath,
        ekey: ekey,
        headersJson: headersJson,
      );
    } catch (e) {
      final msg = e.toString();
      final directWriteFailure = msg.contains('创建目标文件失败') ||
          msg.contains('写入文件失败') ||
          msg.contains('创建下载目录失败');
      if (!directWriteFailure) rethrow;
      ApplicationLogManager.instance.warn(
          '下载', '直写 $destPath 失败，回退 MediaStore 兼容模式：$msg');
      final fallback = await _mediaStoreFallback(
        url: url,
        dir: dir,
        destPath: destPath,
        item: item,
        parsed: parsed,
        settings: settings,
        headersJson: headersJson,
        ekey: ekey,
      );
      if (fallback == null) {
        ApplicationLogManager.instance
            .error('下载', 'MediaStore 回退也失败：$msg');
        rethrow;
      }
      ApplicationLogManager.instance
          .warn('下载', '已回退写入：$fallback（目标目录 ${p.basename(dir)}）');
      finalPath = fallback;
    }

    _updateTask(task.songPath, progressPercent: 85);

    if (finalPath == destPath) {
      final wantLyrics = settings?.downloadLyrics ?? true;
      if (wantLyrics || (settings?.embedDownloadLyrics ?? false)) {
        await _finalizeExtras(item, destPath, parsed, settings);
      }
    }

    _updateTask(task.songPath, progressPercent: 95);

    return (finalPath, usedQuality);
  }

  Future<String?> _mediaStoreFallback({
    required String url,
    required String dir,
    required String destPath,
    required QueueItem item,
    required Map<String, dynamic> parsed,
    AppSettings? settings,
    required String headersJson,
    String? ekey,
  }) async {
    if (!Platform.isAndroid) return null;
    if (!await MediaStoreWriter.available) return null;
    try {
      final cache = await getTemporaryDirectory();
      final ext = p.extension(destPath);
      final tempPath = p.join(cache.path,
          'dl_fallback_${DateTime.now().microsecondsSinceEpoch}$ext');
      await downloadOnlineSong(
        url: url,
        destPath: tempPath,
        ekey: ekey,
        headersJson: headersJson,
      );

      final saveLyricsFile = settings?.downloadLyrics ?? true;
      final wantLyrics =
          saveLyricsFile || (settings?.embedDownloadLyrics ?? false);
      if (wantLyrics) {
        await _finalizeExtras(item, tempPath, parsed, settings);
      }

      final relativePath = _mediaRelativePath(dir);
      final finalPath = await MediaStoreWriter.writeFromPath(
        relativePath: relativePath,
        displayName: p.basename(destPath),
        mime: _mimeFromExtension(ext),
        srcPath: tempPath,
      );
      if (finalPath == null) return null;

      final baseNoExt = tempPath.substring(0, tempPath.length - ext.length);
      final fmt = settings?.downloadLyricsFormat ?? 'lrc';
      final tempLyrics = File('$baseNoExt.$fmt');
      if (saveLyricsFile && await tempLyrics.exists()) {
        await MediaStoreWriter.writeFromPath(
          relativePath: 'Download/弦予',
          displayName:
              '${p.basenameWithoutExtension(destPath)}.$fmt',
          mime: 'application/octet-stream',
          srcPath: tempLyrics.path,
        );
      }
      for (final f in [File(tempPath), tempLyrics, File('$baseNoExt.cover')]) {
        try {
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
      return finalPath;
    } catch (_) {
      return null;
    }
  }

  static String _mediaRelativePath(String dir) {
    final norm = dir.replaceAll('\\', '/');
    final m = RegExp(r'/storage/[^/]+/(Music|Download)(/.*)?$').firstMatch(norm);
    if (m != null) {
      final sub = (m.group(2) ?? '').replaceAll(RegExp(r'^/+|/+$'), '');
      return sub.isEmpty ? '${m.group(1)}/弦予' : '${m.group(1)}/$sub';
    }
    return 'Music/弦予';
  }

  static String _mimeFromExtension(String ext) {
    switch (ext.toLowerCase()) {
      case '.mp3':
        return 'audio/mpeg';
      case '.m4a':
      case '.mp4':
        return 'audio/mp4';
      case '.ogg':
      case '.opus':
        return 'audio/ogg';
      case '.wav':
        return 'audio/wav';
      case '.flac':
        return 'audio/flac';
      case '.ape':
        return 'audio/x-ape';
      case '.wma':
        return 'audio/x-ms-wma';
      case '.dsf':
      case '.dff':
        return 'audio/x-dsd';
      default:
        return 'application/octet-stream';
    }
  }

  Future<void> _finalizeExtras(
      QueueItem item, String filePath, Map<String, dynamic> parsed,
      AppSettings? settings) async {
    try {
      final embedMetadata = settings?.embedDownloadMetadata ?? true;
      final embedLyrics = settings?.embedDownloadLyrics ?? false;
      final embedCover = settings?.embedDownloadCover ?? true;
      final saveLyricsFile = settings?.downloadLyrics ?? true;

      if (!embedMetadata && !embedLyrics && !embedCover && !saveLyricsFile) {
        return;
      }

      final wordByWord =
          (settings?.downloadLyricsStyle ?? 'word-by-word') != 'line-by-line';
      String? lyricsText;
      if (saveLyricsFile || embedLyrics) {
        if (parsed.containsKey('pluginId')) {
          lyricsText = await _fetchPluginLyric(parsed, wordByWord: wordByWord);
        } else {
          final source = item.source ?? parsed['source'] ?? '';
          if (source.isNotEmpty) {
            lyricsText = await _fetchLxLyric(source, item.onlineInfoJson ?? '',
                wordByWord: wordByWord);
          }
        }
        lyricsText ??= '';
      }

      final dot = filePath.lastIndexOf('.');
      final base = dot == -1 ? filePath : filePath.substring(0, dot);
      final lyricsFormat = settings?.downloadLyricsFormat ?? 'lrc';
      final convertedLyrics = _convertLyricsFormat(lyricsText ?? '', lyricsFormat);
      final request = jsonEncode({
        'lyricsText':
            (saveLyricsFile && convertedLyrics.isNotEmpty)
                ? convertedLyrics
                : null,
        'lyricsPath': '$base.$lyricsFormat',
        'coverUrl': embedCover ? item.coverUrl : null,
        'coverPath': '$base.cover',
        'metadata': embedMetadata
            ? {
                'filePath': filePath,
                'title': item.title.isEmpty ? null : item.title,
                'artist': item.artist.isEmpty ? null : item.artist,
                'album': item.album.isEmpty ? null : item.album,
                if (embedLyrics && convertedLyrics.isNotEmpty)
                  'lyrics': convertedLyrics,
              }
            : null,
        'embedCover': embedCover,
      });
      await finalizeDownloadExtras(requestJson: request);
    } catch (_) {
    }
  }

  static const List<String> _qualityLadder = [
    'mgg', '128k', '192k', '320k', 'flac', 'flac24bit',
    'hires', 'vinyl', 'dolby', 'atmos', 'atmos_plus', 'master',
  ];

  static List<String> _qualityCandidates(
      String preferred, String fallbackBehavior) {
    final desc = _qualityLadder.reversed.toList();
    final i = desc.indexOf(preferred);
    if (i < 0) return [preferred, ...desc];
    if (fallbackBehavior == 'higher') {
      final asc = _qualityLadder.indexOf(preferred);
      return asc < 0 ? [preferred, ...desc] : _qualityLadder.sublist(asc);
    }
    return desc.sublist(i);
  }

  Future<ResolvedMediaUrl?> _resolveLxUrl(String songJson, String quality) async {
    final engine = await _ref.read(pluginEngineProvider.future);
    final resolved = await engine
        .resolveLxUrl((jsonDecode(songJson) as Map).cast<String, dynamic>(), quality);
    final url = resolved?['url'] as String?;
    return (url == null || url.isEmpty) ? null : ResolvedMediaUrl(url: url);
  }

  Future<ResolvedMediaUrl?> _resolvePluginUrl(
      Map<String, dynamic> songJson, String quality) async {
    final pluginId = songJson['pluginId'] as String?;
    final sourceKey = songJson['source'] as String? ?? '';
    final musicInfo = songJson['musicInfo'] as Map<String, dynamic>? ?? {};
    final format = songJson['format'] as String? ?? 'lx';
    if (pluginId == null || pluginId.isEmpty) throw StateError(tr('插件信息缺失'));

    final engine = await _ref.read(pluginEngineProvider.future);
    final sources = await engine.store.loadSources();
    final source = sources.where((s) => s.id == pluginId).toList();
    if (source.isEmpty) throw StateError(tr('插件未启用'));

    if (isMfFormatValue(format)) {
      return engine.getMusicFreeUrl(
        source.first,
        musicInfo,
        preferred: quality,
      );
    }

    final result =
        await engine.getMusicUrl(source.first, sourceKey, musicInfo, quality);
    final url = result?['url'] as String? ?? '';
    if (url.isEmpty || !RegExp(r'^https?://').hasMatch(url)) return null;
    final type = result?['type'];
    final reported =
        type is String && type.isNotEmpty
            ? PluginEngine.normalizeQualityKey(type)
            : null;
    return ResolvedMediaUrl(url: url, quality: reported);
  }

  Future<String?> _fetchLxLyric(String source, String songInfoJson,
      {required bool wordByWord}) async {
    if (songInfoJson.isEmpty) return null;
    final raw = await fetchLyricFromSource(
      source: source,
      songInfoJson: songInfoJson,
    );
    if (raw.isEmpty || raw == 'null') return null;
    final obj = jsonDecode(raw) as Map<String, dynamic>;
    final text = wordByWord
        ? (obj['lxlyric'] ?? obj['yrc'] ?? obj['qrc'] ?? obj['lyric'])
            as String? ?? ''
        : (obj['lyric'] as String?) ?? '';
    return text.isEmpty ? null : text;
  }

  Future<String?> _fetchPluginLyric(Map<String, dynamic> songJson,
      {required bool wordByWord}) async {
    final pluginId = songJson['pluginId'] as String?;
    final sourceKey = songJson['source'] as String? ?? '';
    final musicInfo = songJson['musicInfo'] as Map<String, dynamic>? ?? {};
    if (pluginId == null || pluginId.isEmpty) return null;

    final engine = await _ref.read(pluginEngineProvider.future);
    final sources = await engine.store.loadSources();
    final source = sources.where((s) => s.id == pluginId).toList();
    if (source.isEmpty) return null;

    final lyric = await engine.getLyric(source.first, sourceKey, musicInfo);
    if (lyric == null) return null;
    final text = wordByWord
        ? (lyric['lxlyric'] ??
                lyric['yrc'] ??
                lyric['qrc'] ??
                lyric['eslrc'] ??
                lyric['lyric']) as String? ??
            ''
        : (lyric['lyric'] as String?) ?? '';
    // 未解密的加密密文（QQ/酷我对特定歌曲返回 QRC/e-lrc hex）不能落盘
    if (text.isEmpty || pluginLyricLooksEncrypted(text)) return null;
    return text;
  }

  static String _convertLyricsFormat(String text, String format) {
    if (text.isEmpty) return text;
    if (format == 'txt') {
      return text
          .replaceAll(RegExp(r'\[\d{1,2}:\d{1,2}(?:[.:]\d{1,3})?\]'), '')
          .replaceAll(RegExp(r'<\d+,\d+>'), '')
          .replaceAll(RegExp(r'\[\d+,\d+\]'), '')
          .trim();
    }
    return text.trim();
  }

  Future<void> _recordHistory(DownloadHistoryEntry entry) async {
    final dataDir = await _ref.read(appDataDirProvider.future);
    final map = <String, dynamic>{};
    for (final e in state.history) {
      if (e.songPath != entry.songPath) map[e.songPath] = e.toJson();
    }
    map[entry.songPath] = entry.toJson();
    await writeDownloadHistory(dataDir: dataDir, content: jsonEncode(map));
    state = state.copyWith(
      history: [entry, ...state.history.where((e) => e.songPath != entry.songPath)],
    );
  }

  void _updateTask(
    String songPath, {
    DownloadStatus? status,
    String? error,
    String? filePath,
    int? progressPercent,
  }) {
    state = state.copyWith(
      tasks: state.tasks.map((t) {
        if (t.songPath != songPath) return t;
        return t.copyWith(
          status: status ?? t.status,
          error: error,
          filePath: filePath,
          progressPercent: progressPercent ?? t.progressPercent,
        );
      }).toList(),
    );
    _syncNotificationProgress();
  }

  void _syncNotificationProgress() {
    final activeTasks = state.tasks.where((t) =>
        t.status == DownloadStatus.downloading ||
        t.status == DownloadStatus.waiting ||
        t.status == DownloadStatus.done).toList();

    if (activeTasks.isEmpty) {
      DownloadNotificationService.dismiss();
      return;
    }

    final totalCount = activeTasks.length;
    final doneCount = activeTasks.where((t) => t.status == DownloadStatus.done).length;

    DownloadTask currentTask;
    final downloadingList = activeTasks.where((t) => t.status == DownloadStatus.downloading).toList();
    if (downloadingList.isNotEmpty) {
      currentTask = downloadingList.first;
    } else {
      currentTask = activeTasks.first;
    }

    final isAllDone = doneCount == totalCount && totalCount > 0;

    DownloadNotificationService.update(
      currentTitle: currentTask.title,
      currentArtist: currentTask.artist,
      doneCount: doneCount,
      totalCount: totalCount,
      progressPercent: isAllDone ? 100 : (currentTask.status == DownloadStatus.done ? 100 : currentTask.progressPercent),
      isFinished: isAllDone,
      isFailed: currentTask.status == DownloadStatus.failed,
    );
  }

  Future<void> removeHistory(String songPath) async {
    final dataDir = await _ref.read(appDataDirProvider.future);
    final map = <String, dynamic>{};
    for (final e in state.history) {
      if (e.songPath != songPath) map[e.songPath] = e.toJson();
    }
    await writeDownloadHistory(dataDir: dataDir, content: jsonEncode(map));
    state = state.copyWith(
        history: state.history.where((e) => e.songPath != songPath).toList());
  }

  Future<void> clearHistory({bool deleteFiles = false}) async {
    if (deleteFiles) {
      for (final entry in state.history) {
        try {
          if (entry.filePath.isNotEmpty) {
            await _deleteDownloadedFile(entry.filePath);
            final dot = entry.filePath.lastIndexOf('.');
            if (dot != -1) {
              final base = entry.filePath.substring(0, dot);
              await _deleteDownloadedFile('$base.lrc');
              await _deleteDownloadedFile('$base.cover');
            }
          }
        } catch (_) {}
      }
    }
    final dataDir = await _ref.read(appDataDirProvider.future);
    await writeDownloadHistory(dataDir: dataDir, content: '{}');
    state = state.copyWith(history: const []);
  }

  Future<void> _deleteDownloadedFile(String path) async {
    try {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
    if (await File(path).exists()) {
      await MediaStoreWriter.deleteMedia(path);
    }
  }

  void clearFinishedTasks() {
    state = state.copyWith(
        tasks: state.tasks
            .where((t) =>
                t.status == DownloadStatus.waiting ||
                t.status == DownloadStatus.downloading)
            .toList());
  }
}

String fileNameFromPath(String filePath) {
  final parts = filePath.split(RegExp(r'[\\/]'));
  return parts.last.isNotEmpty ? parts.last : filePath;
}

final downloadProvider =
    StateNotifierProvider<DownloadManager, DownloadState>((ref) {
  return DownloadManager(ref);
});
