import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/db_path.dart';
import '../library/library_provider.dart';
import '../rust/api.dart' as frb;
import '../i18n/i18n.dart';

class RemoteSourceInfo {
  final String id;
  final String name;
  final String provider;
  final String baseUrl;
  final String? username;
  final String rootPath;
  final bool enabled;
  final int? lastSyncAt;
  final String? lastSyncError;

  const RemoteSourceInfo({
    required this.id,
    required this.name,
    required this.provider,
    required this.baseUrl,
    this.username,
    required this.rootPath,
    required this.enabled,
    this.lastSyncAt,
    this.lastSyncError,
  });

  factory RemoteSourceInfo.fromJson(Map<String, dynamic> j) => RemoteSourceInfo(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        provider: j['provider'] as String? ?? 'webdav',
        baseUrl: j['baseUrl'] as String? ?? '',
        username: j['username'] as String?,
        rootPath: j['rootPath'] as String? ?? '/',
        enabled: j['enabled'] as bool? ?? true,
        lastSyncAt: (j['lastSyncAt'] as num?)?.toInt(),
        lastSyncError: j['lastSyncError'] as String?,
      );

  String get lastSyncText {
    final ts = lastSyncAt;
    if (ts == null || ts <= 0) return tr('从未同步');
    final dt = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return tr('刚刚同步');
    if (diff.inHours < 1) return tr('{n} 分钟前同步', {'n': diff.inMinutes});
    if (diff.inDays < 1) return tr('{n} 小时前同步', {'n': diff.inHours});
    if (diff.inDays < 30) return tr('{n} 天前同步', {'n': diff.inDays});
    return tr('{date} 同步', {'date': '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}'});
  }
}

class RemoteCacheUsageInfo {
  final int bytes;
  final int files;
  const RemoteCacheUsageInfo({required this.bytes, required this.files});

  factory RemoteCacheUsageInfo.fromJson(Map<String, dynamic> j) =>
      RemoteCacheUsageInfo(
        bytes: (j['bytes'] as num?)?.toInt() ?? 0,
        files: (j['files'] as num?)?.toInt() ?? 0,
      );

