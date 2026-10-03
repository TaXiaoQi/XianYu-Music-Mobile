// 部分：cloud Tab（part 拆分自 playlist_import_page.dart）
part of 'playlist_import_page.dart';

// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------

class _CloudImportTab extends ConsumerStatefulWidget {
  const _CloudImportTab();

  @override
  ConsumerState<_CloudImportTab> createState() => _CloudImportTabState();
}

class _CloudImportTabState extends ConsumerState<_CloudImportTab> {
  static const _autoKey = '__auto__';

  String? _selectedPluginId;
  PluginSource? _resolved;
  bool _searching = false;
  bool _importing = false;
  List<MfSheetItem> _sheets = const [];
  String? _error;
  final _keywordCtrl = TextEditingController();
  final _renameCtrl = TextEditingController();

  @override
  void dispose() {
    _keywordCtrl.dispose();
    _renameCtrl.dispose();
    super.dispose();
  }

  List<PluginSource> get _plugins => ref
      .watch(pluginManagerProvider)
      .sources
      .where(
        (s) =>
            s.enabled &&
            (s.format == PluginFormat.musicfree ||
                s.format == PluginFormat.anime),
      )
      .toList();

  PluginSource? get _selected {
    final id = _selectedPluginId;
    if (id == null || id.isEmpty || id == _autoKey) return null;
    return _plugins.where((s) => s.id == id).firstOrNull;
  }

  static Map<String, List<String>> get _platformKeywords => {
    'netease': [tr('网易云'), 'netease', 'wy'],
    'qq': [tr('qq音乐'), 'qqmusic', tr('腾讯'), 'tx', 'qq'],
    'kuwo': ['kuwo', tr('酷我'), 'kw'],
    'kugou': ['kugou', tr('酷狗'), 'kg'],
    'qishui': [tr('汽水'), 'qishui', 'douyin'],
  };

  String? _detectPlatformFromUrl(String input) {
    final t = input.toLowerCase();
    if (t.contains('music.163.com') ||
        t.contains('163cn.tv') ||
        t.contains('163.com/playlist')) {
      return 'netease';
    }
    if (t.contains('y.qq.com') || t.contains('c.y.qq.com')) return 'qq';
    if (t.contains('kuwo.cn')) return 'kuwo';
    if (t.contains('kugou.com') || t.contains('t.kugou.com')) {
      return 'kugou';
    }
    if (t.contains('qishui') || t.contains('汽水')) return 'qishui';
    return null;
  }

  PluginSource? _matchPluginByPlatform(
    String canonical,
    List<PluginSource> plugins,
  ) {
    final keywords = _platformKeywords[canonical] ?? const [];
    for (final p in plugins) {
      for (final label in [p.name, ...p.sources]) {
        final n = _normPlatform(label);
        for (final k in keywords) {
          final nk = _normPlatform(k);
          if (n == nk || (nk.length >= 2 && n.contains(nk))) return p;
        }
      }
    }
    return null;
  }

  String _normPlatform(Object? v) => (v?.toString() ?? '')
      .replaceAll(RegExp(r'[\s_.\-—/\\()[\]（）【】·]+'), '')
      .replaceAll(RegExp(r'(?:音乐|music|音源|source)+$'), '')
      .toLowerCase();

