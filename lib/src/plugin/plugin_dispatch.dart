import '../player/media_url.dart';
import 'baka_plugin_manager.dart';
import 'plugin_engine.dart';
import 'plugin_models.dart';

/// 唯一的 format 分发层：baka 插件走 baka arm（BakaPluginManager 自持），
/// 其余沙箱格式走 mf arm（PluginEngine）。
///
/// PluginEngine（mf 引擎）内部不含任何 baka 分支；baka 与 mf 的全部交汇
/// 收敛在本文件。若未来 baka 作者独立出规范，只需替换本层的 baka arm。
Future<ResolvedMediaUrl?> pluginGetMediaUrl(
  PluginEngine engine,
  PluginSource source,
  Map<String, dynamic> songInfo, {
  String preferred = '320k',
  String fallback = 'lower',
}) {
  if (bakaManager.shouldRouteToBaka(engine, source)) {
    return bakaManager.getMediaSource(
      engine,
      source,
      songInfo,
      preferred: preferred,
      fallback: fallback,
    );
  }
  return engine.getMusicFreeUrl(
    source,
    songInfo,
    preferred: preferred,
    fallback: fallback,
  );
}
