import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/navigation/shell.dart';
import '../../src/plugins/plugin_provider.dart';

/// 音源管理页：导入、启用停用、卸载音源插件。
///
/// 支持从本地 `.js` 文件或订阅 URL 导入 LX Music 兼容音源脚本。
class MusicSourcesPage extends ConsumerStatefulWidget {
  const MusicSourcesPage({super.key});

  @override
  ConsumerState<MusicSourcesPage> createState() => _MusicSourcesPageState();
}

class _MusicSourcesPageState extends ConsumerState<MusicSourcesPage>
    with HidesShellChrome {
  /// 正在导入，用于禁用按钮并显示进度。
  bool _importing = false;

  void _toast(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        duration: Duration(seconds: error ? 4 : 2),
        backgroundColor:
            error ? Theme.of(context).colorScheme.error : null,
      ),
    );
  }

  Future<void> _importFromFile() async {
    setState(() => _importing = true);
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['js'],
      );
      final path = picked?.files.single.path;
      if (path == null) return; // 用户取消

      final name =
          await ref.read(pluginProvider.notifier).installFromFile(path);
      _toast('已导入音源：$name');
    } catch (e) {
      _toast('导入失败：$e', error: true);
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _importFromUrl() async {
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('从链接导入'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: 'https://example.com/source.js',
            labelText: '音源订阅链接',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    if (url == null || url.isEmpty) return;

    setState(() => _importing = true);
    try {
      final name = await ref.read(pluginProvider.notifier).installFromUrl(url);
      _toast('已导入音源：$name');
    } catch (e) {
      _toast('导入失败：$e', error: true);
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _confirmRemove(PluginInfo plugin) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('移除音源'),
        content: Text('确定移除「${plugin.name}」吗？\n移除后依赖它的在线播放将不可用。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(pluginProvider.notifier).remove(plugin.id);
      _toast('已移除');
    } catch (e) {
      _toast('移除失败：$e', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(pluginProvider);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('音源管理'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: state.loading
                ? null
                : () => ref.read(pluginProvider.notifier).load(),
          ),
        ],
      ),
      floatingActionButton: _importing
          ? const FloatingActionButton(
              onPressed: null,
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          : FloatingActionButton.extended(
              onPressed: _showImportSheet,
              icon: const Icon(Icons.add),
              label: const Text('导入音源'),
            ),
      body: state.loading && state.plugins.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (state.error != null)
                  Container(
                    width: double.infinity,
                    color: scheme.errorContainer,
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      state.error!,
                      style: TextStyle(color: scheme.onErrorContainer),
                    ),
                  ),
                Expanded(
                  child: state.plugins.isEmpty
                      ? _emptyView(scheme)
                      : _pluginList(state, scheme),
                ),
              ],
            ),
    );
  }

  Widget _emptyView(ColorScheme scheme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.extension_off_outlined,
                size: 56, color: scheme.onSurfaceVariant),
            const SizedBox(height: 16),
            const Text(
              '还没有音源',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              '在线搜索与播放需要音源支持。\n'
              '点击下方按钮，从本地文件或订阅链接导入 LX Music 兼容音源脚本。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Widget _pluginList(PluginState state, ColorScheme scheme) {
    return ListView.separated(
      // 底栏已隐藏，仅为 FAB 留出空间。
      padding: const EdgeInsets.only(bottom: 88),
      itemCount: state.plugins.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final p = state.plugins[i];
        return ListTile(
          leading: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: p.enabled
                  ? scheme.primary.withValues(alpha: 0.14)
                  : scheme.onSurface.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(10),
            ),
            alignment: Alignment.center,
            child: Icon(
              Icons.extension,
              size: 20,
              color: p.enabled ? scheme.primary : scheme.onSurfaceVariant,
            ),
          ),
          title: Text(
            p.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 2),
              Text(
                [
                  if (p.version.isNotEmpty) p.version,
                  if (p.author.isNotEmpty) p.author,
                ].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 4),
              // 展示该插件覆盖的音源，让用户知道能听哪些平台
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  for (final s in p.sources)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: scheme.primary.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        _sourceLabel(s),
                        style: TextStyle(fontSize: 10, color: scheme.primary),
                      ),
                    ),
                ],
              ),
            ],
          ),
          isThreeLine: true,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Switch(
                value: p.enabled,
                onChanged: (v) =>
                    ref.read(pluginProvider.notifier).setEnabled(p.id, v),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () => _confirmRemove(p),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 音源标识 → 中文名，未知标识原样显示。
  String _sourceLabel(String id) {
    return switch (id) {
      'kw' => '酷我',
      'kg' => '酷狗',
      'tx' => 'QQ音乐',
      'wy' => '网易云',
      'mg' => '咪咕',
      _ => id,
    };
  }

  void _showImportSheet() {
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                '导入音源',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.insert_drive_file_outlined),
              title: const Text('从本地文件'),
              subtitle: const Text('选择 .js 音源脚本'),
              onTap: () {
                Navigator.pop(ctx);
                _importFromFile();
              },
            ),
            ListTile(
              leading: const Icon(Icons.link),
              title: const Text('从链接'),
              subtitle: const Text('输入音源订阅地址'),
              onTap: () {
                Navigator.pop(ctx);
                _importFromUrl();
              },
            ),
          ],
        ),
      ),
    );
  }
}
