import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/db_path.dart';
import '../rust/api.dart' as frb;

/// WebDAV 远程源配置（与 Rust RemoteSource 一致，不含密码）。
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

  /// 上次同步时间文案（相对时间）。
  String get lastSyncText {
    final ts = lastSyncAt;
    if (ts == null || ts <= 0) return '从未同步';
    final dt = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return '刚刚同步';
    if (diff.inHours < 1) return '${diff.inMinutes} 分钟前同步';
    if (diff.inDays < 1) return '${diff.inHours} 小时前同步';
    if (diff.inDays < 30) return '${diff.inDays} 天前同步';
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} 同步';
  }
}

/// 远程音频缓存用量。
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

/// 同步结果。
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

/// 远程源管理服务：封装 Rust WebDAV 远程源 API。
class RemoteLibraryService {
  final Ref _ref;
  RemoteLibraryService(this._ref);

  Future<String> _dbPath() => _ref.read(dbPathProvider.future);

  /// 远程音频缓存根目录（系统缓存目录下 remote-audio，LRU 上限 2GB）。
  /// 提前创建目录，避免 Rust 侧 read_dir 报「目录不存在」。
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

  /// 保存（新增或编辑）远程源。编辑时密码留空表示沿用原密码。
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

  /// 测试连接（PROPFIND 根目录）。失败抛异常。
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

  /// 测试已保存远程源的连接：密码留空时沿用存储密码，仅叠加表单覆盖项。
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

  /// 同步远程源：扫描远程目录并写入音乐库。
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

  /// 解析远程歌曲播放来源：已缓存返回本地路径，否则返回带认证的直链。
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
}

/// 远程歌曲播放计划。
class RemotePlaybackPlan {
  /// 已缓存文件的本地路径（非空时直接本地播放）。
  final String? cachedPath;
  /// 远程直链（未缓存时流式播放）。
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

  /// Basic Auth 请求头（有凭据时）。
  Map<String, String>? get headers {
    if (username == null || username!.isEmpty) return null;
    final token = base64Encode(utf8.encode('$username:$password'));
    return {'Authorization': 'Basic $token'};
  }
}

final remoteLibraryServiceProvider = Provider<RemoteLibraryService>(
  (ref) => RemoteLibraryService(ref),
);

/// 远程源列表 + 缓存用量状态。
class RemoteLibraryState {
  final List<RemoteSourceInfo> sources;
  final RemoteCacheUsageInfo cacheUsage;
  final bool loading;
  /// 正在同步的远程源 id。
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
      // 缓存用量查询失败不影响源列表展示。
      var usage = state.cacheUsage;
      try {
        usage = await _service.cacheUsage();
      } catch (_) {}
      state = state.copyWith(sources: sources, cacheUsage: usage);
    } catch (_) {
      // 列表加载失败保持旧数据
    } finally {
      state = state.copyWith(loading: false);
    }
  }

  /// 同步远程源并刷新状态，返回结果文案。
  Future<String> sync(String sourceId) async {
    state = state.copyWith(syncingSourceId: sourceId);
    try {
      final result = await _service.syncSource(sourceId);
      await refresh();
      return '同步完成：解析 ${result.parsedSongs} 首（共 ${result.audioFiles} 个音频文件）';
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
