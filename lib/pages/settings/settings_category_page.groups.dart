part of 'settings_category_page.dart';

class _StepperSliderRow extends StatelessWidget {
  const _StepperSliderRow({
    required this.slider,
    required this.enabled,
    required this.readValue,
    required this.step,
    required this.min,
    required this.max,
    required this.onAdjust,
    this.format,
    this.valueWidth = 40,
  });

  final Widget slider;
  final bool enabled;
  final double Function() readValue;
  final double step;
  final double min;
  final double max;
  final void Function(double value) onAdjust;
  final String Function(double)? format;
  final double valueWidth;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget stepButton(IconData icon, double delta) {
      return IconButton(
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints.tightFor(width: 30, height: 30),
        padding: EdgeInsets.zero,
        iconSize: 16,
        style: IconButton.styleFrom(
          backgroundColor: enabled
              ? scheme.surfaceContainerHighest
              : scheme.surfaceContainerHighest.withValues(alpha: 0.4),
          foregroundColor: enabled
              ? scheme.onSurfaceVariant
              : scheme.onSurfaceVariant.withValues(alpha: 0.45),
        ),
        icon: Icon(icon),
        onPressed: enabled
            ? () => onAdjust((readValue() + delta).clamp(min, max))
            : null,
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        stepButton(Icons.remove, -step),
        const SizedBox(width: 6),
        SizedBox(width: 120, child: slider),
        const SizedBox(width: 6),
        stepButton(Icons.add, step),
        if (format != null) ...[
          const SizedBox(width: 8),
          SizedBox(
            width: valueWidth,
            child: Text(
              format!(readValue()),
              textAlign: TextAlign.end,
              style: TextStyle(
                fontSize: 12.5,
                color: enabled
                    ? scheme.onSurface
                    : scheme.onSurface.withValues(alpha: 0.45),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _CardGroup extends ConsumerWidget {
  const _CardGroup({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final items = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      items.add(children[i]);
      if (i != children.length - 1) {
        items.add(
          Divider(
            height: 1,
            indent: 52,
            endIndent: 16,
            thickness: 0.5,
            color: scheme.onSurface.withValues(alpha: 0.08),
          ),
        );
      }
    }

    return frostedCardSurface(
      context: context,
      ref: ref,
      radius: 16,
      themeSlot: useLandscape(ref) ? 'ls-settings.detail' : null,
      child: Material(
        color: Colors.transparent,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide.none,
        ),
        child: Column(children: items),
      ),
    );
  }
}

class _ColorDot extends StatelessWidget {
  const _ColorDot({required this.color});
  final Color color;
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

class _StorageSettingsGroup extends ConsumerStatefulWidget {
  const _StorageSettingsGroup();

  @override
  ConsumerState<_StorageSettingsGroup> createState() =>
      _StorageSettingsGroupState();
}

class _StorageSettingsGroupState extends ConsumerState<_StorageSettingsGroup> {
  static const _kMinMB = 1;
  static const _kMaxMB = 10240;

  int? _currentBytes;
  int? _maxBytes;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final c = await frb.streamCacheCurrentBytes();
      final m = await frb.streamCacheMaxBytes();
      if (!mounted) return;
      setState(() {
        _currentBytes = c.toInt();
        _maxBytes = m.toInt();
      });
    } catch (_) {
    }
  }

  static String _fmtBytes(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) {
      return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  Future<void> _pickLimit() async {
    final s = ref.read(settingsProvider).valueOrNull;
    final notifier = ref.read(settingsProvider.notifier);
    final controller = TextEditingController(
      text: (s?.streamCacheSizeMB ?? 500).toString(),
    );
    var chosen = 0;
    await showPredictiveDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title:   Text(tr('播放缓存上限')),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration:   InputDecoration(
            hintText: tr('输入 1 - 10240 MB'),
            suffixText: ' MB',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child:   Text(tr('取消')),
          ),
          TextButton(
            onPressed: () {
              final v = int.tryParse(controller.text.trim());
              chosen = (v ?? 500).clamp(_kMinMB, _kMaxMB);
              Navigator.of(ctx).pop();
            },
            child:   Text(tr('确定')),
          ),
        ],
      ),
    );
    if (chosen <= 0) return;
    await notifier.setStreamCacheSizeMB(chosen);
    await frb.setStreamCacheMaxSizeBytes(
      bytes: BigInt.from(chosen * 1024 * 1024),
    );
    await _refresh();
  }

  Future<void> _clear() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await frb.clearStreamCache();
      await _refresh();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(settingsProvider).valueOrNull;
    final limitMB = s?.streamCacheSizeMB ?? 500;
    final cur = _currentBytes;
    final max = _maxBytes ?? limitMB * 1024 * 1024;
    final scheme = Theme.of(context).colorScheme;
    return _CardGroup(
      children: [
        ListTile(
          leading: const Icon(Icons.sd_storage_outlined),
          title:   Text(tr('播放缓存上限')),
          subtitle:   Text(tr('在线播放的临时音源文件最大缓存量')),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$limitMB MB',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(width: 4),
              Icon(Icons.chevron_right, size: 18, color: scheme.outline),
            ],
          ),
          onTap: _pickLimit,
        ),
        ListTile(
          leading: const Icon(Icons.cleaning_services_outlined),
          title:   Text(tr('清理播放缓存')),
          subtitle: Text(
            cur == null
                ? tr('读取中…')
                : tr('当前 {cur} / 上限 {max}', {'cur': _fmtBytes(cur), 'max': _fmtBytes(max)}),
          ),
          trailing: TextButton(
            onPressed: (cur ?? 0) == 0 ? null : _clear,
            child: Text(_busy ? tr('清理中…') : tr('清理')),
          ),
        ),
      ],
    );
  }
}

