// 网盘直链内存缓存。
//
// key = cloud:// path（provider/account/file 唯一标识）；值 = 直链 + 失效
// 时刻。失效判定：expireAt（provider 给出）或默认 TTL 兜底。播放中直链
// 异常（起播失败/时长异常）由 player_provider.cloud 主动 [invalidate]
// 后重取一次。

import 'cloud_types.dart';

class DirectLinkCache {
  DirectLinkCache._();

  static final DirectLinkCache instance = DirectLinkCache._();

  final _map = <String, _Entry>{};

  Future<CloudDirectLink?> get(
    String key,
    Duration defaultTtl, {
    bool allowExpired = false,
  }) async {
    final e = _map[key];
    if (e == null) return null;
    final expiredAt =
        e.link.expireAt ?? e.cachedAt.add(defaultTtl);
    if (DateTime.now().isAfter(expiredAt)) {
      if (!allowExpired) return null;
    }
    return e.link;
  }

  void put(String key, CloudDirectLink link) {
    _map[key] = _Entry(link, DateTime.now());
  }

  /// 直链失效后清缓存重取（重取失败保留旧值做一次兜底重试由调用方决定）。
  void invalidate(String key) => _map.remove(key);

  void clear() => _map.clear();
}

class _Entry {
  _Entry(this.link, this.cachedAt);
  final CloudDirectLink link;
  final DateTime cachedAt;
}
