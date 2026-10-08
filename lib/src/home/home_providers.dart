import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth/account_api.dart';
import '../auth/auth_provider.dart';
import '../core/application_logger.dart';
import '../core/db_path.dart';
import '../library/library_provider.dart';
import '../online/online_meta_store.dart';
import '../player/player_provider.dart';
import '../rust/api.dart';
import '../i18n/i18n.dart';

class MostPlayedEntry {
  final Song? song;
  final QueueItem? onlineItem;
  final int playCount;
  const MostPlayedEntry({this.song, this.onlineItem, required this.playCount});

  QueueItem? toQueueItem() => song?.toQueueItem() ?? onlineItem;
}

bool isOnlineSongPath(String p) =>
    p.startsWith('lx://') || p.startsWith('plugin://');

final mostPlayedProvider = FutureProvider<List<MostPlayedEntry>>((ref) async {
  final dbPath = await ref.read(dbPathProvider.future);
  final json = await statsGetBehaviorStats(
    dbPath: dbPath,
    timeRangeJson: '{"type":"All"}',
  );
  final j = jsonDecode(json) as Map<String, dynamic>;
  final top = (j['top_songs'] as List? ?? const []);
  final songsByPath = {
    for (final s in ref.watch(libraryProvider.select((st) => st.songs)))
      s.path: s,
  };
  final onlinePaths = [
    for (final e in top)
      if (isOnlineSongPath(
          (e as Map<String, dynamic>)['song_path'] as String? ?? ''))
        e['song_path'] as String,
  ];
  final onlineMeta = onlinePaths.isEmpty
      ? const <String, QueueItem>{}
      : await ref.read(onlineMetaStoreProvider).getAll(onlinePaths);
  final entries = <MostPlayedEntry>[];
  for (final e in top) {
    final m = e as Map<String, dynamic>;
    final path = m['song_path'] as String? ?? '';
    final song = songsByPath[path];
    if (song != null) {
      entries.add(MostPlayedEntry(
        song: song,
        playCount: (m['play_count'] as num?)?.toInt() ?? 0,
      ));
      continue;
    }
    if (isOnlineSongPath(path)) {
      final item = onlineMeta[path];
      if (item != null) {
        entries.add(MostPlayedEntry(
          onlineItem: item,
          playCount: (m['play_count'] as num?)?.toInt() ?? 0,
        ));
      }
    }
  }
  return entries;
});

class ListenStatsData {
  final int totalSeconds;
  final int todaySeconds;
  final int todayPlayCount;

  const ListenStatsData({
    this.totalSeconds = 0,
    this.todaySeconds = 0,
    this.todayPlayCount = 0,
  });

  String get totalDurationText => _formatDuration(totalSeconds);
  String get todayDurationText => _formatDuration(todaySeconds);

  static String _formatDuration(int seconds) {
    if (seconds <= 0) return tr('0 分钟');
    final hours = seconds ~/ 3600;
    final mins = (seconds % 3600) ~/ 60;
    if (hours > 0) {
      // 累计值会长成「21 小时 14 分钟」九个字，挤在三等分的一列里会把
      // 另外两列压窄；十小时以上收成小数小时（21.2 小时），精度够用也更整齐。
      if (hours >= 10) {
        final h = seconds / 3600;
        final text = h.toStringAsFixed(1);
        return '${text.endsWith('.0') ? h.toStringAsFixed(0) : text} 小时';
      }
      return '$hours 小时 $mins 分';
    }
    return '$mins 分钟';
  }
}

class ListenServerSnapshot {
  final int total;
  final int daily;
  final int weekly;
  /// 快照归属账号：防止切换账号后读到别人的账
  final String uid;
  /// 队列未入账余额（离线/弱网期间产生的真实播放，还没被服务端确认）。
  /// 显示 = 快照 + 余额：离线时数字照常涨；联网回执成功那一刻余额被
  /// 新快照覆盖归零，数值连续且与排行榜最终一致。
  final int pendingTotal;
  final int pendingDaily;
  const ListenServerSnapshot({
    required this.total,
    required this.daily,
    required this.weekly,
    this.uid = '',
    this.pendingTotal = 0,
    this.pendingDaily = 0,
  });

