import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'plugin_engine.dart';
import 'plugin_models.dart';
import 'plugin_preferences.dart';
import 'plugin_provider.dart';
import 'plugin_subscriptions.dart';
import '../i18n/i18n.dart';

class PluginUpdateCheckResult {
  final bool hasUpdate;
  final String currentVersion;
  final String newVersion;
  final String? newScript;
  final String updateUrl;

  PluginUpdateCheckResult({
    required this.hasUpdate,
    required this.currentVersion,
    required this.newVersion,
    this.newScript,
    required this.updateUrl,
  });
}

int compareVersions(String a, String b) {
  final pa = _parseVersion(a);
  final pb = _parseVersion(b);
  final maxLen =
      pa.fields.length > pb.fields.length ? pa.fields.length : pb.fields.length;
  for (var i = 0; i < maxLen; i++) {
    final av = i < pa.fields.length ? pa.fields[i] : 0;
    final bv = i < pb.fields.length ? pb.fields[i] : 0;
    if (av != bv) return av.compareTo(bv);
  }
  if (pa.pre == null || pb.pre == null) return 0;
  if (pa.preToken != pb.preToken) {
    return pa.preToken.compareTo(pb.preToken);
  }
  return pa.preNum.compareTo(pb.preNum);
}

class _VersionParts {
  final List<int> fields;
  final String? pre;
  final String preToken;
  final int preNum;
  const _VersionParts(this.fields, this.pre, this.preToken, this.preNum);
}

_VersionParts _parseVersion(String v) {
  var s = v.trim();
  if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
  final dash = s.indexOf('-');
  final main = dash >= 0 ? s.substring(0, dash) : s;
  final preStr = dash >= 0 ? s.substring(dash + 1) : null;
  final fields =
      main.split(RegExp(r'[._+]')).map((p) => int.tryParse(p) ?? 0).toList();
  var preToken = '';
  var preNum = 0;
  if (preStr != null) {
    preToken = RegExp(r'^[a-zA-Z]*').firstMatch(preStr)?.group(0) ?? '';
    final num = RegExp(r'(\d+)').firstMatch(preStr);
    preNum = num != null ? int.tryParse(num.group(1)!) ?? 0 : 0;
  }
  return _VersionParts(fields, preStr, preToken, preNum);
}

String? _extractMusicFreeVersion(String script) {
  final propMatches = RegExp(
          r'[{,]\s*version\s*:\s*[\x27\x22]([^\x27\x22]+)[\x27\x22]')
      .allMatches(script);
  if (propMatches.isNotEmpty) {
    return propMatches.last.group(1);
  }
  final match = RegExp(
          r'version\s*[=:]\s*[\x27\x22]([^\x27\x22]+)[\x27\x22]')
      .firstMatch(script);
  return match?.group(1);
}

String? _extractMusicFreeSrcUrl(String script) {
  final propMatches = RegExp(
          r'[{,]\s*srcUrl\s*:\s*[\x27\x22]([^\x27\x22]+)[\x27\x22]')
      .allMatches(script);
  if (propMatches.isNotEmpty) {
    return propMatches.last.group(1);
  }
  final match = RegExp(
          r'srcUrl\s*[=:]\s*[\x27\x22]([^\x27\x22]+)[\x27\x22]')
      .firstMatch(script);
  return match?.group(1);
}

class PluginUpdateService {
  final PluginEngine engine;
  final PluginManager manager;
  final List<PluginSubscription> Function()? subscriptionsReader;

  PluginUpdateService(this.engine, this.manager,
      {this.subscriptionsReader});

  final Map<String, ({int at, List<({String url, String? version, String? name})> items})>
      _subCache = {};
  final Map<String, Future<({int at, List<({String url, String? version, String? name})> items})>>
      _subFetchInFlight = {};
  static const int _subCacheTtlMs = 5 * 60 * 1000;

