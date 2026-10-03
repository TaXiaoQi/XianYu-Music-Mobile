import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/db_path.dart';
import '../core/application_logger.dart';
import '../core/rust_init.dart';
import '../core/settings.dart';
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

/// 用户取消在线导入（弹窗返回键/取消键）：在网络步骤之间抛出，
/// 静默终止安装流程；安装弹窗已随取消关闭，调用方不再弹错误提示
class PluginInstallCancelled implements Exception {
  const PluginInstallCancelled();

  @override
  String toString() => 'PluginInstallCancelled';
}

Future<String?> fetchPluginScriptWithRetry(
  String url, {
  Duration connectionTimeout = const Duration(seconds: 15),
  Duration responseTimeout = const Duration(seconds: 20),
  // 响应体下载超时：connectionTimeout/responseTimeout 只覆盖到响应头，
  // body 中途断流时 join() 会永久挂起（导入小黑条卡死的根因），必须有界
  Duration bodyTimeout = const Duration(seconds: 60),
  String userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
  int attempts = 3,
  bool Function()? cancelled,
}) async {
  Object? lastErr;
  for (var i = 1; i <= attempts; i++) {
    if (cancelled?.call() ?? false) return null;
    final client = HttpClient()..connectionTimeout = connectionTimeout;
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set('User-Agent', userAgent);
      req.headers.set('Accept', '*/*');
      // 浏览器风格请求头：实测同一 URL 用浏览器能下载、在本客户端固定 403，
      // 且换网络（WiFi/移动数据）无改善，故不是网络路径问题。部分站点前置了
      // 机器人防护，只凭 UA + Accept 会被判为非浏览器请求直接拒绝。
      final parsed = Uri.parse(url);
      req.headers.set('Accept-Language', 'zh-CN,zh;q=0.9,en;q=0.8');
      req.headers.set('Referer', '${parsed.scheme}://${parsed.host}/');
      req.headers.set('Connection', 'keep-alive');
      final resp = await req.close().timeout(responseTimeout);
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        // 记下状态码之外的响应体开头：403 既可能是 CDN 机器人拦截，也可能是
        // key/鉴权被拒，两者修法不同，只看状态码分不出来（不重试，4xx 重试无意义）。
        var snippet = '';
        try {
          snippet = (await resp.transform(utf8.decoder).join()).trim();
          if (snippet.length > 200) snippet = snippet.substring(0, 200);
        } catch (e) { AppLog.debug('plugin', '读取错误响应体失败: $e'); }
        AppLog.warn(
          'plugin',
          'fetch script http ${resp.statusCode} $url body=${snippet.isEmpty ? '(empty)' : snippet}',
        );
        // 403 可能是 Key 限制 UA（服务端响应体明说「User-Agent 已被限制」）。
        // 只在这一种情况下用 LX 客户端 UA 重试一次，且不替换全局默认 UA：
        // 多数源站依赖浏览器 UA，全局改会悄悄弄坏它们。
        if (resp.statusCode == 403) {
          try {
            final retryReq = await client.getUrl(parsed);
            retryReq.headers.set('User-Agent', 'lx-music-desktop/2.0.0');
            retryReq.headers.set('Accept', '*/*');
            final retryResp = await retryReq.close().timeout(responseTimeout);
            if (retryResp.statusCode >= 200 && retryResp.statusCode < 300) {
              AppLog.info('plugin', 'fetch script 403 后改用 LX UA 重试成功 $url');
              return await retryResp.transform(utf8.decoder).join().timeout(bodyTimeout);
            }
            AppLog.warn('plugin',
                'fetch script 403 后改用 LX UA 重试仍失败 ${retryResp.statusCode} $url');
          } catch (e) {
            AppLog.warn('plugin', 'fetch script 403 后改用 LX UA 重试异常: $e');
          }
        }
        return null;
      }
      return await resp.transform(utf8.decoder).join().timeout(bodyTimeout);
    } catch (e) {
      lastErr = e;
    } finally {
      client.close();
    }
    if (i < attempts) {
      // 重试间隔中响应取消，避免取消后仍空转完整重试链
      if (cancelled?.call() ?? false) return null;
      await Future.delayed(const Duration(milliseconds: 800));
    }
  }
  AppLog.error('plugin',
      'fetch script failed after $attempts attempts: $url\n$lastErr');
  return null;
}

