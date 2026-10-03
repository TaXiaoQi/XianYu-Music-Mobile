part of 'plugin_page.dart';
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

extension _PluginPageInstall on _PluginPageState {
  void _showInstallSheet() {
    showSheetDialog<void>(
      context,
      (ctx) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
              Text(tr('安装插件'),
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 14),
            _InstallOption(
              icon: Icons.folder_open_outlined,
              title: tr('本地文件'),
              subtitle: tr('选择本地的插件脚本（.js / .txt）'),
              onTap: () {
                Navigator.pop(ctx);
                _pickLocalPlugin();
              },
            ),
            const SizedBox(height: 10),
            _InstallOption(
              icon: Icons.cloud_download_outlined,
              title: tr('在线链接'),
              subtitle: tr('输入 URL 安装，支持单个插件或插件集（JSON）批量'),
              onTap: () {
                Navigator.pop(ctx);
                _showUrlInstallSheet();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickLocalPlugin() async {
    if (_installing) return;
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['js', 'txt'],
    );
    if (files.isEmpty) return;
    for (final f in files) {
      if (!mounted) return;
      try {
        final bytes = await f.readAsBytes();
        if (!mounted) return;
        if (bytes.isEmpty) {
          showXianYuToast(context, tr('读取「{name}」失败或文件为空', {'name': f.name}));
          continue;
        }
        final script = utf8.decode(bytes, allowMalformed: true);
        await _install(script, f.name.isNotEmpty ? f.name : tr('本地插件'));
      } catch (e) {
        if (!mounted) return;
        showXianYuToast(context, tr('读取「{name}」失败：{e}', {'name': f.name, 'e': e}));
      }
    }
  }

  Future<void> _showUrlInstallSheet() async {
    await showSheetDialog<void>(
      context,
      (ctx) => _UrlInstallSheet(
        onInstallUrl: (url) => _installUrl(url),
        // 安装中返回/取消 = 终止导入：立即收起进度小黑条并中止后续步骤
        onCancel: _cancelUrlInstall,
      ),
    );
  }

  /// 返回 null 表示成功（关弹窗）；返回错误文案以便弹窗保留输入状态重试
  Future<String?> _installUrl(String url) async {
    if (url.trim().isEmpty) return tr('链接不能为空');
    _urlInstallCancelled = false;
    final progress = showXianYuProgressToast(context, tr('正在导入插件...'));
    _urlInstallProgress = progress;
    setState(() => _installing = true);
    try {
      final result = await ref
          .read(pluginManagerProvider.notifier)
          .installFromUrl(
            url,
            onProgress: (msg, p) => progress.update(msg, progress: p),
            cancelled: () => _urlInstallCancelled,
          );
      if (!mounted) return null;
      if (result.success) {
        final summary = result.failCount > 0
            ? tr('成功 {ok} 个，失败 {fail} 个', {'ok': result.names.length, 'fail': result.failCount})
            : tr('成功 {ok} 个：{names}', {'ok': result.names.length, 'names': result.names.join('、')});
        progress.complete(tr('插件安装完成，{summary}', {'summary': summary}));
        return null;
      }
      final detail = result.errors.isNotEmpty ? '（${result.errors.first}）' : '';
      final msg = tr('所有插件安装失败{detail}', {'detail': detail});
      progress.fail(msg);
      return msg;
    } on PluginInstallCancelled {
      // 用户已取消：弹窗与小黑条均已收起，静默终止，不再弹失败提示
      return null;
    } catch (e) {
      if (!mounted) return null;
      final msg = e is PluginEngineException ? e.message : e.toString();
      final text = tr('安装失败：{msg}', {'msg': msg});
      progress.fail(text);
      return text;
    } finally {
      if (mounted) setState(() => _installing = false);
    }
  }

  void _cancelUrlInstall() {
    _urlInstallCancelled = true;
    // 立即收起进度小黑条：取消后台安装的收尾由 cancelled 检查点兜底
    _urlInstallProgress?.close();
  }

  Future<void> _install(String script, String name) async {
    if (script.trim().isEmpty) return;
    setState(() => _installing = true);
    try {
      final source = await ref
          .read(pluginManagerProvider.notifier)
          .installFromScript(script, fileName: name);
      if (!mounted) return;
      showXianYuToast(context, tr('插件「{name}」安装成功', {'name': source.name}));
    } catch (e) {
      if (!mounted) return;
      final msg = e is PluginEngineException ? e.message : e.toString();
      showXianYuToast(context, tr('安装失败：{msg}', {'msg': msg}));
    } finally {
      if (mounted) setState(() => _installing = false);
    }
  }
}
