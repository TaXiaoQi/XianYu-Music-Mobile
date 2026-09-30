// 桌面联动设置区：SSDP 扫描发现桌面端 / 手动 IP:端口 / 配对码绑定 / 遥控面板。
// 嵌入 settings_category_page 的 desktop 分类（SettingsCategory.desktop）。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/desktop_link/desktop_link_provider.dart';
import '../../src/i18n/i18n.dart';
import '../../src/widgets/app_toast.dart';
import '../../src/widgets/glass_settings.dart';

class DesktopLinkSection extends ConsumerStatefulWidget {
  const DesktopLinkSection({super.key});

  @override
  ConsumerState<DesktopLinkSection> createState() => _DesktopLinkSectionState();
}

class _DesktopLinkSectionState extends ConsumerState<DesktopLinkSection> {
  String _formatDuration(double secs) {
    final s = secs < 0 ? 0 : secs.round();
    final m = s ~/ 60;
    return '$m:${(s % 60).toString().padLeft(2, '0')}';
  }

  Future<void> _pairWithCode(String host, int port) async {
    final code = await _askPairingCode();
    if (code == null || code.isEmpty) return;
    if (!mounted) return;
    await ref.read(desktopLinkProvider.notifier).connect(
          host: host,
          port: port,
          pairingCode: code,
        );
  }

