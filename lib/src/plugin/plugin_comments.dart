import 'dart:convert';

import 'platform_comments.dart';
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

  /// 解析歌曲所属插件源（musicfree/lx 均可，只要求已启用）。
  Future<PluginSource?> resolveSource(String pluginId) async {
    final matches = sources.where((s) => s.id == pluginId).toList();
    if (matches.isEmpty) return null;
    final source = matches.first;
    if (!source.enabled) return null;
    await engine.ensureLoaded(source);
    return source;
  }

  /// 拉取一页评论。返回 null 表示当前歌曲无法取得评论（平台不支持或缺少 id），
  /// 调用方据此展示"不支持"。musicfree 优先走插件 getMusicComments；失败或
  /// LX（落雪）插件无此扩展时，按歌曲平台直连平台公开评论接口兜底。
  Future<CommentPage?> fetchComments(
    PluginSource source,
    Map<String, dynamic> musicItem,
    int page,
  ) async {
    // 对齐播放链路 getMusicFreeUrl / 桌面端 resetMediaItem：优先透传原始条目
    // rawData（含平台私有 id/songmid 字段），仅补充 platform 与常见字段别名。
    // 否则 baka 等插件的 getMusicComments 读不到 musicItem.id/songmid，评论
    // 接口拿不到歌曲 id 而返回空（表现为「暂无评论」）。
    final normalized = _normalizeMusicItem(source, musicItem);
    if (source.format == PluginFormat.musicfree) {
      try {
        final result = await engine.call(
          source.id,
          'getMusicComments',
          [normalized, page],
          timeoutMs: 15000,
        );
        final parsed = _parseResult(result);
        // 插件明确返回（即便为空）即不再走兜底，避免重复消耗。
        if (parsed.items.isNotEmpty || parsed.isEnd) return parsed;
      } on PluginEngineException catch (e) {
        // 插件未声明 getMusicComments 或调用报错 → 落到平台直连。
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

  /// 规范化传给插件的 musicItem：优先透传 rawData（原始条目），仅补充
  /// platform 与 title/artist/id/songmid 字段别名（与 getMusicFreeUrl 同构）。
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

  /// 平台直连兜底：检测平台后拉取；不可识别或缺 id 时返回 null。
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
  final PluginFormat format;
  final Map<String, dynamic> musicItem;
  const CommentContext({
    required this.pluginId,
    required this.format,
    required this.musicItem,
  });

  /// 解析 onlineSongJson。musicfree 明确声明 format=musicfree；LX 歌曲构造时
  /// 可能未带 format 字段，通过存在 `source` 字段兜底推断为 lx。
  static CommentContext? fromSongJson(String? onlineSongJson) {
    if (onlineSongJson == null || onlineSongJson.isEmpty) return null;
    try {
      final j = jsonDecode(onlineSongJson) as Map<String, dynamic>;
      final pluginId = j['pluginId'] as String?;
      if (pluginId == null || pluginId.isEmpty) return null;
      final musicInfo = j['musicInfo'];
      if (musicInfo is! Map) return null;
      final formatRaw = j['format'];
      final format =
          formatRaw == 'musicfree' ? PluginFormat.musicfree : PluginFormat.lx;
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
