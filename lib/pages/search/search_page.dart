import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../src/auth/account_api.dart';
import '../../src/core/db_path.dart';
import '../../src/download/download_provider.dart';
import '../../src/library/library_provider.dart';
import '../../src/navigation/shell.dart';
import '../../src/player/player_provider.dart';
import '../../src/plugin/plugin_catalog.dart';
import '../../src/plugin/plugin_models.dart';
import '../../src/plugin/plugin_provider.dart';
import '../../src/plugin/plugin_search.dart';
import '../../src/playlist/playlist_provider.dart';
import '../../src/playlist/playlist_store.dart';
import '../../src/rust/api.dart';
import '../../src/widgets/mini_player_bar.dart';
import '../../src/widgets/online_cover.dart';
import '../../src/widgets/song_list_view.dart';
import '../home/online_detail_page.dart';
import '../library/song_list_page.dart';

// ==================== 来源模型 ====================

enum _SourceType { local, musicfree, lx }

/// 单个可选搜索来源：插件音源（musicfree 单条 / lx 多平台拆分）或“本地”。
class _SourceItem {
  final String id;
  final String name;
  final _SourceType type;
  final PluginSource? plugin;
  final String? lxKey;

  const _SourceItem({
    required this.id,
    required this.name,
    required this.type,
    this.plugin,
    this.lxKey,
  });

  bool get isLocal => type == _SourceType.local;
}

/// LX 插件声明的合法音源 key 及展示名（与桌面端对齐）。
const _validLxSources = {'kw', 'kg', 'tx', 'wy', 'mg'};
const _lxSourceNames = <String, String>{
  'kw': '小蜗音乐',
  'kg': '小枸音乐',
  'tx': '小秋音乐',
  'wy': '小芸音乐',
  'mg': '小蜜音乐',
};

// ==================== 结果模型 ====================

/// 单曲结果：本地歌曲或插件歌曲。
class _TrackEntry {
  final bool isLocal;
  final Song? localSong;
  final PluginSource? pluginSource;
  final PluginSearchResult? pluginResult;

  const _TrackEntry({
    required this.isLocal,
    this.localSong,
    this.pluginSource,
    this.pluginResult,
  });
}

enum _CatalogKind { artist, album, playlist }

/// 歌手/专辑/歌单结果：本地条目、在线导航或 LX 派生直放。
class _CatalogItem {
  final String kind; // artist | album | playlist
  final String title;
  final String subtitle;
  final String? coverUrl;
  final String sourceTag;
  // 本地导航
  final ArtistInfo? localArtist;
  final AlbumInfo? localAlbum;
  final ImportedPlaylist? localPlaylist;
  // 在线插件（musicfree）导航到详情页
  final PluginSource? onlinePlugin;
  final Map<String, dynamic>? onlineRaw;
  // LX 派生：直接从派生歌曲列表播放
  final PluginSource? directSource;
  final List<PluginSearchResult> directSongs;

  _CatalogItem({
    required this.kind,
    required this.title,
    this.subtitle = '',
    this.coverUrl,
    required this.sourceTag,
    this.localArtist,
    this.localAlbum,
    this.localPlaylist,
    this.onlinePlugin,
    this.onlineRaw,
    this.directSource,
    List<PluginSearchResult>? directSongs,
  }) : directSongs = directSongs ?? [];

  bool get isLocalEntry =>
      localArtist != null || localAlbum != null || localPlaylist != null;
  bool get isDirectPlay => directSource != null && directSongs.isNotEmpty;
}

// ==================== 搜索页 ====================

