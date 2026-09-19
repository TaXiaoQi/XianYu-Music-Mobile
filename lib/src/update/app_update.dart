import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../auth/account_api.dart';
import '../auth/auth_provider.dart' show defaultAuthBaseUrl;
import '../auth/server_models.dart';
import '../core/platform_caps.dart';
import '../core/settings.dart';
import '../device/device_info.dart';
import '../navigation/routes.dart';
import '../widgets/predictive_dialog_route.dart';
import '../i18n/i18n.dart';

const _lastPromptKey = 'app_update_last_prompt_date';

Future<bool> _isStoreInstall() async {
  final source = await fetchInstallerSource();
  if (source == null) return false;
  return source == 'com.android.vending' || source.contains('fdroid');
}

bool hasNewVersion(LatestVersion latest) =>
    compareVersions(latest.version, appVersion) > 0;

({List<int> fields, String? pre, int preNum}) _parseVersion(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return (fields: const [], pre: null, preNum: 0);
  if (s[0] == 'v' || s[0] == 'V') s = s.substring(1);
  final dash = s.indexOf('-');
  final main = dash >= 0 ? s.substring(0, dash) : s;
  final preStr = dash >= 0 ? s.substring(dash + 1) : null;
  final fields =
      main.split('.').map((p) => int.tryParse(p) ?? 0).toList();
  var preNum = 0;
  if (preStr != null) {
    final m = RegExp(r'(\d+)').firstMatch(preStr);
    preNum = m != null ? int.tryParse(m.group(1)!) ?? 0 : 0;
  }
  return (fields: fields, pre: preStr, preNum: preNum);
}

int compareVersions(String a, String b) {
  final pa = _parseVersion(a);
  final pb = _parseVersion(b);
  final len = pa.fields.length > pb.fields.length
      ? pa.fields.length
      : pb.fields.length;
  for (var i = 0; i < len; i++) {
    final av = i < pa.fields.length ? pa.fields[i] : 0;
    final bv = i < pb.fields.length ? pb.fields[i] : 0;
    if (av != bv) return av > bv ? 1 : -1;
  }
  if (pa.pre == null || pb.pre == null) return 0;
  final preA = pa.pre;
  final preB = pb.pre;
  if (preA != null && preB != null) {
    final aToken = RegExp(r'^[a-zA-Z]*').firstMatch(preA)?.group(0) ?? '';
    final bToken = RegExp(r'^[a-zA-Z]*').firstMatch(preB)?.group(0) ?? '';
    if (aToken != bToken) return aToken.compareTo(bToken) > 0 ? 1 : -1;
    if (pa.preNum != pb.preNum) return pa.preNum > pb.preNum ? 1 : -1;
    if (preA != preB) return preA.compareTo(preB) > 0 ? 1 : -1;
  }
  return 0;
}

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
              await openExternalUrl(ctx, absoluteDownloadUrl(latest.downloadUrl));
            },
            child: Text(tr('去下载')),
          ),
      ],
    ),
  );
}

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

String absoluteDownloadUrl(String url) {
  if (url.isEmpty) return '';
  if (RegExp(r'^https?://', caseSensitive: false).hasMatch(url)) return url;
  final base = Uri.tryParse(defaultAuthBaseUrl);
  if (base == null || base.host.isEmpty) return url;
  final origin = '${base.scheme}://${base.host}'
      '${base.hasPort ? ':${base.port}' : ''}';
  var root = base.path;
  if (root.endsWith('/api')) {
    root = root.substring(0, root.length - '/api'.length);
  }
  return '$origin$root$url';
}

Future<void> checkAppUpdate(
  BuildContext context,
  WidgetRef ref, {
  bool silent = false,
}) async {
  if (Platform.isIOS) {
    if (!silent && context.mounted) {
      _toast(context, tr('iOS 版请在 App Store 内更新'));
    }
    return;
  }
  if (PlatformCaps.isOhos) {
    if (!silent && context.mounted) {
      _toast(context, tr('鸿蒙版请通过官网获取新版本'));
    }
    return;
  }
  if (await _isStoreInstall()) {
    if (!silent && context.mounted) {
      _toast(context, tr('商店安装版请在安装渠道（商店）内更新'));
    }
    return;
  }
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
    if (!silent && context.mounted) {
      _toast(context, tr('当前已是最新版本（{v}）', {'v': appVersion}));
    }
    return;
  }
  if (hasNewVersion(latest)) {
    await showUpdateDialog(context, latest);
  } else if (!silent && context.mounted) {
    _toast(context, tr('当前已是最新版本（{v}）', {'v': appVersion}));
  }
}

Future<void> maybePromptStartupUpdate(WidgetRef ref) async {
  if (Platform.isIOS || PlatformCaps.isOhos) return;
  if (await _isStoreInstall()) return;
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

bool get isBetaBuild {
  final pre = (_parseVersion(appVersion).pre ?? '').toLowerCase();
  return pre.startsWith('beta');
}

Future<bool> maybeGateBetaAccess(WidgetRef ref) async {
  if (!kReleaseMode) return false;
  if (!isBetaBuild) return false;
  (bool, bool) access;
  try {
    access = await ref.read(accountApiProvider).checkBetaAccess();
  } catch (_) {
    return false;
  }
  final (bool allowed, bool pending) = access;
  if (allowed) return false;
  final ctx = appNavigatorKey.currentContext;
  if (ctx == null || !ctx.mounted) return false;
  await showBetaGateDialog(ctx, pending: pending);
  return true;
}

Future<void> runStartupVersionChecks(WidgetRef ref) async {
  final gated = await maybeGateBetaAccess(ref);
  if (!gated) await maybePromptStartupUpdate(ref);
}

Future<void> showBetaGateDialog(BuildContext context, {required bool pending}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    barrierColor: Colors.black87,
    useSafeArea: false,
    builder: (ctx) => PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text(tr('内测资格提示')),
        content: Text(
            pending
                ? tr('该设备的内测申请正在审核中，请耐心等待管理员审核，审核结果将以反馈回复通知。')
                : tr('当前设备未申请内测资格，无法使用内测版本。\n点击「申请资格」填写申请理由，管理员同意后即可继续使用。'),
            style: const TextStyle(fontSize: 14, height: 1.5)),
        actions: [
          TextButton(
            onPressed: () => SystemNavigator.pop(),
            child: Text(tr('退出软件')),
          ),
          if (!pending)
            FilledButton(
              onPressed: () {
                GoRouter.of(ctx).push('/feedback?tab=1');
              },
              child: Text(tr('申请资格')),
            ),
        ],
      ),
    ),
  );
}

String _today() {
  final now = DateTime.now();
  return '${now.year}-${now.month}-${now.day}';
}

void _toast(BuildContext context, String msg) {
  ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
}