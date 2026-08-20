import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../player/player_provider.dart';
import '../rust/api.dart';

/// 在线音源定义。
class OnlineSource {
  final String id;
  final String label;
  const OnlineSource(this.id, this.label);
}

/// 支持的在线音源。顺序即 UI 上的展示顺序。
const kOnlineSources = <OnlineSource>[
  OnlineSource('kw', '酷我'),
  OnlineSource('wy', '网易云'),
  OnlineSource('kg', '酷狗'),
  OnlineSource('tx', 'QQ音乐'),
  OnlineSource('mg', '咪咕'),
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
    return QueueItem(
      path: 'lx://$source/$songmid',
      title: title,
      artist: artist,
      album: album,
      durationMs: durationSeconds * 1000,
      coverUrl: coverUrl,
      source: source,
      // Rust 侧 LxUrlSongInfo 按 camelCase 反序列化，
      // 搜索结果的 snake_case 字段需要转换。
      onlineInfoJson: jsonEncode({
        'songmid': songmid,
        'source': source,
        'hash': raw['hash'],
        'name': title,
        'singer': artist,
        'albumName': album,
        'albumId': raw['album_id'],
        'albumMid': raw['album_mid'],
        'copyrightId': raw['copyright_id'],
        'strMediaMid': raw['str_media_mid'],
        'songId': raw['song_id'],
        '_types': raw['lx_types'],
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
        error: '搜索失败，请检查网络或换个音源',
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
