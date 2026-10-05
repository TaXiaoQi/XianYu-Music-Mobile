part of 'plugin_catalog.dart';

extension PluginCatalogServiceMethods on PluginCatalogService {
  List<PluginSource> get musicFreeSources =>
      sources.where((s) => s.enabled && s.format.isMfCompatible).toList();

  /// 已启用且覆盖榜单平台（wy/kg/kw/tx）的 LX 音源，
  /// 榜单能力由 lx_toplist 兜底模块保证，无需探测插件方法
  List<PluginSource> get lxToplistSources => sources
      .where((s) =>
          s.enabled &&
          s.format == PluginFormat.lx &&
          s.sources
              .toSet()
              .intersection(const {'wy', 'kg', 'kw', 'tx'})
              .isNotEmpty)
      .toList();

  Future<Set<String>> _availableMethods(PluginSource source) async {
    await engine.ensureLoaded(source);
    final meta = engine.metadataOf(source.id);
    final list = meta?['_availableMethods'];
    if (list is List) return list.map((e) => e.toString()).toSet();
    return const {};
  }

  Future<bool> supportsTopLists(PluginSource source) async {
    if (source.format == PluginFormat.lx) {
      return lxToplistSources.contains(source);
    }
    return (await _availableMethods(source)).contains('getTopLists');
  }

  // ==================== 基础调用 ====================

  Future<dynamic> _call(PluginSource source, String method,
      List<dynamic> args, {
        int timeoutMs = 30000,
      }) async {
    await engine.ensureLoaded(source);
    return engine.call(source.id, method, args, timeoutMs: timeoutMs);
  }

  // ==================== 榜单 ====================

  Future<List<MfSheetItem>> getTopLists(PluginSource source,
      {String? lxKey}) async {
    if (source.format == PluginFormat.lx) {
      return _getLxTopLists(source, lxKey: lxKey);
    }
    try {
      final result = await _call(source, 'getTopLists', []);
      if (result is! List) return const [];
      final items = <MfSheetItem>[];
      for (final category in result) {
        if (category is! Map) continue;
        final cat = category.cast<String, dynamic>();
        final data = cat['data'];
        if (data is List && data.isNotEmpty) {
          for (final e in data) {
            if (e is! Map) continue;
            final m = Map<String, dynamic>.from(e);
            m['_isTopList'] = true;
            items.add(_toSheet(m, source, categoryTitle: cat['title']));
          }
        } else {
          cat['_isTopList'] = true;
          items.add(_toSheet(cat, source));
        }
      }
      return items;
    } catch (_) {
      return const [];
    }
  }

  /// LX 音源榜单：走 lx_toplist 兜底模块（服务端下发 JS 优先、Rust builtin 兜底），
  /// 各平台分组扁平进单组。subtitle 取榜单 description（MfSheetItem.subtitle
  /// 首段为 artist，分组标题在榜单页无独立展示位，故不传 categoryTitle）。
  Future<List<MfSheetItem>> _getLxTopLists(PluginSource source,
      {String? lxKey}) async {
    final keys = source.sources
        .where((k) => const {'wy', 'kg', 'kw', 'tx'}.contains(k))
        .where((k) => lxKey == null || k == lxKey)
        .toList();
    final groups = await lxToplistBoardsFallback(keys);
    final items = <MfSheetItem>[];
    for (final category in groups) {
      if (category is! Map) continue;
      final cat = category.cast<String, dynamic>();
      final data = cat['data'];
      if (data is! List) continue;
      for (final e in data) {
        if (e is! Map) continue;
        final m = Map<String, dynamic>.from(e);
        m['_isTopList'] = true;
        // chip 即平台：条目缺 source（下发 JS 模块形状差异）时回退 chip 的 lxKey
        final src = (m['source'] ?? '').toString();
        m['_lxSource'] = src.isNotEmpty
            ? src
            : (lxKey ?? (keys.length == 1 ? keys.first : ''));
        final desc = (m['description'] ?? '').toString();
        if (desc.isNotEmpty) m['artist'] = desc;
        items.add(_toSheet(m, source));
      }
    }
    return items;
  }

  Future<List<PluginSearchResult>> getTopListDetail(
      PluginSource source, Map<String, dynamic> item, {int page = 1}) async {
    final list = await _tryCallList(
        source, 'getTopListDetail', [item, page]);
    return _maybeFillQqDurations(source, list);
  }

  // ==================== 歌单 ====================

