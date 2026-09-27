import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/auth/account_api.dart';
import '../../src/auth/server_models.dart';

/// 排行榜预取缓存：period → 上一次结果。
///
/// 个人中心统计卡点击前先静默预热，页面打开即命中缓存，转场那几百毫秒里
/// 就不会只剩一屏空骨架（这也是"点进去先闪一下"的成因）。
final leaderboardCacheProvider =
    Provider<Map<String, List<LeaderboardEntry>>>((ref) => {});

/// 榜单默认周期（页面第一个 tab）。预取与页面必须用同一个 key 才能命中。
const String kLeaderboardDefaultPeriod = 'daily';

/// 正在预取中的周期：统计卡展示与点击都会触发预热，避免重复请求同一周期。
final _leaderboardPending = <String>{};

/// 静默预热榜单数据：结果放进缓存。失败不抛、也不覆盖已有缓存，
/// 页面自身的加载态照旧兜底。重复触发（已缓存/正在请求）直接跳过。
Future<void> prefetchLeaderboard(
  WidgetRef ref, [
  String period = kLeaderboardDefaultPeriod,
]) async {
  final cache = ref.read(leaderboardCacheProvider);
  if (cache.containsKey(period) || _leaderboardPending.contains(period)) return;
  _leaderboardPending.add(period);
  try {
    final data = await ref
        .read(accountApiProvider)
        .fetchLeaderboard(limit: 15, period: period);
    final list = List<LeaderboardEntry>.from(data.leaderboard);
    if (data.me != null && !list.any((e) => e.isMe)) {
      list.add(data.me!);
    }
    cache[period] = list;
  } catch (_) {
    // 静默失败：页面自己会重新请求并显示加载/错误态
  } finally {
    _leaderboardPending.remove(period);
  }
}

/// 页面侧读缓存。
List<LeaderboardEntry>? readCachedLeaderboard(WidgetRef ref, String period) =>
    ref.read(leaderboardCacheProvider)[period];

/// 页面侧回写缓存（保证下次进入直接命中）。
void storeCachedLeaderboard(
  WidgetRef ref,
  String period,
  List<LeaderboardEntry> entries,
) {
  ref.read(leaderboardCacheProvider)[period] = entries;
}
