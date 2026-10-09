part of 'sync_provider.dart';

/// 播放历史同步服务：由 [SyncNotifier] 装配，状态经 [SyncDomainLens] 读写。
class HistorySyncService {
  HistorySyncService(this._ref, this._lens);

  final Ref _ref;
  final SyncDomainLens _lens;

  AccountApi get _api => _ref.read(accountApiProvider);

  // ==================== 播放历史同步 ====================

  Future<void> upload() async {
    _lens.item = _lens.item.copyWith(syncing: true, errors: []);
    try {
      final dbPath = await _ref.read(dbPathProvider.future);
      final json = await rust.statsGetRecentHistory(dbPath: dbPath, limit: BigInt.from(200));
      final list = (jsonDecode(json) as List)
          .map((e) => e as Map<String, dynamic>)
          .toList();
      if (list.isEmpty) {
        _lens.item = _lens.item.copyWith(
          syncing: false,
          lastSummary: tr('本地暂无播放历史'),
          lastTime: DateTime.now(),
        );
        return;
      }
      final payload = list
          .map((e) => {
                'songPath': e['songPath'] ?? '',
                'playedAt': (e['playedAt'] as num?)?.toInt() ?? 0,
              })
          .where((e) => (e['songPath'] as String).isNotEmpty)
          .toList();
      final count = await _api.uploadHistory(payload);
      _lens.item = _lens.item.copyWith(
        syncing: false,
        lastSummary: tr('已上传 {n} 条播放记录', {'n': count}),
        lastTime: DateTime.now(),
        errors: [],
      );
    } catch (e) {
      AppLog.warn('sync', '播放历史上传失败: $e');
      _fail(e is AuthException ? e.message : tr('上传失败: {e}', {'e': e}));
    }
  }

  Future<void> download() async {
    _lens.item = _lens.item.copyWith(syncing: true, errors: []);
    try {
      final history = await _api.downloadHistory();
      if (history.isEmpty) {
        _lens.item = _lens.item.copyWith(
          syncing: false,
          lastSummary: tr('云端暂无播放历史'),
          lastTime: DateTime.now(),
        );
        return;
      }
      final dbPath = await _ref.read(dbPathProvider.future);
      var added = 0;
      for (final item in history) {
        final path = (item['songPath'] as String?)?.trim() ?? '';
        if (path.isEmpty) continue;
        await rust.statsAddToHistory(dbPath: dbPath, songPath: path);
        added++;
      }
      await _ref.read(recentProvider.notifier).refresh();
      _lens.item = _lens.item.copyWith(
        syncing: false,
        lastSummary: tr('已恢复 {n} 条播放历史', {'n': added}),
        lastTime: DateTime.now(),
        errors: [],
      );
    } catch (e) {
      AppLog.warn('sync', '播放历史下载失败: $e');
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
