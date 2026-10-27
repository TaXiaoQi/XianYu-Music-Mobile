// 兜底行为配置（服务端签名下发）共享类型。
//
// 服务端只下发配置 JSON（各元数据链路的开关/平台来源），不含任何可执行代码；
// 客户端 ed25519 验签（fallback_verify.rs，消息 xianyu-fallback-config-v1）通过
// 后才采纳，全部逻辑固定在客户端原生实现中。模块 key 与服务端约定一致；
// 未知 key / 未知方法在解析时忽略，新增 key 需两端同步。

import 'dart:convert';

/// 兜底配置的模块 key（移动端接入的五条链路）
const kFallbackModuleLxLyric = 'lx_lyric';
const kFallbackModulePluginFallback = 'plugin_fallback';
const kFallbackModulePlaylistImport = 'playlist_import';
const kFallbackModuleLxToplist = 'lx_toplist';
const kFallbackModuleLxRecommendSheets = 'lx_recommend_sheets';

/// 各模块客户端已知的方法白名单（disabledMethods 之外的方法名忽略）
const fallbackModuleMethods = <String, List<String>>{
  kFallbackModuleLxLyric: ['fetchLyric'],
  kFallbackModuleLxToplist: ['getTopLists', 'getTopListDetail'],
  kFallbackModuleLxRecommendSheets: [
    'getRecommendSheetTags',
    'getRecommendSheetsByTag',
  ],
  kFallbackModulePluginFallback: [
    'hostSearchFallback',
    'hostAlbumSearchFallback',
    'hostAlbumSongsFallback',
    'fillSongDurations',
  ],
  kFallbackModulePlaylistImport: [
    'getListDetailKg',
    'getListDetailWy',
    'getListDetailTx',
    'getListDetailKw',
    'getListDetailMg',
    'getListDetailQishui',
  ],
};

/// 允许经 params.sources 下发平台来源的模块（wy/kg/kw/tx 子集）
const fallbackModuleSourceKeys = <String>{
  kFallbackModuleLxToplist,
  kFallbackModuleLxRecommendSheets,
};

const _knownSourceKeys = {'wy', 'kg', 'kw', 'tx'};

/// 单模块配置：version 用于服务端版本追踪，客户端行为只看开关与参数
class FallbackModuleConfig {
  final int version;
  /// 服务端要求关闭的链路方法（命中后该链路返回空，不再走原生实现）
  final Set<String> disabledMethods;
  /// 平台来源白名单与顺序（仅榜单/推荐歌单模块生效；null = 不调整）
  final List<String>? sources;

  const FallbackModuleConfig({
    required this.version,
    this.disabledMethods = const {},
    this.sources,
  });
}

/// 解析后的整包兜底配置
class FallbackRemoteConfig {
  final int version;
  final Map<String, FallbackModuleConfig> modules;

  const FallbackRemoteConfig({
    required this.version,
    required this.modules,
  });
}

/// 解析服务端配置 JSON；结构非法/字段残缺返回 null，未知 key 与方法忽略。
FallbackRemoteConfig? parseFallbackConfigJson(String raw) {
  Object? decoded;
  try {
    decoded = const JsonDecoder().convert(raw);
  } catch (_) {
    return null;
  }
  if (decoded is! Map) return null;
  final version = (decoded['version'] as num?)?.toInt() ?? 0;
  if (version < 1) return null;
  final rawModules = decoded['modules'];
  if (rawModules is! Map) return null;
  final modules = <String, FallbackModuleConfig>{};
  for (final entry in rawModules.entries) {
    final key = entry.key.toString();
    final knownMethods = fallbackModuleMethods[key];
    if (knownMethods == null || entry.value is! Map) continue;
    final m = entry.value as Map;
    final disabled = <String>{};
    final rawDisabled = m['disabledMethods'];
    if (rawDisabled is List) {
      for (final method in rawDisabled) {
        final name = method.toString();
        if (knownMethods.contains(name)) disabled.add(name);
      }
    }
    List<String>? sources;
    if (fallbackModuleSourceKeys.contains(key)) {
      final rawSources = m['params'] is Map
          ? (m['params'] as Map)['sources']
          : null;
      if (rawSources is List) {
        final valid =
            rawSources.map((s) => s.toString()).where(_knownSourceKeys.contains).toList();
        // 至少保留一个有效来源才采纳，避免空列表把整条链路打空
        if (valid.isNotEmpty) sources = valid;
      }
    }
    modules[key] = FallbackModuleConfig(
      version: (m['version'] as num?)?.toInt() ?? 0,
      disabledMethods: disabled,
      sources: sources,
    );
  }
  return FallbackRemoteConfig(version: version, modules: modules);
}
