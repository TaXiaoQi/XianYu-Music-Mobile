part of 'sync_provider.dart';

/// 网盘凭据云同步：把本地 AES 密封的凭据串整包上云 / 拉取合并。
/// 服务端只见 `xy1:` 密文；绑定/解绑/凭据轮换经 store.onPersisted 钩子
/// 触发防抖自动上传，登录后与手动同步走 upload/download 全量路径。
class CloudCredsSyncService {
  CloudCredsSyncService(this._ref, this._lens);

  final Ref _ref;
  final SyncDomainLens _lens;

  AccountApi get _api => _ref.read(accountApiProvider);

  String get _ciyuanxiId => _ref.read(authProvider).user?.ciyuanxiId ?? '';

  Future<void> upload() async {
    _lens.item = _lens.item.copyWith(syncing: true, errors: []);
    try {
      final uid = _ciyuanxiId;
      final sealed = uid.isEmpty
          ? null
          : await CloudCredentialsStore.instance.exportForSync(uid);
      if (sealed == null || sealed.isEmpty) {
        _lens.item = _lens.item.copyWith(
          syncing: false,
          lastSummary: tr('未绑定网盘账号，跳过上传'),
          lastTime: DateTime.now(),
          errors: [],
        );
        return;
      }
      await _api.uploadCloudCreds(sealed);
      _lens.item = _lens.item.copyWith(
        syncing: false,
        lastSummary: tr('网盘账号已上传'),
        lastTime: DateTime.now(),
        errors: [],
      );
    } catch (e) {
      AppLog.warn('sync', '网盘凭据上传失败: $e');
      _fail(e is AuthException ? e.message : tr('上传失败: {e}', {'e': e}));
    }
  }

  Future<void> download() async {
    _lens.item = _lens.item.copyWith(syncing: true, errors: []);
    try {
      final sealed = await _api.downloadCloudCreds();
      if (sealed == null) {
        _lens.item = _lens.item.copyWith(
          syncing: false,
          lastSummary: tr('云端暂无网盘账号'),
          lastTime: DateTime.now(),
        );
        return;
      }
      // 指纹去重合并进本地（不覆盖本地已有绑定）
      await CloudCredentialsStore.instance.importFromSync(sealed, _ciyuanxiId);
      _lens.item = _lens.item.copyWith(
        syncing: false,
        lastSummary: tr('已拉取云端网盘账号'),
        lastTime: DateTime.now(),
        errors: [],
      );
    } catch (e) {
      AppLog.warn('sync', '网盘凭据下载失败: $e');
      _fail(e is AuthException ? e.message : tr('下载失败: {e}', {'e': e}));
    }
  }

  void _fail(String err) {
    _lens.item = _lens.item.copyWith(
      syncing: false,
      errors: [err],
    );
  }
}
