import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/db_path.dart';
import '../rust/api.dart' as frb;
import 'plugin_engine.dart';
import 'plugin_models.dart';
import 'plugin_store.dart';

/// 插件引擎实例（懒加载，dataDir 就绪后创建）。
final pluginEngineProvider = FutureProvider<PluginEngine>((ref) async {
  final dataDir = await ref.watch(appDataDirProvider.future);
  final store = PluginStore(dataDir);
  final engine = PluginEngine(dataDir, store);
  try {
    await frbPluginEngineInit(dataDir);
  } catch (_) {
    // 初始化失败不阻塞，后续调用会重试
  }
  return engine;
});

/// 插件列表状态。
class PluginListState {
  final List<PluginSource> sources;
  final bool loading;
  final String? error;

  const PluginListState({
    this.sources = const [],
    this.loading = false,
    this.error,
  });

  PluginListState copyWith({
    List<PluginSource>? sources,
    bool? loading,
    String? error,
  }) {
    return PluginListState(
      sources: sources ?? this.sources,
      loading: loading ?? this.loading,
      error: error,
    );
  }
}

/// 插件管理器：列表增删改、安装（URL/脚本）、启用禁用。
class PluginManager extends StateNotifier<PluginListState> {
  PluginManager(this._ref) : super(const PluginListState());

  final Ref _ref;

  PluginEngine? _engine;

  /// 当前已安装插件列表（供外部只读访问）。
  List<PluginSource> get sources => state.sources;

  Future<PluginEngine> _getEngine() async {
    final cached = _engine;
    if (cached != null) return cached;
    final engine = await _ref.read(pluginEngineProvider.future);
    _engine = engine;
    return engine;
  }

  Future<void> refresh() async {
    final engine = await _getEngine();
    final sources = await engine.store.loadSources();
    state = PluginListState(sources: sources);
  }

  /// 安装插件（脚本内容），自动检测格式并加载验证。
  /// 返回安装后的 PluginSource；失败抛出 [PluginEngineException]。
  Future<PluginSource> installFromScript(
    String script, {
    String? fileName,
  }) async {
    final engine = await _getEngine();
    final trimmed = script.trim();
    if (trimmed.isEmpty) {
      throw PluginEngineException('插件内容为空');
    }
    final bytes = utf8.encode(trimmed);
    if (bytes.length > 2 * 1024 * 1024) {
      throw PluginEngineException('插件大小超过 2MB');
    }

    final isLx = engine.isLxPluginScript(trimmed);
    final info = engine.parseLxScriptInfo(trimmed);
    final id = sha256.convert(bytes).toString();

    // 已存在同 ID 插件：直接返回现有条目
    final existing = state.sources.where((s) => s.id == id).toList();
    if (existing.isNotEmpty) {
      return existing.first;
    }

    // 加载验证（失败抛出异常，由调用方提示）
    Map<String, dynamic>? metadata;
    if (isLx) {
      metadata = await engine.loadLx(id, trimmed, scriptInfo: info);
      if (metadata == null) {
        throw PluginEngineException('LX 插件初始化失败');
      }
    } else {
      metadata = await engine.loadMusicFree(id, trimmed);
      if (metadata == null) {
        throw PluginEngineException('插件加载失败');
      }
    }

    // 持久化脚本
    final path = await engine.store.saveScript(id, trimmed);

    final sources = _extractSources(isLx, metadata);
    final source = PluginSource(
      id: id,
      name: (info['name'] ?? (fileName ?? '未知插件')).toString(),
      format: isLx ? PluginFormat.lx : PluginFormat.musicfree,
      version: info['version'] ?? '',
      author: info['author'] ?? '',
      description: info['description'] ?? '',
      filePath: path,
      importedAt: DateTime.now().millisecondsSinceEpoch,
      enabled: true,
      sources: sources,
    );

    final list = [...state.sources, source];
    await engine.store.saveSources(list);
    state = PluginListState(sources: list);
    return source;
  }

  /// 从 URL 安装插件（远程脚本）。
  Future<PluginSource> installFromUrl(String url) async {
    final script = await _fetchScript(url);
    if (script == null || script.isEmpty) {
      throw PluginEngineException('无法获取插件脚本');
    }
    return installFromScript(script, fileName: url);
  }

  Future<String?> _fetchScript(String url) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set('User-Agent',
          'Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36');
      req.headers.set('Accept', '*/*');
      final resp = await req.close().timeout(const Duration(seconds: 15));
      if (resp.statusCode < 200 || resp.statusCode >= 300) return null;
      final body = await resp.transform(utf8.decoder).join();
      return body;
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  /// 启用/禁用插件。
  Future<void> toggleEnabled(String id) async {
    final engine = await _getEngine();
    final list = state.sources.map((s) {
      if (s.id == id) return s.copyWith(enabled: !s.enabled);
      return s;
    }).toList();
    await engine.store.saveSources(list);
    state = PluginListState(sources: list);

    final source = list.firstWhere((s) => s.id == id);
    if (!source.enabled) {
      // 禁用时销毁沙箱实例
      await engine.destroy(id);
    }
  }

  /// 卸载插件。
  Future<void> remove(String id) async {
    final engine = await _getEngine();
    await engine.destroy(id);
    await engine.store.deleteScript(id);
    final list = state.sources.where((s) => s.id != id).toList();
    await engine.store.saveSources(list);
    state = PluginListState(sources: list);
  }

  /// 重新加载指定插件（用于启用后初始化）。
  Future<bool> reload(String id) async {
    final engine = await _getEngine();
    final source = state.sources.where((s) => s.id == id).toList();
    if (source.isEmpty) return false;
    final info = await engine.ensureLoaded(source.first);
    return info != null;
  }

  List<String> _extractSources(bool isLx, Map<String, dynamic>? metadata) {
    if (metadata == null) return const [];
    if (isLx) {
      final sources = metadata['sources'];
      if (sources is Map) {
        return sources.keys.map((k) => k.toString()).toList();
      }
      return const [];
    }
    // MusicFree：platform 字段
    final platform = metadata['platform'];
    if (platform is String && platform.isNotEmpty) return [platform];
    return const [];
  }
}

final pluginManagerProvider =
    StateNotifierProvider<PluginManager, PluginListState>((ref) {
  final manager = PluginManager(ref);
  // 启动时异步加载插件列表
  Future.microtask(() => manager.refresh());
  return manager;
});

/// 暴露 FRB 插件引擎初始化（供 provider 使用）。
Future<void> frbPluginEngineInit(String dataDir) async {
  await frb.pluginEngineInit(dataDir: dataDir);
}
