import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../player/player_provider.dart';
import '../rust/api.dart';
import '../i18n/i18n.dart';

/// 在线音源定义。
class OnlineSource {
  final String id;
  final String label;
  const OnlineSource(this.id, this.label);
}

/// 支持的在线音源。顺序即 UI 上的展示顺序。
List<OnlineSource> get kOnlineSources => <OnlineSource>[
  OnlineSource('kw', tr('酷我')),
  OnlineSource('wy', tr('网易云')),
  OnlineSource('kg', tr('酷狗')),
  OnlineSource('tx', tr('QQ音乐')),
  OnlineSource('mg', tr('咪咕')),
];

/// 在线搜索结果条目。
///
/// 字段对应 Rust 侧 `LxSearchItem`，仅保留 UI 与播放所需部分。
class OnlineTrack {
  final String title;
  final String artist;
  final String album;
  final String songmid;
  final String source;

  /// 形如 `04:29` 的时长文本；缺失时为空串。
  final String interval;

  /// 封面 URL；部分音源不返回。
  final String? coverUrl;

  /// 解析直链所需的完整原始信息。
  final Map<String, dynamic> raw;

  const OnlineTrack({
    required this.title,
    required this.artist,
    required this.album,
    required this.songmid,
    required this.source,
    required this.interval,
    required this.raw,
    this.coverUrl,
  });

  factory OnlineTrack.fromJson(Map<String, dynamic> j) {
    return OnlineTrack(
      title: (j['name'] as String?) ?? '',
      artist: (j['singer'] as String?) ?? '',
      album: (j['album_name'] as String?) ?? '',
      songmid: (j['songmid'] as String?) ?? '',
      source: (j['source'] as String?) ?? '',
      interval: (j['interval'] as String?) ?? '',
      coverUrl: j['img'] as String?,
      raw: j,
    );
  }

  /// 时长秒数；无法解析时为 0。
  int get durationSeconds {
    final parts = interval.split(':');
    if (parts.length != 2) return 0;
    final m = int.tryParse(parts[0]) ?? 0;
    final s = int.tryParse(parts[1]) ?? 0;
    return m * 60 + s;
  }

  /// 构造播放队列项。
  ///
  /// `path` 使用 `lx://` 伪协议以便与本地文件路径区分。
  QueueItem toQueueItem() {
    final String intervalStr = interval.isNotEmpty
        ? interval
        : '${durationSeconds ~/ 60}:${(durationSeconds % 60).toString().padLeft(2, '0')}';
    final int intervalMs = durationSeconds * 1000;

    // 容错提取各类音源的关键 ID 字段（匹配 Rust LyricSongInfo 反序列化）
    final dynamic songId =
        raw['song_id'] ?? raw['songId'] ?? raw['id'] ?? songmid;
    final dynamic hash = raw['hash'] ??
        raw['FileHash'] ??
        raw['hash_flac'] ??
        raw['hash_high'] ??
        (source == 'kg' ? songmid : null);
    final dynamic copyrightId = raw['copyright_id'] ?? raw['copyrightId'];
    final dynamic strMediaMid =
        raw['str_media_mid'] ?? raw['strMediaMid'] ?? raw['media_mid'];
    final dynamic albumMid = raw['album_mid'] ?? raw['albumMid'];
    final dynamic albumId = raw['album_id'] ?? raw['albumId'];

    return QueueItem(
      path: 'lx://$source/$songmid',
      title: title,
      artist: artist,
      album: album,
      durationMs: intervalMs,
      coverUrl: coverUrl,
      source: source,
      // Rust 侧 LyricSongInfo 按 camelCase 反序列化，类型要求 strict。
      onlineInfoJson: jsonEncode({
        'songmid': songmid.toString(),
        'source': source,
        'hash': hash?.toString(),
        'name': title,
        'singer': artist,
        'albumName': album,
        'interval': intervalStr, // String 类型，完全匹配 Rust 要求
        '_interval': intervalMs, // u32 毫秒数，匹配 Rust _interval 要求
        'albumId': albumId,
        'albumMid': albumMid?.toString(),
        'copyrightId': copyrightId?.toString(),
        'strMediaMid': strMediaMid?.toString(),
        'songId': songId,
        '_types': raw['lx_types'] ?? raw['_types'],
      }),
    );
  }
}

/// 在线搜索状态。
class OnlineSearchState {
  final String keyword;
  final String source;
  final List<OnlineTrack> results;
  final bool loading;
  final String? error;

  const OnlineSearchState({
    this.keyword = '',
    this.source = 'kw',
    this.results = const [],
    this.loading = false,
    this.error,
  });

  OnlineSearchState copyWith({
    String? keyword,
    String? source,
    List<OnlineTrack>? results,
    bool? loading,
    Object? error = _noChange,
  }) {
    return OnlineSearchState(
      keyword: keyword ?? this.keyword,
      source: source ?? this.source,
      results: results ?? this.results,
      loading: loading ?? this.loading,
      error: error == _noChange ? this.error : error as String?,
    );
  }
}

const Object _noChange = Object();

class OnlineSearchNotifier extends StateNotifier<OnlineSearchState> {
  OnlineSearchNotifier(this._ref) : super(const OnlineSearchState());

  final Ref _ref;

  /// 递增令牌：只接受最新一次查询结果，避免慢响应覆盖新结果。
  int _token = 0;

  /// 切换音源。已有关键词时立即重新搜索。
  Future<void> setSource(String source) async {
    if (source == state.source) return;
    state = state.copyWith(source: source);
    if (state.keyword.isNotEmpty) {
      await search(state.keyword);
    }
  }

  Future<void> search(String keyword) async {
    final q = keyword.trim();
    if (q.isEmpty) {
      _token++;
      state = state.copyWith(
        keyword: '',
        results: const [],
        loading: false,
        error: null,
      );
      return;
    }

    final token = ++_token;
    state = state.copyWith(keyword: q, loading: true, error: null);

    try {
      final json = await lxSearch(
        source: state.source,
        keyword: q,
        limit: 30,
      );
      if (!mounted || token != _token) return;
      final list = (jsonDecode(json) as List)
          .map((e) => OnlineTrack.fromJson(e as Map<String, dynamic>))
          .toList();
      state = state.copyWith(results: list, loading: false);
    } catch (e) {
      if (!mounted || token != _token) return;
      state = state.copyWith(
        results: const [],
        loading: false,
        error: tr('搜索失败，请检查网络或换个音源'),
      );
    }
  }

  void clear() {
    _token++;
    state = const OnlineSearchState();
  }

  /// 播放搜索结果，从指定索引开始，整个结果列表入队。
  Future<void> play(int index) async {
    final items = state.results.map((t) => t.toQueueItem()).toList();
    if (items.isEmpty) return;
    await _ref
        .read(playerProvider.notifier)
        .playQueue(items, startIndex: index);
  }
}

final onlineSearchProvider =
    StateNotifierProvider<OnlineSearchNotifier, OnlineSearchState>((ref) {
  return OnlineSearchNotifier(ref);
});
