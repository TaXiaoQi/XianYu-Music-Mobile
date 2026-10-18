part of 'sync_provider.dart';

/// 网盘凭据云同步（v2 对比流程）。
///
/// 服务端只见 `xy1:` 密文。绑定/解绑/凭据轮换/目录勾选经 store.onPersisted
/// 钩子触发防抖自动上传，登录后与手动同步走 upload/download 全量路径：
/// - 上传仅在本地向变化未同步（changeAt != syncedAt）时执行，无变化跳过；
/// - 下载带时间戳（`__ts__`）的串时云端较新才整体替换应用，本地较新跳过，
///   防止轮换类盘（阿里 refresh_token 单次有效）新凭据被云端旧包打回；
/// - 旧格式串（无时间戳）回退并集合并。
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
      if (uid.isEmpty) {
        _lens.item = _lens.item.copyWith(
          syncing: false,
          lastSummary: tr('未登录，跳过上传'),
          lastTime: DateTime.now(),
          errors: [],
        );
        return;
      }
      final store = CloudCredentialsStore.instance;
      await store.ensureLoaded();
      if (!store.needsUpload) {
        _lens.item = _lens.item.copyWith(
          syncing: false,
          lastSummary: tr('网盘账号无变化，跳过上传'),
          lastTime: DateTime.now(),
          errors: [],
        );
        return;
      }
      final sealed = await store.exportForSync(uid);
      if (sealed == null) {
        _lens.item = _lens.item.copyWith(
          syncing: false,
          lastSummary: tr('未绑定网盘账号，跳过上传'),
          lastTime: DateTime.now(),
          errors: [],
        );
        return;
      }
      await _api.uploadCloudCreds(sealed);
      await store.markSynced();
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
      final r = await CloudCredentialsStore.instance
          .importFromSync(sealed, _ciyuanxiId);
      _lens.item = _lens.item.copyWith(
        syncing: false,
        lastSummary: r.applied
            ? (r.changed ? tr('已应用云端网盘账号') : tr('网盘账号与云端一致'))
            : tr('本地较新，跳过云端下发'),
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
