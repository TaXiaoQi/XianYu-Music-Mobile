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
import '../core/settings.dart';
import '../player/player_provider.dart';
import '../player/media_url.dart';
import '../player/online_quality_probe.dart';
import '../plugin/plugin_engine.dart';
import '../plugin/plugin_provider.dart';
import '../rust/api.dart';
import '../i18n/i18n.dart';

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

  /// 是否已设置自定义下载目录（「下载设置 → 下载目录」里选过路径）。
  /// 未设置时禁止下载，避免歌曲落到无法预期的系统/应用目录。
  bool get hasCustomDownloadDir =>
      (_ref.read(settingsProvider).valueOrNull?.downloadPath ?? '').isNotEmpty;

  /// 下载前校验：①未设置自定义下载目录时提示；②Android 未授予
  /// 「所有文件访问」（MANAGE_EXTERNAL_STORAGE）时给出非阻断提示——
  /// 直写受限时下载会自动走 MediaStore 兼容模式（API 29+ 自有媒体条目
  /// 免存储权限），不应因未授权直接中止。返回 false 时调用方中止下载
  /// （仅目录未设置的情况）。供各下载入口复用。
  Future<bool> requireDownloadDir(BuildContext context) async {
    if (!hasCustomDownloadDir) {
      showXianYuToast(context, tr('请先前往设置下载目录'));
      return false;
    }
    if (Platform.isAndroid) {
      final status = await Permission.manageExternalStorage.status;
      // await 期间调用方面板可能已被关闭（可拖拽的底部面板），此时用
      // 失效 context 查 Overlay 会触发 framework ancestor 断言崩溃。
      if (!context.mounted) return false;
      if (!status.isGranted) {
        showXianYuToast(
            context, tr('未授予所有文件访问权限，将尝试兼容模式写入'));
      }
    }
    return true;
  }

  /// 下载在线歌曲（插件音源或 lx:// 音源）。受并发上限控制，超出排队。
  ///
  /// [quality] 为调用方（下载音质弹窗）选定的档位；未指定时按
  /// 设置下载音质 → 歌曲自带音质 → 320k 依次回退（设置优先，对齐桌面端
  /// `download.quality` 作为默认音质）。
  Future<void> download(QueueItem item, {String? quality}) async {
    if (!item.isOnline) return;
    // 未设置自定义下载目录：一律禁止下载（兜底，UI 入口已由 requireDownloadDir 提示）。
    if (!hasCustomDownloadDir) return;
    // 直写受限时不再硬性拦截：未授予「所有文件访问」仍允许下载，
    // Rust 直写失败后自动回退 MediaStore 兼容模式（见 _mediaStoreFallback）。
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

  /// 判断某在线歌曲是否已下载：下载历史命中且对应文件仍存在即视为已下载。
  Future<bool> isAlreadyDownloaded(String songPath) async {
    final matched = state.history
        .where((h) => h.songPath == songPath && h.filePath.isNotEmpty)
        .toList()
      ..sort((a, b) => b.downloadedAt.compareTo(a.downloadedAt));
    // 历史里任一版本的文件仍存在即可复用，否则视为未下载（允许重下）。
    for (final h in matched) {
      try {
        if (await File(h.filePath).exists()) return true;
      } catch (_) {}
    }
    return false;
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
      throw StateError(tr('在线歌曲信息缺失'));
    }
    final parsed = jsonDecode(songJson) as Map<String, dynamic>;

    // 1. 解析直链：按音质候选链降级（与播放器一致），实际命中的音质用于
    //    文件命名与历史记录。对齐桌面 resolveLxAudioForQuality：采用插件实际上报
    //    档位（而非请求档），并跳过「无损声明却拿到有损直链」的静默降级档，
    //    避免下载出「标着无损却是 320k/mp3」的假音质文件。
    var usedQuality = task.quality;
    String? url;
    for (final q in _qualityCandidates(
        task.quality, settings?.downloadQualityFallbackBehavior ?? 'lower')) {
      final tried = parsed.containsKey('pluginId')
          ? await _resolvePluginUrl(parsed, q)
          : await _resolveLxUrl(songJson, q);
      if (tried == null) continue;
      final u = tried.url;
      final reported = tried.quality ?? q;
      // 无损档却返回有损直链：被静默降级且无对应无损文件，跳过该档回退下一候选。
      final effective = resolveActualQuality(reported, u);
      if (effective != reported) {
        debugPrint('[download] $q 被静默降级为有损直链，跳过：$u');
        continue;
      }
      url = u;
      usedQuality = effective;
      break;
    }
    if (url == null) throw StateError(tr('直链解析失败'));

    _updateTask(task.songPath, progressPercent: 40);

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
      keepSourceFilename: settings?.keepSourceFilename ?? false,
      fileNameStyle: settings?.downloadFileNameStyle ?? 'artist-title',
      overwriteExisting: settings?.overwriteExisting ?? false,
    );

    _updateTask(task.songPath, progressPercent: 60);

    // 3. 流式下载。部分国产 ROM（sdcardfs/纯净模式沙箱）在已授予「所有文件
    //    访问」时仍拦截对公共存储的直接路径写入——Rust 直写失败时回退
    //    MediaStore 通道（API 29+ 自有媒体条目免存储权限）：先下到应用缓存，
    //    在缓存上完成歌词/元数据收尾，再经 ContentResolver 落盘公共存储。
    var finalPath = destPath;
    try {
      await downloadOnlineSong(
        url: url,
        destPath: destPath,
        ekey: null,
        headersJson: '{}',
      );
    } catch (e) {
      final msg = e.toString();
      final directWriteFailure = msg.contains('创建目标文件失败') ||
          msg.contains('写入文件失败') ||
          msg.contains('创建下载目录失败');
      if (!directWriteFailure) rethrow;
      final fallback = await _mediaStoreFallback(
        url: url,
        dir: dir,
        destPath: destPath,
        item: item,
        parsed: parsed,
        settings: settings,
      );
      if (fallback == null) rethrow;
      finalPath = fallback;
    }

    _updateTask(task.songPath, progressPercent: 85);

    // 4. 收尾：直写成功时在最终路径收尾；回退模式下已在缓存临时文件上完成
    //    （tag 嵌入必须发生在直接可写的文件上）。
    if (finalPath == destPath) {
      final wantLyrics = settings?.downloadLyrics ?? true;
      if (wantLyrics || (settings?.embedDownloadLyrics ?? false)) {
        await _finalizeExtras(item, destPath, parsed, settings);
      }
    }

    _updateTask(task.songPath, progressPercent: 95);

    return (finalPath, usedQuality);
  }

  /// 直写失败时的 MediaStore 回退：下载到应用缓存 → 按缓存路径收尾（歌词
  /// 文件/封面/元数据嵌入，全部落在确定可写的缓存上）→ 经 MediaStore 落盘
  /// 公共存储 → 迁移歌词独立文件并清理缓存。返回真实落盘路径；不可回退
  /// （非 Android、API < 29、MediaStore 写入失败）返回 null，由调用方抛出
  /// 原始直写错误。
  Future<String?> _mediaStoreFallback({
    required String url,
    required String dir,
    required String destPath,
    required QueueItem item,
    required Map<String, dynamic> parsed,
    AppSettings? settings,
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
        ekey: null,
        headersJson: '{}',
      );

      // 收尾在临时文件上做：sidecar 与 tag 嵌入都写缓存，一定可写。
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

      // 歌词独立文件：非媒体文件经 MediaStore 只能进 Download/ 集合，落到
      // Download/弦予/；tag 里已按设置嵌入歌词。
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
      // 清理缓存临时文件（音频 + 歌词 + 封面 sidecar；封面已嵌入 tag）。
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

  /// 把公共存储目录映射为 MediaStore RELATIVE_PATH：仅 Music/、Download/
  /// 前缀按原样映射（子目录含文件名部分剥除）；其余目录（含 Android/data
  /// 等系统禁区）归入 Music/弦予，避免 insert 直接被拒。
  static String _mediaRelativePath(String dir) {
    final norm = dir.replaceAll('\\', '/');
    final m = RegExp(r'/storage/[^/]+/(Music|Download)(/.*)?$').firstMatch(norm);
    if (m != null) {
      final sub = (m.group(2) ?? '').replaceAll(RegExp(r'^/+|/+$'), '');
      return sub.isEmpty ? '${m.group(1)}/弦予' : '${m.group(1)}/$sub';
    }
    return 'Music/弦予';
  }

  /// 按扩展名映射 MIME（决定 MediaStore 目标集合：audio/* → Audio，
  /// 其余 → Downloads）。
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
      // 歌词样式：word-by-word 优先逐字（无逐字回退逐行）；line-by-line 仅取逐行歌词。
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
      // 歌词格式转换（对齐桌面端 downloadExtras.ts fetchLyricText）：
      // txt 去时间标签与逐字词级标签输出纯文本；lrc 原样。
      // **独立文件与 tag 嵌入用同一份转换后文本**（桌面端 savedLyricText
      // 同源），避免「txt 文件 + tag 里还是带时间戳的 lrc」不一致。
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
      // 收尾（歌词/封面/嵌入）失败不影响下载本身
    }
  }

  /// 音质阶梯（低 → 高），与播放器/设置页档位一致（对齐桌面端 rank 排序）；候选链向下降级。
  static const List<String> _qualityLadder = [
    'mgg', '128k', '192k', '320k', 'flac', 'flac24bit',
    'hires', 'vinyl', 'dolby', 'atmos', 'atmos_plus', 'master',
  ];

  /// 音质缺失回退策略：lower（默认）从当前档向下降级；higher 从当前档向上升级。
  /// 对齐桌面端 download.qualityFallbackBehavior。
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
    final resolved = await lxResolveUrl(
      songInfoJson: songJson,
      quality: quality,
      dataDir: await _ref.read(appDataDirProvider.future),
    );
    if (resolved == 'null' || resolved.isEmpty) return null;
    final url = (jsonDecode(resolved)['url'] as String?) ?? '';
    return url.isEmpty ? null : ResolvedMediaUrl(url: url);
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

    if (format == 'musicfree') {
      // MusicFree 插件：getMediaSource + 内部音质降级映射；直链带上插件实际上报档位。
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
    // 采用插件实际上报档位（type），避免请求无损却下载到降级有损而误标档位。
    final type = result?['type'];
    final reported =
        type is String && type.isNotEmpty
            ? PluginEngine.normalizeQualityKey(type)
            : null;
    return ResolvedMediaUrl(url: url, quality: reported);
  }

  /// [wordByWord] 为 true 时优先逐字歌词（lxlyric/yrc/qrc），无逐字回退逐行；
  /// 为 false 时仅取标准逐行歌词（lyric 字段）。
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
    return text.isEmpty ? null : text;
  }

  /// 歌词格式转换，逐行对齐桌面端 fetchLyricText.processFormat：
  /// - txt：剥时间标签 `[mm:ss(.xxx)]` + 逐字词级标签 `<s,e>` / `[s,e]`，
  ///   保留其余方括号元数据（[ti:] 等），仅整体 trim——与桌面端输出逐字节
  ///   一致（同一首歌在两端下载 txt 内容相同）。
  /// - lrc：原样 trim。
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

    // 优先取正在下载中的任务
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

  /// 清空下载记录（可选同时删除本地已下载的文件）。MediaStore 兼容模式下
  /// 落盘的文件由 ContentResolver 删除兜底（仅限本应用自有条目）。
  Future<void> clearHistory({bool deleteFiles = false}) async {
    if (deleteFiles) {
      for (final entry in state.history) {
        try {
          if (entry.filePath.isNotEmpty) {
            await _deleteDownloadedFile(entry.filePath);
            // 清理关联的 lrc 歌词和 cover 封面文件
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

  /// 删除单个下载产物：先直接删（正常路径）；残留时回退 MediaStore
  /// （兼容模式下落盘的文件，在直写受限设备上 File.delete 也可能失效）。
  Future<void> _deleteDownloadedFile(String path) async {
    try {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
    if (await File(path).exists()) {
      await MediaStoreWriter.deleteMedia(path);
    }
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