  Future<({List<PluginSearchResult> songs, bool? isEnd})> getMusicSheetInfoWithEnd(
      PluginSource source, Map<String, dynamic> item,
      {int page = 1}) async {
    final imported = _importedTracksOf(item);
    if (imported != null) {
      final songs = page == 1
          ? imported
              .map((e) => mfItemToSearchResult(e, source))
              .where((r) => r.name.isNotEmpty)
              .toList()
          : const <PluginSearchResult>[];
      return (songs: await _maybeFillQqDurations(source, songs), isEnd: true);
    }
    final methods = await _availableMethods(source);
    if (methods.contains('getMusicSheetInfo')) {
      final raw = await _tryCallRaw(source, 'getMusicSheetInfo', [item, page]);
      if (raw != null) {
        final list = extractMfResultList(raw);
        if (list.isNotEmpty) {
          final songs = list
              .map((e) => mfItemToSearchResult(e, source))
              .where((r) => r.name.isNotEmpty)
              .toList();
          return (
            songs: await _maybeFillQqDurations(source, songs),
            isEnd: extractMfIsEnd(raw),
          );
        }
      }
    }
    if (page == 1 && methods.contains('search')) {
      final title = _stripHtml(item['title'] ?? item['name'] ?? '');
      if (title.isNotEmpty) {
        final songs = await _tryCallList(source, 'search', [title, 1, 'music']);
        return (songs: songs, isEnd: true);
      }
    }
    return (songs: const <PluginSearchResult>[], isEnd: true);
  }

  List<Map<String, dynamic>>? _importedTracksOf(Map<String, dynamic> item) {
    final raw = item['_importedTracks'];
    if (raw is List && raw.isNotEmpty) {
      return raw.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
    }
    return null;
  }

  Future<bool> supportsSheetImport(PluginSource source) => _availableMethods(
      source).then((m) =>
      m.contains('importMusicSheet') || m.contains('importPlaylist'));

  Future<List<Map<String, dynamic>>> _importSheetRaw(
      PluginSource source, String urlLike) async {
    final methods = await _availableMethods(source);
    if (!methods.contains('importMusicSheet')) return const [];
    return _tryCallRawList(source, 'importMusicSheet', [urlLike]);
  }

  Future<List<PluginSearchResult>> importMusicSheet(
      PluginSource source, String urlLike) async {
    final raw = await _importSheetRaw(source, urlLike);
    if (raw.isEmpty) return const [];
    final songs = raw
        .map((e) => mfItemToSearchResult(e, source))
        .where((r) => r.name.isNotEmpty)
        .take(2000)
        .toList();
    return _maybeFillQqDurations(source, songs);
  }

  Future<PluginSearchResult?> importMusicItem(
      PluginSource source, String urlLike) async {
    final methods = await _availableMethods(source);
    if (!methods.contains('importMusicItem')) return null;
    final raw = await _tryCallRaw(source, 'importMusicItem', [urlLike]);
    if (raw == null) return null;
    Map<String, dynamic>? item;
    if (raw is Map && (raw['id'] != null || raw['songmid'] != null)) {
      item = raw.cast<String, dynamic>();
    } else {
      final list = extractMfResultList(raw);
      if (list.isNotEmpty) item = list.first;
    }
    if (item == null) return null;
    final r = mfItemToSearchResult(item, source);
    return r.name.isEmpty ? null : r;
  }

  /// 链接/歌单 ID 精确导入：am importPlaylist → 插件 importMusicSheet →
  /// 五平台宿主兜底。返回 null 表示该音源无法精确导入此输入。
  /// 供 searchSheets 与导入页「自动识别」遍历音源使用（不落公开搜索）。
  Future<MfSheetItem?> importSheetExact(
      PluginSource source, String keyword) async {
    // am 插件（animemusic/1）歌单导入：importPlaylist 返回真实歌单
    // 名/封面/创建者，优先走它
    final methods = await _availableMethods(source);
    if (methods.contains('importPlaylist')) {
      final raw = await _tryCallRaw(source, 'importPlaylist', [keyword]);
      final sheet = _sheetFromAnimeImport(source, keyword, raw);
      if (sheet != null) return sheet;
    }
    final direct =
        await _tryCallRawList(source, 'importMusicSheet', [keyword]);
    if (direct.isNotEmpty) {
      return _sheetFromImportedTracks(source, keyword, direct).first;
    }
    // 插件对部分平台歌单解析失败或返回空：宿主兜底
    final kgSheet = await _kgFallbackSheet(source, keyword);
    if (kgSheet != null) return kgSheet;
    final qsSheet = await _qsFallbackSheet(source, keyword);
    if (qsSheet != null) return qsSheet;
    final wySheet = await _wyFallbackSheet(source, keyword);
    if (wySheet != null) return wySheet;
    final txSheet = await _txFallbackSheet(source, keyword);
    if (txSheet != null) return txSheet;
    final kwSheet = await _kwFallbackSheet(source, keyword);
    if (kwSheet != null) return kwSheet;
    return null;
  }