class _LogGroup extends ConsumerStatefulWidget {
  const _LogGroup();

  @override
  ConsumerState<_LogGroup> createState() => _LogGroupState();
}

class _LogGroupState extends ConsumerState<_LogGroup> {
  bool _busy = false;

  void _toast(String msg) {
    showXianYuToast(context, msg, duration: const Duration(seconds: 2));
  }

  Future<void> _export() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final manager = ApplicationLogManager.instance;
      final logs = ref.read(applicationLogsProvider);
      if (logs.isEmpty) {
        if (mounted) _toast(tr('暂无日志'));
        return;
      }
      final content = manager.formatExport(onlyErrors: false);
      final docs = await getApplicationDocumentsDirectory();
      final fileName = 'xianyu_all_logs_${DateTime.now().millisecondsSinceEpoch}.txt';
      final file = File('${docs.path}/$fileName');
      await file.writeAsString(content, flush: true);
      if (!mounted) return;
      _toast(tr('日志已导出'));
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)], text: tr('弦予音乐日志')),
      );
    } catch (e) {
      if (mounted) _toast(tr('导出失败：{e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clearLogs() async {
    if (_busy) return;
    if (ref.read(applicationLogsProvider).isEmpty) {
      _toast(tr('暂无日志'));
      return;
    }
    final confirmed = await showPredictiveDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title:   Text(tr('清理日志')),
        content:   Text(tr('确定要清空全部应用日志吗？此操作不可恢复。')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child:   Text(tr('取消')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child:   Text(tr('清理')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    ApplicationLogManager.instance.clear();
    if (mounted) _toast(tr('日志已清理'));
  }

  Widget _action(
    BuildContext context, {
    required IconData icon,
    required String title,
    VoidCallback? onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(icon, color: scheme.primary),
      title: Text(title),
      trailing: Icon(Icons.chevron_right,
          size: 18, color: scheme.outline),
      onTap: onTap,
    );
  }

  @override
  Widget build(BuildContext context) {
    final logs = ref.watch(applicationLogsProvider);
    return _CardGroup(
      children: [
        _action(
          context,
          icon: Icons.description_outlined,
          title: tr('导出日志（{n} 条）', {'n': logs.length}),
          onTap: _busy ? () {} : _export,
        ),
        _action(
          context,
          icon: Icons.delete_sweep_outlined,
          title: tr('清理日志'),
          onTap: _busy ? () {} : _clearLogs,
        ),
      ],
    );
  }
}

class _AppBackupGroup extends ConsumerStatefulWidget {
  const _AppBackupGroup();

  @override
  ConsumerState<_AppBackupGroup> createState() => _AppBackupGroupState();
}

class _AppBackupGroupState extends ConsumerState<_AppBackupGroup> {
  bool _busy = false;

  void _toast(String msg) {
    showXianYuToast(context, msg, duration: const Duration(seconds: 2));
  }

  Future<void> _exportBackup() async {
    if (_busy) return;
    final selection = await _pickExportSelection();
    if (selection == null || !mounted) return;

    setState(() => _busy = true);
    try {
      final service = ref.read(appBackupProvider);
      final json = await service.exportJson(
        includePlaylists: selection.$1,
        includeFavorites: selection.$2,
        includePlugins: selection.$3,
        includeSettings: selection.$4,
      );

      if (SafChannel.isSupported) {
        final treeUri = await SafChannel.chooseFolderTree(persist: false);
        if (treeUri == null || !mounted) return;
        final docId = await SafChannel.createTreeFile(
          treeUri,
          backupFileName(),
          json,
        );
        if (!mounted) return;
        if (docId.isEmpty) {
          _toast(tr('导出失败：无法写入所选文件夹'));
          return;
        }
        final folder = await SafChannel.friendlyTreeName(treeUri);
        if (mounted) _toast(tr('备份已导出到 {folder}', {'folder': folder}));
        return;
      }

      final docs = await getApplicationDocumentsDirectory();
      final path = await writeBackupFile(docs.path, json);
      if (!mounted) return;
      _toast(tr('备份已导出'));
      await SharePlus.instance.share(
        ShareParams(files: [XFile(path)], text: tr('弦予音乐应用备份')),
      );
    } catch (e) {
      if (!mounted) return;
      _toast(tr('导出失败：{e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<(bool, bool, bool, bool)?> _pickExportSelection() {
    var playlists = true;
    var favorites = true;
    var plugins = true;
    var settings = true;
    return showPredictiveDialog<(bool, bool, bool, bool)>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: Text(tr('导出应用备份')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tr('选择要导出到备份文件的内容，可单独开关每一项。'),
                style: const TextStyle(fontSize: 12.5),
              ),
              const SizedBox(height: 8),
              _backupCheck(
                  tr('歌单'), playlists, true, (v) => setDialog(() => playlists = v ?? false)),
              _backupCheck(
                  tr('收藏'), favorites, true, (v) => setDialog(() => favorites = v ?? false)),
              _backupCheck(
                  tr('插件'), plugins, true, (v) => setDialog(() => plugins = v ?? false)),
              _backupCheck(
                  tr('设置'), settings, true, (v) => setDialog(() => settings = v ?? false)),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr('取消')),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(ctx, (playlists, favorites, plugins, settings)),
              child: Text(tr('导出')),
            ),
          ],
        ),
      ),
    );
  }

  Future<String?> _askBackupPassword() async {
    final controller = TextEditingController();
    final result = await showPredictiveDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('加密备份')),
        content: TextField(
          controller: controller,
          obscureText: true,
          autofocus: true,
          decoration: InputDecoration(hintText: tr('输入导出时设置的密码')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('取消')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(
                ctx, controller.text.isEmpty ? null : controller.text),
            child: Text(tr('确认')),
          ),
        ],
      ),
    );
    return result;
  }

  Future<void> _importBackup() async {
    if (_busy) return;
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (files.isEmpty) return;
      final file = files.first;

      String content = '';
      final path = file.path ?? '';
      if (path.isNotEmpty && File(path).existsSync()) {
        content = await File(path).readAsString();
      } else {
        final bytes = await file.readAsBytes();
        if (bytes.isEmpty) {
          _toast(tr('无法读取所选文件'));
          return;
        }
        content = utf8.decode(bytes);
      }

      final service = ref.read(appBackupProvider);
      Map<String, dynamic> backup;
      try {
        backup = service.parse(content);
      } on BackupPasswordRequiredException {
        // 加密备份：先输入密码再解析
        final password = await _askBackupPassword();
        if (password == null) return;
        try {
          backup = service.parse(content, password: password);
        } on FormatException catch (e) {
          if (!mounted) return;
          _toast(e.message);
          return;
        }
      }
      final options = await _confirmBackupImport(service.summarize(backup));
      if (options == null) return;

      setState(() => _busy = true);
      final result = await service.import(backup, includePlaylists: options.$1,
          includeFavorites: options.$2, includePlugins: options.$3, includeSettings: options.$4);
      if (!mounted) return;
      final parts = <String>[
        if (options.$1) tr('歌单 {n}', {'n': result.importedPlaylists}),
        if (options.$2) tr('收藏 {n}', {'n': result.importedFavorites}),
        if (options.$3)
          tr('插件 {n}', {'n': result.importedPlugins}) + (result.skippedPlugins > 0 ? tr('（跳过 {n}）', {'n': result.skippedPlugins}) : ''),
        if (options.$4 && result.settingsApplied) tr('设置'),
      ];
      _toast(parts.isEmpty ? tr('未导入任何内容') : tr('导入完成：{parts}', {'parts': parts.join('，')}));
      if (result.errors.isNotEmpty && mounted) {
        await showPredictiveDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title:   Text(tr('部分内容导入失败')),
            content: SizedBox(
              width: double.maxFinite,
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final e in result.errors)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child:
                          Text(e, style: const TextStyle(fontSize: 12.5)),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child:   Text(tr('知道了')),
              ),
            ],
          ),
        );
      }
    } on FormatException catch (e) {
      if (!mounted) return;
      _toast(e.message);
    } catch (e) {
      if (!mounted) return;
      _toast(tr('导入失败：{e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<(bool, bool, bool, bool)?> _confirmBackupImport(
      AppBackupSummary summary) {
    var playlists = true;
    var favorites = true;
    var plugins = true;
    var settings = false;
    return showPredictiveDialog<(bool, bool, bool, bool)>(
            context: context,
            builder: (ctx) => StatefulBuilder(
              builder: (ctx, setDialog) => AlertDialog(
                title:   Text(tr('导入应用备份')),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (summary.createdAt.isNotEmpty)
                      Text(
                          tr('备份时间：{time}', {'time': summary.createdAt.length >= 19 ? summary.createdAt.substring(0, 19).replaceAll('T', ' ') : summary.createdAt}),
                          style: const TextStyle(fontSize: 12.5)),
                    const SizedBox(height: 6),
                    Text(
                      tr('歌单 {n} 个（{songs} 首）\n', {'n': summary.playlistCount, 'songs': summary.totalSongs}) +
                      tr('收藏 {n} 首、收藏集 {m} 个\n', {'n': summary.favoriteCount, 'm': summary.favoriteCollectionCount}) +
                      tr('插件 {n} 个', {'n': summary.pluginCount}) + (summary.hasSettings ? tr('\n含设置') : ''),
                      style: const TextStyle(fontSize: 12.5),
                    ),
                    const SizedBox(height: 10),
                      Text(tr('选择导入内容：'), style: TextStyle(fontSize: 12.5)),
                    _backupCheck(tr('歌单'), playlists, summary.playlistCount > 0,
                        (v) => setDialog(() => playlists = v ?? false)),
                    _backupCheck(tr('收藏'), favorites,
                        summary.favoriteCount + summary.favoriteCollectionCount > 0,
                        (v) => setDialog(() => favorites = v ?? false)),
                    _backupCheck(tr('插件'), plugins, summary.pluginCount > 0,
                        (v) => setDialog(() => plugins = v ?? false)),
                    _backupCheck(
                        tr('设置（覆盖当前设置）'),
                        settings,
                        summary.hasSettings,
                        (v) => setDialog(() => settings = v ?? false)),
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child:   Text(tr('取消')),
                  ),
                  FilledButton(
                    onPressed: () =>
                        Navigator.pop(ctx, (playlists, favorites, plugins, settings)),
                    child:   Text(tr('导入')),
                  ),
                ],
              ),
            ),
          );
  }

  Widget _backupCheck(
      String label, bool value, bool enabled, ValueChanged<bool?> onChanged) {
    return CheckboxListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      title: Text(label, style: const TextStyle(fontSize: 13.5)),
      value: value,
      onChanged: enabled ? onChanged : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final trailing = _busy
        ? const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Icon(Icons.chevron_right,
            size: 18, color: scheme.onSurfaceVariant);
    return _CardGroup(
      children: [
        ListTile(
          leading: const Icon(Icons.archive_outlined),
          title:   Text(tr('导出应用备份')),
          subtitle:   Text(tr('选择导出内容，每次指定文件夹保存')),
          trailing: trailing,
          onTap: _busy ? null : _exportBackup,
        ),
        ListTile(
          leading: const Icon(Icons.settings_backup_restore_outlined),
          title:   Text(tr('导入应用备份')),
          subtitle:   Text(tr('从备份文件恢复（支持选择导入内容）')),
          trailing: trailing,
          onTap: _busy ? null : _importBackup,
        ),
      ],
    );
  }
}