  Future<String?> _askPairingCode() {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr('输入配对码')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              tr('在电脑端「设置 → 联动 → 桌面联动」中查看 6 位配对码'),
              style: Theme.of(dialogContext).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.number,
              maxLength: 6,
              decoration: InputDecoration(
                counterText: '',
                hintText: tr('6 位数字'),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(tr('取消')),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: Text(tr('连接')),
          ),
        ],
      ),
    );
  }

  Future<void> _askManualAddress() async {
    final controller = TextEditingController();
    final address = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr('手动连接桌面端')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              tr('输入电脑端显示的地址，如 192.168.1.5:9979'),
              style: Theme.of(dialogContext).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(hintText: '192.168.1.5:9979'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(tr('取消')),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: Text(tr('连接')),
          ),
        ],
      ),
    );
    if (address == null || address.isEmpty) return;
    final parts = address.split(':');
    final host = parts.first.trim();
    final port = parts.length > 1 ? int.tryParse(parts[1].trim()) : null;
    if (host.isEmpty || port == null || port <= 0 || port > 65535) {
      if (mounted) {
        showXianYuToast(context, tr('地址格式不正确'),
            duration: const Duration(seconds: 2));
      }
      return;
    }
    await _pairWithCode(host, port);
  }

  String _phaseLabel(DesktopLinkState s) => switch (s.phase) {
        DesktopLinkPhase.idle => s.hasSavedTarget
            ? tr('未连接')
            : tr('未连接，扫描或手动添加电脑端'),
        DesktopLinkPhase.connecting => tr('连接中…'),
        DesktopLinkPhase.pairing => tr('需要配对'),
        DesktopLinkPhase.reconnecting => tr('重连中…'),
        DesktopLinkPhase.connected =>
          tr('已连接 {name}', {'name': s.desktopName.isEmpty ? '${s.host}:${s.port}' : s.desktopName}),
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final link = ref.watch(desktopLinkProvider);
    final notifier = ref.read(desktopLinkProvider.notifier);
    final connected = link.phase == DesktopLinkPhase.connected;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
          child: Text(
            tr('桌面联动'),
            style: TextStyle(
              fontSize: 13,
              color: scheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: frostedCardSurface(
            context: context,
            ref: ref,
            radius: 16,
            child: Material(
              color: Colors.transparent,
              clipBehavior: Clip.antiAlias,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide.none,
              ),
              child: Column(
                children: [
                  _row(
                    icon: Icons.computer_outlined,
                    title: tr('连接状态'),
                    subtitle: link.message.isEmpty
                        ? _phaseLabel(link)
                        : '${_phaseLabel(link)} · ${link.message}',
                    trailing: const SizedBox.shrink(),
                  ),
                  _divider(),
                  _row(
                    icon: Icons.wifi_find_outlined,
                    title: tr('扫描局域网电脑'),
                    subtitle: link.scanning
                        ? tr('正在扫描…')
                        : tr('搜索同一网络下正在运行的弦予桌面端'),
                    trailing: link.scanning
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const SizedBox.shrink(),
                    showChevron: false,
                    onTap: link.scanning ? null : () => notifier.scan(),
                  ),
                  _divider(),
                  _row(
                    icon: Icons.edit_outlined,
                    title: tr('手动连接'),
                    subtitle: tr('输入电脑端显示的 IP 与端口'),
                    trailing: const SizedBox.shrink(),
                    showChevron: false,
                    onTap: _askManualAddress,
                  ),
                  if (link.hasSavedTarget) ...[
                    _divider(),
                    _row(
                      icon: Icons.link_off_outlined,
                      title: tr('忘记配对'),
                      subtitle: tr('清除已保存的电脑地址与授权'),
                      trailing: const SizedBox.shrink(),
                      showChevron: false,
                      onTap: () async {
                        final ctx = context;
                        await notifier.forgetTarget();
                        if (!ctx.mounted) return;
                        showXianYuToast(ctx, tr('已清除配对'),
                            duration: const Duration(seconds: 2));
                      },
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        // 扫描结果
        if (link.scanResults.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: frostedCardSurface(
              context: context,
              ref: ref,
              radius: 16,
              child: Material(
                color: Colors.transparent,
                clipBehavior: Clip.antiAlias,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide.none,
                ),
                child: Column(
                  children: [
                    for (var i = 0; i < link.scanResults.length; i++) ...[
                      if (i > 0) _divider(),
                      _row(
                        icon: Icons.desktop_windows_outlined,
                        title: link.scanResults[i].name,
                        subtitle:
                            '${link.scanResults[i].host}:${link.scanResults[i].port}',
                        trailing: connected &&
                                link.scanResults[i].host == link.host &&
                                link.scanResults[i].port == link.port
                            ? Icon(Icons.check_circle_outline,
                                size: 20, color: scheme.primary)
                            : const SizedBox.shrink(),
                        onTap: () => _pairWithCode(
                          link.scanResults[i].host,
                          link.scanResults[i].port,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        // 遥控面板
        if (connected) ...[
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: frostedCardSurface(
              context: context,
              ref: ref,
              radius: 16,
              child: Material(
                color: Colors.transparent,
                clipBehavior: Clip.antiAlias,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide.none,
                ),
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            link.remoteTitle.isEmpty
                                ? tr('电脑端未在播放')
                                : link.remoteTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          if (link.remoteArtist.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              link.remoteArtist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                          const SizedBox(height: 2),
                          Text(
                            '${_formatDuration(link.remotePosition)} / ${_formatDuration(link.remoteDuration)}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton(
                          tooltip: tr('上一首'),
                          onPressed: () => notifier.sendCmd('prev'),
                          icon: const Icon(Icons.skip_previous_outlined),
                        ),
                        const SizedBox(width: 8),
                        FilledButton.tonalIcon(
                          onPressed: () => notifier.sendCmd('toggle'),
                          icon: Icon(link.remotePlaying
                              ? Icons.pause_outlined
                              : Icons.play_arrow_outlined),
                          label: Text(link.remotePlaying
                              ? tr('暂停')
                              : tr('开始播放')),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          tooltip: tr('下一首'),
                          onPressed: () => notifier.sendCmd('next'),
                          icon: const Icon(Icons.skip_next_outlined),
                        ),
                      ],
                    ),
                    // 进度
                    if (link.remoteDuration > 0)
                      Slider(
                        value: link.remotePosition
                            .clamp(0, link.remoteDuration),
                        max: link.remoteDuration,
                        onChanged: (v) => {},
                        onChangeEnd: (v) =>
                            notifier.sendCmd('seek', {'pos': v}),
                      ),
                    // 音量
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                      child: Row(
                        children: [
                          Icon(Icons.volume_down_outlined,
                              size: 20, color: scheme.onSurfaceVariant),
                          Expanded(
                            child: Slider(
                              value: link.remoteVolume.clamp(0.0, 1.0),
                              onChanged: (v) =>
                                  notifier.sendCmd('volume', {'v': v}),
                            ),
                          ),
                          Icon(Icons.volume_up_outlined,
                              size: 20, color: scheme.onSurfaceVariant),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _row({
    required IconData icon,
    required String title,
    required String subtitle,
    required Widget trailing,
    bool showChevron = true,
    VoidCallback? onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Icon(icon, color: scheme.onSurfaceVariant),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Theme.of(context)
                        .textTheme
                        .bodyLarge
                        ?.copyWith(fontSize: 15),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            trailing,
            if (showChevron && onTap != null) ...[
              const SizedBox(width: 4),
              Icon(Icons.chevron_right,
                  size: 18, color: scheme.outline),
            ],
          ],
        ),
      ),
    );
  }

  Widget _divider() => Divider(
        height: 1,
        indent: 52,
        endIndent: 16,
        thickness: 0.5,
        color: Theme.of(context)
            .colorScheme
            .onSurface
            .withValues(alpha: 0.08),
      );
}
