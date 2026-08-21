import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/db_path.dart';
import '../rust/api.dart' as rust;

/// 已安装的音源插件。
class PluginInfo {
  final String id;
  final String name;
  final String version;
  final String author;
  final String description;
  final bool enabled;

  /// 该插件支持的音源标识（kw/kg/tx/wy 等）。
  final List<String> sources;

  /// 各音源支持的音质档位。
  final Map<String, List<String>> qualitys;

  /// 安装来源：本地文件路径或订阅 URL。
  final String origin;

  const PluginInfo({
    required this.id,
    required this.name,
    required this.version,
    required this.author,
    required this.description,
    required this.enabled,
    required this.sources,
    required this.qualitys,
    required this.origin,
  });

  factory PluginInfo.fromJson(Map<String, dynamic> j) {
    final rawQ = (j['qualitys'] as Map?) ?? const {};
    return PluginInfo(
      id: (j['id'] as String?) ?? '',
      name: (j['name'] as String?) ?? '',
      version: (j['version'] as String?) ?? '',
      author: (j['author'] as String?) ?? '',
      description: (j['description'] as String?) ?? '',
      enabled: (j['enabled'] as bool?) ?? false,
      sources: ((j['sources'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList(),
      qualitys: rawQ.map(
        (k, v) => MapEntry(
          k.toString(),
          ((v as List?) ?? const []).map((e) => e.toString()).toList(),
        ),
      ),
      origin: (j['origin'] as String?) ?? '',
    );
  }

  /// 是否来自订阅 URL（可用于后续更新）。
  bool get fromUrl => origin.startsWith('http://') || origin.startsWith('https://');
}

/// 插件列表状态。
class PluginState {
  final List<PluginInfo> plugins;
  final bool loading;

  /// 最近一次操作的错误信息。
  final String? error;

  const PluginState({
    this.plugins = const [],
    this.loading = false,
    this.error,
  });

  PluginState copyWith({
    List<PluginInfo>? plugins,
    bool? loading,
    Object? error = _noChange,
  }) {
    return PluginState(
      plugins: plugins ?? this.plugins,
      loading: loading ?? this.loading,
      error: error == _noChange ? this.error : error as String?,
    );
  }

  /// 已启用的插件覆盖的全部音源。
  Set<String> get enabledSources => plugins
      .where((p) => p.enabled)
      .expand((p) => p.sources)
      .toSet();

  /// 是否有任何已启用的插件。
  bool get hasEnabled => plugins.any((p) => p.enabled);
}

const Object _noChange = Object();

class PluginNotifier extends StateNotifier<PluginState> {
  PluginNotifier(this._ref) : super(const PluginState(loading: true)) {
    load();
  }

  final Ref _ref;

  Future<String> _dataDir() => _ref.read(appDataDirProvider.future);

  /// 读取已安装插件列表。
  Future<void> load() async {
    state = state.copyWith(loading: true, error: null);
    try {
      final json = await rust.pluginList(dataDir: await _dataDir());
      final list = (jsonDecode(json) as List)
          .map((e) => PluginInfo.fromJson(e as Map<String, dynamic>))
          .toList();
      if (!mounted) return;
      state = state.copyWith(plugins: list, loading: false);
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(loading: false, error: '读取插件列表失败：$e');
    }
  }

  /// 从本地 `.js` 文件导入。
  ///
  /// 返回导入成功的插件名；失败抛出带原因的异常。
  Future<String> installFromFile(String path) async {
    final json = await rust.pluginInstallFile(
      dataDir: await _dataDir(),
      path: path,
    );
    final info = PluginInfo.fromJson(jsonDecode(json) as Map<String, dynamic>);
    await load();
    return info.name;
  }

  /// 从订阅 URL 导入。
  Future<String> installFromUrl(String url) async {
    final json = await rust.pluginInstallUrl(
      dataDir: await _dataDir(),
      url: url,
    );
    final info = PluginInfo.fromJson(jsonDecode(json) as Map<String, dynamic>);
    await load();
    return info.name;
  }

  /// 启用或停用。
  Future<void> setEnabled(String id, bool enabled) async {
    await rust.pluginSetEnabled(
      dataDir: await _dataDir(),
      id: id,
      enabled: enabled,
    );
    await load();
  }

  /// 卸载。
  Future<void> remove(String id) async {
    await rust.pluginRemove(dataDir: await _dataDir(), id: id);
    await load();
  }
}

final pluginProvider =
    StateNotifierProvider<PluginNotifier, PluginState>((ref) {
  return PluginNotifier(ref);
});
