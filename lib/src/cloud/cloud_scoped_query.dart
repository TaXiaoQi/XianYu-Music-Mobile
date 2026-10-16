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
    while (queue.isNotEmpty) {
      final cur = queue.removeAt(0);
      String? cursor; // 首页为 null，有 nextCursor 才翻页
      while (true) {
        final CloudListResult r;
        try {
          r = await provider.listDir(cred, cur, cursor: cursor);
        } catch (_) {
          break; // 单文件夹失败不影响其余范围
        }
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
          }
        }
        cursor = r.nextCursor;
        if (cursor == null || cursor.isEmpty) break;
      }
    }
  }
  return out;
}
