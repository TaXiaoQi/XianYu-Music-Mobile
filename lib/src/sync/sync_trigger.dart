// 数据变更触发器：业务域在修改数据后调用 markDirty，AutoSyncService 启动时注册处理器。
// 通过静态类解耦，避免业务 provider 与 sync 模块相互 import 成环。
typedef SyncTriggerHandler = void Function(Set<String> domains);

class SyncTrigger {
  static SyncTriggerHandler? _handler;

  // 常用域标识（与 AutoSyncService._flushDirty 的分发一致）
  static const playlists = 'playlists';
  static const plugins = 'plugins';
  static const favorites = 'favorites';
  static const settings = 'settings';

  static void register(SyncTriggerHandler? handler) => _handler = handler;

  /// 业务域数据变更后调用；连续变更由防抖合并，未注册或未登录时为空操作
  static void markDirty(Set<String> domains) => _handler?.call(domains);
}
