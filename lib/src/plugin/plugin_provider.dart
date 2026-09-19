import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/db_path.dart';
import '../core/rust_init.dart';
import '../rust/api.dart' as frb;
import '../sync/plugin_sync_state.dart';
import 'plugin_engine.dart';
import 'plugin_models.dart';
import 'plugin_store.dart';
import 'plugin_subscriptions.dart';
import 'plugin_user_vars.dart';
import '../i18n/i18n.dart';

const _bilibiliCookieKeys = {
  'SESSDATA',
  'buvid3',
  'buvid4',
  'bili_jct',
  'DedeUserID',
  'DedeUserID__ckMd5',
  'b_nut',
  '_uuid',
  'PVID',
  'sid',
};

final pluginEngineProvider = FutureProvider<PluginEngine>((ref) async {
  await ref.watch(rustInitProvider.future);
  final dataDir = await ref.watch(appDataDirProvider.future);
  final store = PluginStore(dataDir);
  final engine = PluginEngine(dataDir, store);
  engine.userVarsProvider = (pluginId) =>
      ref.read(pluginUserVarValuesProvider.notifier).valuesOf(pluginId);
  try {
    await frbPluginEngineInit(dataDir);
  } catch (_) {
  }
  return engine;
});

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

class PluginInstallResult {
  final List<String> names;
  final int failCount;
  final List<String> errors;

  const PluginInstallResult({
    this.names = const [],
    this.failCount = 0,
    this.errors = const [],
  });

  bool get success => names.isNotEmpty;
}

class PluginManager extends StateNotifier<PluginListState> {
  PluginManager(this._ref) : super(const PluginListState());

  final Ref _ref;

  PluginEngine? _engine;

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

  Future<PluginSource> installFromScript(
    String script, {
    String? fileName,
    String? nameOverride,
    String? versionOverride,
    String? sourceUrl,
  }) async {
    final engine = await _getEngine();
    final trimmed = script.trim();
    if (trimmed.isEmpty) {
      throw PluginEngineException(tr('插件内容为空'));
    }
    final bytes = utf8.encode(trimmed);
    if (bytes.length > 2 * 1024 * 1024) {
      throw PluginEngineException(tr('插件大小超过 2MB'));
    }

    final isLx = engine.isLxPluginScript(trimmed);
    final isAnime = !isLx && engine.isAnimePluginScript(trimmed);
    final info = engine.parseLxScriptInfo(trimmed);
    final id = sha256.convert(bytes).toString();

    final existing = state.sources.where((s) => s.id == id).toList();
    if (existing.isNotEmpty) {
      return existing.first;
    }

    Map<String, dynamic>? metadata;
    if (isLx) {
      metadata = await engine.loadLx(id, trimmed, scriptInfo: info);
      if (metadata == null) {
        throw PluginEngineException(tr('LX 插件初始化失败'));
      }
    } else {
      metadata = await engine.loadMusicFree(id, trimmed);
      if (metadata == null) {
        throw PluginEngineException(tr('插件加载失败'));
      }
    }

    final path = await engine.store.saveScript(id, trimmed);

    final sources = _extractSources(isLx, metadata);
    final fallbackName = isLx
        ? (info['name'] ?? fileName ?? tr('未知插件'))
        : ((metadata['pluginName'] ?? metadata['platform']) ?? fileName ?? tr('未知插件'));
    final mAuthor = isLx
        ? (info['author'] ?? '')
        : (metadata['author']?.toString() ?? '');
    final mVersion = versionOverride ??
        (isLx ? (info['version'] ?? '') : (metadata['version']?.toString() ?? ''));
    final mDesc = isLx
        ? (info['description'] ?? '')
        : (metadata['description']?.toString() ?? '');
    final source = PluginSource(
      id: id,
      name: (nameOverride ?? fallbackName).toString(),
      format: isLx
          ? PluginFormat.lx
          : (isAnime ? PluginFormat.anime : PluginFormat.musicfree),
      version: mVersion,
      author: mAuthor,
      description: mDesc,
      filePath: path,
      sourceUrl: sourceUrl ?? '',
      importedAt: DateTime.now().millisecondsSinceEpoch,
      enabled: true,
      sources: sources,
      sortOrder: state.sources.length,
    );

    final list = [...state.sources, source];
    await engine.store.saveSources(list);
    state = PluginListState(sources: list);
    await PluginSyncState.clearTombstones([source.id]);
    return source;
  }

