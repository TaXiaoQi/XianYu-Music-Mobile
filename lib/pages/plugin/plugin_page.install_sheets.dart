part of 'plugin_page.dart';

class _UrlInstallSheet extends StatefulWidget {
  const _UrlInstallSheet({
    required this.onInstallUrl,
    this.onCancel,
  });
  final Future<String?> Function(String url) onInstallUrl;

  /// 安装进行中用户返回/点取消时触发：终止后台导入并收起进度小黑条
  final VoidCallback? onCancel;

  @override
  State<_UrlInstallSheet> createState() => _UrlInstallSheetState();
}

class _UrlInstallSheetState extends State<_UrlInstallSheet> {
  final _urlCtrl = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _urlCtrl.dispose();
    super.dispose();
  }

  Future<void> _installFromUrl() async {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty || _loading) return;
    // 点击安装先主动失焦：输入框 autofocus 拿走的焦点若残留到弹窗
    // 关闭转场之后，键盘会被再次拉起；统一在发起安装时收起键盘
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _loading = true;
      _error = null;
    });
    final error = await widget.onInstallUrl(url);
    if (!mounted) return;
    if (error == null) {
      Navigator.pop(context);
    } else {
      // 失败：保留已输入链接便于重试（键盘已随失焦收起，错误原因显示在弹窗内）
      setState(() {
        _loading = false;
        _error = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopScope(
      // 安装中允许返回，但返回语义 = 取消导入（终止后台安装并收起小黑条），
      // 避免出现“弹窗已关、导入仍在跑、小黑条永不消失且无法取消”的死状态
      onPopInvokedWithResult: (didPop, _) {
        if (didPop && _loading) widget.onCancel?.call();
      },
      child: SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
              Text(tr('在线链接安装'),
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(
              tr('支持 LX（落雪）与 MusicFree 格式，链接可为单个插件或插件集（JSON）'),
              style: TextStyle(fontSize: 12, color: scheme.outline),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _urlCtrl,
              autofocus: true,
              decoration:   InputDecoration(
                labelText: tr('插件 URL'),
                border: OutlineInputBorder(),
                isDense: true,
              ),
              keyboardType: TextInputType.url,
              onSubmitted: (_) => _installFromUrl(),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(fontSize: 12, color: scheme.error),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () {
                    if (_loading) widget.onCancel?.call();
                    Navigator.pop(context);
                  },
                  child:   Text(tr('取消')),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _loading ? null : _installFromUrl,
                  icon: _loading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.download, size: 18),
                  label:   Text(tr('安装')),
                ),
              ],
            ),
          ],
        ),
      ),
      ),
    );
  }
}

class _InstallOption extends ConsumerWidget {
  const _InstallOption({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: appCardFill(context, ref),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide.none,
      ),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, size: 20, color: scheme.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: const TextStyle(
                            fontSize: 14.5, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(subtitle,
                        style: TextStyle(
                            fontSize: 12, color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, size: 20, color: scheme.outline),
            ],
          ),
        ),
      ),
    );
  }
}