  ListenServerSnapshot copyWith({required int pendingTotal, required int pendingDaily}) =>
      ListenServerSnapshot(
        total: total,
        daily: daily,
        weekly: weekly,
        uid: uid,
        pendingTotal: pendingTotal,
        pendingDaily: pendingDaily,
      );
}

// ==================== v2：事件流水 + 云端唯一账本 ====================
// 旧协议（本地 baseline + delta 上报 + 快照合并显示）已废弃：三个状态各自
// 维护，任何一环断（弱网超时/快照未写入/回执缺字段）显示就与排行榜脱节。
// v2 客户端零账本：只产「听歌事件」流水（幂等 id + 秒数），服务端去重入账；
// 显示一律 = 云端现算快照，与排行榜同源，结构上不可能再出现两处数字对不上。

/// 事件队列 + 快照状态。状态即快照（null = 尚未拿到云端账本）。
class ListenStatsSyncNotifier extends StateNotifier<ListenServerSnapshot?> {
  ListenStatsSyncNotifier(this._ref) : super(null) {
    _restoreQueue();
  }

  final Ref _ref;

  static const _queueKey = 'listen_events_queue_v2';
  // 单事件秒数上限：采样差值物理上不可能超过，超过视为本地表跳变丢弃
  static const int _maxEventSecs = 600;
  // 单批条数上限（与服务端一致）
  static const int _maxBatch = 200;
  // 队列上限：超过丢最老（防存储膨胀，宁可少报）
  static const int _maxQueue = 2000;
  // 快照拉取网络节流
  static const int _pullThrottleMs = 30000;

  List<Map<String, dynamic>> _queue = [];
  bool _queueLoaded = false;
  bool _busy = false;
  // 最近一次成功回执（快照刚被刷新）的时刻：50s 内的心跳快照拉取直接跳过
  int _lastEchoAt = 0;
  int _lastPullAt = 0;
  Timer? _flushTimer;

  String get _uid =>
      _ref.read(authProvider.notifier).currentState.user?.ciyuanxiId ??
      _ref.read(authProvider.notifier).currentState.user?.id ??
      '';

  bool get _isLoggedIn => _ref.read(authProvider).isLoggedIn;

  String _genId() {
    final r = Random();
    return '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
        '${r.nextInt(0x7fffffff).toRadixString(36)}';
  }

