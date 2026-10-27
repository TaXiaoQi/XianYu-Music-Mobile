// 文件夹范围网盘搜索：只遍历指定文件夹找音频，替代全盘 searchFiles。
//
// 账号在「网盘 → 选择文件夹」里勾选了一个或多个文件夹时，在线播放
// 结果页 / 日推等调用方用本实现代替全盘搜索——完整遍历选定文件夹子
// 树（不设深度/数量/页数上限，大文件夹几千首也会全部扫到），目录间
// 并发（_dirConcurrency），文件名包含关键词（忽略大小写）即收集。
//
// 路径语义与浏览页/选择器一致：进入子目录取「条目 path 非空且异于
// 当前目录时用 path，否则用 id」（覆盖 path 型盘与 id 型盘）。

import 'dart:async';

import 'cloud_provider.dart';
import 'cloud_types.dart';
import '../core/application_logger.dart';

/// 目录间并发上限：串行逐目录 listDir 在大目录树下是几十上百次网络往返，
/// 是搜索结果页慢的主因；同目录翻页仍串行（cursor 链式依赖）。上限对齐
/// 头部元数据探针并发（4），温和不触发风控。
const int _dirConcurrency = 4;

/// path 是否落在任一 root 子树内（目录边界：路径前缀 + '/'）。
/// root 本身也命中（filesearch 对目录本身不返回，防御性兜住）。
bool _isUnderRoots(String path, List<String> roots) => roots.any((r) {
      final base = r.endsWith('/') ? r : '$r/';
      return path == r || path.startsWith(base);
    });

/// 百度特化：filesearch 服务端全盘检索一次返回（含 path），1 次 API 替代
/// 逐目录 listDir 遍历——几十个目录的树即使并发也要多轮往返，是百度范围
/// 搜索慢的主因。命中按 roots 路径前缀过滤 + 文件名 contains 复核
/// （filesearch 是服务端分词匹配，可能宽于本地 contains）。
/// 失败（OAuth 轨无搜索接口等）返回 null，调用方回落通用遍历。
/// 注意：服务端索引对新建文件有短暂延迟，极新文件可能搜不到（通用遍历无
/// 此差异）。filesearch 无翻页（nextCursor 恒空），一次拉全。
Future<List<CloudFile>?> _scopedSearchAudioBaidu({
  required CloudProvider provider,
  required Map<String, String> cred,
  required List<String> roots,
  required String keyword,
}) async {
  try {
    final all = await provider.searchFiles(cred, keyword.trim());
    final kw = keyword.trim().toLowerCase();
    return all.files
        .where((f) =>
            !f.isDir &&
            f.isAudio &&
            f.name.toLowerCase().contains(kw) &&
            f.path != null &&
            _isUnderRoots(f.path!, roots))
        .toList();
  } catch (e) {
    final msg = e.toString();
    // 网络类失败（频控/断网）不回落 BFS：几十次 listDir 连击会加重百度
    // 风控（实测连播同域名播放直链一起打到 403/连接重置），风控期返回
    // 空结果；仅业务不支持（OAuth 轨无搜索接口）回落通用遍历。
    if (!msg.contains('OAuth') && !msg.contains('不支持')) {
      AppLog.warn('cloud',
          '[scopedSearch] ${provider.id} filesearch 失败(网络/风控?)，返回空: $msg');
      return const [];
    }
    AppLog.debug(
        'cloud', '[scopedSearch] ${provider.id} filesearch 不支持，回落遍历: $msg');
    return null;
  }
}

/// 在 [roots] 指定的文件夹范围内搜索文件名含 [keyword] 的音频。
/// 同 id 只留一条（目录间并发遍历，结果顺序不定）；网络异常的子文件夹跳过。
Future<List<CloudFile>> scopedSearchAudio({
  required CloudProvider provider,
  required Map<String, String> cred,
  required List<String> roots,
  required String keyword,
}) async {
  final kw = keyword.trim().toLowerCase();
  if (kw.isEmpty) return const [];
  if (provider.id == 'baidu') {
    final viaApi = await _scopedSearchAudioBaidu(
        provider: provider, cred: cred, roots: roots, keyword: keyword);
    if (viaApi != null) return viaApi;
    // 回落通用遍历
  }
  final outcome = await _walkAudioDirs(
      provider: provider, cred: cred, roots: roots, keyword: kw);
  return outcome.files;
}

