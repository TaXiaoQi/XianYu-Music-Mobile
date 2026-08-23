import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/library/library_provider.dart';
import '../../src/player/player_provider.dart';
import '../../src/remote/remote_library_service.dart';
import '../../src/widgets/mini_player_bar.dart';

/// 远程音乐库管理页：WebDAV 源的添加/编辑/同步/删除与缓存管理。
class RemoteLibraryPage extends ConsumerWidget {
  const RemoteLibraryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final state = ref.watch(remoteLibraryProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('远程音乐库 (WebDAV)')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showSourceEditor(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('添加 WebDAV 音乐库'),
      ),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 10),
                child: Text(
                  '挂载 WebDAV 服务器上的音乐，同步后远程歌曲会加入本地曲库；播放时优先使用缓存，未缓存则在线流式播放',
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                ),
              ),
              if (state.sources.isEmpty && !state.loading)
                _buildEmptyHint(scheme)
              else
                for (final source in state.sources)
                  _SourceCard(source: source),
              const SizedBox(height: 20),
              _buildCacheCard(context, ref, state),
            ],
          ),
          if (_hasPlayerSong(ref))
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

  static bool _hasPlayerSong(WidgetRef ref) =>
      ref.watch(playerProvider.select((s) => s.current != null));

  Widget _buildEmptyHint(ColorScheme scheme) => Container(
        padding: const EdgeInsets.symmetric(vertical: 36),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          children: [
            Icon(Icons.cloud_off_outlined,
                size: 44, color: scheme.outline.withValues(alpha: 0.6)),
            const SizedBox(height: 12),
            Text('还没有远程音乐库',
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurfaceVariant)),
            const SizedBox(height: 4),
            Text('点击下方按钮添加 WebDAV 服务器',
                style: TextStyle(fontSize: 12, color: scheme.outline)),
          ],
        ),
      );

  Widget _buildCacheCard(
      BuildContext context, WidgetRef ref, RemoteLibraryState state) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.cached_outlined),
            title: const Text('远程音频缓存',
                style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
            subtitle: Text(
              '${state.cacheUsage.bytesText} · ${state.cacheUsage.files} 个文件（上限 2GB，超出自动淘汰）',
              style: const TextStyle(fontSize: 12),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton.icon(
                onPressed: state.cacheUsage.bytes <= 0
                    ? null
                    : () async {
                        final ok = await _confirm(
                          context,
                          title: '清理远程缓存',
                          message: '将删除全部已缓存的远程音频文件（不影响远程源配置与曲库记录），正在播放的远程歌曲可能中断。',
                        );
                        if (ok != true) return;
                        try {
                          await ref
                              .read(remoteLibraryProvider.notifier)
                              .clearCache();
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('远程缓存已清理')),
                            );
                          }
                        } catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('清理失败：$e')),
                            );
                          }
                        }
                      },
                icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                label: const Text('清理缓存'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 添加/编辑远程源表单（底部弹层）。
  Future<void> _showSourceEditor(BuildContext context, WidgetRef ref,
      {RemoteSourceInfo? editing}) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _SourceEditorSheet(editing: editing),
    );
  }

  Future<bool?> _confirm(BuildContext context,
      {required String title, required String message}) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }
}

/// 单个远程源卡片。
class _SourceCard extends ConsumerWidget {
  const _SourceCard({required this.source});
  final RemoteSourceInfo source;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final state = ref.watch(remoteLibraryProvider);
    final syncing = state.syncingSourceId == source.id;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.cloud_outlined,
                    size: 22, color: scheme.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(source.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(
                      '${source.baseUrl}${source.rootPath == '/' ? '' : source.rootPath}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              if (source.enabled)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text('已启用',
                      style: TextStyle(
                          fontSize: 10.5,
                          color: scheme.primary,
                          fontWeight: FontWeight.w600)),
                )
              else
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: scheme.outline.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text('已停用',
                      style: TextStyle(
                          fontSize: 10.5, color: scheme.onSurfaceVariant)),
                ),
              PopupMenuButton<String>(
                icon: Icon(Icons.more_vert,
                    size: 20, color: scheme.onSurfaceVariant),
                onSelected: (v) => _onMenu(context, ref, v),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'edit', child: Text('编辑')),
                  PopupMenuItem(value: 'remove', child: Text('删除')),
                ],
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (source.lastSyncError != null &&
              source.lastSyncError!.isNotEmpty) ...[
            Text(
              '上次同步失败：${source.lastSyncError}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: scheme.error),
            ),
            const SizedBox(height: 4),
          ] else
            Text(
              source.lastSyncText,
              style: TextStyle(fontSize: 11.5, color: scheme.outline),
            ),
          const SizedBox(height: 2),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton.icon(
                onPressed: syncing ? null : () => _sync(context, ref),
                icon: syncing
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.sync_outlined, size: 18),
                label: Text(syncing ? '同步中…' : '同步'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _onMenu(BuildContext context, WidgetRef ref, String action) async {
    if (action == 'edit') {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (_) => _SourceEditorSheet(editing: source),
      );
    } else if (action == 'remove') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('删除远程源'),
          content: Text(
              '将删除「${source.name}」及其在曲库中的全部远程歌曲（不删除服务器上的文件）。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(ctx).colorScheme.error),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除'),
            ),
          ],
        ),
      );
      if (ok != true) return;
      try {
        await ref.read(remoteLibraryProvider.notifier).remove(source.id);
        ref.read(libraryProvider.notifier).load();
        if (context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('远程源已删除')));
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('删除失败：$e')));
        }
      }
    }
  }

  Future<void> _sync(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final message =
          await ref.read(remoteLibraryProvider.notifier).sync(source.id);
      // 同步写入曲库后刷新音乐库列表。
      ref.read(libraryProvider.notifier).load();
      messenger.showSnackBar(SnackBar(content: Text(message)));
    } catch (e) {
      // 刷新以显示 lastSyncError。
      ref.read(remoteLibraryProvider.notifier).refresh();
      messenger.showSnackBar(SnackBar(content: Text('同步失败：$e')));
    }
  }
}

