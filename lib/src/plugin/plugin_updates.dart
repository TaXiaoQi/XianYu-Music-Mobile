import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'plugin_engine.dart';
import 'plugin_models.dart';
import 'plugin_preferences.dart';
import 'plugin_provider.dart';

/// 插件更新检查结果。
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

/// 版本号比较：返回 >0 表示 a 更新，<0 表示 b 更新，0 表示相同。
/// 支持语义化版本如 "1.0.5"、"1.0.5-fix7"、"2.0.0-beta.1"。
int compareVersions(String a, String b) {
  final va = _parseVersion(a);
  final vb = _parseVersion(b);
  final maxLen = va.length > vb.length ? va.length : vb.length;
  for (var i = 0; i < maxLen; i++) {
    final diff = (i < va.length ? va[i] : 0) - (i < vb.length ? vb[i] : 0);
    if (diff != 0) return diff;
  }
  return 0;
}

List<int> _parseVersion(String v) {
  return v
      .split(RegExp(r'[-.]'))
      .map((p) => int.tryParse(p) ?? 0)
      .toList();
}

/// 从 MusicFree/Baka 脚本中提取版本号（不执行脚本）。
/// 优先匹配对象属性形式的 version（前面是 { 或 ,），取最后一个匹配。
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

/// 从 MusicFree/Baka 脚本中提取 srcUrl（不执行脚本）。
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

/// 插件更新服务：检查更新 + 执行更新。
class PluginUpdateService {
  final PluginEngine engine;
  final PluginManager manager;

  PluginUpdateService(this.engine, this.manager);

  /// 检查单个插件是否有可用更新。
  Future<PluginUpdateCheckResult?> checkPluginUpdate(
      PluginSource source) async {
    // 该插件已标记"跳过版本检查"，直接不检查。
    if (await PluginPreferences.getSkipUpdateCheck(source.id)) {
      return null;
    }
    String? updateUrl;

    if (source.format == PluginFormat.musicfree) {
      final script = await engine.store.readScript(source.id);
      if (script != null) {
        updateUrl = _extractMusicFreeSrcUrl(script);
      }
      if (updateUrl == null && source.filePath.startsWith('http')) {
        updateUrl = source.filePath;
      }
    } else {
      final script = await engine.store.readScript(source.id);
      if (script != null) {
        final info = engine.parseLxScriptInfo(script);
        if (info['homepage'] != null && info['homepage']!.isNotEmpty) {
          updateUrl = info['homepage'];
        }
      }
      if (updateUrl == null && source.filePath.startsWith('http')) {
        updateUrl = source.filePath;
      }
    }

    if (updateUrl == null || updateUrl.isEmpty) return null;

    final newScript = await _fetchScript(updateUrl);
    if (newScript == null || newScript.isEmpty) return null;

    // 脚本哈希对比：source.id 就是安装时脚本 SHA256 哈希。
    // 哈希一致说明内容未变化，直接判定无更新。
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

  /// 执行插件更新：安装新脚本并替换旧插件。
  Future<({bool success, PluginSource? newSource, String message})>
      performPluginUpdate(
          PluginSource source, PluginUpdateCheckResult checkResult) async {
    if (checkResult.newScript == null) {
      return (success: false, newSource: null, message: '无新脚本可更新');
    }
    try {
      final newSource = await manager.installFromScript(
        checkResult.newScript!,
        fileName: checkResult.updateUrl,
      );
      // 脚本哈希变化 → 新 ID，替换旧插件；哈希一致时 installFromScript 直接返回现有条目
      if (newSource.id != source.id) {
        await manager.remove(source.id);
      }
      return (
        success: true,
        newSource: newSource,
        message: '${source.name} 已更新到 ${newSource.version}',
      );
    } catch (e) {
      final msg = e is PluginEngineException ? e.message : e.toString();
      return (success: false, newSource: null, message: '更新失败: $msg');
    }
  }

  /// 批量检查所有已启用插件的更新。
  Future<Map<String, PluginUpdateCheckResult>> checkAll() async {
    final results = <String, PluginUpdateCheckResult>{};
    final sources = manager.sources;
    for (final source in sources) {
      try {
        final result = await checkPluginUpdate(source);
        if (result != null) results[source.id] = result;
      } catch (_) {
        // 单个插件检查失败不影响其他
      }
    }
    return results;
  }

  /// 静默批量检查并安装可用更新（供"启动自动更新"调用）。
  /// 跳过已标记"跳过版本检查"的插件，单个失败不中断。
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
        // 跳过失败项
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

/// 启动时自动更新插件（fire-and-forget，失败静默）。
/// 仅在全局开关开启且本地存在已安装插件时执行，更新后写入日志。
Future<void> runPluginAutoUpdateOnStartup(
    ProviderContainer container, void Function(String message)? log) async {
  try {
    if (!await PluginPreferences.getAutoUpdateOnStartup()) return;
    final engine = await container.read(pluginEngineProvider.future);
    final service = PluginUpdateService(
      engine,
      container.read(pluginManagerProvider.notifier),
    );
    final installed = await service.checkAndInstallAll();
    if (installed > 0 && log != null) {
      log('启动自动更新：已更新 $installed 个插件');
    }
  } catch (_) {
    // 启动静默自动更新失败不打扰用户
  }
}
