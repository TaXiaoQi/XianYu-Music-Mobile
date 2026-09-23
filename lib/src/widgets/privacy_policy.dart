import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../auth/account_api.dart';
import '../auth/server_models.dart';
import '../i18n/i18n.dart';
import 'user_agreement.dart';

const kPrivacyPolicyDefaultTitle = '弦予音乐隐私政策';

const kPrivacyPolicyUrl = 'https://xianyumusic.cn/privacy.html';

const kPrivacyConsentPrefKey = 'privacy_policy_agreed_v1';

/// 已确认的服务器下发版本 fingerprint（id_updatedAt）。
const kPrivacyConsentFingerprintKey = 'privacy_policy_agreed_fp';

const kPrivacyPolicyDefaultUpdatedAt = '2026-09-04';

const kPrivacyPolicyDefaultContent = '''
弦予音乐（以下简称"本软件"）由个人开发者维护。我们深知个人信息对你的重要性，并会按照本政策收集、使用和保护你的信息。请在使用前仔细阅读本政策。

一、我们收集的信息
· 账号信息：注册弦予号时收集邮箱地址、昵称、头像与密码。密码经不可逆加密后存储，我们无法看到明文。
· 使用统计：为你提供听歌统计、听歌排行等功能时，收集聚合后的收听时长、收听次数等统计数据。
· 收藏与歌单：你主动创建或收藏的歌单、歌曲信息，用于云端同步。
· 反馈与错误日志：你主动提交反馈时，可选择附带错误日志与设备信息（设备型号、操作系统版本），仅用于定位和修复问题。
· 内测资格：申请内测时收集设备标识信息，用于内测名单管理。

二、本地数据
你的本地音乐文件、播放记录、设置与自定义插件仅存储在你的设备上。未经你的主动操作（如提交反馈、登录同步），这些数据不会离开你的设备。

三、信息的使用
· 创建与管理账号、提供云端同步与统计功能；
· 定位与修复软件问题、改进产品体验；
· 我们不将你的个人信息用于广告投放，不向任何第三方出售你的个人信息。

四、第三方服务说明
· 本软件支持加载第三方开发者提供的音源插件。插件向你选择的第三方在线服务发起请求、获取内容的行为由插件自身完成，请你自行评估所安装插件的可信度。
· 本软件官网与更新服务由开发者自托管的服务器提供，仅用于分发软件与提供 API 服务。

五、数据存储与安全
云端数据存储于受访问控制保护的服务器数据库中，密码等敏感信息经加密处理。我们采取合理的技术手段防止数据被未经授权地访问、泄露或篡改，但互联网环境不存在绝对安全，请妥善保管你的账号凭据。

六、你的权利
· 在软件内随时修改昵称、头像等账号资料；
· 清除本地数据：卸载软件或清除应用数据即可删除全部本地信息；
· 注销账号或删除云端数据：可通过软件内反馈入口或下述联系方式提出申请，我们将在核实后处理。

七、未成年人保护
本软件不面向未满 14 周岁的儿童单独收集个人信息。若你未满 14 周岁，请在监护人陪同下阅读本政策并在征得监护人同意后使用本软件。

八、政策更新
本政策可能随软件功能更新而不时修订，修订后的版本将在本页面发布并更新日期。继续使用本软件即视为接受更新后的政策。

九、联系我们
如对本政策有任何疑问、意见或投诉，可通过以下渠道联系我们：
· 软件内「反馈」入口（可附带日志与设备信息）
· GitHub Issues：github.com/TaXiaoQi/XianYu-Music-Desktop/issues
· 官方 QQ 群：https://qm.qq.com/q/P1sKHAAl6S

在线版本：$kPrivacyPolicyUrl
''';

Future<bool> showPrivacyPolicyModal({required BuildContext context}) {
  return showUserAgreementModal(
    context: context,
    agreement: const UserAgreement(
      title: kPrivacyPolicyDefaultTitle,
      content: kPrivacyPolicyDefaultContent,
    ),
  );
}

