// 文件夹范围网盘搜索：只遍历指定文件夹找音频，替代全盘 searchFiles。
//
// 账号在「网盘 → 选择文件夹」里勾选了一个或多个文件夹时，在线播放
// 结果页 / 日推等调用方用本实现代替全盘搜索——BFS 完整遍历选定文件
// 夹子树（不设深度/数量/页数上限，大文件夹几千首也会全部扫到），
// 文件名包含关键词（忽略大小写）即收集。
//
// 路径语义与浏览页/选择器一致：进入子目录取「条目 path 非空且异于
// 当前目录时用 path，否则用 id」（覆盖 path 型盘与 id 型盘）。

import 'cloud_provider.dart';
import 'cloud_types.dart';
import '../core/application_logger.dart';

/// 在 [roots] 指定的文件夹范围内搜索文件名含 [keyword] 的音频。
/// 返回结果按遍历顺序去重（同 id 只留一条）；网络异常的子文件夹跳过。
Future<List<CloudFile>> scopedSearchAudio({
  required CloudProvider provider,
  required Map<String, String> cred,
  required List<String> roots,
  required String keyword,
}) async {
  final kw = keyword.trim().toLowerCase();
  if (kw.isEmpty) return const [];
  final seen = <String>{};
  final out = <CloudFile>[];
  for (final root in roots) {
    final queue = <String>[root];
    var dirs = 0;
    while (queue.isNotEmpty) {
      final cur = queue.removeAt(0);
      dirs++;
      String? cursor; // 首页为 null，有 nextCursor 才翻页
      while (true) {
        final CloudListResult r;
        try {
          r = await provider.listDir(cred, cur, cursor: cursor);
        } catch (e) {
          // 单文件夹失败不影响其余范围；留痕便于诊断遍历断链
          AppLog.warn('cloud',
              '[scopedSearch] ${provider.id} 列目录失败 dir=$cur cursor=$cursor: $e');
          break;
        }
        var hits = 0;
        for (final f in r.files) {
          if (f.isDir) {
            final next =
                (f.path != null && f.path!.isNotEmpty && f.path != cur)
                    ? f.path!
                    : f.id;
            queue.add(next);
          } else if (f.isAudio &&
              f.name.toLowerCase().contains(kw) &&
              seen.add(f.id)) {
            out.add(f);
            hits++;
          }
        }
        AppLog.debug('cloud',
            '[scopedSearch] ${provider.id} dir=$cur cursor=$cursor files=${r.files.length} hits=$hits next=${r.nextCursor}');
        cursor = r.nextCursor;
        if (cursor == null || cursor.isEmpty) break;
      }
    }
    AppLog.debug(
        'cloud', '[scopedSearch] ${provider.id} root=$root dirs=$dirs hits 累计=${out.length}');
  }
  return out;
}

/// 网盘关键词搜索统一入口（搜索结果页 / 日推共用）：
/// 已选文件夹 → 优先只遍历选定范围（快）；范围内无命中则自动扩大到
/// 全盘（搜索是全局动作，勾选范围只是加速——勾选的文件夹未必包含
/// 目标文件）。未选目录 → 先盘侧搜索（快且支持翻页），接口变更/限流
/// ——如迅雷「无效的文件过滤器」——则回退根目录全盘遍历。
Future<List<CloudFile>> cloudKeywordSearchAudio({
  required CloudProvider provider,
  required Map<String, String> cred,
  required List<String> selectedRoots,
  required String keyword,
}) async {
  final kw = keyword.trim();
  if (kw.isEmpty) return const [];
  AppLog.debug('cloud',
      '[scopedSearch] ${provider.id} kw=$kw selectedRoots=$selectedRoots');
  if (selectedRoots.isNotEmpty) {
    final scoped = await scopedSearchAudio(
        provider: provider, cred: cred, roots: selectedRoots, keyword: kw);
    if (scoped.isNotEmpty) return scoped;
    AppLog.debug('cloud',
        '[scopedSearch] ${provider.id} 范围内无命中，扩大到全盘遍历');
  }
  try {
    final res = await provider.searchFiles(cred, kw);
    final hits = res.files.where((f) => !f.isDir && f.isAudio).toList();
    if (hits.isNotEmpty) return hits;
  } catch (e) {
    AppLog.warn('cloud', '${provider.id} 盘侧搜索失败，回退全盘遍历: $e');
  }
  return scopedSearchAudio(
      provider: provider, cred: cred, roots: [provider.rootPath], keyword: kw);
}
