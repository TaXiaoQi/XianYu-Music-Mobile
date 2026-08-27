import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../auth/account_api.dart';
import '../auth/server_models.dart';
import '../core/settings.dart';
import '../navigation/routes.dart';
import '../widgets/predictive_dialog_route.dart';
import '../i18n/i18n.dart';

/// 最近一次「启动自动弹升级窗」的日期。默认当日只自动弹一次，避免每次冷启动打扰。
const _lastPromptKey = 'app_update_last_prompt_date';

/// 服务端版本是否比本地新。
bool hasNewVersion(LatestVersion latest) =>
    compareVersions(latest.version, appVersion) > 0;

/// 版本号比较：a > b 返回 1，a < b 返回 -1，相等返回 0。
int compareVersions(String a, String b) {
  final aParts = a.split('.').map((s) => int.tryParse(s) ?? 0).toList();
  final bParts = b.split('.').map((s) => int.tryParse(s) ?? 0).toList();
  final len = aParts.length > bParts.length ? aParts.length : bParts.length;
  for (var i = 0; i < len; i++) {
    final av = i < aParts.length ? aParts[i] : 0;
    final bv = i < bParts.length ? bParts[i] : 0;
    if (av > bv) return 1;
    if (av < bv) return -1;
  }
  return 0;
}

/// 通用升级弹窗：展示版本号与更新说明，提供「暂不更新 / 去下载」。
Future<void> showUpdateDialog(BuildContext context, LatestVersion latest) {
  return showPredictiveDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: Text(tr('发现新版本')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr('最新版本：{v}', {'v': latest.version}),
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            if (latest.content.isNotEmpty)
              Text(latest.content,
                  style: const TextStyle(fontSize: 13, height: 1.5)),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(tr('暂不更新')),
        ),
        if (latest.downloadUrl.isNotEmpty)
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await openExternalUrl(ctx, latest.downloadUrl);
            },
            child: Text(tr('去下载')),
          ),
      ],
    ),
  );
}

/// 用系统浏览器打开外部链接（下载 APK 等）。
Future<void> openExternalUrl(BuildContext context, String url) async {
  if (url.isEmpty) {
    _toast(context, tr('无法打开链接'));
    return;
  }
  final uri = Uri.tryParse(url);
  if (uri == null) {
    _toast(context, tr('无法打开链接'));
    return;
  }
  try {
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) _toast(context, tr('无法打开链接'));
  } catch (_) {
    if (context.mounted) _toast(context, tr('无法打开链接'));
  }
}

/// 手动检查更新（如「关于」页按钮）：
/// [silent] 为 true 时静默，不弹任何提示；否则出错/无新版本时用 toast 提示。
Future<void> checkAppUpdate(
  BuildContext context,
  WidgetRef ref, {
  bool silent = false,
}) async {
  final LatestVersion? latest;
  try {
    latest = await ref.read(accountApiProvider).fetchServerUpdate();
  } catch (_) {
    if (!silent && context.mounted) {
      _toast(context, tr('检查更新失败，请稍后重试'));
    }
    return;
  }
  if (!context.mounted) return;
  if (latest == null) {
    if (!silent) _toast(context, tr('检查更新失败，请稍后重试'));
    return;
  }
  if (hasNewVersion(latest)) {
    await showUpdateDialog(context, latest);
  } else if (!silent && context.mounted) {
    _toast(context, tr('当前已是最新版本（{v}）', {'v': appVersion}));
  }
}

/// 启动自动检查：静默。仅当设置开启「启动检测」且当日未弹过时，弹出升级窗。
Future<void> maybePromptStartupUpdate(WidgetRef ref) async {
  final mode = ref.read(settingsProvider).valueOrNull?.updateCheckMode;
  if (mode == 'never') return;

  LatestVersion? latest;
  try {
    latest = await ref.read(accountApiProvider).fetchServerUpdate();
  } catch (_) {
    return;
  }
  if (latest == null) return;
  if (!hasNewVersion(latest)) return;

  final prefs = await SharedPreferences.getInstance();
  final today = _today();
  if (prefs.getString(_lastPromptKey) == today) return;
  await prefs.setString(_lastPromptKey, today);

  final ctx = appNavigatorKey.currentContext;
  if (ctx == null || !ctx.mounted) return;
  await showUpdateDialog(ctx, latest);
}

String _today() {
  final now = DateTime.now();
  return '${now.year}-${now.month}-${now.day}';
}

void _toast(BuildContext context, String msg) {
  ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
}