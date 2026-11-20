import 'host_sheet_import.dart';
import 'plugin_models.dart';

/// 内置 lx 直连兜底的平台开关：对应平台需有启用插件才可用。
///
/// 与桌面端 lxPluginGate.ts 同规则——没有对应插件就不兜底，
/// App 退化为本地播放器形态。
/// - wy/tx/kw/kg/mg：存在启用的 lx 插件声明该音源（sources 含平台键）
/// - qishui：存在任意已启用且匹配汽水的插件（lx 用 sources 含 qs；
///   musicfree/anime 用 QishuiSheetImport.isQishuiSource 判定，
///   汽水插件一般是 anime/musicfree 格式）
bool hasEnabledLxPluginFor(List<PluginSource> plugins, String platform) {
  final enabled = plugins.where((p) => p.enabled);
  if (platform == 'qishui') {
    return enabled.any((p) =>
        p.format == PluginFormat.lx
            ? p.sources.contains('qs')
            : QishuiSheetImport.isQishuiSource(p.name, p.sources));
  }
  return enabled
      .any((p) => p.format == PluginFormat.lx && p.sources.contains(platform));
}