final pluginEngineProvider = FutureProvider<PluginEngine>((ref) async {
  await ref.watch(rustInitProvider.future);
  final dataDir = await ref.watch(appDataDirProvider.future);
  final store = PluginStore(dataDir);
  final engine = PluginEngine(dataDir, store);
  engine.userVarsProvider = (pluginId) =>
      ref.read(pluginUserVarValuesProvider.notifier).valuesOf(pluginId);
  // 音源自报「不支持某档位」时挑选可用档位要用到用户的降级方向；
  // 设置变化时同步，避免插件引擎反向依赖设置层
  void syncFallback() {
    engine.lxFallbackBehavior = ref.read(settingsProvider).valueOrNull
            ?.onlineQualityFallbackBehavior ??
        'lower';
  }

  syncFallback();
  ref.listen(
    settingsProvider.select((s) => s.valueOrNull?.onlineQualityFallbackBehavior),
    (_, _) => syncFallback(),
  );
  try {
    await frbPluginEngineInit(dataDir);
  } catch (e) { AppLog.warn('plugin', '插件引擎初始化失败: $e'); }
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

/// 零宽/方向控制/BOM/软连字符等不可见字符：BakaMusic 等插件为规避审查，
/// 会在 name/platform 字段里塞这类混淆串。Dart 的 trim() 不去除它们，
/// 导致「trim 非空但渲染不可见」的插件名（插件页标题空白、又不触发未知插件兜底）
final RegExp _invisibleChars = RegExp(
    '[\u200b-\u200f\u202a-\u202e\u2060\u2066-\u2069\ufeff\u00ad\u3164]');

/// 去除不可见字符后的文本：用于展示与「是否为空」判定
String stripInvisibleChars(String s) => s.replaceAll(_invisibleChars, '');

String? _firstNonEmptyText(Iterable<Object?> values) {
  for (final v in values) {
    if (v == null) continue;
    final s = stripInvisibleChars(v.toString()).trim();
    if (s.isNotEmpty) return s;
  }
  return null;
}

String pluginDisplayName(PluginSource source) {
  final s = stripInvisibleChars(source.name).trim();
  return s.isNotEmpty ? s : tr('未知插件');
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
    final fallbackName = _firstNonEmptyText(isLx
            ? [info['name'], fileName]
            : [
                metadata['pluginName'],
                metadata['platform'],
                fileName,
              ]) ??
        tr('未知插件');
    final mAuthor = isLx
        ? (info['author'] ?? '')
        : (metadata['author']?.toString() ?? '');
    final mVersion = versionOverride ??
        (isLx ? (info['version'] ?? '') : (metadata['version']?.toString() ?? ''));
    final mDesc = isLx
        ? (info['description'] ?? '')
        : (metadata['description']?.toString() ?? '');
    // name 落库前去不可见字符：nameOverride（订阅 JSON 的 name 字段）同样可能
    // 被零宽混淆，纯混淆串会连带 fallback 链失效（存进去渲染为空白）
    final rawName = (nameOverride ?? fallbackName).toString();
    final cleanName = stripInvisibleChars(rawName).trim();
    final source = PluginSource(
      id: id,
      name: cleanName.isNotEmpty ? cleanName : tr('未知插件'),
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

  Future<PluginInstallResult> installFromUrl(
    String url, {
    void Function(String message, double? progress)? onProgress,
    bool Function()? cancelled,
  }) async {
    void checkCancelled() {
      if (cancelled?.call() ?? false) throw const PluginInstallCancelled();
    }

    checkCancelled();
    onProgress?.call(tr('正在获取插件脚本...'), null);
    final script = await _fetchScript(url, cancelled: cancelled);
    checkCancelled();
    if (script == null || script.isEmpty) {
      throw PluginEngineException(tr('无法获取插件脚本，请检查 URL 与网络'));
    }

    final batch = _parsePluginList(script);
    if (batch != null && batch.isNotEmpty) {
      final result = await _installBatch(batch,
          onProgress: onProgress, cancelled: cancelled);
      if (result.success) {
        await _recordSubscription(url);
      }
      return result;
    }

    checkCancelled();
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
    } catch (e) { AppLog.warn('plugin', '记录订阅来源失败: $e'); }
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
    } catch (e) {
      AppLog.warn('plugin', 'plugin list parse failed: $e');
      return null;
    }
  }

  Future<PluginInstallResult> _installBatch(
    List<Map<String, dynamic>> items, {
    void Function(String message, double? progress)? onProgress,
    bool Function()? cancelled,
  }) async {
    final names = <String>[];
    final errors = <String>[];
    final total = items.length;
    for (var i = 0; i < items.length; i++) {
      // 批量导入逐项响应取消（PluginInstallCancelled 向上穿透，
      // 由 installFromUrl 的调用方静默处理）
      if (cancelled?.call() ?? false) throw const PluginInstallCancelled();
      final item = items[i];
      final url = item['url'].toString();
      final label = (item['name'] ?? url).toString();
      onProgress?.call(
        tr('正在导入 {label} ({i}/{total})', {'label': label, 'i': i + 1, 'total': total}),
        i / total,
      );
      try {
        final script = await _fetchScript(url, cancelled: cancelled);
        if (cancelled?.call() ?? false) {
          throw const PluginInstallCancelled();
        }
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
      } on PluginInstallCancelled {
        // 取消不能被吞成单项失败：向上穿透交给调用方静默处理
        rethrow;
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

  Future<String?> _fetchScript(String url,
          {bool Function()? cancelled}) =>
      fetchPluginScriptWithRetry(url, cancelled: cancelled);

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
      } catch (_) { /* 行内容解析失败，跳过该条 */ }
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
    } catch (e) { AppLog.warn('plugin', '导入插件 Cookie 失败: $e'); }
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
