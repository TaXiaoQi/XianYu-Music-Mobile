import 'dart:convert';

import 'plugin_engine.dart';
import 'plugin_models.dart';

/// 评论条目（对齐桌面端 CommentPanel 的 normalizeComment 规范化）。
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

    // 兼容多种二级评论字段名（与桌面端一致）
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

/// 评论分页结果。
class CommentPage {
  final List<CommentItem> items;
  final bool isEnd;
  const CommentPage({required this.items, required this.isEnd});
}

/// 插件评论服务：MusicFree getMusicComments(musicItem, page)。
class PluginCommentService {
  final PluginEngine engine;
  final List<PluginSource> sources;

  PluginCommentService(this.engine, this.sources);

  /// 当前歌曲可评论的插件源（仅 MusicFree 且声明了 getMusicComments）。
  Future<PluginSource?> resolveSource(String pluginId) async {
    final matches = sources.where((s) => s.id == pluginId).toList();
    if (matches.isEmpty) return null;
    final source = matches.first;
    if (!source.enabled || source.format != PluginFormat.musicfree) return null;
    await engine.ensureLoaded(source);
    final meta = engine.metadataOf(source.id);
    final methods = meta?['_availableMethods'];
    if (methods is! List || !methods.contains('getMusicComments')) return null;
    return source;
  }

  /// 拉取一页评论。插件不支持时抛 [PluginEngineException] 由 UI 兜底。
  Future<CommentPage> fetchComments(
    PluginSource source,
    Map<String, dynamic> musicItem,
    int page,
  ) async {
    final result = await engine.call(
      source.id,
      'getMusicComments',
      [musicItem, page],
      timeoutMs: 15000,
    );
    if (result is List) {
      // 个别插件直接返回数组
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

/// 从播放队列项的 onlineSongJson 提取评论所需上下文。
class CommentContext {
  final String pluginId;
  final Map<String, dynamic> musicItem;
  const CommentContext({required this.pluginId, required this.musicItem});

  static CommentContext? fromSongJson(String? onlineSongJson) {
    if (onlineSongJson == null || onlineSongJson.isEmpty) return null;
    try {
      final j = jsonDecode(onlineSongJson) as Map<String, dynamic>;
      final pluginId = j['pluginId'] as String?;
      if (pluginId == null || pluginId.isEmpty) return null;
      if ((j['format'] as String?) != 'musicfree') return null;
      final musicInfo = j['musicInfo'];
      if (musicInfo is! Map) return null;
      return CommentContext(
        pluginId: pluginId,
        musicItem: musicInfo.cast<String, dynamic>(),
      );
    } catch (_) {
      return null;
    }
  }
}