/// 搜索页：合并后的单一在线搜索页。顶部 4 个内容 tab（单曲/歌手/专辑/歌单），
/// tab 下方为来源切换条；来源仅由插件音源构建，无插件时降级为“本地”索引音乐库。
class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage>
    with SingleTickerProviderStateMixin, HidesShellChrome {
  final TextEditingController _ctrl = TextEditingController();
  late final TabController _tab;
  String _activeQuery = '';

  List<_SourceItem> _sources = const [];
  String _selectedSourceId = '';

  Timer? _debounce;

  // 输入统计：1.5s 无新输入后批量上报新增字符数。
  int _pendingCharCount = 0;
  int _lastQueryLength = 0;
  Timer? _inputFlushTimer;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 4, vsync: this);
    ref.listenManual(pluginManagerProvider, (_, _) => _refreshSources());
    _refreshSources();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _inputFlushTimer?.cancel();
    _tab.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  _SourceItem get _selected {
    for (final s in _sources) {
      if (s.id == _selectedSourceId) return s;
    }
    return _sources.isNotEmpty
        ? _sources.first
        : const _SourceItem(
            id: 'local', name: '本地', type: _SourceType.local);
  }

  /// 从插件音源构建来源列表；无插件时返回“本地”。
  void _refreshSources() {
    final plugins = ref.read(pluginManagerProvider).sources;
    final enabled = plugins.where((p) => p.enabled).toList();
    final items = <_SourceItem>[];
    for (final p in enabled) {
      if (p.format == PluginFormat.musicfree) {
        items.add(_SourceItem(
            id: p.id, name: p.name, type: _SourceType.musicfree, plugin: p));
      } else if (p.format == PluginFormat.lx) {
        final lx = p.sources.where(_validLxSources.contains).toList();
        if (lx.isEmpty) continue;
        if (lx.length == 1) {
          items.add(_SourceItem(
              id: p.id,
              name: p.name,
              type: _SourceType.lx,
              plugin: p,
              lxKey: lx.first));
        } else {
          for (final key in lx) {
            items.add(_SourceItem(
                id: '${p.id}__$key',
                name: _lxSourceNames[key] ?? key,
                type: _SourceType.lx,
                plugin: p,
                lxKey: key));
          }
        }
      }
    }
    final result = items.isEmpty
        ? const [
            _SourceItem(id: 'local', name: '本地', type: _SourceType.local)
          ]
        : items;
    // 若不触发重建，列表不会更新；若当前选中项失效则落回第一项。
    if (!mounted) return;
    setState(() {
      _sources = result;
      if (result.every((s) => s.id != _selectedSourceId)) {
        _selectedSourceId = result.first.id;
      }
    });
  }

  void _onSourceSelected(String id) {
    if (id == _selectedSourceId) return;
    setState(() => _selectedSourceId = id);
    // 子 tab 通过 didUpdateWidget 感知来源变化并重搜（仅可见 tab）。
  }

  void _onChanged(String keyword) {
    setState(() {}); // 更新清除按钮显隐。

    // 输入统计上报（1.5s 无新输入后批量上报新增字符数）。
    final len = keyword.length;
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

    _debounce?.cancel();
    final q = keyword.trim();
    if (q.isEmpty) {
      _setActiveQuery('');
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 220), () {
      _setActiveQuery(q);
    });
  }

  void _setActiveQuery(String q) {
    if (!mounted) return;
    setState(() => _activeQuery = q);
  }

  void _clearInput() {
    _debounce?.cancel();
    _ctrl.clear();
    _setActiveQuery('');
  }

  Widget _buildSourceBar(ColorScheme scheme) {
    return Container(
      height: 48,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: ListView(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.symmetric(vertical: 6),
        children: [
          for (final s in _sources)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _SourceChip(
                label: s.name,
                selected: s.id == _selected.id,
                scheme: scheme,
                onTap: () => _onSourceSelected(s.id),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final player = ref.watch(playerProvider);
    final hasSong = player.current != null;
    final selected = _selected;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: TextField(
          controller: _ctrl,
          autofocus: true,
          textInputAction: TextInputAction.search,
          onChanged: _onChanged,
          onSubmitted: (q) {
            FocusScope.of(context).unfocus();
            _debounce?.cancel();
            _setActiveQuery(q.trim());
          },
          decoration: InputDecoration(
            hintText: '搜索音乐、歌手、专辑、歌单',
            border: InputBorder.none,
            suffixIcon: _ctrl.text.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.clear, size: 20),
                    onPressed: _clearInput,
                  ),
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.graphic_eq_outlined, size: 22),
            tooltip: '听歌识曲',
            onPressed: () => context.push('/recognize'),
          ),
        ],
        bottom: TabBar(
          controller: _tab,
          tabs: const [
            Tab(text: '单曲'),
            Tab(text: '歌手'),
            Tab(text: '专辑'),
            Tab(text: '歌单'),
          ],
        ),
      ),
      body: Stack(
        children: [
          Column(
            children: [
              _buildSourceBar(scheme),
              const Divider(height: 1),
              Expanded(
                child: TabBarView(
                  controller: _tab,
                  children: [
                    _TrackTab(
                      keyword: _activeQuery,
                      source: selected,
                      visible: _tab.index == 0,
                    ),
                    _CatalogTab(
                      kind: _CatalogKind.artist,
                      keyword: _activeQuery,
                      source: selected,
                      visible: _tab.index == 1,
                    ),
                    _CatalogTab(
                      kind: _CatalogKind.album,
                      keyword: _activeQuery,
                      source: selected,
                      visible: _tab.index == 2,
                    ),
                    _CatalogTab(
                      kind: _CatalogKind.playlist,
                      keyword: _activeQuery,
                      source: selected,
                      visible: _tab.index == 3,
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (hasSong)
            Positioned(
              left: 14,
              right: 14,
              bottom: MediaQuery.of(context).padding.bottom + 12,
              child: const MiniPlayerBar(),
            ),
        ],
      ),
    );
  }
}

// ==================== 来源切换条 ====================

class _SourceChip extends StatelessWidget {
  final String label;
  final bool selected;
  final ColorScheme scheme;
  final VoidCallback onTap;

  const _SourceChip({
    required this.label,
    required this.selected,
    required this.scheme,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: selected
                ? scheme.primary.withValues(alpha: 0.10)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              color: selected ? scheme.primary : scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

// ==================== 单曲 tab ====================

class _TrackTab extends ConsumerStatefulWidget {
  final String keyword;
  final _SourceItem source;
  final bool visible;

  const _TrackTab({
    required this.keyword,
    required this.source,
    required this.visible,
  });

  @override
  ConsumerState<_TrackTab> createState() => _TrackTabState();
}

class _TrackTabState extends ConsumerState<_TrackTab>
    with AutomaticKeepAliveClientMixin {
  List<_TrackEntry> _results = const [];
  bool _loading = false;
  String _searchedHash = '';

  @override
  bool get wantKeepAlive => true;

  @override
  void didUpdateWidget(covariant _TrackTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.visible) return;
    final q = widget.keyword.trim();
    final hash = '${widget.source.id}|$q';
    if (hash != _searchedHash) _search(q, hash);
  }

  List<PluginSource> _plugins() => ref.read(pluginManagerProvider).sources;

  Future<void> _search(String q, String hash) async {
    final src = widget.source;
    setState(() {
      _searchedHash = hash;
      _loading = q.isNotEmpty;
      if (q.isEmpty) _results = const [];
    });
    if (q.isEmpty) return;

    final List<_TrackEntry> out = [];
    try {
      if (src.isLocal) {
        final dbPath = await ref.read(dbPathProvider.future);
        final json = await searchLibrarySongs(
            dbPath: dbPath, query: q, limit: BigInt.from(100));
        final list = (jsonDecode(json) as List)
            .map((e) => Song.fromJson(e as Map<String, dynamic>))
            .toList();
        out.addAll(list.map((s) =>
            _TrackEntry(isLocal: true, localSong: s)));
        ref.read(accountApiProvider).reportSearch(q, 'local', list.length);
      } else {
        final engine = await ref.read(pluginEngineProvider.future);
        List<PluginSearchResult> items;
        if (src.type == _SourceType.musicfree) {
          final catalog = PluginCatalogService(engine, _plugins());
          items = await catalog.searchMusic(src.plugin!, q);
        } else {
          items = await engine.searchInPlugin(src.plugin!, src.lxKey!, q);
        }
        out.addAll(items.map((r) => _TrackEntry(
            isLocal: false, pluginSource: src.plugin, pluginResult: r)));
        ref.read(accountApiProvider).reportSearch(q, 'online', items.length);
      }
    } catch (_) {
      // 单次失败保持空结果，由 UI 展示提示。
    }
    if (!mounted) return;
    setState(() {
      _results = out;
      _loading = false;
    });
  }

  void _play(int index) {
    FocusScope.of(context).unfocus();
    final e = _results[index];
    if (e.isLocal) {
      ref.read(libraryProvider.notifier).playList([e.localSong!], 0);
      return;
    }
    final engine = ref.read(pluginEngineProvider).valueOrNull;
    if (engine == null) return;
    final service = PluginSearchService(engine, _plugins());
    final item = service.toQueueItem(e.pluginSource!, e.pluginResult!);
    ref.read(playerProvider.notifier).playQueue([item], startIndex: 0);
  }

  void _download(int index) {
    final e = _results[index];
    if (e.isLocal) return;
    final engine = ref.read(pluginEngineProvider).valueOrNull;
    if (engine == null) return;
    final service = PluginSearchService(engine, _plugins());
    final item = service.toQueueItem(e.pluginSource!, e.pluginResult!);
    ref.read(downloadProvider.notifier).download(item);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('开始下载：${item.title}')),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final scheme = Theme.of(context).colorScheme;
    final q = widget.keyword.trim();

    if (q.isEmpty) {
      return _emptyHint('输入关键词搜索音乐', scheme, source: widget.source.name);
    }
    if (_loading && _results.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_results.isEmpty) {
      return _emptyHint('没有找到相关歌曲', scheme, source: widget.source.name);
    }

    final bottomInset = MediaQuery.of(context).padding.bottom + 92;
    return ListView.separated(
      padding: EdgeInsets.only(bottom: bottomInset),
      itemCount: _results.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final e = _results[i];
        if (e.isLocal) {
          final s = e.localSong!;
          return ListTile(
            leading: SongCover(song: s),
            title: highlightedText(s.title, q, scheme.primary, maxLines: 1),
            subtitle: Text(
              [s.artist, s.album, '本地']
                  .where((x) => x.isNotEmpty)
                  .join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
            onTap: () => _play(i),
          );
        }
        final r = e.pluginResult!;
        return ListTile(
          dense: true,
          leading: r.img != null && r.img!.isNotEmpty
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Image.network(
                    r.img!,
                    width: 44,
                    height: 44,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) =>
                        _musicPlaceholder(scheme),
                  ),
                )
              : _musicPlaceholder(scheme),
          title: highlightedText(r.name, q, scheme.primary, maxLines: 1),
          subtitle: Text(
            [r.singer, r.albumName, widget.source.name]
                .where((x) => x.isNotEmpty)
                .join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: Icon(Icons.download_outlined,
                    size: 20, color: scheme.primary),
                tooltip: '下载',
                onPressed: () => _download(i),
              ),
              Text(
                r.interval,
                style: TextStyle(fontSize: 12, color: scheme.outline),
              ),
            ],
          ),
          onTap: () => _play(i),
        );
      },
    );
  }
}

// ==================== 歌手 / 专辑 / 歌单 tab ====================

class _CatalogTab extends ConsumerStatefulWidget {
  final _CatalogKind kind;
  final String keyword;
  final _SourceItem source;
  final bool visible;

  const _CatalogTab({
    required this.kind,
    required this.keyword,
    required this.source,
    required this.visible,
  });

  @override
  ConsumerState<_CatalogTab> createState() => _CatalogTabState();
}

class _CatalogTabState extends ConsumerState<_CatalogTab>
    with AutomaticKeepAliveClientMixin {
  List<_CatalogItem> _items = const [];
  bool _loading = false;
  String _searchedHash = '';

  @override
  bool get wantKeepAlive => true;

  String _kindName(_CatalogKind k) => switch (k) {
        _CatalogKind.artist => '歌手',
        _CatalogKind.album => '专辑',
        _CatalogKind.playlist => '歌单',
      };

  @override
  void didUpdateWidget(covariant _CatalogTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.visible) return;
    final q = widget.keyword.trim();
    final hash = '${widget.source.id}|$q';
    if (hash != _searchedHash) _search(q, hash);
  }

  List<PluginSource> _plugins() => ref.read(pluginManagerProvider).sources;

  Future<void> _search(String q, String hash) async {
    final src = widget.source;
    setState(() {
      _searchedHash = hash;
      _loading = q.isNotEmpty;
      if (q.isEmpty) _items = const [];
    });
    if (q.isEmpty) return;

    final List<_CatalogItem> out = [];
    try {
      if (src.isLocal) {
        out.addAll(_searchLocal(q));
      } else if (src.type == _SourceType.musicfree) {
        out.addAll(await _searchMusicFree(q));
      } else {
        // LX 平台：单曲内派生出歌手/专辑；歌单无目录搜索能力。
        if (widget.kind == _CatalogKind.playlist) {
          out.clear();
        } else {
          out.addAll(await _searchLxDerive(q));
        }
      }
    } catch (_) {
      // 单次失败保持空结果。
    }
    if (!mounted) return;
    setState(() {
      _items = out;
      _loading = false;
    });
  }

  /// 本地库索引：按当前类型过滤歌手/专辑/歌单。
  List<_CatalogItem> _searchLocal(String q) {
    final lower = q.toLowerCase();
    final tag = '本地';
    final out = <_CatalogItem>[];
    try {
      switch (widget.kind) {
        case _CatalogKind.artist:
          final artists = ref.read(libraryProvider).artists;
          for (final a in artists) {
            if (a.name.toLowerCase().contains(lower)) {
              out.add(_CatalogItem(
                kind: 'artist',
                title: a.name,
                subtitle: '${a.count} 首',
                sourceTag: tag,
                localArtist: a,
              ));
            }
          }
        case _CatalogKind.album:
          final albums = ref.read(libraryProvider).albums;
          for (final a in albums) {
            if (a.name.toLowerCase().contains(lower) ||
                a.artist.toLowerCase().contains(lower)) {
              out.add(_CatalogItem(
                kind: 'album',
                title: a.name,
                subtitle: '${a.artist} · ${a.count} 首',
                sourceTag: tag,
                localAlbum: a,
              ));
            }
          }
        case _CatalogKind.playlist:
          final playlists = ref.read(playlistManagerProvider).playlists;
          for (final p in playlists) {
            if (p.name.toLowerCase().contains(lower)) {
              out.add(_CatalogItem(
                kind: 'playlist',
                title: p.name,
                subtitle: '${p.songs.length} 首',
                sourceTag: tag,
                localPlaylist: p,
              ));
            }
          }
      }
    } catch (_) {}
    return out;
  }

  Future<List<_CatalogItem>> _searchMusicFree(String q) async {
    final engine = await ref.read(pluginEngineProvider.future);
    final source = widget.source;
    final catalog = PluginCatalogService(engine, _plugins());
    final out = <_CatalogItem>[];
    final tag = source.name;
    try {
      switch (widget.kind) {
        case _CatalogKind.artist:
          final list = await catalog.searchArtists(source.plugin!, q);
          for (final a in list) {
            out.add(_CatalogItem(
              kind: 'artist',
              title: a.name,
              coverUrl: a.avatarUrl,
              sourceTag: tag,
              onlinePlugin: source.plugin,
              onlineRaw: a.raw,
            ));
          }
        case _CatalogKind.album:
          final list = await catalog.searchAlbums(source.plugin!, q);
          for (final a in list) {
            out.add(_CatalogItem(
              kind: 'album',
              title: a.name,
              subtitle: a.artist,
              coverUrl: a.coverUrl,
              sourceTag: tag,
              onlinePlugin: source.plugin,
              onlineRaw: a.raw,
            ));
          }
        case _CatalogKind.playlist:
          final list = await catalog.searchSheets(source.plugin!, q);
          for (final s in list) {
            out.add(_CatalogItem(
              kind: 'playlist',
              title: s.title,
              subtitle: s.subtitle,
              coverUrl: s.coverUrl,
              sourceTag: tag,
              onlinePlugin: source.plugin,
              onlineRaw: s.raw,
            ));
          }
      }
    } catch (_) {}
    return out;
  }

  /// LX 平台：复用单曲搜索结果按歌手/专辑去重派生。
  Future<List<_CatalogItem>> _searchLxDerive(String q) async {
    final engine = await ref.read(pluginEngineProvider.future);
    final source = widget.source;
    final songs = await engine
        .searchInPlugin(source.plugin!, source.lxKey ?? '', q, limit: 60);
    final isArtist = widget.kind == _CatalogKind.artist;
    final map = <String, _CatalogItem>{};
    for (final s in songs) {
      final key = isArtist ? s.singer.trim() : s.albumName.trim();
      if (key.isEmpty) continue;
      final existing = map[key];
      if (existing != null) {
        existing.directSongs.add(s);
        continue;
      }
      map[key] = _CatalogItem(
        kind: isArtist ? 'artist' : 'album',
        title: key,
        subtitle: isArtist ? '' : s.singer,
        coverUrl: s.img,
        sourceTag: source.name,
        directSource: source.plugin,
        directSongs: [s],
      );
    }
    return map.values.toList();
  }

  void _open(_CatalogItem item) {
    FocusScope.of(context).unfocus();
    if (item.localArtist != null) {
      final a = item.localArtist!;
      Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute(
          builder: (_) => SongListPage(
            title: a.name,
            loader: () => ref.read(libraryProvider.notifier).songsByArtist(a.name),
          ),
        ),
      );
      return;
    }
    if (item.localAlbum != null) {
      final a = item.localAlbum!;
      Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute(
          builder: (_) => SongListPage(
            title: a.name,
            loader: () => ref.read(libraryProvider.notifier).songsByAlbum(a.key),
          ),
        ),
      );
      return;
    }
    if (item.localPlaylist != null) {
      ref
          .read(playlistManagerProvider.notifier)
          .play(item.localPlaylist!, 0);
      return;
    }
    final engine = ref.read(pluginEngineProvider).valueOrNull;
    if (engine == null) return;
    // LX 派生：直接播放其歌曲列表。
    if (item.isDirectPlay) {
      final service = PluginSearchService(engine, _plugins());
      final items = item.directSongs
          .map((s) => service.toQueueItem(item.directSource!, s))
          .toList();
      ref.read(playerProvider.notifier).playQueue(items, startIndex: 0);
      return;
    }
    // musicfree 在线条目：进入在线详情页。
    context.push(
      '/online-detail',
      extra: OnlineDetailArgs(
        type: switch (item.kind) {
          'artist' => OnlineDetailType.artist,
          'album' => OnlineDetailType.album,
          _ => OnlineDetailType.playlist,
        },
        pluginId: item.onlinePlugin?.id ?? '',
        title: item.title,
        subtitle: item.subtitle,
        coverUrl: item.coverUrl,
        raw: item.onlineRaw ?? const {},
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final scheme = Theme.of(context).colorScheme;
    final q = widget.keyword.trim();
    final name = _kindName(widget.kind);

    if (q.isEmpty) {
      return _emptyHint('输入关键词搜索$name', scheme, source: widget.source.name);
    }
    if (_loading && _items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_items.isEmpty) {
      return _emptyHint('没有找到相关$name', scheme, source: widget.source.name);
    }

    final bottomInset = MediaQuery.of(context).padding.bottom + 92;
    return ListView.separated(
      padding: EdgeInsets.only(bottom: bottomInset),
      itemCount: _items.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final item = _items[i];
        final isArtist = item.kind == 'artist';
        return ListTile(
          leading: _catalogLeading(item, isArtist, scheme),
          title: highlightedText(item.title, q, scheme.primary, maxLines: 1),
          subtitle: Text(
            [item.subtitle, item.sourceTag]
                .where((x) => x.isNotEmpty)
                .join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          trailing: Icon(Icons.chevron_right,
              color: scheme.outline, size: 22),
          onTap: () => _open(item),
        );
      },
    );
  }

  Widget _catalogLeading(_CatalogItem item, bool isArtist, ColorScheme scheme) {
    if (item.localArtist != null) {
      final name = item.localArtist!.name;
      return CircleAvatar(
        backgroundColor: scheme.primaryContainer,
        child: Text(
          name.isEmpty ? '?' : String.fromCharCode(name.runes.first),
          style: TextStyle(color: scheme.onPrimaryContainer),
        ),
      );
    }
    if (item.localAlbum != null) {
      return Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: scheme.tertiaryContainer,
          borderRadius: BorderRadius.circular(6),
        ),
        alignment: Alignment.center,
        child: const Icon(Icons.album, size: 20),
      );
    }
    if (item.localPlaylist != null) {
      return Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: scheme.secondaryContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        alignment: Alignment.center,
        child: const Icon(Icons.queue_music, size: 20),
      );
    }
    return OnlineCover(
      url: item.coverUrl,
      size: 46,
      radius: isArtist ? 23 : 8,
    );
  }
}

// ==================== 公共组件 ====================

Widget _emptyHint(String message, ColorScheme scheme,
    {required String source}) {
  return Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.search_off, size: 40, color: scheme.outline),
        const SizedBox(height: 12),
        Text(message, style: TextStyle(color: scheme.onSurfaceVariant)),
        const SizedBox(height: 4),
        Text(
          '结果来自 $source',
          style: TextStyle(fontSize: 12, color: scheme.outline),
        ),
      ],
    ),
  );
}

Widget _musicPlaceholder(ColorScheme scheme) {
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