/// 网盘页全量音频列举：遍历 [selectedRoots]（空 = 从全盘根目录起）收集
/// 全部音频文件，无关键词过滤；BFS/并发/容错语义与 scopedSearchAudio 一致。
/// 一个文件都没拿到且有目录失败时抛错（带末次错误），避免「静默 0 首」。
Future<List<CloudFile>> cloudListAllAudio({
  required CloudProvider provider,
  required Map<String, String> cred,
  required List<String> selectedRoots,
}) async {
  final outcome = await _walkAudioDirs(
    provider: provider,
    cred: cred,
    roots: selectedRoots.isNotEmpty ? selectedRoots : [provider.rootPath],
    keyword: null,
  );
  if (outcome.files.isEmpty && outcome.failedDirs > 0) {
    throw StateError('遍历目录失败 ${outcome.failedDirs} 个：${outcome.lastError}');
  }
  return outcome.files;
}

/// 目录树 BFS 遍历收集音频：[keyword] 为空时全量收集（网盘页），
/// 否则按文件名 contains 过滤（忽略大小写，scope 搜索）。
/// 返回收集结果与失败目录统计：全量场景「一个文件都没有且有目录失败」
/// 时上层据此抛错给出可见提示，而不是静默展示 0 首。
class WalkOutcome {
  WalkOutcome(this.files, this.failedDirs, this.lastError);

  final List<CloudFile> files;
  final int failedDirs;
  final String lastError;
}

Future<WalkOutcome> _walkAudioDirs({
  required CloudProvider provider,
  required Map<String, String> cred,
  required List<String> roots,
  String? keyword,
}) async {
  final kw = keyword?.trim().toLowerCase() ?? '';
  final seen = <String>{};
  final out = <CloudFile>[];
  final queue = <String>[...roots];
  var active = 0;
  var failedDirs = 0;
  var lastError = '';
  // 并发上限：百度（网页 API 高频触发风控，连带播放直链 403）、
  // 阿里（v2/file/list 对并发连击限流）收紧到 2，其余 4。
  final dirConcurrency = (provider.id == 'baidu' || provider.id == 'aliyun')
      ? 2
      : _dirConcurrency;
  // 自适应并发：起步 1（与文件夹浏览串行同节奏——串行从未被拦），
  // 连续 4 个目录成功才 +1 档提速；任一目录失败立即退回 1 并退避重试。
  var currentLimit = 1;
  var successStreak = 0;

  // 单个目录：整页拉完（翻页串行），发现的子目录入共享队列；返回是否成功
  Future<bool> scanDir(String cur) async {
    String? cursor; // 首页为 null，有 nextCursor 才翻页
    while (true) {
      CloudListResult r;
      try {
        r = await provider.listDir(cred, cur, cursor: cursor);
      } catch (e) {
        // 限流/抖动常为瞬态：退避后重试一次再放弃
        await Future<void>.delayed(const Duration(milliseconds: 900));
        try {
          r = await provider.listDir(cred, cur, cursor: cursor);
        } catch (e2) {
          // 与桌面端 walkAudio 日志对齐：失败目录留痕便于诊断遍历断链
          failedDirs += 1;
          lastError = '$e2';
          AppLog.warn('cloud',
              '[walkAudio] ${provider.id} 列目录失败 dir=$cur cursor=$cursor: $e2');
          return false;
        }
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
            (kw.isEmpty || f.name.toLowerCase().contains(kw)) &&
            seen.add(f.id)) {
          out.add(f);
          hits++;
        }
      }
      AppLog.debug('cloud',
          '[walkAudio] ${provider.id} dir=$cur cursor=$cursor files=${r.files.length} hits=$hits next=${r.nextCursor}');
      cursor = r.nextCursor;
      if (cursor == null || cursor.isEmpty) break;
    }
    return true;
  }

  final done = Completer<void>();
  void pump() {
    if (active == 0 && queue.isEmpty) {
      if (!done.isCompleted) done.complete();
      return;
    }
    while (active < currentLimit && queue.isNotEmpty) {
      final dir = queue.removeAt(0);
      active++;
      scanDir(dir).then((ok) {
        if (ok) {
          successStreak++;
          // 连续成功 4 个目录提一档并发，直到该盘上限
          if (successStreak >= 4 && currentLimit < dirConcurrency) {
            successStreak = 0;
            currentLimit += 1;
          }
        } else {
          // 一失败立即退回串行节奏（文件夹浏览同款），成功后再逐步恢复
          successStreak = 0;
          currentLimit = 1;
        }
      }).whenComplete(() {
        active--;
        pump();
      });
    }
  }

  pump();
  await done.future;
  return WalkOutcome(out, failedDirs, lastError);
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
