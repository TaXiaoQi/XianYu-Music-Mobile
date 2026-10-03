part of 'player_provider.dart';

extension PlayerNotifierQueue on PlayerNotifier {
  Future<void> playQueue(List<QueueItem> items,
      {int startIndex = 0, bool shareLinkPlayback = false}) async {
    if (items.isEmpty) return;
    AppLog.info('play', 'playQueue ${items.length} 首 startIndex=$startIndex');
    _shareLinkPlayback = shareLinkPlayback;
    _shuffleHistory.clear();
    _shuffleFuture.clear();
    state = state.copyWith(
      queue: items,
      queueIndex: startIndex,
      current: items[startIndex],
    );
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
    if (queue.isEmpty) {
      _playEpoch++;
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
      await _playAt(newIndex);
    } else {
      state = state.copyWith(queue: queue, queueIndex: newIndex);
    }
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
    final queue = [...state.queue];
    final qi = state.queueIndex;
    if (queue.isEmpty) {
      state = state.copyWith(
        queue: [item],
        queueIndex: 0,
        current: null,
        isPlaying: false,
      );
      return;
    }
    final insertAt = (qi + 1).clamp(0, queue.length);
    queue.insert(insertAt, item);
    state = state.copyWith(queue: queue, queueIndex: qi);
  }

  Future<void> cyclePlayMode() async {
    final next = (state.playMode + 1) % 3;
    state = state.copyWith(playMode: next);
    _shuffleHistory.clear();
    _shuffleFuture.clear();
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
    if (_shuffleFuture.isNotEmpty) {
      final path = _shuffleFuture.removeLast();
      final i = state.queue.indexWhere((q) => q.path == path);
      if (i >= 0) return i;
    }
    if (state.current != null) {
      _shuffleHistory.add(state.current!.path);
      if (_shuffleHistory.length > 256) _shuffleHistory.removeAt(0);
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
    return _randomDistinctIndex();
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