  List<({String url, String? version, String? name})> _parseSubscriptionItems(
      String content) {
    try {
      final json = jsonDecode(content);
      final list = json is List
          ? json
          : (json is Map
              ? (json['plugins'] ?? json['plugin'] ?? json['sources'])
              : null);
      if (list is! List) return <({String url, String? version, String? name})>[];
      return [
        for (final it in list)
          if (it is Map &&
              it['url'] is String &&
              (it['url'] as String).trim().isNotEmpty)
            (
              url: (it['url'] as String).trim(),
              version: it['version'] is String
                  ? (it['version'] as String).trim()
                  : null,
              name: it['name'] is String ? it['name'] as String : null,
            ),
      ];
    } catch (_) {
      return <({String url, String? version, String? name})>[];
    }
  }

  Future<List<({String url, String? version, String? name})>> _getSubscriptionItems(
      String subUrl) async {
    final cached = _subCache[subUrl];
    if (cached != null &&
        DateTime.now().millisecondsSinceEpoch - cached.at <= _subCacheTtlMs) {
      return cached.items;
    }
    Future<({int at, List<({String url, String? version, String? name})> items})>?
        inFlight = _subFetchInFlight[subUrl];
    if (inFlight == null) {
      inFlight = (() async {
        final content = await _fetchScript(subUrl);
        return (
          at: DateTime.now().millisecondsSinceEpoch,
          items: content == null
              ? <({String url, String? version, String? name})>[]
              : _parseSubscriptionItems(content),
        );
      })();
      _subFetchInFlight[subUrl] = inFlight;
    }
    try {
      final entry = await inFlight;
      _subCache[subUrl] = entry;
      return entry.items;
    } finally {
      _subFetchInFlight.remove(subUrl);
    }
  }

  String _stripUrlQuery(String u) {
    try {
      final uri = Uri.parse(u);
      return '${uri.scheme}://${uri.authority}${uri.path}';
    } catch (_) {
      return u;
    }
  }

  bool _matchSubscriptionItem(
    ({String url, String? version, String? name}) item,
    String filePath,
    String pluginName,
  ) {
    if (item.url == filePath) return true;
    final itemStrip = _stripUrlQuery(item.url);
    final fileStrip = _stripUrlQuery(filePath);
    if (itemStrip.isNotEmpty &&
        fileStrip.isNotEmpty &&
        itemStrip == fileStrip) {
      return true;
    }
    final itemName = item.name;
    if (pluginName.isNotEmpty &&
        itemName != null &&
        itemName.trim() == pluginName.trim()) {
      return true;
    }
    return false;
  }

  Future<({String url, String? version, String? name, String subscriptionUrl})?>
      _findSubscriptionPlugin(String filePath, String pluginName) async {
    final subs = subscriptionsReader?.call() ?? const [];
    if (filePath.isEmpty || !filePath.startsWith('http')) return null;
    for (final sub in subs) {
      if (sub.url.isEmpty) continue;
      final items = await _getSubscriptionItems(sub.url);
      for (final item in items) {
        if (_matchSubscriptionItem(item, filePath, pluginName)) {
          return (
            url: item.url,
            version: item.version,
            name: item.name,
            subscriptionUrl: sub.url,
          );
        }
      }
    }
    return null;
  }

