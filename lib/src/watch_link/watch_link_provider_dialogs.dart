part of 'watch_link_provider.dart';

class _TransferConfirmDialog extends StatelessWidget {
  const _TransferConfirmDialog({required this.watchName});

  final String watchName;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = scheme.primary;
    return ModernDialogCard(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.watch_outlined, color: accent, size: 22),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    tr('传递给腕上设备'),
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              tr('是否将当前播放传递给 {name}？', {
                'name': watchName.isEmpty ? tr('腕上设备') : watchName,
              }),
              style: TextStyle(
                fontSize: 14,
                height: 1.45,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => Navigator.of(context).pop('device'),
                icon: const Icon(Icons.check_circle_outline, size: 18),
                label: Text(tr('允许该设备')),
                style: FilledButton.styleFrom(
                  backgroundColor: accent,
                  foregroundColor: scheme.onPrimary,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => Navigator.of(context).pop('once'),
                icon: const Icon(Icons.schedule, size: 18),
                label: Text(tr('允许本次')),
                style: OutlinedButton.styleFrom(
                  foregroundColor: accent,
                  side: BorderSide(color: accent.withValues(alpha: 0.45)),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop('never'),
                style: TextButton.styleFrom(
                  foregroundColor: scheme.onSurfaceVariant,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(tr('不允许')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _IncomingBackupDialog extends StatefulWidget {
  const _IncomingBackupDialog({
    required this.fileName,
    required this.content,
  });

  final String fileName;
  final String content;

  @override
  State<_IncomingBackupDialog> createState() => _IncomingBackupDialogState();
}

class _IncomingBackupDialogState extends State<_IncomingBackupDialog> {
  bool _saving = false;

  bool _sharing = false;

  String? _error;

  bool get _busy => _saving || _sharing;

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      String? saved;
      if (SafChannel.isSupported) {
        // 安卓：可自选保存位置
        final treeUri = await SafChannel.chooseFolderTree(persist: false);
        if (treeUri == null) return;
        final docId = await SafChannel.createTreeFile(
            treeUri, widget.fileName, widget.content);
        saved = docId.isEmpty ? null : widget.fileName;
      } else {
        final docs = await getApplicationDocumentsDirectory();
        final dir = Directory('${docs.path}/backups');
        if (!dir.existsSync()) dir.createSync(recursive: true);
        final path = '${dir.path}${Platform.pathSeparator}${widget.fileName}';
        await File(path).writeAsString(widget.content, flush: true);
        saved = widget.fileName;
      }
      if (saved != null) {
        if (mounted) Navigator.of(context).pop('saved');
        return;
      }
      setState(() => _error = tr('无法写入所选文件夹'));
    } catch (e) {
      setState(() => _error = tr('保存失败：{e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _share() async {
    if (_sharing) return;
    setState(() {
      _sharing = true;
      _error = null;
    });
    try {
      final docs = await getApplicationDocumentsDirectory();
      final file =
          File('${docs.path}${Platform.pathSeparator}${widget.fileName}');
      await file.writeAsString(widget.content, flush: true);
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)], text: tr('弦予音乐腕上端备份')),
      );
      if (mounted) Navigator.of(context).pop('saved');
    } catch (e) {
      setState(() => _error = tr('分享失败：{e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  void _cancel() => Navigator.of(context).pop('cancelled');

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = scheme.primary;
    final sizeKb = (utf8.encode(widget.content).length / 1024).truncate();
    return ModernDialogCard(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.settings_backup_restore_rounded,
                      color: accent, size: 22),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    tr('收到腕上备份'),
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              tr('腕上设备推送了一份应用备份，可保存到手机或一键分享。'),
              style: TextStyle(
                fontSize: 14,
                height: 1.45,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Icon(Icons.insert_drive_file_outlined,
                      size: 18, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (sizeKb > 0) ...[
              const SizedBox(height: 4),
              Text(
                tr('约 {kb} KB', {'kb': sizeKb}),
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(fontSize: 12.5, color: scheme.error),
              ),
            ],
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _save,
                    icon: _saving
                        ? SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: scheme.onPrimary))
                        : const Icon(Icons.save_alt, size: 18),
                    label: Text(_saving ? tr('保存中…') : tr('保存文件')),
                    style: FilledButton.styleFrom(
                      backgroundColor: accent,
                      foregroundColor: scheme.onPrimary,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _share,
                    icon: _sharing
                        ? SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.share_outlined, size: 18),
                    label: Text(_sharing ? tr('分享中…') : tr('一键分享')),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: accent,
                      side: BorderSide(color: accent.withValues(alpha: 0.5)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: _busy ? null : _cancel,
                style: TextButton.styleFrom(
                  foregroundColor: scheme.onSurfaceVariant,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(tr('取消')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _IncomingLogDialog extends StatefulWidget {
  const _IncomingLogDialog({
    required this.fileName,
    required this.content,
  });

  final String fileName;

  final String content;

  @override
  State<_IncomingLogDialog> createState() => _IncomingLogDialogState();
}

class _IncomingLogDialogState extends State<_IncomingLogDialog> {
  bool _sharing = false;

  String? _error;

  Future<void> _share() async {
    if (_sharing) return;
    setState(() {
      _sharing = true;
      _error = null;
    });
    try {
      final docs = await getApplicationDocumentsDirectory();
      final file =
          File('${docs.path}${Platform.pathSeparator}${widget.fileName}');
      await file.writeAsString(widget.content, flush: true);
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)], text: tr('弦予音乐腕上端日志')),
      );
      if (mounted) Navigator.of(context).pop('saved');
    } catch (e) {
      setState(() => _error = tr('分享失败：{e}', {'e': e}));
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  void _cancel() => Navigator.of(context).pop('cancelled');

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = scheme.primary;
    final sizeKb = (utf8.encode(widget.content).length / 1024).truncate();
    return ModernDialogCard(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.article_outlined, color: accent, size: 22),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    tr('收到腕上日志'),
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              tr('腕上设备推送了一份运行日志，可直接通过系统分享面板发给开发者或自行留存。'),
              style: TextStyle(
                fontSize: 14,
                height: 1.45,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Icon(Icons.insert_drive_file_outlined,
                      size: 18, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (sizeKb > 0) ...[
              const SizedBox(height: 4),
              Text(
                tr('约 {kb} KB', {'kb': sizeKb}),
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(fontSize: 12.5, color: scheme.error),
              ),
            ],
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _sharing ? null : _share,
                icon: _sharing
                    ? SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: scheme.onPrimary))
                    : const Icon(Icons.share_outlined, size: 18),
                label: Text(_sharing ? tr('分享中…') : tr('分享日志')),
                style: FilledButton.styleFrom(
                  backgroundColor: accent,
                  foregroundColor: scheme.onPrimary,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: _sharing ? null : _cancel,
                style: TextButton.styleFrom(
                  foregroundColor: scheme.onSurfaceVariant,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(tr('取消')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
