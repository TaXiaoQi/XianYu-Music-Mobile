import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../auth/account_api.dart';
import '../auth/auth_provider.dart' show defaultAuthBaseUrl;
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

/// 解析主版本段与预发布段（如 `1.0.1-beta7` → 主版本 [1,0,1]，预发布 `beta` + 7）。
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

/// 版本号比较（支持 `-betaN`/`-alphaN` 等预发布后缀）：
/// 主版本数字逐段比较，相等时正式版 > 预发布版；
/// 预发布之间按前缀（字母）再数字比较，避免 `beta7` 与 `beta6` 被判为相等。
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
  // 主版本相等：正式版 > 预发布版。
  if (pa.pre == null && pb.pre != null) return 1;
  if (pa.pre != null && pb.pre == null) return -1;
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
              await openExternalUrl(ctx, absoluteDownloadUrl(latest.downloadUrl));
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

/// 把服务端返回的相对下载链接（如 `/uploads/packages/...`）拼成可打开的绝对地址。
/// 服务端 `download_url` 通常为站点内相对路径，需补全域名后才能被浏览器/Rust 下载。
String absoluteDownloadUrl(String url) {
  if (url.isEmpty) return '';
  if (RegExp(r'^https?://', caseSensitive: false).hasMatch(url)) return url;
  final base = Uri.tryParse(defaultAuthBaseUrl);
  if (base == null || base.host.isEmpty) return url;
  final origin = '${base.scheme}://${base.host}'
      '${base.hasPort ? ':${base.port}' : ''}';
  // 默认 server 的 API 前缀为 /api，而静态文件 /uploads 挂在站点根下，需去掉前缀。
  var root = base.path;
  if (root.endsWith('/api')) {
    root = root.substring(0, root.length - '/api'.length);
  }
  return '$origin$root$url';
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
    // 服务端未发布任何版本，视作已是最新而非错误。
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

/// 内测门槛判定：本地版本号预发布段以 beta 开头即为内测构建。
bool get isBetaBuild {
  final pre = (_parseVersion(appVersion).pre ?? '').toLowerCase();
  return pre.startsWith('beta');
}

/// 内测版开屏门槛：beta 构建且设备不在内测名单 → 弹全局不可退出弹窗。
/// 先查资格，不在名单时再看有无待审核的内测申请：
/// 有 → 弹「审核中」弹窗（仅退出软件）；无 → 弹「申请资格」弹窗。
/// 返回 true 表示已拦截（调用方跳过后续启动检查）；网络失败 fail-open 放行。
Future<bool> maybeGateBetaAccess(WidgetRef ref) async {
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

/// 启动版本检查统一入口：先做内测门槛（被拦截则不再弹更新窗），再做更新提示。
Future<void> runStartupVersionChecks(WidgetRef ref) async {
  final gated = await maybeGateBetaAccess(ref);
  if (!gated) await maybePromptStartupUpdate(ref);
}

/// 内测资格拦截弹窗：全局不可退出（遮罩不可点、系统返回被 PopScope 拦截），
/// 仅「退出软件」与「申请资格」两个出口；申请页关闭后弹窗仍在最前。
///
/// [pending] 为 true：设备已有待审核的内测申请，改为「审核中」提示，
/// 仅「退出软件」一个按钮，不再提供申请入口。
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
                // 跳转反馈页内测申请 tab；返回后本弹窗仍覆盖全局，无法绕过。
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