  List<MfSheetItem> _sheetFromImportedTracks(
      PluginSource source, String keyword, List<Map<String, dynamic>> tracks) {
    final title = tr('{name}收藏夹', {'name': source.name});
    return [
      MfSheetItem(
        id: keyword,
        title: title,
        coverUrl: _extractCover(tracks.first),
        trackCount: tracks.length,
        platform: source.name,
        pluginId: source.id,
        raw: {
          'id': keyword,
          'title': title,
          '_importedTracks': tracks,
        },
      ),
    ];
  }

  Future<MfSheetItem> _hostImportSheetItem(
      PluginSource source, String keyword, HostSheetImportResult result) async {
    final songs = result.tracks
        .map((e) => mfItemToSearchResult(e, source))
        .where((r) => r.name.isNotEmpty)
        .toList();
    final title = result.name.isNotEmpty
        ? result.name
        : tr('{name}收藏夹', {'name': source.name});
    return MfSheetItem(
      id: keyword,
      title: title,
      artist: result.author,
      coverUrl: result.cover.isNotEmpty
          ? result.cover
          : (result.tracks.isNotEmpty ? _extractCover(result.tracks.first) : null),
      trackCount: songs.isNotEmpty ? songs.length : result.tracks.length,
      platform: source.name,
      pluginId: source.id,
      raw: {
        'id': keyword,
        'title': title,
        '_importedTracks': result.tracks,
      },
    );
  }

  /// 宿主侧歌单兜底导入（歌单源更新链路用）：
  /// 酷狗→汽水→网易云→QQ→酷我依次尝试（新三平台按来源门槛收敛数字 ID 歧义）。
  /// 返回原始曲目 map。
  Future<List<Map<String, dynamic>>> importHostSheetRaw(
      PluginSource source, String urlLike) async {
    final kg = await KgSheetImport.import(urlLike);
    if (kg != null && kg.tracks.isNotEmpty) {
      final songs = kg.tracks
          .map((e) => mfItemToSearchResult(e, source))
          .where((r) => r.name.isNotEmpty)
          .toList();
      if (songs.isNotEmpty) return kg.tracks;
    }
    final qs = await QishuiSheetImport.import(urlLike);
    if (qs != null && qs.tracks.isNotEmpty) {
      final songs = qs.tracks
          .map((e) => mfItemToSearchResult(e, source))
          .where((r) => r.name.isNotEmpty)
          .toList();
      if (songs.isNotEmpty) return qs.tracks;
    }
    if (WySheetImport.isWyKeyword(urlLike) ||
        WySheetImport.isWySource(source.name, source.sources)) {
      final wy = await WySheetImport.import(urlLike);
      if (wy != null && wy.tracks.isNotEmpty) {
        final songs = wy.tracks
            .map((e) => mfItemToSearchResult(e, source))
            .where((r) => r.name.isNotEmpty)
            .toList();
        if (songs.isNotEmpty) return wy.tracks;
      }
    }
    if (TxSheetImport.isTxKeyword(urlLike) ||
        TxSheetImport.isTxSource(source.name, source.sources)) {
      final tx = await TxSheetImport.import(urlLike);
      if (tx != null && tx.tracks.isNotEmpty) {
        final songs = tx.tracks
            .map((e) => mfItemToSearchResult(e, source))
            .where((r) => r.name.isNotEmpty)
            .toList();
        if (songs.isNotEmpty) return tx.tracks;
      }
    }
    if (KwSheetImport.isKwKeyword(urlLike) ||
        KwSheetImport.isKwSource(source.name, source.sources)) {
      final kw = await KwSheetImport.import(urlLike);
      if (kw != null && kw.tracks.isNotEmpty) {
        final songs = kw.tracks
            .map((e) => mfItemToSearchResult(e, source))
            .where((r) => r.name.isNotEmpty)
            .toList();
        if (songs.isNotEmpty) return kw.tracks;
      }
    }
    return const [];
  }