/// 启动时的隐私同意闸门：
/// 1. 拉取服务器下发版本（6s 超时，失败/无下发用内置默认版）；
/// 2. 已同意旧版且服务器无更新 → 直接放行；
/// 3. 未同意或服务器有更新版 → 弹窗（没确认过才弹，确认状态存本地
///    fingerprint，机制与公告一致），同意后上报服务器留存。
Future<bool> ensurePrivacyConsent(BuildContext context) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final prefs = await SharedPreferences.getInstance();
  final agreedV1 = prefs.getBool(kPrivacyConsentPrefKey) ?? false;
  final remote = await container.read(accountApiProvider).fetchPrivacyPolicy();
  final remoteFp =
      remote == null ? '' : '${remote.id}_${remote.updatedAt}';
  final confirmedFp = prefs.getString(kPrivacyConsentFingerprintKey) ?? '';
  // 已同意过内置版：服务器无下发或已确认过该下发版本时放行。
  if (agreedV1 &&
      (remote == null ||
          remoteFp.isEmpty ||
          remoteFp == confirmedFp)) {
    return true;
  }
  if (!context.mounted) return false;
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    barrierColor: Colors.black87,
    useSafeArea: false,
    builder: (_) => _PrivacyConsentDialog(remote: remote),
  ).then((v) => v ?? false);
  return ok;
}

class _PrivacyConsentDialog extends StatefulWidget {
  const _PrivacyConsentDialog({this.remote});

  final PrivacyPolicyRemote? remote;

  @override
  State<_PrivacyConsentDialog> createState() => _PrivacyConsentDialogState();
}

class _PrivacyConsentDialogState extends State<_PrivacyConsentDialog> {
  final _scroll = ScrollController();
  bool _atEnd = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refresh();
      _scroll.addListener(_onScroll);
    });
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    final el = _scroll.position;
    if (!el.hasContentDimensions) return;
    final atEnd =
        el.maxScrollExtent <= 0 || el.pixels >= el.maxScrollExtent - 6;
    if (_atEnd != atEnd) setState(() => _atEnd = atEnd);
  }

  void _refresh() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final el = _scroll.position;
      if (!el.hasContentDimensions) {
        setState(() => _atEnd = true);
        return;
      }
      setState(() => _atEnd =
          el.maxScrollExtent <= 0 || el.pixels >= el.maxScrollExtent - 6);
    });
  }

  Future<void> _agree() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kPrivacyConsentPrefKey, true);
    final remote = widget.remote;
    if (remote != null) {
      await prefs.setString(
          kPrivacyConsentFingerprintKey, '${remote.id}_${remote.updatedAt}');
      // 确认上报（留存用，失败不影响本地放行）。
      unawaitedConfirm(remote);
    }
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  void unawaitedConfirm(PrivacyPolicyRemote remote) {
    ProviderScope.containerOf(context, listen: false)
        .read(accountApiProvider)
        .confirmPrivacyPolicy(remote);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final remote = widget.remote;
    final updatedAt = remote?.updatedAt ?? kPrivacyPolicyDefaultUpdatedAt;
    final content = remote?.content ?? kPrivacyPolicyDefaultContent;
    return PopScope(
      canPop: false,
      child: AlertDialog(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        titlePadding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
        contentPadding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
        actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        title: Row(
          children: [
            Icon(Icons.privacy_tip_outlined, size: 22, color: scheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                tr(kPrivacyPolicyDefaultTitle),
                style:
                    const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          height: 360,
          child: Scrollbar(
            controller: _scroll,
            child: SingleChildScrollView(
              controller: _scroll,
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    content,
                    style: TextStyle(
                        fontSize: 13.5,
                        height: 1.6,
                        color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 16),
                  // 更新日期放内容最底部。
                  Text(
                    '${tr('更新日期')}：$updatedAt',
                    style: TextStyle(fontSize: 12, color: scheme.outline),
                  ),
                ],
              ),
            ),
          ),
        ),
        // 控件一行横排（同普通弹窗）：左侧在线版入口，右侧不同意/同意。
        actions: [
          Row(
            children: [
              TextButton(
                onPressed: () => launchUrl(
                  Uri.parse(kPrivacyPolicyUrl),
                  mode: LaunchMode.externalApplication,
                ),
                child: Text(
                  tr('查看在线版'),
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => SystemNavigator.pop(),
                child: Text(
                  tr('不同意并退出'),
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              const SizedBox(width: 4),
              FilledButton(
                onPressed: _atEnd ? _agree : null,
                child: Text(
                  _atEnd ? tr('同意并继续') : tr('请滚动至底部'),
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