  Future<void> _search() async {
    final keyword = _keywordCtrl.text.trim();
    if (keyword.isEmpty || _searching) return;

    final plugins = _plugins;
    var source = _selected;
    var autoResolved = false;
    if (source == null) {
      final canonical = _detectPlatformFromUrl(keyword);
      if (canonical != null) {
        source = _matchPluginByPlatform(canonical, plugins);
        if (source == null) {
          setState(() {
            _error = tr('未找到支持该平台的音源插件，请先安装对应插件');
          });
          return;
        }
        autoResolved = true;
      } else if (plugins.length == 1) {
        source = plugins.first;
        autoResolved = true;
      }
      // 仍无法锁定音源：链接/纯数字歌单 ID 在下方遍历音源精确导入
    }

    setState(() {
      _searching = true;
      _error = null;
      _sheets = const [];
    });
    try {
      final engine = await ref.read(pluginEngineProvider.future);
      final catalog = PluginCatalogService(
        engine,
        ref.read(pluginManagerProvider).sources,
      );
      if (source == null) {
        // 遍历音源精确导入（importMusicSheet + 宿主兜底，不落公开搜索：
        // 公开搜索对链接/ID 只会返回噪音）。纯数字 ID 存在平台歧义，
        // 以第一个命中的音源为准，也可手动切换音源重试。
        MfSheetItem? hit;
        if (PluginCatalogService.looksLikeSheetLinkOrId(keyword)) {
          for (final p in plugins) {
            hit = await catalog.importSheetExact(p, keyword);
            if (hit != null) {
              source = p;
              break;
            }
          }
        }
        if (hit == null || source == null) {
          if (!mounted) return;
          setState(() {
            _error = tr('无法识别歌单链接，请选择对应音源后重试，或直接粘贴分享链接');
          });
          return;
        }
        _resolved = source;
        final sheet = hit;
        if (!mounted) return;
        // 精确命中也先进预览列表：展示歌单信息，用户点击条目才真正导入，
        // 避免链接识别错误时直接落库（与公开搜索结果的行为一致）
        setState(() {
          _sheets = [sheet];
        });
        return;
      }
      if (autoResolved) _resolved = source;
      final sheets = await catalog.searchSheets(source, keyword);
      if (!mounted) return;
      if (sheets.isEmpty) {
        final single = await catalog.importMusicItem(source, keyword);
        if (single != null) {
          await _importSingleSong(source, single);
          return;
        }
      }
      // 链接/ID 精确命中的唯一结果同样只做预览：用户点击条目才开始导入
      setState(() {
        _sheets = sheets;
        if (sheets.isEmpty) _error = tr('未找到匹配的歌单，换个关键词或链接试试');
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = tr('搜索失败：{e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _importSheet(MfSheetItem sheet) async {
    final plugins = _plugins;
    final sheetPlugin = plugins
        .where((p) => p.id == sheet.pluginId)
        .firstOrNull;
    final source = sheetPlugin ?? _resolved ?? _selected;
    if (source == null || _importing) return;
    setState(() => _importing = true);
    try {
      final engine = await ref.read(pluginEngineProvider.future);
      final catalog = PluginCatalogService(
        engine,
        ref.read(pluginManagerProvider).sources,
      );

      final songs = <ImportedSong>[];
      final seen = <String>{};
      var page = 1;
      var maxPageSize = 0;
      final total = sheet.trackCount ?? 0;
      while (page <= 50) {
        final result = await catalog.getMusicSheetInfoWithEnd(
          source,
          sheet.raw,
          page: page,
        );
        final results = result.songs;
        if (results.isEmpty) break;
        final fresh = results.where((r) {
          final key = '${r.songmid}|${r.name}|${r.singer}';
          return seen.add(key);
        }).toList();
        if (fresh.isEmpty) break;
        songs.addAll(
          fresh
              .map(
                (r) => importedSongFromQueueItem(
                  PluginCatalogService.toQueueItem(source, r),
                ),
              )
              .toList(),
        );
        if (result.isEnd == true) break;
        if (total > 0 && songs.length >= total) break;
        if (results.length > maxPageSize) maxPageSize = results.length;
        if (results.length < maxPageSize) break;
        page++;
      }

      if (songs.isEmpty) {
        if (!mounted) return;
        _toast(tr('歌单为空或获取失败'));
        return;
      }

      final rename = _renameCtrl.text.trim();
      final name = rename.isNotEmpty ? rename : sheet.title;
      final manager = ref.read(playlistManagerProvider.notifier);
      await manager.create(name);
      final created = ref.read(playlistManagerProvider).playlists;
      if (created.isEmpty) {
        if (!mounted) return;
        _toast(tr('歌单创建失败'));
        return;
      }
      await manager.addSongs(created.last.id, songs);
      final keyword = _keywordCtrl.text.trim();
      final isUrlImport = sheet.raw['_importedTracks'] != null;
      Map<String, dynamic>? sourceRaw;
      if (!isUrlImport && sheet.raw.isNotEmpty) {
        sourceRaw = Map<String, dynamic>.from(sheet.raw)
          ..remove('_importedTracks');
      }
      await manager.setSource(
        created.last.id,
        sourcePluginId: source.id,
        sourceUrl: keyword,
        sourceRaw: sourceRaw,
      );
      if (!mounted) return;
      _toast(tr('已导入「{name}」，共 {n} 首歌曲', {'name': name, 'n': songs.length}));
    } catch (e) {
      if (!mounted) return;
      _toast(tr('导入失败：{e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _importSingleSong(
    PluginSource source,
    PluginSearchResult song,
  ) async {
    try {
      final rename = _renameCtrl.text.trim();
      final name = rename.isNotEmpty ? rename : song.name;
      final manager = ref.read(playlistManagerProvider.notifier);
      await manager.create(name);
      final created = ref.read(playlistManagerProvider).playlists;
      if (created.isEmpty) {
        if (!mounted) return;
        _toast(tr('歌单创建失败'));
        return;
      }
      await manager.addSongs(created.last.id, [
        importedSongFromQueueItem(
          PluginCatalogService.toQueueItem(source, song),
        ),
      ]);
      if (!mounted) return;
      _toast(tr('已导入单曲「{name}」', {'name': song.name}));
    } catch (e) {
      if (!mounted) return;
      _toast(tr('导入失败：{e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  void _toast(String msg) {
    showXianYuToast(context, msg);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final plugins = _plugins;

    if (plugins.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_outlined, size: 52, color: scheme.outline),
              const SizedBox(height: 12),
              Text(
                tr('暂无可用的音源插件'),
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 4),
              Text(
                tr('先在 设置 → 音源 安装并启用插件，再回来导入在线歌单'),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: scheme.outline),
              ),
            ],
          ),
        ),
      );
    }

    var selected = _selectedPluginId;
    if (selected != null &&
        selected != _autoKey &&
        !plugins.any((p) => p.id == selected)) {
      selected = _autoKey;
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        Text(
          tr('选择音源'),
          style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          initialValue: selected ?? _autoKey,
          items: [
            DropdownMenuItem(value: _autoKey, child: Text(tr('自动识别'))),
            for (final p in plugins)
              DropdownMenuItem(value: p.id, child: Text(p.name)),
          ],
          onChanged: (v) => setState(() {
            _selectedPluginId = v;
            _resolved = null;
          }),
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _keywordCtrl,
          enabled: !_searching && !_importing,
          onSubmitted: (_) => _search(),
          decoration: InputDecoration(
            labelText: tr('歌单分享链接或歌单 ID'),
            hintText: tr('粘贴歌单分享链接或输入歌单 ID'),
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _renameCtrl,
          enabled: !_importing,
          decoration: InputDecoration(
            labelText: tr('歌单重命名（可选）'),
            hintText: tr('导入后给歌单起个新名字'),
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          tr(
            '选择「自动识别」直接粘贴网易云/QQ音乐/酷我/酷狗/汽水的分享链接，或选择对应音源后输入歌单 ID，点击搜索即可导入全部曲目。关键词搜索只能搜公开歌单，导入自己的歌单请粘贴分享链接或歌单 ID。',
          ),
          style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 14),
        FilledButton.icon(
          onPressed: (_searching || _importing) ? null : _search,
          icon: _searching
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.search, size: 18),
          label: Text(tr('搜索歌单')),
        ),
        if (_error != null) ...[
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: scheme.errorContainer.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              _error!,
              style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
            ),
          ),
        ],
        if (_sheets.isNotEmpty) ...[
          const SizedBox(height: 18),
          Text(
            tr('搜索结果 · {n}', {'n': _sheets.length}),
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          for (final sheet in _sheets)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Material(
                color: appCardColor(context),
                clipBehavior: Clip.antiAlias,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide.none,
                ),
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: _importing ? null : () => _importSheet(sheet),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                    child: Row(
                      children: [
                        OnlineCover(url: sheet.coverUrl, size: 48, radius: 8),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                sheet.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 14.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                sheet.subtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (_importing)
                          const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        else
                          Icon(
                            Icons.download_for_offline_outlined,
                            size: 22,
                            color: scheme.primary,
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ],
    );
  }
}