  Future<PluginInstallResult> installFromUrl(String url) async {
    final script = await _fetchScript(url);
    if (script == null || script.isEmpty) {
      throw PluginEngineException(tr('无法获取插件脚本，请检查 URL 与网络'));
    }

    final batch = _parsePluginList(script);
    if (batch != null && batch.isNotEmpty) {
      final result = await _installBatch(batch);
      if (result.success) {
        await _recordSubscription(url);
      }
      return result;
    }

    final source = await installFromScript(script,
        fileName: url, sourceUrl: url);
    await _recordSubscription(url, name: source.name);
    return PluginInstallResult(names: [source.name]);
  }

  Future<void> _recordSubscription(String url, {String? name}) async {
    try {
      await _ref
          .read(pluginSubscriptionsProvider.notifier)
          .addFromInstall(url, name: name);
    } catch (_) {
    }
  }

  List<Map<String, dynamic>>? _parsePluginList(String content) {
    final trimmed = content.trim();
    if (!trimmed.startsWith('{') && !trimmed.startsWith('[')) return null;
    try {
      final json = jsonDecode(trimmed);
      final List? list;
      if (json is List) {
        list = json;
      } else if (json is Map) {
        final v = json['plugins'] ?? json['plugin'];
        list = v is List ? v : null;
      } else {
        list = null;
      }
      if (list == null || list.isEmpty) return null;
      final items = list
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .where((e) => (e['url'] ?? '').toString().isNotEmpty)
          .toList();
      if (items.isEmpty) return null;
      return items;
    } catch (_) {
      return null;
    }
  }

  Future<PluginInstallResult> _installBatch(
      List<Map<String, dynamic>> items) async {
    final names = <String>[];
    final errors = <String>[];
    for (final item in items) {
      final url = item['url'].toString();
      final label = (item['name'] ?? url).toString();
      try {
        final script = await _fetchScript(url);
        if (script == null || script.isEmpty) {
          errors.add(tr('{label}: 获取脚本失败', {'label': label}));
          continue;
        }
        final source = await installFromScript(
          script,
          fileName: url,
          nameOverride: item['name']?.toString(),
          versionOverride: item['version']?.toString(),
          sourceUrl: url,
        );
        names.add(source.name);
      } on PluginEngineException catch (e) {
        errors.add('$label: ${e.message}');
      } catch (_) {
        errors.add(tr('{label}: 安装失败', {'label': label}));
      }
    }
    return PluginInstallResult(
      names: names,
      failCount: items.length - names.length,
      errors: errors,
    );
  }