  String get bytesText {
    var v = bytes.toDouble();
    if (v >= 1024 * 1024 * 1024) {
      return '${(v / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
    if (v >= 1024 * 1024) {
      return '${(v / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (v >= 1024) return '${(v / 1024).toStringAsFixed(0)} KB';
    return '$v B';
  }
}

class RemoteSyncResultInfo {
  final String sourceId;
  final int indexedFiles;
  final int audioFiles;
  final int parsedSongs;
  const RemoteSyncResultInfo({
    required this.sourceId,
    required this.indexedFiles,
    required this.audioFiles,
    required this.parsedSongs,
  });

  factory RemoteSyncResultInfo.fromJson(Map<String, dynamic> j) =>
      RemoteSyncResultInfo(
        sourceId: j['sourceId'] as String? ?? '',
        indexedFiles: (j['indexedFiles'] as num?)?.toInt() ?? 0,
        audioFiles: (j['audioFiles'] as num?)?.toInt() ?? 0,
        parsedSongs: (j['parsedSongs'] as num?)?.toInt() ?? 0,
      );
}

class RemoteDirEntryInfo {
  final String name;
  final String remotePath;
  final bool isDir;
  final int size;
  const RemoteDirEntryInfo({
    required this.name,
    required this.remotePath,
    required this.isDir,
    required this.size,
  });

  factory RemoteDirEntryInfo.fromJson(Map<String, dynamic> j) =>
      RemoteDirEntryInfo(
        name: j['name'] as String? ?? '',
        remotePath: j['remotePath'] as String? ?? '/',
        isDir: j['isDir'] as bool? ?? false,
        size: (j['size'] as num?)?.toInt() ?? 0,
      );
}

class TranscodeResultInfo {
  final String path;
  final bool decodedNow;
  const TranscodeResultInfo({required this.path, required this.decodedNow});

  factory TranscodeResultInfo.fromJson(Map<String, dynamic> j) =>
      TranscodeResultInfo(
        path: j['path'] as String? ?? '',
        decodedNow: j['decodedNow'] as bool? ?? false,
      );
}

class RemoteLibraryService {
  final Ref _ref;
  RemoteLibraryService(this._ref);

  Future<String> _dbPath() => _ref.read(dbPathProvider.future);

  Future<String> _cacheRoot() async {
    final base = await getTemporaryDirectory();
    final root = p.join(base.path, 'remote-audio');
    final dir = Directory(root);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return root;
  }

  Future<List<RemoteSourceInfo>> listSources() async {
    final json = await frb.listRemoteSources(dbPath: await _dbPath());
    final list = jsonDecode(json) as List;
    return list
        .map((e) => RemoteSourceInfo.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
  }

  Future<RemoteSourceInfo> saveSource({
    String? id,
    required String name,
    required String baseUrl,
    String? username,
    String? password,
    String rootPath = '/',
  }) async {
    final input = <String, dynamic>{
      if (id != null && id.isNotEmpty) 'id': id,
      'name': name,
      'provider': 'webdav',
      'baseUrl': baseUrl,
      'username': (username == null || username.isEmpty) ? null : username,
      'password': (password == null || password.isEmpty) ? null : password,
      'rootPath': rootPath.isEmpty ? '/' : rootPath,
    };
    final json = await frb.saveRemoteSource(
        dbPath: await _dbPath(), sourceJson: jsonEncode(input));
    return RemoteSourceInfo.fromJson(
        (jsonDecode(json) as Map).cast<String, dynamic>());
  }

  Future<void> removeSource(String sourceId) async {
    await frb.removeRemoteSource(dbPath: await _dbPath(), sourceId: sourceId);
  }

  Future<void> testConnection({
    String? id,
    required String name,
    required String baseUrl,
    String? username,
    String? password,
    String rootPath = '/',
  }) async {
    final input = <String, dynamic>{
      if (id != null && id.isNotEmpty) 'id': id,
      'name': name,
      'provider': 'webdav',
      'baseUrl': baseUrl,
      'username': (username == null || username.isEmpty) ? null : username,
      'password': (password == null || password.isEmpty) ? null : password,
      'rootPath': rootPath.isEmpty ? '/' : rootPath,
    };
    await frb.webdavTestConnection(sourceJson: jsonEncode(input));
  }

  Future<void> testSavedSource(
    String sourceId, {
    required String baseUrl,
    required String username,
    required String rootPath,
  }) async {
    final overrides = <String, dynamic>{
      'baseUrl': baseUrl.trim(),
      'username': username.trim(),
      'rootPath': rootPath.trim().isEmpty ? '/' : rootPath.trim(),
    };
    await frb.webdavTestSavedSource(
      dbPath: await _dbPath(),
      sourceId: sourceId,
      overridesJson: jsonEncode(overrides),
    );
  }

  Future<RemoteSyncResultInfo> syncSource(String sourceId) async {
    final json = await frb.syncRemoteSource(
      dbPath: await _dbPath(),
      cacheRoot: await _cacheRoot(),
      sourceId: sourceId,
    );
    return RemoteSyncResultInfo.fromJson(
        (jsonDecode(json) as Map).cast<String, dynamic>());
  }

  Future<RemoteCacheUsageInfo> cacheUsage() async {
    final json = await frb.getRemoteCacheUsage(cacheRoot: await _cacheRoot());
    return RemoteCacheUsageInfo.fromJson(
        (jsonDecode(json) as Map).cast<String, dynamic>());
  }

  Future<RemoteCacheUsageInfo> clearCache() async {
    final json = await frb.clearRemoteCache(cacheRoot: await _cacheRoot());
    return RemoteCacheUsageInfo.fromJson(
        (jsonDecode(json) as Map).cast<String, dynamic>());
  }

  Future<RemotePlaybackPlan> playbackSource(String remoteUri) async {
    final dbPath = await _dbPath();
    final json =
        await frb.remotePlaybackSource(dbPath: dbPath, remoteUri: remoteUri);
    final map = (jsonDecode(json) as Map).cast<String, dynamic>();
    final kind = map['kind'] as String? ?? '';
    if (kind == 'cached') {
      return RemotePlaybackPlan.cached(map['path'] as String? ?? '');
    }
    return RemotePlaybackPlan.stream(
      url: map['url'] as String? ?? '',
      username: map['username'] as String?,
      password: map['password'] as String?,
    );
  }

  Future<void> precacheRemote(String remoteUri) async {
    await frb.precacheRemoteSong(
      dbPath: await _dbPath(),
      cacheRoot: await _cacheRoot(),
      remoteUri: remoteUri,
    );
  }

  Future<List<RemoteDirEntryInfo>> listDirectory(
      String sourceId, String path) async {
    final json = await frb.listRemoteDirectory(
      dbPath: await _dbPath(),
      sourceId: sourceId,
      path: path,
    );
    final list = jsonDecode(json) as List;
    return list
        .map((e) =>
            RemoteDirEntryInfo.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
  }

  Future<List<RemoteDirEntryInfo>> browseDirectory({
    required String baseUrl,
    String? username,
    String? password,
    required String path,
  }) async {
    final json = await frb.webdavBrowseDirectory(
      sourceJson: jsonEncode(<String, dynamic>{
        'name': 'browse',
        'provider': 'webdav',
        'baseUrl': baseUrl.trim(),
        'username': (username == null || username.isEmpty) ? null : username,
        'password': (password == null || password.isEmpty) ? null : password,
        'rootPath': '/',
      }),
      path: path,
    );
    final list = jsonDecode(json) as List;
    return list
        .map((e) =>
            RemoteDirEntryInfo.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
  }

  Future<TranscodeResultInfo> transcodeToWav(String srcPath) async {
    final json = await frb.transcodeAudioToWav(
      dbPath: await _dbPath(),
      cacheRoot: await _cacheRoot(),
      srcPath: srcPath,
    );
    return TranscodeResultInfo.fromJson(
        (jsonDecode(json) as Map).cast<String, dynamic>());
  }
}

class RemotePlaybackPlan {
  final String? cachedPath;
  final String url;
  final String? username;
  final String? password;

  const RemotePlaybackPlan({
    this.cachedPath,
    required this.url,
    this.username,
    this.password,
  });

  const RemotePlaybackPlan.cached(String path)
      : cachedPath = path,
        url = '',
        username = null,
        password = null;

  const RemotePlaybackPlan.stream({
    required this.url,
    this.username,
    this.password,
  }) : cachedPath = null;

  bool get isCached => cachedPath != null && cachedPath!.isNotEmpty;

  Map<String, String>? get headers {
    if (username == null || username!.isEmpty) return null;
    final token = base64Encode(utf8.encode('$username:$password'));
    return {'Authorization': 'Basic $token'};
  }
}

final remoteLibraryServiceProvider = Provider<RemoteLibraryService>(
  (ref) => RemoteLibraryService(ref),
);

class RemoteLibraryState {
  final List<RemoteSourceInfo> sources;
  final RemoteCacheUsageInfo cacheUsage;
  final bool loading;
  final String? syncingSourceId;
  const RemoteLibraryState({
    this.sources = const [],
    this.cacheUsage = const RemoteCacheUsageInfo(bytes: 0, files: 0),
    this.loading = false,
    this.syncingSourceId,
  });

  RemoteLibraryState copyWith({
    List<RemoteSourceInfo>? sources,
    RemoteCacheUsageInfo? cacheUsage,
    bool? loading,
    String? syncingSourceId,
    bool clearSyncing = false,
  }) =>
      RemoteLibraryState(
        sources: sources ?? this.sources,
        cacheUsage: cacheUsage ?? this.cacheUsage,
        loading: loading ?? this.loading,
        syncingSourceId:
            clearSyncing ? null : (syncingSourceId ?? this.syncingSourceId),
      );
}

class RemoteLibraryNotifier extends StateNotifier<RemoteLibraryState> {
  final RemoteLibraryService _service;
  RemoteLibraryNotifier(this._service) : super(const RemoteLibraryState()) {
    refresh();
  }

  Future<void> refresh() async {
    state = state.copyWith(loading: true);
    try {
      final sources = await _service.listSources();
      var usage = state.cacheUsage;
      try {
        usage = await _service.cacheUsage();
      } catch (_) {}
      state = state.copyWith(sources: sources, cacheUsage: usage);
    } catch (_) {
    } finally {
      state = state.copyWith(loading: false);
    }
  }

  Future<String> sync(String sourceId) async {
    state = state.copyWith(syncingSourceId: sourceId);
    try {
      final result = await _service.syncSource(sourceId);
      await refresh();
      return tr('同步完成：解析 {parsed} 首（共 {total} 个音频文件）', {'parsed': result.parsedSongs, 'total': result.audioFiles});
    } finally {
      state = state.copyWith(clearSyncing: true);
    }
  }

  Future<void> remove(String sourceId) async {
    await _service.removeSource(sourceId);
    await refresh();
  }

  Future<void> clearCache() async {
    final usage = await _service.clearCache();
    state = state.copyWith(cacheUsage: usage);
  }
}

final remoteLibraryProvider =
    StateNotifierProvider<RemoteLibraryNotifier, RemoteLibraryState>(
  (ref) => RemoteLibraryNotifier(ref.read(remoteLibraryServiceProvider)),
);

class RemoteAutoSyncService {
  static const _interval = Duration(hours: 24);
  static const _keyPrefix = 'xianyu_remote_auto_sync_at:';
  final Ref _ref;
  Timer? _timer;
  bool _running = false;

  RemoteAutoSyncService(this._ref);

  void start() {
    if (_timer != null) return;
    unawaited(_check());
    _timer = Timer.periodic(const Duration(hours: 1), (_) => _check());
  }

  Future<void> _check() async {
    if (_running) return;
    _running = true;
    var synced = false;
    try {
      final sources = await _ref.read(remoteLibraryServiceProvider).listSources();
      final prefs = await SharedPreferences.getInstance();
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final source in sources) {
        if (!source.enabled) continue;
        final last = prefs.getInt('$_keyPrefix${source.id}') ?? 0;
        if (now - last < _interval.inMilliseconds) continue;
        try {
          if (_ref.read(remoteLibraryProvider).syncingSourceId != null) break;
          await _ref.read(remoteLibraryServiceProvider).syncSource(source.id);
          await prefs.setInt('$_keyPrefix${source.id}',
              DateTime.now().millisecondsSinceEpoch);
          synced = true;
        } catch (_) {}
      }
    } catch (_) {} finally {
      _running = false;
    }
    if (synced) {
      _ref.read(remoteLibraryProvider.notifier).refresh();
      _ref.read(libraryProvider.notifier).load();
    }
  }
}

final remoteAutoSyncProvider = Provider<RemoteAutoSyncService>(
  (ref) => RemoteAutoSyncService(ref),
);
