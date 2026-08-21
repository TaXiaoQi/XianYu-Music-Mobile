import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/core/db_path.dart';
import '../../src/library/library_provider.dart';
import '../../src/online/online_search_provider.dart';
import '../../src/rust/api.dart';
import '../../src/widgets/online_cover.dart';
import '../../src/widgets/song_list_view.dart';

/// 搜索页：本地曲库搜索。
class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage>
    with SingleTickerProviderStateMixin {
  final TextEditingController _ctrl = TextEditingController();
  late final TabController _tab;
  List<Song> _results = const [];
  bool _loading = false;
  bool _searched = false;

  Timer? _debounce;
  /// 递增序号：只接受最新一次查询的结果，避免慢查询覆盖新结果。
  int _queryToken = 0;
  /// 当前结果对应的查询词，用于高亮。防抖期间仍指向旧词，
  /// 保证高亮与列表内容一致。
  String _activeQuery = '';

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
    // 切换 Tab 时同步提示文案，并按需触发另一侧的搜索。
    _tab.addListener(() {
      if (_tab.indexIsChanging) return;
      setState(() {});
      final q = _ctrl.text.trim();
      if (q.isEmpty) return;
      if (_tab.index == 1) {
        final online = ref.read(onlineSearchProvider);
        // 在线侧尚未搜过该词时补一次，避免空白。
        if (online.keyword != q) {
          ref.read(onlineSearchProvider.notifier).search(q);
        }
      }
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _tab.dispose();
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
      ref.read(onlineSearchProvider.notifier).clear();
      setState(() {
        _results = const [];
        _searched = false;
        _loading = false;
        _activeQuery = '';
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 220), () {
      // 本地搜索始终执行（切回本地 Tab 时结果已就绪）；
      // 在线搜索仅在当前处于在线 Tab 时触发，避免无谓的网络请求。
      _search(q);
      if (_tab.index == 1) {
        ref.read(onlineSearchProvider.notifier).search(q);
      }
    });
  }

  Future<void> _search(String keyword) async {
    final q = keyword.trim();
    if (q.isEmpty) {
      setState(() {
        _results = const [];
        _searched = false;
        _activeQuery = '';
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
        _activeQuery = q;
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
      // 高亮当前已生效的查询词（而非输入框实时文本），与结果保持一致。
      highlight: _activeQuery,
      onPlay: (list, i) {
        FocusScope.of(context).unfocus();
        return ref.read(libraryProvider.notifier).playList(list, i);
      },
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
          onSubmitted: (q) {
            FocusScope.of(context).unfocus();
            _search(q);
            if (_tab.index == 1) {
              ref.read(onlineSearchProvider.notifier).search(q);
            }
          },
          decoration: InputDecoration(
            hintText: _tab.index == 0 ? '搜索本地音乐' : '搜索在线音乐',
            border: InputBorder.none,
            suffixIcon: _ctrl.text.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.clear, size: 20),
                    onPressed: _clearInput,
                  ),
          ),
        ),
        bottom: TabBar(
          controller: _tab,
          tabs: const [
            Tab(text: '本地'),
            Tab(text: '在线'),
          ],
        ),
      ),
      // 全屏路由，无底栏遮挡，结果列表铺满可用高度。
      body: TabBarView(
        controller: _tab,
        children: [
          _buildBody(scheme),
          _OnlineSearchTab(highlight: _activeQuery),
        ],
      ),
    );
  }

  void _clearInput() {
    _ctrl.clear();
    _debounce?.cancel();
    _queryToken++; // 作废在途请求
    ref.read(onlineSearchProvider.notifier).clear();
    setState(() {
      _results = const [];
      _searched = false;
      _loading = false;
      _activeQuery = '';
    });
  }
}

/// 在线搜索结果页：音源切换 + 带封面时长的结果列表。
class _OnlineSearchTab extends ConsumerWidget {
  const _OnlineSearchTab({required this.highlight});

  final String highlight;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(onlineSearchProvider);
    final scheme = Theme.of(context).colorScheme;

    return Column(
      children: [
        // 音源切换条
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            children: [
              for (final s in kOnlineSources)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(s.label),
                    // 去掉默认的垂直内边距，使 chip 自然高度与横向列表
                    // 强制的 32px 一致，避免内部布局被压缩导致文字偏下。
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    selected: state.source == s.id,
                    onSelected: (_) =>
                        ref.read(onlineSearchProvider.notifier).setSource(s.id),
                  ),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(child: _buildResults(context, ref, state, scheme)),
      ],
    );
  }

  Widget _buildResults(
    BuildContext context,
    WidgetRef ref,
    OnlineSearchState state,
    ColorScheme scheme,
  ) {
    if (state.keyword.isEmpty) {
      return Center(
        child: Text(
          '输入关键词搜索在线音乐',
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
      );
    }
    // 有旧结果时不整页替换为转圈，避免切换音源时闪烁。
    if (state.loading && state.results.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(state.error!, textAlign: TextAlign.center),
        ),
      );
    }
    if (state.results.isEmpty) {
      return const Center(child: Text('该音源没有匹配结果'));
    }

    return ListView.separated(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).padding.bottom + 12,
      ),
      itemCount: state.results.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final t = state.results[i];
        return ListTile(
          leading: OnlineCover(url: t.coverUrl),
          title: highlightedText(t.title, highlight, scheme.primary,
              maxLines: 1),
          subtitle: highlightedText(
            t.album.isEmpty ? t.artist : '${t.artist} · ${t.album}',
            highlight,
            scheme.primary,
            maxLines: 1,
          ),
          trailing: Text(
            t.interval.isEmpty ? '--:--' : t.interval,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          onTap: () {
            FocusScope.of(context).unfocus();
            ref.read(onlineSearchProvider.notifier).play(i);
          },
        );
      },
    );
  }
}


