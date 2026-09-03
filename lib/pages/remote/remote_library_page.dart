import 'package:xianyu_music_mobile/src/widgets/predictive_dialog_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/library/library_provider.dart';
import '../../src/remote/remote_library_service.dart';
import '../../src/widgets/bottom_play_bar_slot.dart';
import '../../src/widgets/glass_appbar.dart';
import '../../src/widgets/sheet_dialog.dart';
import '../../src/core/app_colors.dart';
import '../../src/widgets/app_toast.dart';
import '../../src/i18n/i18n.dart';

/// 远程音乐库管理页：WebDAV 源的添加/编辑/同步/删除与缓存管理。
class RemoteLibraryPage extends ConsumerWidget {
  const RemoteLibraryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final state = ref.watch(remoteLibraryProvider);

    return Scaffold(
      backgroundColor: appScaffoldBackground(context, ref),
      resizeToAvoidBottomInset: false,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showSourceEditor(context, ref),
        icon: const Icon(Icons.add),
        label:   Text(tr('添加 WebDAV 音乐库')),
      ),
      body: Stack(
        children: [
          Padding(
            padding: EdgeInsets.only(top: GlassTopBar.height(context)),
            child: RepaintBoundary(child: Stack(
              children: [
                ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 4, bottom: 10),
                      child: Text(
                        tr('挂载 WebDAV 服务器上的音乐，同步后远程歌曲会加入本地曲库；播放时优先使用缓存，未缓存则在线流式播放'),
                        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                      ),
                    ),
                    if (state.sources.isEmpty && !state.loading)
                      _buildEmptyHint(context, scheme)
                    else
                      for (final source in state.sources)
                        _SourceCard(source: source),
                    const SizedBox(height: 20),
                    _buildCacheCard(context, ref, state),
                  ],
                ),
                const BottomPlayBarSlot(),
              ],
            )),
          ),
          Positioned(
            top: 0, left: 0, right: 0,
            child: GlassTopBar(
              leading: const BackButton(),
              title:   Text(tr('远程音乐库 (WebDAV)')),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyHint(BuildContext context, ColorScheme scheme) => Container(
        padding: const EdgeInsets.symmetric(vertical: 36),
        decoration: BoxDecoration(
          color: appCardColor(context),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          children: [
            Icon(Icons.cloud_off_outlined,
                size: 44, color: scheme.outline.withValues(alpha: 0.6)),
            const SizedBox(height: 12),
            Text(tr('还没有远程音乐库'),
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurfaceVariant)),
            const SizedBox(height: 4),
            Text(tr('点击下方按钮添加 WebDAV 服务器'),
                style: TextStyle(fontSize: 12, color: scheme.outline)),
          ],
        ),
      );

  Widget _buildCacheCard(
      BuildContext context, WidgetRef ref, RemoteLibraryState state) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
      decoration: BoxDecoration(
        color: appCardColor(context),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.cached_outlined),
            title:   Text(tr('远程音频缓存'),
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
                          title: tr('清理远程缓存'),
                          message: tr('将删除全部已缓存的远程音频文件（不影响远程源配置与曲库记录），正在播放的远程歌曲可能中断。'),
                        );
                        if (ok != true) return;
                        try {
                          await ref
                              .read(remoteLibraryProvider.notifier)
                              .clearCache();
                          if (context.mounted) {
                            showXianYuToast(context, tr('远程缓存已清理'));
                          }
                        } catch (e) {
                          if (context.mounted) {
                            showXianYuToast(context, tr('清理失败：{e}', {'e': e}));
                          }
                        }
                      },
                icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                label:   Text(tr('清理缓存')),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 添加/编辑远程源表单（居中弹窗）。
  Future<void> _showSourceEditor(BuildContext context, WidgetRef ref,
      {RemoteSourceInfo? editing}) {
    return showSheetDialog<void>(
      context,
      (_) => _SourceEditorSheet(editing: editing),
    );
  }

  Future<bool?> _confirm(BuildContext context,
      {required String title, required String message}) {
    return showPredictiveDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child:   Text(tr('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child:   Text(tr('确定')),
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
        color: appCardColor(context),
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
                  child: Text(tr('已启用'),
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
                  child: Text(tr('已停用'),
                      style: TextStyle(
                          fontSize: 10.5, color: scheme.onSurfaceVariant)),
                ),
              PopupMenuButton<String>(
                icon: Icon(Icons.more_vert,
                    size: 20, color: scheme.onSurfaceVariant),
                onSelected: (v) => _onMenu(context, ref, v),
                itemBuilder: (_) =>   [
                  PopupMenuItem(value: 'edit', child: Text(tr('编辑'))),
                  PopupMenuItem(value: 'remove', child: Text(tr('删除'))),
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
                label: Text(syncing ? tr('同步中…') : tr('同步')),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _onMenu(BuildContext context, WidgetRef ref, String action) async {
    if (action == 'edit') {
      await showSheetDialog<void>(
        context,
        (_) => _SourceEditorSheet(editing: source),
      );
    } else if (action == 'remove') {
      final ok = await showPredictiveDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title:   Text(tr('删除远程源')),
          content: Text(
              '将删除「${source.name}」及其在曲库中的全部远程歌曲（不删除服务器上的文件）。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child:   Text(tr('取消')),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(ctx).colorScheme.error),
              onPressed: () => Navigator.pop(ctx, true),
              child:   Text(tr('删除')),
            ),
          ],
        ),
      );
      if (ok != true) return;
      try {
        await ref.read(remoteLibraryProvider.notifier).remove(source.id);
        ref.read(libraryProvider.notifier).load();
        if (context.mounted) {
          showXianYuToast(context, tr('远程源已删除'));
        }
      } catch (e) {
        if (context.mounted) {
          showXianYuToast(context, tr('删除失败：{e}', {'e': e}));
        }
      }
    }
  }

  Future<void> _sync(BuildContext context, WidgetRef ref) async {
    try {
      final message =
          await ref.read(remoteLibraryProvider.notifier).sync(source.id);
      // 同步写入曲库后刷新音乐库列表。
      ref.read(libraryProvider.notifier).load();
      if (context.mounted) showXianYuToast(context, message);
    } catch (e) {
      // 刷新以显示 lastSyncError。
      ref.read(remoteLibraryProvider.notifier).refresh();
      if (context.mounted) showXianYuToast(context, tr('同步失败：{e}', {'e': e}));
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
          name: _name.text.trim().isEmpty ? tr('测试') : _name.text.trim(),
          baseUrl: _baseUrl.text.trim(),
          username: _username.text.trim(),
          password: _password.text,
          rootPath: rootPath,
        );
      }
      if (!mounted) return;
      showXianYuToast(context, tr('连接成功'));
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = tr('连接失败：{e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  /// 浏览远程目录并选取根目录。
  ///
  /// 编辑态密码留空：沿用存储密码浏览已保存源；其余按表单连接信息浏览
  /// （新增源未保存也能浏览）。
  Future<void> _browseRoot() async {
    final url = _baseUrl.text.trim();
    if (!RegExp(r'^https?://').hasMatch(url)) {
      setState(() => _error = tr('请先填写以 http:// 或 https:// 开头的服务器地址'));
      return;
    }
    final service = ref.read(remoteLibraryServiceProvider);
    Future<List<RemoteDirEntryInfo>> fetcher(String path) async {
      if (_isEditing && _password.text.isEmpty) {
        return service.listDirectory(widget.editing!.id, path);
      }
      return service.browseDirectory(
        baseUrl: url,
        username: _username.text.trim(),
        password: _password.text,
        path: path,
      );
    }

    final picked = await showSheetDialog<String>(
      context,
      (_) => _RemoteDirBrowserSheet(
        fetcher: fetcher,
        initialPath: _rootPath.text.trim().isEmpty ? '/' : _rootPath.text.trim(),
      ),
      barrierDismissible: false,
    );
    if (picked == null || picked.isEmpty) return;
    if (mounted) setState(() => _rootPath.text = picked);
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = tr('请填写名称'));
      return;
    }
    final url = _baseUrl.text.trim();
    if (!RegExp(r'^https?://').hasMatch(url)) {
      setState(() => _error = tr('服务器地址需以 http:// 或 https:// 开头'));
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
      setState(() => _error = tr('保存失败：{e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      // 键盘避让由 showSheetDialog 的 DialogKeyboardLift 统一处理，这里固定布局
      padding: EdgeInsets.zero,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
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
            Text(_isEditing ? tr('编辑远程音乐库') : tr('添加 WebDAV 音乐库'),
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 16),
            _field(controller: _name, label: tr('名称'), hint: tr('如：我的 NAS 音乐')),
            const SizedBox(height: 12),
            _field(
                controller: _baseUrl,
                label: tr('服务器地址'),
                hint: 'https://dav.example.com/dav',
                keyboard: TextInputType.url),
            const SizedBox(height: 12),
            _field(controller: _username, label: tr('用户名（可选）'), hint: 'username'),
            const SizedBox(height: 12),
            _field(
              controller: _password,
              label: _isEditing ? tr('密码（留空保持不变）') : tr('密码（可选）'),
              hint: 'password',
              obscure: _obscurePassword,
              onToggleObscure: () =>
                  setState(() => _obscurePassword = !_obscurePassword),
            ),
            const SizedBox(height: 12),
            _field(
                controller: _rootPath,
                label: tr('根目录'),
                hint: '/',
                keyboard: TextInputType.text,
                suffix: IconButton(
                  icon: const Icon(Icons.folder_open_outlined, size: 20),
                  tooltip: tr('浏览目录'),
                  onPressed: _browseRoot,
                )),
            const SizedBox(height: 6),
            Text(
              tr('从根目录开始递归扫描音频文件（含 ape/wv/dsf/dff，远程 DSD 需 USB 独占直通）'),
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
                    label: Text(_testing ? tr('测试中…') : tr('测试连接')),
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
                    label: Text(_saving ? tr('保存中…') : tr('保存')),
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
    Widget? suffix,
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
        suffixIcon: onToggleObscure != null
            ? IconButton(
                icon: Icon(obscure ? Icons.visibility_off : Icons.visibility,
                    size: 19),
                onPressed: onToggleObscure,
              )
            : suffix,
      ),
    );
  }
}

/// 远程目录浏览弹窗：逐级进入子目录，选取作为 WebDAV 根目录。
class _RemoteDirBrowserSheet extends StatefulWidget {
  const _RemoteDirBrowserSheet({
    required this.fetcher,
    required this.initialPath,
  });

  final Future<List<RemoteDirEntryInfo>> Function(String path) fetcher;
  final String initialPath;

  @override
  State<_RemoteDirBrowserSheet> createState() => _RemoteDirBrowserSheetState();
}

class _RemoteDirBrowserSheetState extends State<_RemoteDirBrowserSheet> {
  late String _path = widget.initialPath;
  List<RemoteDirEntryInfo> _dirs = const [];
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await widget.fetcher(_path);
      if (!mounted) return;
      final dirs = entries.where((e) => e.isDir).toList()
        ..sort((a, b) =>
            a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      setState(() => _dirs = dirs);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = tr('加载失败：{e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 上级目录：去掉末尾段；根目录的上级仍是根目录。
  String get _parentPath {
    var p = _path;
    if (p.isEmpty || p == '/') return '/';
    if (p.endsWith('/')) p = p.substring(0, p.length - 1);
    final idx = p.lastIndexOf('/');
    return idx <= 0 ? '/' : p.substring(0, idx);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tr('选择根目录'),
                  style:
                      const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Row(
                children: [
                  if (_path != '/' && _path.isNotEmpty)
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.arrow_upward, size: 20),
                      tooltip: tr('上级目录'),
                      onPressed: _loading ? null : () {
                        setState(() => _path = _parentPath);
                        _load();
                      },
                    ),
                  Expanded(
                    child: Text(
                      _path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12.5, color: scheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        Flexible(
          child: SizedBox(
            width: double.maxFinite,
            height: 320,
            child: _loading
                ? const Center(
                    child: SizedBox(
                        width: 26,
                        height: 26,
                        child: CircularProgressIndicator(strokeWidth: 2.4)))
                : _error != null
                    ? Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Center(
                          child: Text(_error!,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  fontSize: 12.5, color: scheme.error)),
                        ),
                      )
                    : _dirs.isEmpty
                        ? Center(
                            child: Text(tr('此目录下没有子目录'),
                                style: TextStyle(
                                    fontSize: 12.5,
                                    color: scheme.onSurfaceVariant)),
                          )
                        : ListView.builder(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 8),
                            itemCount: _dirs.length,
                            itemBuilder: (_, i) {
                              final dir = _dirs[i];
                              return ListTile(
                                dense: true,
                                leading: Icon(Icons.folder_outlined,
                                    size: 22, color: scheme.primary),
                                title: Text(dir.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 14)),
                                trailing: const Icon(Icons.chevron_right,
                                    size: 20),
                                onTap: () {
                                  setState(() => _path = dir.remotePath);
                                  _load();
                                },
                              );
                            },
                          ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(tr('取消')),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _loading
                      ? null
                      : () => Navigator.pop(context, _path),
                  icon: const Icon(Icons.check, size: 18),
                  label: Text(tr('选择此目录')),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
