import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../src/core/app_colors.dart';
import '../../src/navigation/shell.dart';
import '../../src/plugin/plugin_catalog.dart';
import '../../src/plugin/plugin_models.dart';
import '../../src/plugin/plugin_provider.dart';
import '../../src/widgets/online_cover.dart';
import 'online_detail_page.dart';

/// 音源榜单页：插件来源切换 + 榜单网格（对齐桌面 TopLists）。
class TopListsPage extends ConsumerStatefulWidget {
  const TopListsPage({super.key});

  @override
  ConsumerState<TopListsPage> createState() => _TopListsPageState();
}

class _TopListsPageState extends ConsumerState<TopListsPage>
    with HidesShellChrome {
  List<PluginSource> _sources = const [];
  String? _selectedId;
  List<MfSheetItem> _boards = const [];
  bool _loading = true;
  bool _checking = true;

  @override
  void initState() {
    super.initState();
    _detectSources();
  }

  Future<void> _detectSources() async {
    setState(() => _checking = true);
    final engine = await ref.read(pluginEngineProvider.future);
    final sources =
        ref.read(pluginManagerProvider).sources.where((s) => s.enabled).toList();
    final catalog = PluginCatalogService(engine, sources);
    final supported = <PluginSource>[];
    for (final s in catalog.musicFreeSources) {
      if (await catalog.supportsTopLists(s)) supported.add(s);
    }
    if (!mounted) return;
    setState(() {
      _sources = supported;
      _checking = false;
    });
    if (supported.isNotEmpty) {
      await _load(supported.first);
    } else {
      setState(() => _loading = false);
    }
  }

  Future<void> _load(PluginSource source) async {
    setState(() {
      _selectedId = source.id;
      _loading = true;
    });
    final engine = await ref.read(pluginEngineProvider.future);
    final catalog = PluginCatalogService(engine,
        ref.read(pluginManagerProvider).sources);
    final boards = await catalog.getTopLists(source);
    if (!mounted) return;
    setState(() {
      _boards = boards;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: appSurfaceBg(context),
      appBar: AppBar(
        title: const Text('音源榜单'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
      ),
      body: Column(
        children: [
          if (_sources.isNotEmpty)
            SizedBox(
              height: 46,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                children: [
                  for (final s in _sources)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(s.name),
                        showCheckmark: false,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        selected: _selectedId == s.id,
                        onSelected: (_) => _load(s),
                      ),
                    ),
                ],
              ),
            ),
          Expanded(child: _buildBody(scheme)),
        ],
      ),
    );
  }

  Widget _buildBody(ColorScheme scheme) {
    if (_checking || (_loading && _boards.isEmpty)) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(strokeWidth: 2),
            const SizedBox(height: 12),
            Text(
              _checking ? '正在检测可用音源…' : '正在加载榜单…',
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }
    if (_sources.isEmpty) {
      return _empty(
        scheme,
        Icons.extension_outlined,
        '暂无支持榜单的插件\n请先在「插件管理」安装支持排行榜的音源插件',
      );
    }
    if (_boards.isEmpty) {
      return _empty(scheme, Icons.library_music_outlined, '该音源暂无榜单\n试试切换其他音源');
    }
    return GridView.builder(
      padding: EdgeInsets.fromLTRB(14, 8, 14, MediaQuery.of(context).padding.bottom + 24),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.72,
      ),
      itemCount: _boards.length,
      itemBuilder: (context, i) {
        final b = _boards[i];
        return InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _openBoard(b),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: OnlineCover(url: b.coverUrl, size: 200, radius: 12),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Text(
                b.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
              if (b.subtitle.isNotEmpty)
                Text(
                  b.subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 11, color: scheme.onSurfaceVariant),
                ),
            ],
          ),
        );
      },
    );
  }

  void _openBoard(MfSheetItem b) {
    context.push('/online-detail',
        extra: OnlineDetailArgs(
          type: OnlineDetailType.toplist,
          pluginId: b.pluginId,
          title: b.title,
          subtitle: b.subtitle,
          coverUrl: b.coverUrl,
          raw: b.raw,
        ));
  }

  Widget _empty(ColorScheme scheme, IconData icon, String message) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 52, color: scheme.onSurfaceVariant.withValues(alpha: 0.4)),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 13, height: 1.6, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
