part of 'watch_link_provider.dart';

extension WatchLinkControllerTransport on WatchLinkController {
  void _send(LinkMessage msg, {bool cloud = false, bool low = false}) {
    final useCloud = cloud || (!_connected && _cloudWatchOnline);
    try {
      final q = low ? _txLowQueue : _txQueue;
      for (final frame in encodeFrames(msg, nextSeq: _nextSeq)) {
        q.add((frame, useCloud));
      }
      _drainTx();
    } catch (_) {
    }
  }

  Future<void> _drainTx() async {
    if (_txDraining) return;
    _txDraining = true;
    final gen = _txGen;
    try {
      while (gen == _txGen) {
        if (!_connected && !_cloudWatchOnline) {
          _txQueue.clear();
          _txLowQueue.clear();
          return;
        }
        final q = _txQueue.isNotEmpty ? _txQueue : _txLowQueue;
        if (q.isEmpty) return;
        final (frame, useCloud) = q.first;
        if (useCloud) {
          await _cloud.send(frame);
        } else {
          await _channel.send(frame).timeout(const Duration(seconds: 5));
        }
        q.removeAt(0);
      }
      if (gen != _txGen) {
        _txQueue.clear();
        _txLowQueue.clear();
      }
    } catch (_) {
      _txQueue.clear();
      _txLowQueue.clear();
    } finally {
      if (gen == _txGen) _txDraining = false;
    }
  }
}
