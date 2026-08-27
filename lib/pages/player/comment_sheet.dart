import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/core/app_colors.dart';
import '../../src/plugin/plugin_comments.dart';
import '../../src/plugin/plugin_engine.dart';
import '../../src/plugin/plugin_provider.dart';
import '../../src/i18n/i18n.dart';

/// 歌曲评论弹层：分页加载 + 点赞/最新排序 + 二级评论展开。
class CommentSheet extends ConsumerStatefulWidget {
  const CommentSheet({super.key, required this.songJson});

  /// 播放队列项的 onlineSongJson（含 pluginId/musicInfo）。
  final String? songJson;

  @override
  ConsumerState<CommentSheet> createState() => _CommentSheetState();
}

class _CommentSheetState extends ConsumerState<CommentSheet> {
  List<CommentItem> _comments = [];
  int _page = 1;
  bool _isEnd = false;
  bool _loading = false;
  bool _loadingMore = false;
  String? _error;
  bool _unsupported = false;
  int _sortMode = 0; // 0 最多赞 1 最新
  final Set<String> _expandedReplies = {};
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _fetch(1);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scroll.position.pixels >=
            _scroll.position.maxScrollExtent - 200 &&
        !_loading &&
        !_loadingMore &&
        !_isEnd &&
        _comments.isNotEmpty) {
      _fetch(_page + 1);
    }
  }

  Future<void> _fetch(int page) async {
    final ctx = CommentContext.fromSongJson(widget.songJson);
    if (ctx == null) {
      setState(() => _unsupported = true);
      return;
    }
    setState(() {
      if (page == 1) {
        _loading = true;
        _error = null;
        _unsupported = false;
      } else {
        _loadingMore = true;
      }
    });
    try {
      final engine = await ref.read(pluginEngineProvider.future);
      final sources = await engine.store.loadSources();
      final service = PluginCommentService(engine, sources);
      final source = await service.resolveSource(ctx.pluginId);
      if (source == null) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _loadingMore = false;
          _unsupported = true;
          _isEnd = true;
        });
        return;
      }
      final result = await service.fetchComments(source, ctx.musicItem, page);
      if (result == null) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _loadingMore = false;
          _unsupported = true;
          _isEnd = true;
        });
        return;
      }
      if (!mounted) return;
      setState(() {
        if (page == 1) {
          _comments = result.items;
          _expandedReplies.clear();
        } else {
          // 按内容去重，个别插件每页重复返回
          final seen = _comments
              .map((c) => '${c.id}|${c.nickName}|${c.comment}')
              .toSet();
          for (final c in result.items) {
            final key = '${c.id}|${c.nickName}|${c.comment}';
            if (!seen.contains(key)) {
              _comments.add(c);
              seen.add(key);
            }
          }
        }
        _page = page;
        _isEnd = result.isEnd || result.items.isEmpty;
        _loading = false;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        if (page == 1) {
          _error = _friendlyError(e);
        }
        _isEnd = page > 1;
      });
    }
  }

  String _friendlyError(Object e) {
    final msg = e is PluginEngineException ? e.message : e.toString();
    if (RegExp(r'getMusicComments', caseSensitive: false).hasMatch(msg) ||
        RegExp(r'not\s+a\s+function|undefined', caseSensitive: false)
            .hasMatch(msg)) {
      return '';
    }
    return msg.replaceFirst(RegExp(r'^PluginEngineException: '), '');
  }

  List<CommentItem> get _sorted {
    final list = [..._comments];
    if (_sortMode == 0) {
      list.sort((a, b) => (b.like ?? 0).compareTo(a.like ?? 0));
    } else {
      list.sort((a, b) => (b.createAt ?? 0).compareTo(a.createAt ?? 0));
    }
    return list;
  }

  String _fmtTime(int? ts) {
    if (ts == null || ts <= 0) return '';
    // 秒级时间戳转毫秒
    final ms = ts < 100000000000 ? ts * 1000 : ts;
    final diff = DateTime.now().millisecondsSinceEpoch - ms;
    if (diff < 60000) return tr('刚刚');
    if (diff < 3600000) return tr('{n}分钟前', {'n': diff ~/ 60000});
    if (diff < 86400000) return tr('{n}小时前', {'n': diff ~/ 3600000});
    if (diff < 2592000000) return tr('{n}天前', {'n': diff ~/ 86400000});
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  String _fmtLike(int? n) {
    if (n == null || n <= 0) return '';
    if (n >= 10000) return tr('{n}万', {'n': (n / 10000).toStringAsFixed(1)});
    return '$n';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final sorted = _sorted;

    return SafeArea(
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 标题 + 排序切换
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 4),
              child: Row(
                children: [
                  Text(tr('评论'),
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w700)),
                  if (_comments.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Text(tr('{n} 条', {'n': _comments.length}),
                        style: TextStyle(
                            fontSize: 12, color: scheme.onSurfaceVariant)),
                  ],
                  const Spacer(),
                  _buildSortToggle(scheme),
                  IconButton(
                    icon: Icon(Icons.close,
                        size: 20, color: scheme.onSurfaceVariant),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: scheme.outlineVariant.withValues(alpha: 0.4)),
            Expanded(child: _buildBody(scheme, sorted)),
          ],
        ),
      ),
    );
  }

  Widget _buildSortToggle(ColorScheme scheme) {
    final labels = [tr('最多赞'), tr('最新')];
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 2),
      decoration: BoxDecoration(
        color: appCardColor(context),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(labels.length, (i) {
          final selected = _sortMode == i;
          return GestureDetector(
            onTap: () => setState(() => _sortMode = i),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: selected ? scheme.primary : Colors.transparent,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                labels[i],
                style: TextStyle(
                  fontSize: 12,
                  color: selected ? Colors.white : scheme.onSurfaceVariant,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _buildBody(ColorScheme scheme, List<CommentItem> sorted) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_unsupported) {
      return _placeholder(
        scheme,
        icon: Icons.mode_comment_outlined,
        text: tr('当前音源不支持评论'),
      );
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: TextStyle(color: scheme.error)),
            const SizedBox(height: 12),
            FilledButton.tonal(
              onPressed: () => _fetch(1),
              child:   Text(tr('重试')),
            ),
          ],
        ),
      );
    }
    if (sorted.isEmpty) {
      return _placeholder(
        scheme,
        icon: Icons.mode_comment_outlined,
        text: tr('暂无评论'),
      );
    }
    return ListView.separated(
      controller: _scroll,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: sorted.length + 1,
      separatorBuilder: (_, _) => Divider(
        indent: 64,
        height: 1,
        color: scheme.outlineVariant.withValues(alpha: 0.3),
      ),
      itemBuilder: (context, i) {
        if (i == sorted.length) {
          if (_loadingMore) {
            return const Padding(
              padding: EdgeInsets.all(16),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
          }
          if (_isEnd) {
            return Padding(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: Text(tr('没有更多评论了'),
                    style: TextStyle(
                        fontSize: 12, color: scheme.onSurfaceVariant)),
              ),
            );
          }
          return const SizedBox.shrink();
        }
        return _CommentTile(
          item: sorted[i],
          expanded: _expandedReplies.contains('${sorted[i].id}_$i'),
          onToggleReply: () => setState(() {
            final key = '${sorted[i].id}_$i';
            if (!_expandedReplies.remove(key)) _expandedReplies.add(key);
          }),
          fmtTime: _fmtTime,
          fmtLike: _fmtLike,
        );
      },
    );
  }

  Widget _placeholder(ColorScheme scheme,
      {required IconData icon, required String text}) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 40, color: scheme.onSurfaceVariant),
          const SizedBox(height: 10),
          Text(text, style: TextStyle(color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

class _CommentTile extends StatelessWidget {
  const _CommentTile({
    required this.item,
    required this.expanded,
    required this.onToggleReply,
    required this.fmtTime,
    required this.fmtLike,
  });

  final CommentItem item;
  final bool expanded;
  final VoidCallback onToggleReply;
  final String Function(int?) fmtTime;
  final String Function(int?) fmtLike;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final time = fmtTime(item.createAt);
    final meta = [
      if (time.isNotEmpty) time,
      if (item.location != null && item.location!.isNotEmpty) item.location!,
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Avatar(url: item.avatar),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        item.nickName.isEmpty ? tr('匿名用户') : item.nickName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    if (fmtLike(item.like).isNotEmpty) ...[
                      const SizedBox(width: 8),
                      Icon(Icons.thumb_up_alt_outlined,
                          size: 13, color: scheme.onSurfaceVariant),
                      const SizedBox(width: 3),
                      Text(
                        fmtLike(item.like),
                        style: TextStyle(
                            fontSize: 11, color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ],
                ),
                if (meta.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      meta,
                      style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurfaceVariant.withValues(alpha: 0.7)),
                    ),
                  ),
                const SizedBox(height: 4),
                Text(
                  item.comment,
                  style: const TextStyle(fontSize: 14, height: 1.45),
                ),
                if (item.replies.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  GestureDetector(
                    onTap: onToggleReply,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          tr('{n} 条回复', {'n': item.replies.length}),
                          style: TextStyle(
                              fontSize: 12,
                              color: scheme.primary,
                              fontWeight: FontWeight.w600),
                        ),
                        Icon(
                          expanded
                              ? Icons.keyboard_arrow_up
                              : Icons.keyboard_arrow_down,
                          size: 16,
                          color: scheme.primary,
                        ),
                      ],
                    ),
                  ),
                  // 二级评论展开：AnimatedSize 平滑过渡
                  AnimatedSize(
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOutCubic,
                    alignment: Alignment.topCenter,
                    child: expanded
                        ? Container(
                            margin: const EdgeInsets.only(top: 8),
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: appCardColor(context),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Column(
                              children: [
                                for (final r in item.replies)
                                  Padding(
                                    padding:
                                        const EdgeInsets.symmetric(vertical: 5),
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        _Avatar(url: r.avatar, size: 24),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Row(
                                                children: [
                                                  Expanded(
                                                    child: Text(
                                                      r.nickName.isEmpty
                                                          ? tr('匿名用户')
                                                          : r.nickName,
                                                      maxLines: 1,
                                                      overflow: TextOverflow
                                                          .ellipsis,
                                                      style: TextStyle(
                                                        fontSize: 12,
                                                        fontWeight:
                                                            FontWeight.w600,
                                                        color: scheme
                                                            .onSurfaceVariant,
                                                      ),
                                                    ),
                                                  ),
                                                  if (fmtLike(r.like)
                                                      .isNotEmpty)
                                                    Text(
                                                      fmtLike(r.like),
                                                      style: TextStyle(
                                                          fontSize: 11,
                                                          color: scheme
                                                              .onSurfaceVariant),
                                                    ),
                                                ],
                                              ),
                                              if (fmtTime(r.createAt)
                                                  .isNotEmpty)
                                                Text(
                                                  fmtTime(r.createAt),
                                                  style: TextStyle(
                                                      fontSize: 10,
                                                      color: scheme
                                                          .onSurfaceVariant
                                                          .withValues(
                                                              alpha: 0.7)),
                                                ),
                                              const SizedBox(height: 2),
                                              Text(
                                                r.comment,
                                                style: const TextStyle(
                                                    fontSize: 13,
                                                    height: 1.4),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                          )
                        : const SizedBox(width: double.infinity),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.url, this.size = 36});

  final String? url;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (url == null || url!.isEmpty) {
      return CircleAvatar(
        radius: size / 2,
        backgroundColor: appCardColor(context),
        child: Icon(Icons.person, size: size * 0.55, color: scheme.onSurfaceVariant),
      );
    }
    return ClipOval(
      child: CachedNetworkImage(
        imageUrl: url!,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorWidget: (_, _, _) => CircleAvatar(
          radius: size / 2,
          backgroundColor: appCardColor(context),
          child: Icon(Icons.person,
              size: size * 0.55, color: scheme.onSurfaceVariant),
        ),
      ),
    );
  }
}
