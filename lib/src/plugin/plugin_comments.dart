import 'dart:convert';

import 'platform_comments.dart';
import 'plugin_engine.dart';
import 'plugin_models.dart';

class CommentItem {
  final String id;
  final String nickName;
  final String? avatar;
  final String comment;
  final int? like;
  final int? createAt;
  final String? location;
  final List<CommentItem> replies;

  const CommentItem({
    required this.id,
    required this.nickName,
    this.avatar,
    required this.comment,
    this.like,
    this.createAt,
    this.location,
    this.replies = const [],
  });

  static CommentItem normalize(dynamic raw) {
    if (raw is! Map) {
      return const CommentItem(id: '', nickName: '', comment: '');
    }
    final m = raw.cast<String, dynamic>();
    int? like;
    final likeRaw = m['like'] ?? m['likeCount'] ?? m['likes'] ?? m['like_count'];
    if (likeRaw is num) like = likeRaw.toInt();
    int? createAt;
    final timeRaw =
        m['createAt'] ?? m['createdAt'] ?? m['timestamp'] ?? m['time'];
    if (timeRaw is num) createAt = timeRaw.toInt();

    List<CommentItem> replies = const [];
    for (final field in [
      'replies',
      'replyList',
      'subComments',
      'children',
      'replys',
      'sub_comment',
      'reply_list',
    ]) {
      final v = m[field];
      if (v is List && v.isNotEmpty) {
        replies = v.map(CommentItem.normalize).toList();
        break;
      }
    }

    return CommentItem(
      id: (m['id'] ?? m['commentId'] ?? m['comment_id'] ?? '').toString(),
      nickName: ((m['nickName'] ?? m['nickname'] ?? m['userName'] ?? m['name'])
              as String?) ??
          '',
      avatar: (m['avatar'] ?? m['userAvatar'] ?? m['headPic']) as String?,
      comment: ((m['comment'] ?? m['content'] ?? m['text']) as String?) ?? '',
      like: like,
      createAt: createAt,
      location: (m['location'] ?? m['address']) as String?,
      replies: replies,
    );
  }
}

class CommentPage {
  final List<CommentItem> items;
  final bool isEnd;
  const CommentPage({required this.items, required this.isEnd});
}

class PluginCommentService {
  final PluginEngine engine;
  final List<PluginSource> sources;

  PluginCommentService(this.engine, this.sources);

  Future<PluginSource?> resolveSource(String pluginId) async {
    final matches = sources.where((s) => s.id == pluginId).toList();
    if (matches.isEmpty) return null;
    final source = matches.first;
    if (!source.enabled) return null;
    await engine.ensureLoaded(source);
    return source;
  }

  Future<CommentPage?> fetchComments(
    PluginSource source,
    Map<String, dynamic> musicItem,
    int page,
  ) async {
    final normalized = _normalizeMusicItem(source, musicItem);
    if (source.format.isMfCompatible) {
      try {
        final result = await engine.call(
          source.id,
          'getMusicComments',
          [normalized, page],
          timeoutMs: 15000,
        );
        final parsed = _parseResult(result);
        if (parsed.items.isNotEmpty || parsed.isEnd) return parsed;
      } on PluginEngineException catch (e) {
        final msg = e.message;
        if (!RegExp(r'getMusicComments|not\s+a\s+function|undefined',
                caseSensitive: false)
            .hasMatch(msg)) {
          rethrow;
        }
        return _fallback(source, normalized, page);
      } catch (_) {
        return _fallback(source, normalized, page);
      }
    }
    return _fallback(source, normalized, page);
  }

  Map<String, dynamic> _normalizeMusicItem(
    PluginSource source,
    Map<String, dynamic> songInfo,
  ) {
    final raw = songInfo['rawData'];
    final musicItem = raw is Map<String, dynamic>
        ? Map<String, dynamic>.from(raw)
        : Map<String, dynamic>.from(songInfo);
    if (musicItem['platform'] == null) {
      musicItem['platform'] = source.name;
    }
    if (!musicItem.containsKey('title') && songInfo.containsKey('name')) {
      musicItem['title'] = songInfo['name'];
    }
    if (!musicItem.containsKey('artist') && songInfo.containsKey('singer')) {
      musicItem['artist'] = songInfo['singer'];
    }
    if (!musicItem.containsKey('id') &&
        ((musicItem['id'] as dynamic)?.toString() ?? '').isEmpty &&
        songInfo.containsKey('songmid')) {
      musicItem['id'] = songInfo['songmid'];
    }
    if (!musicItem.containsKey('songmid') && songInfo.containsKey('songmid')) {
      musicItem['songmid'] = songInfo['songmid'];
    }
    return musicItem;
  }

  Future<CommentPage?> _fallback(
    PluginSource source,
    Map<String, dynamic> musicItem,
    int page,
  ) async {
    final platform =
        detectCommentPlatform(pluginName: source.name, musicInfo: musicItem);
    if (platform == null) return null;
    return fetchPlatformComments(
      platform: platform,
      musicInfo: musicItem,
      page: page,
    );
  }

  CommentPage _parseResult(dynamic result) {
    if (result is List) {
      final items = result.map(CommentItem.normalize).toList();
      return CommentPage(items: items, isEnd: items.isEmpty);
    }
    if (result is Map) {
      final m = result.cast<String, dynamic>();
      final raw = m['data'];
      final items =
          raw is List ? raw.map(CommentItem.normalize).toList() : <CommentItem>[];
      final isEnd = m['isEnd'] is bool
          ? m['isEnd'] as bool
          : (m['more'] is bool ? !(m['more'] as bool) : items.isEmpty);
      return CommentPage(items: items, isEnd: isEnd);
    }
    return const CommentPage(items: [], isEnd: true);
  }
}

class CommentContext {
  final String pluginId;
  final PluginFormat format;
  final Map<String, dynamic> musicItem;
  const CommentContext({
    required this.pluginId,
    required this.format,
    required this.musicItem,
  });

  static CommentContext? fromSongJson(String? onlineSongJson) {
    if (onlineSongJson == null || onlineSongJson.isEmpty) return null;
    try {
      final j = jsonDecode(onlineSongJson) as Map<String, dynamic>;
      final pluginId = j['pluginId'] as String?;
      if (pluginId == null || pluginId.isEmpty) return null;
      final musicInfo = j['musicInfo'];
      if (musicInfo is! Map) return null;
      final formatRaw = j['format'];
      final format = isMfFormatValue(formatRaw is String ? formatRaw : null)
          ? PluginFormat.musicfree
          : PluginFormat.lx;
      return CommentContext(
        pluginId: pluginId,
        format: format,
        musicItem: musicInfo.cast<String, dynamic>(),
      );
    } catch (_) {
      return null;
    }
  }
}
