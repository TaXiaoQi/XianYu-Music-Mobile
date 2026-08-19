import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/core/db_path.dart';
import '../../src/library/library_provider.dart';
import '../../src/rust/api.dart';
import '../../src/widgets/song_list_view.dart';

/// 搜索页：本地曲库搜索。
class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final TextEditingController _ctrl = TextEditingController();
  List<Song> _results = const [];
  bool _loading = false;
  bool _searched = false;

  Timer? _debounce;
  /// 递增序号：只接受最新一次查询的结果，避免慢查询覆盖新结果。
  int _queryToken = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  /// 输入变化：防抖 220ms 后自动搜索，边打字边出结果。
  void _onChanged(String keyword) {
    // 立即刷新一次以更新清除按钮的显隐。
    setState(() {});
    _debounce?.cancel();
    final q = keyword.trim();
    if (q.isEmpty) {
      _queryToken++; // 作废在途请求
      setState(() {
        _results = const [];
        _searched = false;
        _loading = false;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 220), () => _search(q));
  }

  Future<void> _search(String keyword) async {
    final q = keyword.trim();
    if (q.isEmpty) {
      setState(() {
        _results = const [];
        _searched = false;
      });
      return;
    }
    final token = ++_queryToken;
    setState(() {
      _loading = true;
      _searched = true;
    });
    try {
      final dbPath = await ref.read(dbPathProvider.future);
      final json = await searchLibrarySongs(
          dbPath: dbPath, query: q, limit: BigInt.from(100));
      final list = (jsonDecode(json) as List)
          .map((e) => Song.fromJson(e as Map<String, dynamic>))
          .toList();
      // 已有更新的查询发出，丢弃这次结果。
      if (!mounted || token != _queryToken) return;
      setState(() {
        _results = list;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || token != _queryToken) return;
      setState(() {
        _results = const [];
        _loading = false;
      });
    }
  }

  Widget _buildBody(ColorScheme scheme) {
    if (!_searched) {
      return Center(
        child: Text(
          '输入关键词搜索本地音乐',
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
      );
    }
    // 有旧结果时不整页替换为转圈，避免边打字边闪烁；
    // 仅首次查询（无结果可展示）显示加载指示器。
    if (_loading && _results.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_results.isEmpty) {
      return const Center(child: Text('没有匹配的歌曲'));
    }
    return SongsListView(
      songs: _results,
      // 底部留出系统手势区高度，最后一项不贴边。
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).padding.bottom + 12,
      ),
      onPlay: (list, i) => ref.read(libraryProvider.notifier).playList(list, i),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _ctrl,
          autofocus: true,
          textInputAction: TextInputAction.search,
          onChanged: _onChanged,
          onSubmitted: _search,
          decoration: InputDecoration(
            hintText: '搜索歌曲、歌手、专辑',
            border: InputBorder.none,
            suffixIcon: _ctrl.text.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.clear, size: 20),
                    onPressed: () {
                      _ctrl.clear();
                      _debounce?.cancel();
                      _queryToken++; // 作废在途请求
                      setState(() {
                        _results = const [];
                        _searched = false;
                        _loading = false;
                      });
                    },
                  ),
          ),
        ),
      ),
      // 全屏路由，无底栏遮挡，结果列表铺满可用高度。
      body: _buildBody(scheme),
    );
  }
}