/// 添加/编辑远程源表单弹层。
class _SourceEditorSheet extends ConsumerStatefulWidget {
  const _SourceEditorSheet({this.editing});
  final RemoteSourceInfo? editing;

  @override
  ConsumerState<_SourceEditorSheet> createState() => _SourceEditorSheetState();
}

class _SourceEditorSheetState extends ConsumerState<_SourceEditorSheet> {
  late final TextEditingController _name =
      TextEditingController(text: widget.editing?.name ?? '');
  late final TextEditingController _baseUrl =
      TextEditingController(text: widget.editing?.baseUrl ?? '');
  late final TextEditingController _username =
      TextEditingController(text: widget.editing?.username ?? '');
  final TextEditingController _password = TextEditingController();
  late final TextEditingController _rootPath =
      TextEditingController(text: widget.editing?.rootPath ?? '/');
  bool _obscurePassword = true;
  bool _testing = false;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _baseUrl.dispose();
    _username.dispose();
    _password.dispose();
    _rootPath.dispose();
    super.dispose();
  }

  bool get _isEditing => widget.editing != null;

  /// 编辑时空密码表示沿用原密码。
  String? get _passwordForSave =>
      _isEditing && _password.text.isEmpty ? null : _password.text;

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _error = null;
    });
    try {
      final service = ref.read(remoteLibraryServiceProvider);
      final rootPath = _rootPath.text.trim().isEmpty ? '/' : _rootPath.text.trim();
      if (_isEditing && _password.text.isEmpty) {
        // 编辑态密码留空：沿用存储密码，仅测试表单中改动的连接信息。
        await service.testSavedSource(
          widget.editing!.id,
          baseUrl: _baseUrl.text,
          username: _username.text,
          rootPath: rootPath,
        );
      } else {
        await service.testConnection(
          name: _name.text.trim().isEmpty ? '测试' : _name.text.trim(),
          baseUrl: _baseUrl.text.trim(),
          username: _username.text.trim(),
          password: _password.text,
          rootPath: rootPath,
        );
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('连接成功')));
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '连接失败：$e');
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = '请填写名称');
      return;
    }
    final url = _baseUrl.text.trim();
    if (!RegExp(r'^https?://').hasMatch(url)) {
      setState(() => _error = '服务器地址需以 http:// 或 https:// 开头');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final service = ref.read(remoteLibraryServiceProvider);
      await service.saveSource(
        id: widget.editing?.id,
        name: _name.text.trim(),
        baseUrl: url,
        username: _username.text.trim(),
        password: _passwordForSave,
        rootPath: _rootPath.text.trim().isEmpty ? '/' : _rootPath.text.trim(),
      );
      await ref.read(remoteLibraryProvider.notifier).refresh();
      if (!mounted) return;
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '保存失败：$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: scheme.outline.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text(_isEditing ? '编辑远程音乐库' : '添加 WebDAV 音乐库',
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 16),
            _field(controller: _name, label: '名称', hint: '如：我的 NAS 音乐'),
            const SizedBox(height: 12),
            _field(
                controller: _baseUrl,
                label: '服务器地址',
                hint: 'https://dav.example.com/dav',
                keyboard: TextInputType.url),
            const SizedBox(height: 12),
            _field(controller: _username, label: '用户名（可选）', hint: 'username'),
            const SizedBox(height: 12),
            _field(
              controller: _password,
              label: _isEditing ? '密码（留空保持不变）' : '密码（可选）',
              hint: 'password',
              obscure: _obscurePassword,
              onToggleObscure: () =>
                  setState(() => _obscurePassword = !_obscurePassword),
            ),
            const SizedBox(height: 12),
            _field(
                controller: _rootPath,
                label: '根目录',
                hint: '/',
                keyboard: TextInputType.text),
            const SizedBox(height: 6),
            Text(
              '从根目录开始递归扫描音频文件（mp3/flac/wav/m4a/aac/ogg/opus/aiff）',
              style: TextStyle(fontSize: 11, color: scheme.outline),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!,
                  style: TextStyle(fontSize: 12.5, color: scheme.error)),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _testing ? null : _test,
                    icon: _testing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.wifi_tethering, size: 18),
                    label: Text(_testing ? '测试中…' : '测试连接'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: _saving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.check, size: 18),
                    label: Text(_saving ? '保存中…' : '保存'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    String? hint,
    TextInputType? keyboard,
    bool obscure = false,
    VoidCallback? onToggleObscure,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return TextField(
      controller: controller,
      obscureText: obscure,
      keyboardType: keyboard,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        isDense: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.outline.withValues(alpha: 0.3)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.outline.withValues(alpha: 0.3)),
        ),
        suffixIcon: onToggleObscure == null
            ? null
            : IconButton(
                icon: Icon(obscure ? Icons.visibility_off : Icons.visibility,
                    size: 19),
                onPressed: onToggleObscure,
              ),
      ),
    );
  }
}
