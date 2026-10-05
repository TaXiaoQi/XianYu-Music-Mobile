// 兜底模块（fallback modules）共享类型（移植自桌面端 fallbackModules/types）。
//
// 移动端接入四条链路：逐字歌词解码（lx_lyric）、插件宿主兜底（plugin_fallback）、
// 歌单导入（playlist_import）与音源榜单（lx_toplist），key/方法白名单与 Rust 侧
// FALLBACK_MODULE_METHODS（fallback_host/mod.rs）一致；新增 key 需两端同步。

/// 服务端下发的兜底模块 key（移动端子集）
const kFallbackModuleLxLyric = 'lx_lyric';
const kFallbackModulePluginFallback = 'plugin_fallback';
const kFallbackModulePlaylistImport = 'playlist_import';
const kFallbackModuleLxToplist = 'lx_toplist';

/// 各模块期望导出的方法
const fallbackModuleMethods = <String, List<String>>{
  kFallbackModuleLxLyric: ['fetchLyric'],
  kFallbackModuleLxToplist: ['getTopLists', 'getTopListDetail'],
  kFallbackModulePluginFallback: [
    'isQqMusicPluginSource',
    'hostSearchFallback',
    'hostAlbumSearchFallback',
    'hostAlbumSongsFallback',
    'isQqTrialMediaUrl',
    'fillSongDurations',
  ],
  kFallbackModulePlaylistImport: [
    'getListDetailKg',
    'getListDetailWy',
    'getListDetailTx',
    'getListDetailKw',
    'getListDetailQishui',
  ],
};

/// 本地缓存的已验签模块
class CachedFallbackModule {
  final int version;
  final String digest;
  final String code;
  final String signature;
  final String? name;
  final String? updatedAt;

  const CachedFallbackModule({
    required this.version,
    required this.digest,
    required this.code,
    required this.signature,
    this.name,
    this.updatedAt,
  });

  factory CachedFallbackModule.fromJson(Map<String, dynamic> j) =>
      CachedFallbackModule(
        version: (j['version'] as num?)?.toInt() ?? 0,
        digest: (j['digest'] ?? '').toString(),
        code: (j['code'] ?? '').toString(),
        signature: (j['signature'] ?? '').toString(),
        name: (j['name'] as String?)?.isEmpty ?? true ? null : j['name'] as String?,
        updatedAt: (j['updatedAt'] as String?)?.isEmpty ?? true
            ? null
            : j['updatedAt'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'version': version,
        'digest': digest,
        'code': code,
        'signature': signature,
        if (name != null) 'name': name,
        if (updatedAt != null) 'updatedAt': updatedAt,
      };
}

/// 服务端下发的模块条目（经 normalizeModule 校验后）
class ServerFallbackModule {
  final String moduleKey;
  final int version;
  final String digest;
  final String code;
  final String signature;
  final String? name;
  final String? updatedAt;

  const ServerFallbackModule({
    required this.moduleKey,
    required this.version,
    required this.digest,
    required this.code,
    required this.signature,
    this.name,
    this.updatedAt,
  });
}