  Future<PluginUpdateCheckResult?> checkPluginUpdate(
      PluginSource source) async {
    if (await PluginPreferences.getSkipUpdateCheck(source.id)) {
      return null;
    }

    final subPlugin = await _findSubscriptionPlugin(
        source.sourceUrl, source.name);
    if (subPlugin != null && subPlugin.version != null) {
      final hasUpdate = compareVersions(subPlugin.version!, source.version) > 0;
      if (!hasUpdate) {
        return PluginUpdateCheckResult(
          hasUpdate: false,
          currentVersion: source.version,
          newVersion: subPlugin.version!,
          updateUrl: subPlugin.url,
        );
      }
      final newScript = await _fetchScript(subPlugin.url);
      if (newScript != null && newScript.isNotEmpty) {
        return PluginUpdateCheckResult(
          hasUpdate: true,
          currentVersion: source.version,
          newVersion: subPlugin.version!,
          newScript: newScript,
          updateUrl: subPlugin.url,
        );
      }
    }

    String? updateUrl;

    if (source.format == PluginFormat.musicfree) {
      final script = await engine.store.readScript(source.id);
      if (script != null) {
        updateUrl = _extractMusicFreeSrcUrl(script);
      }
      if (updateUrl == null &&
          source.sourceUrl.startsWith('http')) {
        updateUrl = source.sourceUrl;
      }
    } else {
      if (source.sourceUrl.startsWith('http')) {
        updateUrl = source.sourceUrl;
      } else {
        final script = await engine.store.readScript(source.id);
        if (script != null) {
          final info = engine.parseLxScriptInfo(script);
          if (info['homepage'] != null && info['homepage']!.isNotEmpty) {
            updateUrl = info['homepage'];
          }
        }
      }
    }

    if (updateUrl == null || updateUrl.isEmpty) return null;

    final newScript = await _fetchScript(updateUrl);
    if (newScript == null || newScript.isEmpty) return null;

    if (source.format == PluginFormat.musicfree && source.id.isNotEmpty) {
      final newHash = sha256.convert(utf8.encode(newScript)).toString();
      if (newHash == source.id) {
        return PluginUpdateCheckResult(
          hasUpdate: false,
          currentVersion: source.version,
          newVersion: source.version,
          updateUrl: updateUrl,
        );
      }
    }

    String newVersion = '';
    if (source.format == PluginFormat.musicfree) {
      newVersion = _extractMusicFreeVersion(newScript) ?? '';
    } else {
      newVersion = engine.parseLxScriptInfo(newScript)['version'] ?? '';
    }
    if (newVersion.isEmpty) return null;

    final hasUpdate = compareVersions(newVersion, source.version) > 0;
    return PluginUpdateCheckResult(
      hasUpdate: hasUpdate,
      currentVersion: source.version,
      newVersion: newVersion,
      newScript: hasUpdate ? newScript : null,
      updateUrl: updateUrl,
    );
  }

  Future<({bool success, PluginSource? newSource, String message})>
      performPluginUpdate(
          PluginSource source, PluginUpdateCheckResult checkResult) async {
    if (checkResult.newScript == null) {
      return (success: false, newSource: null, message: tr('无新脚本可更新'));
    }
    try {
      final newSource = await manager.installFromScript(
        checkResult.newScript!,
        fileName: checkResult.updateUrl,
        sourceUrl: checkResult.updateUrl,
      );
      if (newSource.id != source.id) {
        await manager.remove(source.id);
      }
      return (
        success: true,
        newSource: newSource,
        message: tr('{name} 已更新到 {version}', {'name': source.name, 'version': newSource.version}),
      );
    } catch (e) {
      final msg = e is PluginEngineException ? e.message : e.toString();
      return (success: false, newSource: null, message: tr('更新失败: {msg}', {'msg': msg}));
    }
  }

  Future<Map<String, PluginUpdateCheckResult>> checkAll() async {
    final results = <String, PluginUpdateCheckResult>{};
    final sources = manager.sources;
    for (final source in sources) {
      try {
        final result = await checkPluginUpdate(source);
        if (result != null) results[source.id] = result;
      } catch (_) {
      }
    }
    return results;
  }

  Future<int> checkAndInstallAll() async {
    var installed = 0;
    for (final source in manager.sources) {
      if (!source.enabled) continue;
      try {
        final result = await checkPluginUpdate(source);
        if (result == null || !result.hasUpdate) continue;
        final outcome = await performPluginUpdate(source, result);
        if (outcome.success) installed++;
      } catch (_) {
      }
    }
    return installed;
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
      return await resp.transform(utf8.decoder).join();
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }
}

Future<void> runPluginAutoUpdateOnStartup(
    ProviderContainer container, void Function(String message)? log) async {
  try {
    if (!await PluginPreferences.getAutoUpdateOnStartup()) return;
    final engine = await container.read(pluginEngineProvider.future);
    final manager = container.read(pluginManagerProvider.notifier);
    if (manager.sources.isEmpty) await manager.refresh();
    final service = PluginUpdateService(
      engine,
      manager,
      subscriptionsReader: () =>
          container.read(pluginSubscriptionsProvider),
    );
    final installed = await service.checkAndInstallAll();
    if (installed > 0 && log != null) {
      log(tr('启动自动更新：已更新 {n} 个插件', {'n': installed}));
    }
  } catch (_) {
  }
}
