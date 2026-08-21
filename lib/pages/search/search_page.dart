import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/auth/account_api.dart';
import '../../src/core/db_path.dart';
import '../../src/library/library_provider.dart';
import '../../src/plugin/plugin_models.dart';
import '../../src/plugin/plugin_provider.dart';
import '../../src/plugin/plugin_search.dart';
import '../../src/player/player_provider.dart';
import '../../src/rust/api.dart';
import '../../src/widgets/song_list_view.dart';

/// 搜索页：本地曲库搜索 + 插件在线搜索。
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
  bool _online = false;

  // 插件在线搜索结果（按插件分组）。
  List<(PluginSource, List<PluginSearchResult>)> _onlineResults = const [];

  // 输入统计：1.5s 无新输入后批量上报新增字符数。
  int _pendingCharCount = 0;
  int _lastQueryLength = 0;
  Timer? _inputFlushTimer;

  @override
  void dispose() {
    _inputFlushTimer?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    final len = value.length;
    final delta = len - _lastQueryLength;
    _lastQueryLength = len;
    if (delta > 0) {
      _pendingCharCount += delta;
      _inputFlushTimer?.cancel();
      _inputFlushTimer = Timer(const Duration(milliseconds: 1500), () {
        final count = _pendingCharCount;
        _pendingCharCount = 0;
        if (count > 0) {
          ref.read(accountApiProvider).reportInputStats(count);
        }
      });
    }
  }

  Future<void> _search(String keyword) async {
    final q = keyword.trim();
    if (q.isEmpty) {
      setState(() {
        _results = const [];
        _onlineResults = const [];
        _searched = false;
      });
      return;
    }
    setState(() {
      _loading = true;
      _searched = true;
    });
    try {
      if (_online) {
        await _searchOnline(q);
        ref.read(accountApiProvider).reportSearch(q, 'online', _onlineResults.length);
      } else {
        final dbPath = await ref.read(dbPathProvider.future);
        final json = await searchLibrarySongs(dbPath: dbPath, query: q, limit: BigInt.from(100));
        final list = (jsonDecode(json) as List)
            .map((e) => Song.fromJson(e as Map<String, dynamic>))
            .toList();
        if (!mounted) return;
        setState(() => _results = list);
        ref.read(accountApiProvider).reportSearch(q, 'local', list.length);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _results = const [];
        _onlineResults = const [];
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _searchOnline(String q) async {
    final pluginState = ref.read(pluginManagerProvider);
    if (pluginState.sources.isEmpty) {
      if (!mounted) return;
      setState(() => _onlineResults = const []);
      return;
    }
    final engine = await ref.read(pluginEngineProvider.future);
    final service = PluginSearchService(engine, pluginState.sources);
    final results = await service.searchAll(q);
    if (!mounted) return;
    setState(() => _onlineResults = results);
  }

  void _playOnlineResult(PluginSource source, PluginSearchResult r) {
    final engine = ref.read(pluginEngineProvider).valueOrNull;
    if (engine == null) return;
    final service = PluginSearchService(engine, ref.read(pluginManagerProvider).sources);
    final item = service.toQueueItem(source, r);
    ref.read(playerProvider.notifier).playQueue([item], startIndex: 0);
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
          onChanged: _onQueryChanged,
          onSubmitted: _search,
          decoration: InputDecoration(
            hintText: _online ? '搜索在线歌曲（插件）' : '搜索歌曲、歌手、专辑',
            border: InputBorder.none,
            suffixIcon: _ctrl.text.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.clear, size: 20),
                    onPressed: () {
                      _ctrl.clear();
                      setState(() {
                        _results = const [];
                        _onlineResults = const [];
                        _searched = false;
                      });
                    },
                  ),
          ),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(40),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                _modeChip('本地', !_online, () {
                  setState(() => _online = false);
                }),
                const SizedBox(width: 8),
                _modeChip('在线', _online, () {
                  setState(() => _online = true);
                }),
              ],
            ),
          ),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : !_searched
              ? Center(
                  child: Text(
                    _online ? '输入关键词搜索在线歌曲' : '输入关键词搜索本地音乐',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                )
              : _online
                  ? _buildOnlineResults(scheme)
                  : _results.isEmpty
                      ? const Center(child: Text('没有匹配的歌曲'))
                      : SongsListView(
                          songs: _results,
                          onPlay: (list, i) =>
                              ref.read(libraryProvider.notifier).playList(list, i),
                        ),
    );
  }

  Widget _modeChip(String label, bool selected, VoidCallback onTap) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? scheme.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: selected ? scheme.onPrimary : scheme.onSurfaceVariant,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  Widget _buildOnlineResults(ColorScheme scheme) {
    if (_onlineResults.isEmpty) {
      return Center(
        child: Text(
          '没有匹配的在线歌曲',
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.only(bottom: 150),
      children: [
        for (final (source, items) in _onlineResults) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                Icon(Icons.music_note, size: 16, color: scheme.primary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    source.name,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  '${items.length} 首',
                  style: TextStyle(fontSize: 12, color: scheme.outline),
                ),
              ],
            ),
          ),
          for (final r in items) _OnlineResultTile(
            result: r,
            onTap: () => _playOnlineResult(source, r),
          ),
        ],
      ],
    );
  }
}

class _OnlineResultTile extends StatelessWidget {
  const _OnlineResultTile({required this.result, required this.onTap});
  final PluginSearchResult result;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      dense: true,
      leading: result.img != null && result.img!.isNotEmpty
          ? ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.network(
                result.img!,
                width: 44,
                height: 44,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => _placeholder(scheme),
              ),
            )
          : _placeholder(scheme),
      title: Text(result.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${result.singer} · ${result.albumName}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
      ),
      trailing: Text(
        result.interval,
        style: TextStyle(fontSize: 12, color: scheme.outline),
      ),
      onTap: onTap,
    );
  }

  Widget _placeholder(ColorScheme scheme) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Icon(Icons.music_note, color: scheme.outline, size: 20),
    );
  }
}