  /// am importPlaylist 返回 {id,title,cover,creator,desc,total,list}，
  /// 曲目结构同 search；用真实歌单元数据包成单一导入结果
  MfSheetItem? _sheetFromAnimeImport(
      PluginSource source, String keyword, dynamic raw) {
    if (raw is! Map) return null;
    final list = raw['list'];
    if (list is! List || list.isEmpty) return null;
    final tracks =
        list.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
    final title = (raw['title'] ?? '').toString().trim();
    final total = _toInt(raw['total']) ?? 0;
    return MfSheetItem(
      id: keyword,
      title: title.isNotEmpty ? title : tr('{name}歌单', {'name': source.name}),
      artist: (raw['creator'] ?? '').toString(),
      coverUrl: (raw['cover'] ?? '').toString(),
      trackCount: total > 0 ? total : tracks.length,
      platform: source.name,
      pluginId: source.id,
      raw: {
        'id': keyword,
        'title': title,
        '_importedTracks': tracks,
      },
    );
  }

  // ==================== 歌手 ====================

  Future<List<MfArtistItem>> searchArtists(
      PluginSource source, String keyword) async {
    final list = await _tryCallRawList(source, 'search', [keyword, 1, 'artist']);
    return list
        .map((m) => _toArtist(m, source))
        .where((a) => a.name.isNotEmpty)
        .toList();
  }

  Future<List<PluginSearchResult>> getArtistWorks(
      PluginSource source, Map<String, dynamic> item, {int page = 1}) async {
    final methods = await _availableMethods(source);
    if (methods.contains('getArtistWorks')) {
      final list =
          await _tryCallList(source, 'getArtistWorks', [item, page, 'music']);
      if (list.isNotEmpty) return _maybeFillQqDurations(source, list);
    }
    if (page == 1 && methods.contains('search')) {
      final name = _stripHtml(item['name'] ?? item['title'] ?? item['artist'] ?? '');
      if (name.isNotEmpty) {
        return _tryCallList(source, 'search', [name, 1, 'music']);
      }
    }
    return const [];
  }

  Future<List<MfAlbumItem>> getArtistAlbums(
      PluginSource source, Map<String, dynamic> item, {int page = 1}) async {
    final list =
        await _tryCallRawList(source, 'getArtistWorks', [item, page, 'album']);
    return list
        .map((m) => _toAlbum(m, source))
        .where((a) => a.name.isNotEmpty)
        .toList();
  }

  Future<String> getArtistInfo(
      PluginSource source, Map<String, dynamic> item) async {
    try {
      final methods = await _availableMethods(source);
      if (!methods.contains('getArtistInfo')) return '';
      final info = await _call(source, 'getArtistInfo', [item]);
      if (info is! Map) return '';
      return _extractDescription(info.cast<String, dynamic>());
    } catch (_) {
      return '';
    }
  }

  // ==================== 专辑 ====================

  Future<List<MfAlbumItem>> searchAlbums(
      PluginSource source, String keyword) async {
    var list = await _tryCallRawList(source, 'search', [keyword, 1, 'album']);
    var albums = list.map((m) => _toAlbum(m, source)).toList();
    if (albums.isEmpty && isQqMusicPluginSource(source, _platformOf(source))) {
      final fb = await qqHostAlbumSearchFallback(source, keyword);
      albums = fb.map((m) => _toAlbum(m, source)).toList();
    }
    return albums.where((a) => a.name.isNotEmpty).toList();
  }

  /// 专辑曲目。不截断数量（小说类专辑可达数千条），isEnd 取插件返回值，
  /// 插件未返回时为 null，由调用方按页大小兜底。
  Future<({List<PluginSearchResult> songs, bool? isEnd})> getAlbumSongs(
      PluginSource source, Map<String, dynamic> item,
      {int page = 1}) async {
    final methods = await _availableMethods(source);
    if (!methods.contains('getAlbumInfo')) {
      if (methods.contains('search')) {
        final title = _stripHtml(item['title'] ?? item['name'] ?? item['album'] ?? '');
        if (title.isNotEmpty) {
          final songs = await _tryCallList(source, 'search', [title, 1, 'music']);
          return (songs: songs, isEnd: true);
        }
      }
      return (songs: const <PluginSearchResult>[], isEnd: true);
    }
    final req = Map<String, dynamic>.from(item);
    final albumMid = req['albumMID'] ?? req['albummid'] ?? req['albumMid'];
    if (albumMid != null && req['albumMID'] == null) {
      req['albumMID'] = albumMid;
    }
    final raw = await _tryCallRaw(source, 'getAlbumInfo', [req, page]);
    var songs = const <PluginSearchResult>[];
    bool? isEnd;
    if (raw != null) {
      final rawList = extractMfResultList(raw);
      if (rawList.isNotEmpty) {
        songs = rawList
            .map((e) => mfItemToSearchResult(e, source))
            .where((r) => r.name.isNotEmpty)
            .toList();
        isEnd = extractMfIsEnd(raw);
      }
    }
    if (songs.isEmpty && isQqMusicPluginSource(source, _platformOf(source))) {
      final mid = (albumMid ?? '').toString();
      if (mid.isNotEmpty) {
        songs = await qqHostAlbumSongsFallback(source, mid, page: page);
        isEnd = songs.length < 30;
      }
    }
    return (songs: await _maybeFillQqDurations(source, songs), isEnd: isEnd);
  }

