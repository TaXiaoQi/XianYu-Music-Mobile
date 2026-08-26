import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/db_path.dart';
import '../core/settings.dart';
import '../player/player_provider.dart';
import '../plugin/plugin_engine.dart';
import '../plugin/plugin_provider.dart';
import '../rust/api.dart';

/// 下载任务状态。
enum DownloadStatus { waiting, downloading, done, failed }

/// 单个下载任务（在线歌曲）。
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
  });

  DownloadTask copyWith({
    DownloadStatus? status,
    String? error,
    String? filePath,
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
      error: error,
      filePath: filePath,
      startedAt: startedAt,
    );
  }
}

/// 下载记录（历史，与桌面端 download_history.json 结构一致）。
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

  /// 已下载文件可直接作为本地歌曲播放。
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

  /// 并发下载调度：等待队列 + 当前活动数。
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

  /// 下载目录：优先用户设置，否则系统下载目录，最后回退应用文档目录。
  Future<String> _downloadDir() async {
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

  /// 下载在线歌曲（插件音源或 lx:// 音源）。受并发上限控制，超出排队。
  ///
  /// [quality] 为调用方（下载音质弹窗）选定的档位；未指定时按
  /// 歌曲自带音质 → 设置下载音质 → 320k 依次回退。
  Future<void> download(QueueItem item, {String? quality}) async {
    if (!item.isOnline) return;
    if (state.tasks.any((t) =>
        t.songPath == item.path &&
        (t.status == DownloadStatus.waiting ||
            t.status == DownloadStatus.downloading))) {
      return;
    }

    final settings = _ref.read(settingsProvider).valueOrNull;
    final q = quality ??
        item.onlineQuality ??
        settings?.downloadQuality ??
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

  /// 按并发上限派发等待队列中的任务。
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
      _updateTask(task.songPath, status: DownloadStatus.done, filePath: filePath);
    } catch (e) {
      _updateTask(
          task.songPath,
          status: DownloadStatus.failed,
          error: e is PluginEngineException
              ? e.message
              : '下载失败：${e.toString()}');
    } finally {
      _active--;
      _drain();
    }
  }

  /// 返回 (目标路径, 实际命中的音质)。
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
      throw StateError('在线歌曲信息缺失');
    }
    final parsed = jsonDecode(songJson) as Map<String, dynamic>;

    // 1. 解析直链：按音质候选链降级（与播放器一致），实际命中的音质用于
    //    文件命名与历史记录。
    var usedQuality = task.quality;
    String? url;
    for (final q in _qualityCandidates(task.quality)) {
      final tried = parsed.containsKey('pluginId')
          ? await _resolvePluginUrl(parsed, q)
          : await _resolveLxUrl(songJson, q);
      if (RegExp(r'^https?://').hasMatch(tried)) {
        url = tried;
        usedQuality = q;
        break;
      }
    }
    if (url == null) throw StateError('直链解析失败');

    // 2. 解析目标路径（命名与冲突检测在 Rust 侧统一处理；移动端不转码，
    //    文件即直链源格式）。
    final dir = await _downloadDir();
    final destPath = await resolveDownloadFullPath(
      directory: dir,
      title: item.title,
      artist: item.artist,
      album: item.album,
      url: url,
      quality: usedQuality,
      keepSourceFilename: false,
      fileNameStyle: settings?.downloadFileNameStyle ?? 'artist-title',
      overwriteExisting: settings?.overwriteExisting ?? false,
    );

    // 3. 流式下载
    await downloadOnlineSong(
      url: url,
      destPath: destPath,
      ekey: null,
      headersJson: '{}',
    );

    // 4. 收尾：可选歌词（独立文件）与嵌入元数据/歌词/封面
    final wantLyrics = settings?.downloadLyrics ?? true;
    if (wantLyrics || (settings?.embedDownloadLyrics ?? false)) {
      await _finalizeExtras(item, destPath, parsed, settings);
    }

    return (destPath, usedQuality);
  }

  /// 下载收尾：保存独立歌词文件，并按设置嵌入元数据/歌词/封面到 tag。
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

      // 歌词文本：独立文件保存或嵌入 tag 都需要。
      String? lyricsText;
      if (saveLyricsFile || embedLyrics) {
        if (parsed.containsKey('pluginId')) {
          lyricsText = await _fetchPluginLyric(parsed);
        } else {
          final source = item.source ?? parsed['source'] ?? '';
          if (source.isNotEmpty) {
            lyricsText = await _fetchLxLyric(source, item.onlineInfoJson ?? '');
          }
        }
        lyricsText ??= '';
      }

      final dot = filePath.lastIndexOf('.');
      final base = dot == -1 ? filePath : filePath.substring(0, dot);
      final request = jsonEncode({
        'lyricsText':
            (saveLyricsFile && lyricsText != null && lyricsText.isNotEmpty)
                ? lyricsText
                : null,
        'lyricsPath': '$base.lrc',
        'coverUrl': embedCover ? item.coverUrl : null,
        'coverPath': '$base.cover',
        'metadata': embedMetadata
            ? {
                'filePath': filePath,
                'title': item.title.isEmpty ? null : item.title,
                'artist': item.artist.isEmpty ? null : item.artist,
                'album': item.album.isEmpty ? null : item.album,
                if (embedLyrics &&
                    lyricsText != null &&
                    lyricsText.isNotEmpty)
                  'lyrics': lyricsText,
              }
            : null,
        'embedCover': embedCover,
      });
      await finalizeDownloadExtras(requestJson: request);
    } catch (_) {
      // 收尾（歌词/封面/嵌入）失败不影响下载本身
    }
  }

  /// 音质阶梯（低 → 高），与播放器/设置页档位一致（对齐桌面端 rank 排序）；候选链向下降级。
  static const List<String> _qualityLadder = [
    'mgg', '128k', '192k', '320k', 'flac', 'flac24bit',
    'hires', 'vinyl', 'dolby', 'atmos', 'atmos_plus', 'master',
  ];

  static List<String> _qualityCandidates(String preferred) {
    final desc = _qualityLadder.reversed.toList();
    final i = desc.indexOf(preferred);
    return i < 0 ? [preferred, ...desc] : desc.sublist(i);
  }

  Future<String> _resolveLxUrl(String songJson, String quality) async {
    final resolved = await lxResolveUrl(
      songInfoJson: songJson,
      quality: quality,
      dataDir: await _ref.read(appDataDirProvider.future),
    );
    if (resolved == 'null' || resolved.isEmpty) return '';
    return (jsonDecode(resolved)['url'] as String?) ?? '';
  }

  Future<String> _resolvePluginUrl(
      Map<String, dynamic> songJson, String quality) async {
    final pluginId = songJson['pluginId'] as String?;
    final sourceKey = songJson['source'] as String? ?? '';
    final musicInfo = songJson['musicInfo'] as Map<String, dynamic>? ?? {};
    final format = songJson['format'] as String? ?? 'lx';
    if (pluginId == null || pluginId.isEmpty) throw StateError('插件信息缺失');

    final engine = await _ref.read(pluginEngineProvider.future);
    final sources = await engine.store.loadSources();
    final source = sources.where((s) => s.id == pluginId).toList();
    if (source.isEmpty) throw StateError('插件未启用');

    if (format == 'musicfree') {
      // MusicFree 插件：getMediaSource + 内部音质降级映射。
      final src = await engine.getMusicFreeUrl(
            source.first,
            musicInfo,
            preferred: quality,
          );
      return src?.url ?? '';
    }

    final result =
        await engine.getMusicUrl(source.first, sourceKey, musicInfo, quality);
    return result?['url'] ?? '';
  }

  Future<String?> _fetchLxLyric(String source, String songInfoJson) async {
    if (songInfoJson.isEmpty) return null;
    final raw = await fetchLyricFromSource(
      source: source,
      songInfoJson: songInfoJson,
    );
    if (raw.isEmpty || raw == 'null') return null;
    final obj = jsonDecode(raw) as Map<String, dynamic>;
    final text = (obj['lxlyric'] ?? obj['yrc'] ?? obj['qrc'] ?? obj['lyric'])
        as String? ?? '';
    return text.isEmpty ? null : text;
  }

  Future<String?> _fetchPluginLyric(Map<String, dynamic> songJson) async {
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
    final text = (lyric['lxlyric'] ??
            lyric['yrc'] ??
            lyric['qrc'] ??
            lyric['eslrc'] ??
            lyric['lyric']) as String? ??
        '';
    return text.isEmpty ? null : text;
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

  void _updateTask(String songPath,
      {DownloadStatus? status, String? error, String? filePath}) {
    state = state.copyWith(
      tasks: state.tasks.map((t) {
        if (t.songPath != songPath) return t;
        return t.copyWith(status: status ?? t.status, error: error, filePath: filePath);
      }).toList(),
    );
  }

  /// 移除一条下载记录。
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

  /// 清空下载记录。
  Future<void> clearHistory() async {
    final dataDir = await _ref.read(appDataDirProvider.future);
    await writeDownloadHistory(dataDir: dataDir, content: '{}');
    state = state.copyWith(history: const []);
  }

  /// 清除已结束的任务（成功/失败），保留进行中与排队中。
  void clearFinishedTasks() {
    state = state.copyWith(
        tasks: state.tasks
            .where((t) =>
                t.status == DownloadStatus.waiting ||
                t.status == DownloadStatus.downloading)
            .toList());
  }
}

/// 从完整路径中取出文件名（兼容 Windows 反斜杠与正斜杠）。
String fileNameFromPath(String filePath) {
  final parts = filePath.split(RegExp(r'[\\/]'));
  return parts.last.isNotEmpty ? parts.last : filePath;
}

final downloadProvider =
    StateNotifierProvider<DownloadManager, DownloadState>((ref) {
  return DownloadManager(ref);
});
