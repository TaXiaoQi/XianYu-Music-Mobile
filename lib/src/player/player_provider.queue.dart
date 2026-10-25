part of 'player_provider.dart';

extension PlayerNotifierQueue on PlayerNotifier {
  Future<void> playQueue(List<QueueItem> items,
      {int startIndex = 0, bool shareLinkPlayback = false}) async {
    if (items.isEmpty) return;
    // 快速双击同一首歌的防抖：300ms 内同参（首曲 path/长度/起点）重复
    // 调用直接忽略，避免并发两条解析链
    final sig = <Object>[
      items.first.path,
      items.length,
      startIndex,
      shareLinkPlayback,
    ];
    final lastSig = _lastPlayQueueSig;
    final lastAt = _lastPlayQueueAt;
    if (lastSig != null &&
        lastAt != null &&
        lastSig.length == sig.length &&
        lastSig.first == sig.first &&
        lastSig[1] == sig[1] &&
        lastSig[2] == sig[2] &&
        lastSig[3] == sig[3] &&
        DateTime.now().difference(lastAt) < const Duration(milliseconds: 300)) {
      AppLog.debug('play', 'playQueue 300ms 内重复调用，忽略: ${items.first.path}');
      return;
    }
    _lastPlayQueueAt = DateTime.now();
    _lastPlayQueueSig = sig;
    AppLog.info('play', 'playQueue ${items.length} 首 startIndex=$startIndex');
    _shareLinkPlayback = shareLinkPlayback;
    _tempQueue.clear();
    _resetShuffleState();
    state = state.copyWith(
      queue: items,
      queueIndex: startIndex,
      current: items[startIndex],
    );
    _syncShuffleRemaining();
    try {
      await _playAt(startIndex);
    } catch (e, st) {
      AppLog.error('play', 'playQueue 异常: $e\n$st');
      state = state.copyWith(isPlaying: false, resolving: false);
    }
  }

  Future<void> removeFromQueue(int index) async {
    final queue = [...state.queue];
    if (index < 0 || index >= queue.length) return;
    final wasCurrent = index == state.queueIndex;
    queue.removeAt(index);
    _tempQueue.removeWhere((t) => t.path == state.queue[index].path);
    if (queue.isEmpty) {
      _playEpoch++;
      _resetShuffleState();
      await _stopExclusive();
      await _player.stop();
      state = const PlaybackState();
      return;
    }
    var newIndex = state.queueIndex;
    if (index < state.queueIndex) {
      newIndex = state.queueIndex - 1;
    } else if (index == state.queueIndex) {
      newIndex = index.clamp(0, queue.length - 1);
    }
    if (wasCurrent) {
      // 先落新队列再续播：_playAt 按 state.queue 取歌，旧队列坐标系
      // 下 newIndex 指向错位（删首元素时会播回刚删的歌）
      state = state.copyWith(queue: queue, queueIndex: newIndex);
      await _playAt(newIndex);
    } else {
      state = state.copyWith(queue: queue, queueIndex: newIndex);
    }
    _syncShuffleRemaining();
  }

  Future<void> clearQueue() async {
    _playEpoch++;
    if (_activeProbeKey != null) {
      try {
        onlineQualityProbeRegistry.invalidate(_activeProbeKey!);
      } catch (e) {
        AppLog.debug('player', '探测任务清理失败: $e');
      }
      _activeProbeKey = null;
    }
    _skipDepth = 0;
    _sessionQualityOverride = null;
    await _stopExclusive();
    try {
      await _player.stop();
    } catch (e) {
      AppLog.warn('player', '播放器停止失败: $e');
    }
    state = const PlaybackState();
    _tempQueue.clear();
    _resetShuffleState();
    await _persistSession();
  }

