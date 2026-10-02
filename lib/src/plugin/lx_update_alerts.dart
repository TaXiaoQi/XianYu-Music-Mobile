import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/application_logger.dart';
import '../i18n/i18n.dart';
import '../navigation/routes.dart';
import '../widgets/app_toast.dart';
import 'plugin_models.dart';
import 'plugin_provider.dart';
import 'plugin_updates.dart';

/// LX 插件自报更新事件流（源自引擎 load/call 结果）。
final lxUpdateAlertEventsProvider = StreamProvider<LxUpdateAlertPayload>((ref) async* {
  final engine = await ref.watch(pluginEngineProvider.future);
  yield* engine.lxUpdateAlertStream;
});

/// 待展示的自报更新队列（会话内按指纹去重，弹窗逐条消化）。
class LxUpdateAlertQueue extends StateNotifier<List<LxUpdateAlertPayload>> {
  LxUpdateAlertQueue() : super(const []);

  final Set<String> _seen = {};

  void enqueue(LxUpdateAlertPayload payload) {
    if (payload.pluginId.isEmpty || !_seen.add(payload.fingerprint)) return;
    state = [...state, payload];
  }

  void dismissHead() {
    if (state.isEmpty) return;
    state = state.sublist(1);
  }
}

final lxUpdateAlertQueueProvider =
    StateNotifierProvider<LxUpdateAlertQueue, List<LxUpdateAlertPayload>>((ref) {
  final queue = LxUpdateAlertQueue();
  ref.listen<AsyncValue<LxUpdateAlertPayload>>(
      lxUpdateAlertEventsProvider, (prev, next) {
    final payload = next.valueOrNull;
    if (payload != null) queue.enqueue(payload);
  });
  return queue;
});

/// LX 插件自报更新提示宿主：挂在 MaterialApp builder 顶层 Stack，
/// 队列非空时逐条弹出确认弹窗。
class LxUpdateAlertHost extends ConsumerStatefulWidget {
  const LxUpdateAlertHost({super.key});

  @override
  ConsumerState<LxUpdateAlertHost> createState() => _LxUpdateAlertHostState();
}

class _LxUpdateAlertHostState extends ConsumerState<LxUpdateAlertHost> {
  bool _showing = false;

  @override
  Widget build(BuildContext context) {
    ref.listen<List<LxUpdateAlertPayload>>(
        lxUpdateAlertQueueProvider, (prev, next) {
      if (!_showing && next.isNotEmpty) {
        _showing = true;
        _showNext();
      }
    });
    return const SizedBox.shrink();
  }

  Future<void> _showNext() async {
    final queue = ref.read(lxUpdateAlertQueueProvider.notifier);
    final alerts = ref.read(lxUpdateAlertQueueProvider);
    if (alerts.isEmpty) {
      _showing = false;
      return;
    }
    final alert = alerts.first;
    try {
      final navigator = appNavigatorKey.currentState;
      if (navigator == null) {
        _showing = false;
        return;
      }
      await showDialog<void>(
        context: navigator.context,
        barrierDismissible: false,
        builder: (dialogContext) => _LxUpdateAlertDialog(alert: alert),
      );
    } catch (e) {
      AppLog.warn('plugin', '[lxUpdateAlert] 展示更新提示失败: $e');
    }
    queue.dismissHead();
    if (!mounted) {
      _showing = false;
      return;
    }
    // 队列还有下一条则继续展示
    if (ref.read(lxUpdateAlertQueueProvider).isNotEmpty) {
      _showNext();
    } else {
      _showing = false;
    }
  }
}

class _LxUpdateAlertDialog extends ConsumerStatefulWidget {
  final LxUpdateAlertPayload alert;

  const _LxUpdateAlertDialog({required this.alert});

  @override
  ConsumerState<_LxUpdateAlertDialog> createState() =>
      _LxUpdateAlertDialogState();
}

class _LxUpdateAlertDialogState extends ConsumerState<_LxUpdateAlertDialog> {
  bool _updating = false;

  PluginSource? _sourceFor(String pluginId) {
    for (final s in ref.read(pluginManagerProvider).sources) {
      if (s.id == pluginId) return s;
    }
    return null;
  }

  Future<void> _applyUpdate(LxUpdateAlertPayload alert) async {
    final source = _sourceFor(alert.pluginId);
    final url = alert.updateUrl;
    if (mounted) setState(() => _updating = true);
    void toastRoot(String msg) {
      final nav = appNavigatorKey.currentState;
      if (nav == null || !nav.mounted) return;
      final ctx = nav.context;
      if (ctx.mounted) showXianYuToast(ctx, msg);
    }

    void popDialog() {
      final nav = appNavigatorKey.currentState;
      if (nav == null || !nav.mounted) return;
      final ctx = nav.context;
      if (ctx.mounted) Navigator.of(ctx, rootNavigator: true).pop();
    }

    try {
      // 对齐桌面端：脚本直链原位替换；非脚本（网页）回退打开更新页
      final script = url == null
          ? null
          : await fetchPluginScriptWithRetry(
              url,
              connectionTimeout: const Duration(seconds: 10),
              responseTimeout: const Duration(seconds: 15),
              userAgent: 'Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36',
            );
      final engine = await ref.read(pluginEngineProvider.future);
      if (script != null &&
          script.trim().isNotEmpty &&
          engine.isLxPluginScript(script)) {
        if (source == null) {
          // 插件已被移除或已更新过，静默关闭
        } else {
          final newVersion = engine.parseLxScriptInfo(script)['version'] ?? '';
          final manager = ref.read(pluginManagerProvider.notifier);
          final service = PluginUpdateService(engine, manager);
          final outcome = await service.performPluginUpdate(
            source,
            PluginUpdateCheckResult(
              hasUpdate: true,
              currentVersion: source.version,
              newVersion: newVersion,
              newScript: script,
              updateUrl: url!,
            ),
          );
          toastRoot(outcome.message);
          AppLog.info('plugin',
              '[lxUpdateAlert] ${source.name} 更新完成: ${outcome.success}');
        }
      } else if (url != null) {
        // 非脚本链接：交给浏览器打开（LX 官方行为）
        try {
          await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
        } catch (e) {
          AppLog.warn('plugin', '[lxUpdateAlert] 打开更新页失败: $e');
        }
      } else {
        toastRoot(tr('无法获取更新脚本'));
      }
    } catch (e) {
      AppLog.warn('plugin', '[lxUpdateAlert] 应用更新失败: $e');
    } finally {
      if (mounted) setState(() => _updating = false);
      popDialog();
    }
  }

  @override
  Widget build(BuildContext context) {
    final source = _sourceFor(widget.alert.pluginId);
    final name = source?.name ?? tr('LX 音源插件');
    final version = source?.version ?? '';
    final hasUrl = (widget.alert.updateUrl ?? '').isNotEmpty;
    return AlertDialog(
      title: Text(tr('「{name}」有新版本', {
        'name': name,
      })),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (version.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    tr('当前版本 v{ver}', {'ver': version}),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              Text(widget.alert.log),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed:
              _updating ? null : () => Navigator.of(context).pop(),
          child: Text(tr('稍后')),
        ),
        if (hasUrl)
          FilledButton(
            onPressed:
                _updating ? null : () => _applyUpdate(widget.alert),
            child: _updating
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(tr('立即更新')),
          ),
      ],
    );
  }
}