  // ==================== 单曲搜索（MusicFree） ====================

  String? _platformOf(PluginSource source) {
    final meta = engine.metadataOf(source.id);
    final p = meta?['platform'];
    return p is String && p.isNotEmpty ? p : null;
  }

  Future<List<PluginSearchResult>> _maybeFillQqDurations(
          PluginSource source, List<PluginSearchResult> list) async =>
      qqFillSongDurations(source, _platformOf(source), list);

  Future<List<PluginSearchResult>> searchMusic(
      PluginSource source, String keyword,
      {int limit = 30}) async {
    final results =
        await _tryCallList(source, 'search', [keyword, 1, 'music'], limit: limit);
    if (results.isNotEmpty) return results;
    if (isQqMusicPluginSource(source, _platformOf(source))) {
      return qqHostSearchFallback(source, keyword, limit: limit);
    }
    return results;
  }

  // ==================== 内部工具 ====================

  Future<List<PluginSearchResult>> _tryCallList(
      PluginSource source, String method, List<dynamic> args,
      {int limit = 100}) async {
    final raw = await _tryCallRawList(source, method, args);
    final mapped = raw
        .map((e) => mfItemToSearchResult(e, source))
        .where((r) => r.name.isNotEmpty)
        .toList();
    return mapped.length > limit ? mapped.sublist(0, limit) : mapped;
  }

  Future<dynamic> _tryCallRaw(
      PluginSource source, String method, List<dynamic> args) async {
    try {
      return await _call(source, method, args);
    } catch (e) {
      AppLog.warn('plugin',
          '[catalog] ${source.name} $method 调用失败: $e');
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> _tryCallRawList(
      PluginSource source, String method, List<dynamic> args) async {
    try {
      final result = await _call(source, method, args);
      final list = extractMfResultList(result);
      AppLog.debug(
          'plugin', '[catalog] ${source.name} $method 返回 ${list.length} 条');
      return list;
    } catch (e) {
      AppLog.warn('plugin',
          '[catalog] ${source.name} $method 调用失败: $e');
      return const [];
    }
  }

  MfSheetItem _toSheet(Map<String, dynamic> m, PluginSource source,
      {dynamic categoryTitle}) {
    final id = (m['id'] ?? m['albumId'] ?? m['songId'] ?? m['musicId'] ?? '')
        .toString();
    return MfSheetItem(
      id: id,
      title: _stripHtml(m['title'] ?? m['name'] ?? m['album'] ?? ''),
      artist: _stripHtml(categoryTitle ?? m['artist'] ?? m['author'] ?? m['singer'] ?? ''),
      coverUrl: _extractCover(m),
      playCount: _toInt(m['playCount'] ?? m['playcount'] ?? m['play_count']),
      trackCount: _toInt(m['trackCount'] ?? m['trackcount'] ?? m['track_count']),
      platform: source.name,
      pluginId: source.id,
      isTopList: m['_isTopList'] == true,
      isAlbum: m['_isAlbum'] == true,
      raw: m,
    );
  }

  MfArtistItem _toArtist(Map<String, dynamic> m, PluginSource source) {
    final id = (m['id'] ?? m['artistId'] ?? '').toString();
    return MfArtistItem(
      id: id,
      name: _stripHtml(m['name'] ?? m['title'] ?? m['artist'] ?? ''),
      avatarUrl: _extractAvatar(m),
      platform: source.name,
      pluginId: source.id,
      raw: m,
    );
  }

  MfAlbumItem _toAlbum(Map<String, dynamic> m, PluginSource source) {
    final id = (m['id'] ?? m['albumId'] ?? m['albumMid'] ?? '').toString();
    return MfAlbumItem(
      id: id,
      name: _stripHtml(m['title'] ?? m['name'] ?? m['album'] ?? ''),
      artist: _extractArtistText(m),
      coverUrl: _extractCover(m),
      platform: source.name,
      pluginId: source.id,
      raw: m,
    );
  }
}