  Future<void> reorderQueue(int oldIndex, int newIndex) async {
    if (oldIndex < 0 || oldIndex >= state.queue.length) return;
    if (newIndex < 0 || newIndex >= state.queue.length) return;
    final queue = [...state.queue];
    final item = queue.removeAt(oldIndex);
    queue.insert(newIndex, item);
    var qi = state.queueIndex;
    if (oldIndex == qi) {
      qi = newIndex;
    } else if (oldIndex < qi && newIndex >= qi) {
      qi--;
    } else if (oldIndex > qi && newIndex <= qi) {
      qi++;
    }
    state = state.copyWith(queue: queue, queueIndex: qi);
  }

  Future<void> playQueueItem(int index) async {
    if (index < 0 || index >= state.queue.length) return;
    await _playAt(index);
  }

  Future<void> playNextShare(QueueItem item) async {
    if (state.queue.isEmpty) {
      state = state.copyWith(
        queue: [item],
        queueIndex: 0,
        current: null,
        isPlaying: false,
      );
      return;
    }
    // 对齐桌面端 playNext：进临时队列（最新添加最先播），不插主队列，
    // 下一次正常切歌时优先消费
    _tempQueue.insert(0, item);
  }

  /// 消费临时队列首元素：播放瞬间才插入主队列 qi+1 并续播。
  /// 返回是否消费（调用方据此决定是否跳过常规下一首选择）。
  Future<bool> _playFromTempQueue() async {
    if (_tempQueue.isEmpty) return false;
    final qi = state.queueIndex;
    if (qi < 0 || qi >= state.queue.length) return false;
    final item = _tempQueue.removeAt(0);
    final queue = [...state.queue];
    final insertAt = (qi + 1).clamp(0, queue.length);
    queue.insert(insertAt, item);
    state = state.copyWith(queue: queue, queueIndex: qi);
    _syncShuffleRemaining();
    await _playAt(insertAt);
    return true;
  }

  Future<void> cyclePlayMode() async {
    final next = (state.playMode + 1) % 3;
    state = state.copyWith(playMode: next);
    _resetShuffleState();
    await _ref.read(settingsProvider.notifier).setPlayMode(next);
    _syncToSystemMediaSession();
  }

  int _pickNextIndex() {
    final n = state.queue.length;
    if (n == 0) return -1;
    if (state.playMode == 2) {
      return _randomNextIndex();
    }
    if (state.queueIndex < 0) return 0;
    return (state.queueIndex + 1) % n;
  }

  int _randomNextIndex() {
    // 回退后前进：优先原路消费 future 栈（消费的歌由 _playAt 钩子记账，
    // 当前歌压回 history，对齐桌面端 nextSong 的 future 分支）
    while (_shuffleFuture.isNotEmpty) {
      final path = _shuffleFuture.removeLast();
      final i = state.queue.indexWhere((q) => q.path == path);
      if (i >= 0) return i;
    }
    return _takeRemainingIndex();
  }

  /// 从本轮洗牌待播序列取下一首：一轮不重播，播完自动重洗。
  int _takeRemainingIndex() {
    _syncShuffleRemaining();
    while (_shuffleRemaining.isNotEmpty) {
      final path = _shuffleRemaining.removeAt(0);
      final i = state.queue.indexWhere((q) => q.path == path);
      if (i >= 0 && path != state.current?.path) return i;
    }
    return _randomDistinctIndex();
  }

  int _randomPrevIndex() {
    if (_shuffleHistory.isNotEmpty) {
      final path = _shuffleHistory.removeLast();
      if (state.current != null) _shuffleFuture.add(state.current!.path);
      final i = state.queue.indexWhere((q) => q.path == path);
      if (i >= 0) return i;
    }
    return _takeRemainingIndex();
  }

  int _randomDistinctIndex() {
    final n = state.queue.length;
    if (n <= 1) return 0;
    final cur = state.current?.path;
    final candidates = <int>[];
    for (var i = 0; i < n; i++) {
      if (state.queue[i].path != cur) candidates.add(i);
    }
    if (candidates.isEmpty) return 0;
    return candidates[_rand.nextInt(candidates.length)];
  }
}