  Future<String?> _fetchScript(String url) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set('User-Agent',
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36');
      req.headers.set('Accept', '*/*');
      final resp = await req.close().timeout(const Duration(seconds: 20));
      if (resp.statusCode < 200 || resp.statusCode >= 300) return null;
      final body = await resp.transform(utf8.decoder).join();
      return body;
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

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
      await engine.destroy(id);
    }
    engine.bakaManager.clearCache(id);
  }

  Future<void> setUpdateAvailable(String id, bool value) async {
    final changed =
        state.sources.where((s) => s.id == id && s.updateAvailable != value).toList();
    if (changed.isEmpty) return;
    final engine = await _getEngine();
    final list = state.sources
        .map((s) => s.id == id ? s.copyWith(updateAvailable: value) : s)
        .toList();
    await engine.store.saveSources(list);
    state = PluginListState(sources: list);
  }

  Future<void> toggleAll(bool enabled) async {
    final changed =
        state.sources.where((s) => s.enabled != enabled).toList();
    if (changed.isEmpty) return;
    final engine = await _getEngine();
    final list =
        state.sources.map((s) => s.copyWith(enabled: enabled)).toList();
    await engine.store.saveSources(list);
    state = PluginListState(sources: list);
    for (final s in changed) {
      if (!enabled) {
        await engine.destroy(s.id);
      }
      engine.bakaManager.clearCache(s.id);
    }
  }

  Future<void> remove(String id) async {
    final engine = await _getEngine();
    await engine.destroy(id);
    await engine.store.deleteScript(id);
    final list = state.sources.where((s) => s.id != id).toList();
    await engine.store.saveSources(list);
    state = PluginListState(sources: list);
    engine.bakaManager.clearCache(id);
  }

  Future<void> reorder(List<String> orderedIds) async {
    final engine = await _getEngine();
    final current = state.sources;
    final idToIndex = <String, int>{
      for (var i = 0; i < orderedIds.length; i++) orderedIds[i]: i,
    };
    final remapped = current
        .map((s) => idToIndex.containsKey(s.id)
            ? s.copyWith(sortOrder: idToIndex[s.id]!)
            : s)
        .toList();
    final list = sortPluginSources(remapped);
    await engine.store.saveSources(list);
    state = PluginListState(sources: list);
  }

  Future<bool> reload(String id) async {
    final engine = await _getEngine();
    final source = state.sources.where((s) => s.id == id).toList();
    if (source.isEmpty) return false;
    final info = await engine.ensureLoaded(source.first);
    return info != null;
  }

  Future<void> updateScript(String oldId, String newScript) async {
    final oldSource = state.sources.where((s) => s.id == oldId).toList();
    if (oldSource.isEmpty) throw PluginEngineException(tr('插件不存在'));
    final engine = await _getEngine();
    final newSource = await installFromScript(
      newScript,
      nameOverride: oldSource.first.name,
      sourceUrl: oldSource.first.sourceUrl,
    );
    if (newSource.id == oldId) return;
    await engine.destroy(oldId);
    await engine.store.deleteScript(oldId);
    final list = state.sources.where((s) => s.id != oldId).toList();
    await engine.store.saveSources(list);
    state = PluginListState(sources: list);
    engine.bakaManager.clearCache(oldId);
    if (newSource.id != oldId) engine.bakaManager.clearCache(newSource.id);
  }

  Future<List<PluginUserVar>> getUserVars(String pluginId) async {
    final engine = await _getEngine();
    final source = state.sources.where((s) => s.id == pluginId).toList();
    if (source.isEmpty) return const [];
    return getPluginUserVars(engine, source.first);
  }

  Future<void> saveUserVars(String pluginId, Map<String, String> values) async {
    final engine = await _getEngine();
    await _ref.read(pluginUserVarValuesProvider.notifier).save(pluginId, values);
    await syncBilibiliCookiesFromVars(pluginId, values);
    await engine.destroy(pluginId);
    final source = state.sources.where((s) => s.id == pluginId).toList();
    if (source.isNotEmpty && source.first.enabled) {
      await engine.ensureLoaded(source.first);
    }
  }

  Future<void> syncBilibiliCookiesFromVars(
      String pluginId, Map<String, String> values) async {
    final isBili = state.sources.any((s) =>
        s.id == pluginId &&
        (s.name == 'bilibili' || s.id.contains('bilibili')));
    if (!isBili) return;
    final cookies = <String, Map<String, String>>{};
    void put(String name, String value) {
      final v = value.trim();
      if (name.isEmpty || v.isEmpty) return;
      cookies[name] = {'value': v, 'domain': 'bilibili.com'};
    }

    for (final e in values.entries) {
      if (_bilibiliCookieKeys.contains(e.key)) put(e.key, e.value);
    }
    for (final raw in values.values) {
      final t = raw.trim();
      if (!(t.startsWith('[') || t.startsWith('{'))) continue;
      try {
        final parsed = jsonDecode(t);
        final items = parsed is List
            ? parsed
            : parsed is Map
                ? parsed.entries.toList()
                : const [];
        for (final it in items) {
          if (it is Map) {
            final name = it['name']?.toString() ?? '';
            final value = it['value'];
            if (name.isNotEmpty && value != null) put(name, value.toString());
          }
        }
      } catch (_) {}
    }
    if (cookies.isEmpty) return;
    try {
      await frb.pluginEngineStoreImport(
        dataDir: await _ref.read(appDataDirProvider.future),
        payloadJson: jsonEncode({
          'cookies': cookies,
          'storage': <String, String>{},
          'overwriteCookies': true,
        }),
      );
    } catch (_) {}
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
    // anime 聚合插件优先 platforms 列表
    final platforms = metadata['platforms'];
    if (platforms is List && platforms.isNotEmpty) {
      return platforms.map((e) => e.toString()).toList();
    }
    final platform = metadata['platform'];
    if (platform is String && platform.isNotEmpty) return [platform];
    return const [];
  }
}

final pluginManagerProvider =
    StateNotifierProvider<PluginManager, PluginListState>((ref) {
  final manager = PluginManager(ref);
  Future.microtask(() => manager.refresh());
  return manager;
});

Future<void> frbPluginEngineInit(String dataDir) async {
  await frb.pluginEngineInit(dataDir: dataDir);
}
