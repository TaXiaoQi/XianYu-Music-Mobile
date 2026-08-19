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

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
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
    setState(() {
      _loading = true;
      _searched = true;
    });
    try {
      final dbPath = await ref.read(dbPathProvider.future);
      final json = await searchLibrarySongs(dbPath: dbPath, query: q, limit: BigInt.from(100));
      final list = (jsonDecode(json) as List)
          .map((e) => Song.fromJson(e as Map<String, dynamic>))
          .toList();
      if (!mounted) return;
      setState(() => _results = list);
    } catch (_) {
      if (!mounted) return;
      setState(() => _results = const []);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
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
                      setState(() {
                        _results = const [];
                        _searched = false;
                      });
                    },
                  ),
          ),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : !_searched
              ? Center(
                  child: Text(
                    '输入关键词搜索本地音乐',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                )
              : _results.isEmpty
                  ? const Center(child: Text('没有匹配的歌曲'))
                  : SongsListView(
                      songs: _results,
                      onPlay: (list, i) =>
                          ref.read(libraryProvider.notifier).playList(list, i),
                    ),
    );
  }
}
