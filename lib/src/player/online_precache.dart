
import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/db_path.dart';
import '../lyrics/lyrics_repository.dart';
import '../online/cover_proxy.dart';
import 'audio_head_cache.dart';
import 'media_url.dart';
import 'online_quality_probe.dart';
import 'player_provider.dart';

const int _maxPrefetchSongs = 5;

const Duration _prefetchTtl = Duration(minutes: 10);

const Duration _perSongTimeout = Duration(seconds: 45);

int estimateHeadBytes(String quality) {
  switch (quality) {
    case 'mgg':
    case '128k':
      return 260_000;
    case '192k':
      return 380_000;
    case '320k':
      return 630_000;
    case 'flac':
      return 2_700_000;
    case 'flac24bit':
    case 'vinyl':
    case 'dolby':
    case 'atmos':
      return 3_300_000;
    case 'hires':
      return 4_600_000;
    case 'atmos_plus':
      return 4_400_000;
    case 'master':
      return 5_800_000;
    default:
      return 2_700_000;
  }
}

class OnlinePrecache {
  OnlinePrecache._();

  static final OnlinePrecache instance = OnlinePrecache._();

  final Map<String, DateTime> _recent = {};

  int _generation = 0;

  void schedule({
    required Ref ref,
    required PlayerNotifier notifier,
    required List<QueueItem> queue,
    required int queueIndex,
    required int playMode,
    required String? currentPath,
    required String preferred,
    required String fallback,
  }) {
    try {
      if (playMode == 1 || playMode == 2) return;
      if (currentPath == null || currentPath.isEmpty) return;
      if (queueIndex < 0 || queueIndex + 1 >= queue.length) return;

      final upcoming = queue
          .sublist(queueIndex + 1)
          .where((s) => s.isOnline)
          .take(_maxPrefetchSongs)
          .toList();
      if (upcoming.isEmpty) return;

      final gen = ++_generation;
      unawaited(_run(gen, ref, notifier, upcoming, preferred, fallback));
    } catch (_) {
    }
  }

  Future<void> _run(
    int gen,
    Ref ref,
    PlayerNotifier notifier,
    List<QueueItem> upcoming,
    String preferred,
    String fallback,
  ) async {
    final candidates = notifier.precacheCandidates(preferred, fallback);
    for (final item in upcoming) {
      if (gen != _generation) return;
      try {
        await _prefetchOne(gen, ref, notifier, item, candidates)
            .timeout(_perSongTimeout, onTimeout: () {});
      } catch (_) {
      }
    }
  }

  Future<void> _prefetchOne(
    int gen,
    Ref ref,
    PlayerNotifier notifier,
    QueueItem item,
    List<String> candidates,
  ) async {
    final json = item.onlineSongJson ?? item.onlineInfoJson;
    if (json == null || json.isEmpty) return;
    final Map<String, dynamic> songJson;
    try {
      songJson = jsonDecode(json) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final key = notifier.precacheProbeKey(songJson, item);

    final now = DateTime.now();
    _recent.removeWhere((_, t) => now.difference(t) > _prefetchTtl);
    if (_recent.containsKey(key)) return;
    _recent[key] = now;

    final probe = notifier.precacheProbeEnsure(songJson, item, key);
    QualityProbeResult? resolved;
    for (final q in candidates) {
      if (gen != _generation) return;
      try {
        final r = await probe.probe(q).timeout(
              const Duration(seconds: 12),
              onTimeout: () => null,
            );
        if (r != null && r.url.isNotEmpty) {
          resolved = r;
          break;
        }
      } catch (_) {}
    }
    if (resolved == null || resolved.url.isEmpty) return;

    try {
      await ref.read(lyricsRepositoryProvider).fetchLyrics(item).timeout(
            const Duration(seconds: 10),
            onTimeout: () => const [],
          );
    } catch (_) {}

    final cover = item.coverUrl;
    if (cover != null && cover.isNotEmpty && !cover.startsWith('file:')) {
      unawaited(CoverProxy.fetch(cover));
    }

    final headers = await withBilibiliStreamCookie(
      resolved.url,
      normalizeMediaRequestHeaders(resolved.url, resolved.headers),
      dataDir: ref.read(appDataDirProvider.future),
    );
    await AudioHeadCache.instance.prefetch(
      url: resolved.url,
      headers: headers,
      maxBytes: estimateHeadBytes(resolved.quality),
    );
  }
}