  Future<void> _restoreQueue() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_queueKey);
      if (raw != null && raw.isNotEmpty) {
        final list = jsonDecode(raw) as List? ?? const [];
        _queue = [
          for (final e in list)
            if (e is Map &&
                e['id'] is String &&
                e['secs'] is num &&
                (e['secs'] as num) > 0)
              Map<String, dynamic>.from(e),
        ];
      }
    } catch (e) {
      AppLog.debug('home', '恢复听歌事件队列失败: $e');
    }
    _queueLoaded = true;
    if (_queue.isNotEmpty) {
      _scheduleFlush();
    }
  }

  Future<void> _persistQueue() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_queueKey, jsonEncode(_queue));
    } catch (e) {
      AppLog.debug('home', '写入听歌事件队列失败: $e');
    }
  }

  /// 事件入队（由播放统计层调用，_secs 为本次确认真实听到的秒数）。
  /// 只入队不立即上报——flush 由节流定时器/心跳/登录同步驱动。
  void enqueue(int secs) {
    if (secs <= 0 || secs > _maxEventSecs) return;
    _queue.add({
      'id': _genId(),
      'secs': secs,
      'ended_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    });
    if (_queue.length > _maxQueue) {
      _queue.removeRange(0, _queue.length - _maxQueue);
    }
    _persistQueue();
    _scheduleFlush();
    _refreshPending();
  }

  /// 东八区「今天」判定：余额的 daily 部分只计入今天的事件
  bool _isToday(int endedAtSecs) {
    final local = DateTime.now().toUtc().add(const Duration(hours: 8));
    final ev = DateTime.fromMillisecondsSinceEpoch(
      (endedAtSecs + 8 * 3600) * 1000,
      isUtc: true,
    );
    return ev.year == local.year && ev.month == local.month && ev.day == local.day;
  }

  /// 重算队列未入账余额并写入 state（不触发网络）。从队列现算，
  /// 无增量漂移：离线期间显示实时反映真实播放，联网回执后归零。
  void _refreshPending() {
    final s = state;
    if (s == null) return;
    int pendingTotal = 0;
    int pendingDaily = 0;
    for (final e in _queue) {
      final secs = (e['secs'] as num?)?.toInt() ?? 0;
      if (secs <= 0) continue;
      pendingTotal += secs;
      final endedAt = (e['ended_at'] as num?)?.toInt() ?? 0;
      if (_isToday(endedAt)) pendingDaily += secs;
    }
    if (pendingTotal != s.pendingTotal || pendingDaily != s.pendingDaily) {
      state = s.copyWith(pendingTotal: pendingTotal, pendingDaily: pendingDaily);
    }
  }

  void _scheduleFlush() {
    _flushTimer?.cancel();
    _flushTimer = Timer(const Duration(seconds: 5), () {
      unawaited(flush());
    });
  }

  /// 批量上报事件队列；成功回执自带最新快照。失败原样保留队列
  /// （幂等键保证重试不重报）。队列空时退化为纯快照拉取。
  Future<void> flush() async {
    if (_busy || !_queueLoaded || !_isLoggedIn) return;
    _busy = true;
    try {
      if (_queue.isEmpty) {
        await _pullSnapshot();
        return;
      }
      final batch = _queue.take(_maxBatch).toList();
      final resp = await _ref
          .read(accountApiProvider)
          .reportListenEvents(batchId: _genId(), events: batch);
      if (resp['resetAt'] is String && (resp['resetAt'] as String).isNotEmpty) {
        await _applyReset(
          resp['resetAt'] as String,
          resp['reason'] as String? ?? '',
        );
        return;
      }
      // 成功：删掉已发送的最老 batch.length 条（期间新入队的事件在尾部，
      // 不受影响；服务端已全部幂等处理，无需逐条确认）
      if (batch.length >= _queue.length) {
        _queue.clear();
      } else {
        _queue.removeRange(0, batch.length);
      }
      _persistQueue();
      _lastEchoAt = DateTime.now().millisecondsSinceEpoch;
      _applySnapshot(resp);
      _refreshPending(); // 回执快照已含刚入账的秒数，余额重算后归零/收敛
    } catch (e) {
      AppLog.debug('home', '听歌事件上报失败（队列保留，稍后重试）: $e');
    } finally {
      _busy = false;
    }
  }

  /// 纯快照拉取：零上报，不产生入账。供自动同步心跳等外部调用，
  /// 让本机不播放时也能追平多端聚合值。
  Future<void> _pullSnapshot() async {
    if (_busy || !_isLoggedIn) return;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (nowMs - _lastPullAt < _pullThrottleMs) return;
    _lastPullAt = nowMs;
    _busy = true;
    try {
      final resp = await _ref.read(accountApiProvider).fetchListenStatsSummary();
      if (resp.isEmpty) return;
      if (resp['resetAt'] is String && (resp['resetAt'] as String).isNotEmpty) {
        await _applyReset(
          resp['resetAt'] as String,
          resp['reason'] as String? ?? '',
        );
        return;
      }
      _lastEchoAt = nowMs;
      _applySnapshot(resp);
      _refreshPending();
    } catch (e) {
      AppLog.debug('home', '拉取云端听歌统计快照失败: $e');
    } finally {
      _busy = false;
    }
  }

  /// 心跳入口：50 秒内有过成功回执（快照刚被刷新）则直接跳过。
  Future<void> heartbeatPull({bool skipIfFresh = false}) async {
    if (skipIfFresh &&
        DateTime.now().millisecondsSinceEpoch - _lastEchoAt < 50000) {
      return;
    }
    if (_queue.isNotEmpty) {
      await flush();
      return;
    }
    await _pullSnapshot();
  }

  void _applySnapshot(Map<String, dynamic> resp) {
    final uid = _uid;
    if (uid.isEmpty) return;
    state = ListenServerSnapshot(
      total: (resp['total'] as num?)?.toInt() ?? 0,
      daily: (resp['daily'] as num?)?.toInt() ?? 0,
      weekly: (resp['weekly'] as num?)?.toInt() ?? 0,
      uid: uid,
    );
  }

  /// 重置信号只被服务端发一次，必须完整落地清零：清本地统计库 + 事件队列，
  /// 快照归零。重置后立刻补拉一次快照把显示追平。
  Future<void> _applyReset(String resetAt, String reason) async {
    try {
      final dbPath = await _ref.read(dbPathProvider.future);
      await statsClearListenStats(dbPath: dbPath);
    } catch (e) {
      AppLog.debug('home', '清空本地听歌统计失败: $e');
    }
    _queue.clear();
    _persistQueue();
    state = ListenServerSnapshot(total: 0, daily: 0, weekly: 0, uid: _uid);
    AppLog.debug('home', '云端听歌统计已重置（$resetAt, $reason）');
  }

  @override
  void dispose() {
    _flushTimer?.cancel();
    super.dispose();
  }
}

final listenStatsSyncProvider =
    StateNotifierProvider<ListenStatsSyncNotifier, ListenServerSnapshot?>(
      (ref) => ListenStatsSyncNotifier(ref),
    );

/// 兼容旧调用方（auto_sync/sync_provider 心跳）：转发到 v2 同步器。
Future<void> pullListenServerSnapshot(Ref ref, {bool skipIfFresh = false}) {
  return ref
      .read(listenStatsSyncProvider.notifier)
      .heartbeatPull(skipIfFresh: skipIfFresh);
}

final FutureProvider<ListenStatsData> listenStatsProvider =
    FutureProvider<ListenStatsData>((ref) async {
  final dbPath = await ref.read(dbPathProvider.future);

  Future<ListenStatsData> readLocal() async {
    int totalSecs = 0;
    int todaySecs = 0;
    int todayCount = 0;
    try {
      final durationsJson = await statsGetListenDurations(dbPath: dbPath);
      final dj = jsonDecode(durationsJson) as Map<String, dynamic>;
      totalSecs = (dj['total'] as num?)?.toInt() ?? 0;
      todaySecs = (dj['daily'] as num?)?.toInt() ?? 0;
      todayCount = (dj['today_play_count'] as num?)?.toInt() ?? 0;
    } catch (e) {
      AppLog.warn('home', '读取本地听歌统计失败: $e');
    }
    return ListenStatsData(
      totalSeconds: totalSecs,
      todaySeconds: todaySecs,
      todayPlayCount: todayCount,
    );
  }

  final auth = ref.watch(authProvider);
  if (!auth.isLoggedIn) {
    // 未登录：没有云端账本，只能显示本地口径
    return readLocal();
  }

  // 登录：显示一律 = 云端现算快照（服务端唯一账本），与排行榜同源。
  // watch 快照 provider，flush/心跳拿到新回执时本页自动重建刷新。
  final local = await readLocal();
  final snap = ref.watch(listenStatsSyncProvider);
  // 挂载即驱动一次同步：有积压事件先上报（回执自带最新快照），
  // 无事件则纯拉快照；notifier 内部有网络节流与并发闸
  unawaited(ref.read(listenStatsSyncProvider.notifier).flush());

  if (snap == null || snap.uid != _currentUid(ref)) {
    // 云端账本还没到手（刚登录/断网）：先显示本地口径兜底，
    // 快照一到 watch 会触发重建
    return local;
  }
  return ListenStatsData(
    totalSeconds: snap.total + snap.pendingTotal,
    todaySeconds: snap.daily + snap.pendingDaily,
    todayPlayCount: local.todayPlayCount,
  );
});

String _currentUid(Ref ref) =>
    ref.read(authProvider.notifier).currentState.user?.ciyuanxiId ??
    ref.read(authProvider.notifier).currentState.user?.id ??
    '';
