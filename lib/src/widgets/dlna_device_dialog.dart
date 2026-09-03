import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../player/cast_provider.dart';
import '../player/player_provider.dart';
import 'app_toast.dart';
import 'modern_dialog.dart';
import 'predictive_dialog_route.dart';
import '../i18n/i18n.dart';

/// DLNA 设备弹窗：扫描局域网渲染器 → 连接 → 投屏态显示设备与断开。
///
/// 连接即投：若当前有正在播放/已暂停的歌曲，连接后立即把当前曲投到设备。
Future<void> showDlnaDeviceDialog(BuildContext context, WidgetRef ref) async {
  await showPredictiveDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (_) => const _DlnaDeviceDialog(),
  );
}

class _DlnaDeviceDialog extends ConsumerStatefulWidget {
  const _DlnaDeviceDialog();

  @override
  ConsumerState<_DlnaDeviceDialog> createState() => _DlnaDeviceDialogState();
}

class _DlnaDeviceDialogState extends ConsumerState<_DlnaDeviceDialog> {
  List<Map<String, dynamic>> _devices = [];
  bool _scanning = false;
  String? _connectingUdn;

  @override
  void initState() {
    super.initState();
    // 弹窗打开即扫描一次（若未在投屏态）。
    final cast = ref.read(dlnaCastProvider);
    if (!cast.isCasting) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scan());
    }
  }

  Future<void> _scan() async {
    if (_scanning) return;
    setState(() => _scanning = true);
    try {
      final devices =
          await ref.read(dlnaCastProvider.notifier).scanDevices();
      if (mounted) setState(() => _devices = devices);
    } catch (_) {
      if (mounted) {
        _devices = [];
        showXianYuToast(context, tr('设备扫描失败，请检查防火墙与网络设置'));
      }
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  /// 连接设备：连接成功后若当前有歌曲，立即投当前曲（播放中则保持进度续播）。
  Future<void> _connect(Map<String, dynamic> dev) async {
    final udn = dev['udn'] as String? ?? '';
    setState(() => _connectingUdn = udn);
    // await 期间弹窗可能被下滑/手势关闭，提前捕获 OverlayState 防 ctx 失效崩溃。
    final overlay = Overlay.of(context, rootOverlay: true);
    // 连接前快照：connect() 会静默本地引擎，之后进度以快照为准。
    final st = ref.read(playerProvider);
    final current = st.current;
    final wasPlaying = st.isPlaying;
    final resumeAt = st.position;
    try {
      final cast = ref.read(dlnaCastProvider.notifier);
      await cast.connect(dev);
      if (current != null) {
        final media =
            await ref.read(playerProvider.notifier).resolveForCast(current);
        if (media == null) {
          showXianYuToastByOverlay(overlay, tr('无法获取播放链接'));
          return;
        }
        await cast.castMedia(
          title: current.title,
          artist: current.artist,
          album: current.album,
          url: media.url,
          isRemote: media.isRemote,
          headers: media.headers,
          durationMs: current.durationMs,
          startAtSecs: wasPlaying ? resumeAt : 0,
          coverUrl: current.coverUrl,
        );
      }
    } catch (e) {
      showXianYuToastByOverlay(
          overlay, tr('连接「{name}」失败', {'name': dev['friendly_name'] ?? ''}));
    } finally {
      if (mounted) setState(() => _connectingUdn = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cast = ref.watch(dlnaCastProvider);
    final scheme = Theme.of(context).colorScheme;

    return ModernDialogCard(
      child: cast.isCasting
          ? _buildConnected(context, cast, scheme)
          : _buildDeviceList(context, scheme),
    );
  }

  // ---------------- 已连接态 ----------------

  Widget _buildConnected(BuildContext context, CastState cast, ColorScheme scheme) {
    final playing = cast.tvState == 'PLAYING';
    final paused = cast.tvState == 'PAUSED_PLAYBACK';
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.cast, size: 18, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  tr('DLNA 投屏'),
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                  color: scheme.primary.withValues(alpha: 0.18)),
            ),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.tv, size: 20, color: scheme.primary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        cast.deviceName,
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        (cast.deviceModel.isEmpty
                                ? tr('DLNA 设备')
                                : cast.deviceModel) +
                            (playing
                                ? ' · ${tr('播放中')}'
                                : paused
                                    ? ' · ${tr('已暂停')}'
                                    : ''),
                        style: TextStyle(
                            fontSize: 11,
                            color: scheme.onSurfaceVariant),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Text(
            tr('本端播放将自动投到设备，播放/暂停/进度/音量即遥控该设备。'),
            style: TextStyle(
                fontSize: 11, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: () {
                Navigator.of(context).pop();
                unawaited(ref.read(dlnaCastProvider.notifier).disconnect());
              },
              child: Text(tr('断开投屏')),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------- 设备列表态 ----------------

  Widget _buildDeviceList(BuildContext context, ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.cast, size: 18, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  tr('DLNA 投屏'),
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
              TextButton.icon(
                onPressed: _scanning ? null : _scan,
                icon: _scanning
                    ? SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: scheme.primary))
                    : const Icon(Icons.refresh, size: 14),
                label: Text(tr('扫描'), style: const TextStyle(fontSize: 12)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 280),
            child: SingleChildScrollView(
              child: _buildDeviceItems(scheme),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceItems(ColorScheme scheme) {
    if (_scanning && _devices.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 28),
        child: Column(
          children: [
            const CircularProgressIndicator(strokeWidth: 2.4),
            const SizedBox(height: 12),
            Text(tr('正在扫描局域网设备…'),
                style: TextStyle(
                    fontSize: 12, color: scheme.onSurfaceVariant)),
          ],
        ),
      );
    }
    if (_devices.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 8),
        child: Column(
          children: [
            Icon(Icons.cast, size: 30, color: scheme.onSurfaceVariant.withValues(alpha: 0.5)),
            const SizedBox(height: 10),
            Text(
              tr('未发现设备\n请确认电视/音箱已开启 DLNA 且与本机同一网络'),
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 12, color: scheme.onSurfaceVariant, height: 1.5),
            ),
          ],
        ),
      );
    }
    return Column(
      children: [
        for (final dev in _devices)
          _DeviceTile(
            device: dev,
            connecting: _connectingUdn == (dev['udn'] ?? ''),
            onTap: () => _connect(dev),
          ),
      ],
    );
  }
}

class _DeviceTile extends StatelessWidget {
  const _DeviceTile({
    required this.device,
    required this.connecting,
    required this.onTap,
  });

  final Map<String, dynamic> device;
  final bool connecting;
  final VoidCallback onTap;

  IconData get _icon {
    final model = (device['model_name'] as String? ?? '').toLowerCase();
    if (model.contains('speaker') || model.contains('audio')) {
      return Icons.speaker;
    }
    if (model.contains('tv') || model.contains('电视')) return Icons.tv;
    return Icons.cast;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final name = device['friendly_name'] as String? ?? '';
    final model = device['model_name'] as String? ?? '';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: scheme.onSurface.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: connecting ? null : onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: scheme.onSurface.withValues(alpha: 0.05),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(_icon, size: 17, color: scheme.onSurfaceVariant),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name,
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w500),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      if (model.isNotEmpty) ...[
                        const SizedBox(height: 1),
                        Text(model,
                            style: TextStyle(
                                fontSize: 10,
                                color: scheme.onSurfaceVariant),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                      ],
                    ],
                  ),
                ),
                if (connecting)
                  SizedBox(
                      width: 15,
                      height: 15,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: scheme.primary)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
