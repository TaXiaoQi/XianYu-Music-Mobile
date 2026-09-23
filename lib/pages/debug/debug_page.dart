import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../src/auth/auth_provider.dart';
import '../../src/auth/server_models.dart';
import '../../src/core/app_colors.dart';
import '../../src/core/developer_mode.dart';
import '../../src/deeplink/share_link_dialog.dart';
import '../../src/notifications/notification_service.dart';
import '../../src/player/player_provider.dart';
import '../../src/playlist/playlist_delete.dart';
import '../../src/playlist/playlist_store.dart';
import '../../src/plugin/plugin_backup_import.dart';
import '../../src/share/share_sheet.dart';
import '../../src/sync/settings_conflict_dialog.dart';
import '../../src/update/app_update.dart';
import '../../src/widgets/add_to_playlist_sheet.dart';
import '../../src/widgets/app_toast.dart';
import '../../src/widgets/dlna_device_dialog.dart';
import '../../src/widgets/glass_appbar.dart';
import '../../src/widgets/privacy_policy.dart';
import '../../src/widgets/song_actions_sheet.dart';
import '../../src/widgets/song_info_dialog.dart';
import '../../src/widgets/user_agreement.dart';
import '../../pages/account/account_dialogs.dart';
import '../../src/i18n/i18n.dart';

class DebugPage extends ConsumerWidget {
  const DebugPage({super.key});

  static QueueItem get _fakeQueueItem => QueueItem(
    path: tr('plugin://demo/测试歌曲'),
    title: tr('测试歌曲'),
    artist: tr('测试歌手'),
    album: tr('测试专辑'),
    durationMs: 240000,
    onlineQuality: '320k',
    source: 'kw',
    onlineSongJson: '{"pluginId":"mf_demo","source":"kw","musicInfo":{}}',
  );

  static ImportedSong get _fakeImportedSong => ImportedSong(
    title: tr('测试歌曲'),
    artist: tr('测试歌手'),
    album: tr('测试专辑'),
    duration: 240,
    path: tr('plugin://demo/测试歌曲'),
    pluginId: 'mf_demo',
    source: 'kw',
    format: 'lx',
  );

  static ImportedPlaylist get _fakePlaylist => ImportedPlaylist(
    id: 'demo-playlist-id',
    name: tr('测试歌单'),
    songs: [_fakeImportedSong],
    importedAt: DateTime.now().millisecondsSinceEpoch,
  );

  /// 云端假歌单：触发「删除范围选择」分支（假 id 不会真正删除）
  static ImportedPlaylist get _fakeCloudPlaylist => ImportedPlaylist(
    id: 'demo-cloud-playlist-id',
    name: tr('云端测试歌单'),
    songs: [_fakeImportedSong],
    importedAt: DateTime.now().millisecondsSinceEpoch,
    cloudId: 'demo-cloud-id',
    isCloud: true,
  );

  static LatestVersion get _fakeLatestVersion => const LatestVersion(
    version: '9.9.9',
    content: '调试用假更新日志：\n· 新增调试弹窗覆盖\n· 修复若干问题',
    downloadUrl: 'https://example.com/app.apk',
    fileSize: 36700160,
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: appScaffoldBackground(context, ref),
      body: Stack(
        children: [
          ListView(
            padding: EdgeInsets.fromLTRB(
              16,
              GlassTopBar.height(context),
              16,
              92 + MediaQuery.of(context).padding.bottom,
            ),
            children: [
              _sectionHeader(context, tr('开发者模式')),
              _CardGroup(
                children: [
                  ListTile(
                    title:   Text(tr('开发者模式')),
                    subtitle: Text(
                      tr('当前已开启，退出后设置页将隐藏调试入口'),
                      style: TextStyle(
                          fontSize: 12, color: scheme.onSurfaceVariant),
                    ),
                    trailing: FilledButton(
                      onPressed: () {
                        ref.read(developerModeProvider.notifier).disable();
                        showXianYuToast(context, tr('已退出调试模式'));
                      },
                      child:   Text(tr('退出')),
                    ),
                  ),
                ],
              ),
              _sectionHeader(context, tr('更新')),
              _CardGroup(
                children: [
                  _DebugRow(
                    title: tr('检查更新弹窗'),
                    subtitle: tr('测试发现新版本弹窗与去下载跳转（假版本）'),
                    onTap: () =>
                        showUpdateDialog(context, _fakeLatestVersion),
                  ),
                  _DebugRow(
                    title: tr('Beta 门控弹窗'),
                    subtitle:
                        tr('测试内测资格提示（注意：关闭弹窗的按钮会退出应用）'),
                    onTap: () => showBetaGateDialog(context, pending: false),
                  ),
                ],
              ),
              _sectionHeader(context, tr('账号与系统')),
              _CardGroup(
                children: [
                  _DebugRow(
                    title: tr('设置同步冲突弹窗'),
                    subtitle: tr('测试云端设置冲突时的选择弹窗'),
                    onTap: () => showSettingsConflictDialog(
                      context: context,
                      localTime: DateTime.now(),
                      cloudTime: DateTime.now().subtract(const Duration(hours: 2)),
                    ),
                  ),
                  _DebugRow(
                    title: tr('资料修改前置确认'),
                    subtitle: tr('测试修改资料前的次数限制与审核提示'),
                    onTap: () => showProfileEditGate(
                      context,
                      title: tr('更换头像'),
                      desc: tr('今日剩余修改机会：0 次。头像修改需管理员审核，审核通过后生效。'),
                      confirmText: tr('知道了'),
                      blocked: true,
                    ),
                  ),
                  _DebugRow(
                    title: tr('公告展示框'),
                    subtitle: tr('测试公告弹窗显示'),
                    onTap: () => ref
                        .read(notificationServiceProvider)
                        .showAnnouncementForDebug(context),
                  ),
                  _DebugRow(
                    title: tr('听歌重置通知'),
                    subtitle: tr('测试听歌记录重置提醒弹窗（模拟未读状态）'),
                    onTap: () async {
                      final notifier = ref.read(notificationServiceProvider);
                      notifier.resetListenResetNoticeForDebug();
                      final prefs = await SharedPreferences.getInstance();
                      await prefs.setInt('pending_listen_reset_at',
                          DateTime.now().millisecondsSinceEpoch);
                      await prefs.setString('pending_listen_reset_reason',
                          tr('调试：模拟听歌记录因账号异常被重置'));
                      if (context.mounted) {
                        await notifier.showPendingListenResetNotice(context);
                      }
                    },
                  ),
                  _DebugRow(
                    title: tr('用户协议弹窗'),
                    subtitle: tr('测试协议滚动阅读与同意交互（假内容）'),
                    onTap: () => showUserAgreementModal(
                      context: context,
                      agreement: const UserAgreement(
                        title: '弦予音乐用户协议',
                        content:
                            '一、本协议为调试预览内容。\n二、滚动到底部后方可点击同意。\n三、此内容仅用于调试弹窗样式。',
                      ),
                    ),
                  ),
                  _DebugRow(
                    title: tr('隐私政策弹窗'),
                    subtitle: tr('测试隐私政策弹窗显示（默认全文）'),
                    onTap: () => showPrivacyPolicyModal(context: context),
                  ),
                  _DebugRow(
                    title: tr('修改密码弹窗'),
                    subtitle: tr('测试修改密码表单弹窗（提交需登录态）'),
                    onTap: () => showChangePasswordDialog(
                        context, ref.read(authProvider.notifier)),
                  ),
                  _DebugRow(
                    title: tr('绑定邮箱弹窗'),
                    subtitle: tr('测试绑定邮箱表单弹窗（提交需登录态）'),
                    onTap: () => showBindEmailDialog(
                        context, ref.read(authProvider.notifier)),
                  ),
                  _DebugRow(
                    title: tr('修改昵称弹窗'),
                    subtitle: tr('测试修改昵称表单弹窗（提交需登录态）'),
                    onTap: () => showChangeNicknameDialog(
                        context, ref.read(authProvider.notifier)),
                  ),
                  _DebugRow(
                    title: tr('修改弦予号弹窗'),
                    subtitle: tr('测试修改弦予号表单弹窗（提交需登录态）'),
                    onTap: () => showChangeCiyuanxiDialog(
                        context, ref.read(authProvider.notifier)),
                  ),
                  _DebugRow(
                    title: tr('注销账号弹窗'),
                    subtitle: tr('测试注销账号确认与验证流程弹窗（提交需登录态）'),
                    onTap: () => showDeleteAccountDialog(
                        context, ref.read(authProvider.notifier)),
                  ),
                  _DebugRow(
                    title: tr('忘记密码弹窗'),
                    subtitle: tr('测试忘记密码找回流程弹窗（提交需服务端）'),
                    onTap: () => showForgotPasswordDialog(
                        context, ref.read(authProvider.notifier)),
                  ),
                ],
              ),
              _sectionHeader(context, tr('歌曲与歌单')),
              _CardGroup(
                children: [
                  _DebugRow(
                    title: tr('歌曲操作弹层'),
                    subtitle: tr('测试收藏/加歌单/歌曲信息/下载操作弹窗（假歌曲）'),
                    onTap: () => showSongActionsSheet(
                      context,
                      ref: ref,
                      item: _fakeQueueItem,
                    ),
                  ),
                  _DebugRow(
                    title: tr('添加到歌单弹窗'),
                    subtitle: tr('测试选择歌单并添加歌曲的弹窗（假歌曲）'),
                    onTap: () => showAddToPlaylistSheet(
                      context,
                      ref,
                      [_fakeImportedSong],
                    ),
                  ),
                  _DebugRow(
                    title: tr('歌曲信息弹窗'),
                    subtitle: tr('测试歌曲信息/标签/歌词查看弹窗（假歌曲）'),
                    onTap: () => showSongInfoDialog(context, ref, _fakeQueueItem),
                  ),
                  _DebugRow(
                    title: tr('歌单操作菜单'),
                    subtitle: tr('测试歌单重命名/删除操作菜单（假歌单）'),
                    onTap: () => showPlaylistActionsSheet(context, ref, _fakePlaylist),
                  ),
                  _DebugRow(
                    title: tr('歌单删除范围选择'),
                    subtitle: tr('测试云端歌单删除范围弹层（假云端 id，删除会失败）'),
                    onTap: () => confirmRemovePlaylist(
                        context, ref, _fakeCloudPlaylist),
                  ),
                ],
              ),
              _sectionHeader(context, tr('分享与投放')),
              _CardGroup(
                children: [
                  _DebugRow(
                    title: tr('分享链接预览弹窗'),
                    subtitle: tr('测试打开他人分享歌曲时的预览确认弹窗'),
                    onTap: () => showShareLinkPreviewDialog(
                      context: context,
                      name: tr('测试歌曲'),
                      artist: tr('测试歌手'),
                      sourceLabel: tr('本地音乐'),
                    ),
                  ),
                  _DebugRow(
                    title: tr('歌曲分享面板'),
                    subtitle: tr('测试歌曲分享/生成链接面板（假歌曲）'),
                    onTap: () => showSongShareSheet(
                      context,
                      ref: ref,
                      song: _fakeQueueItem,
                    ),
                  ),
                  _DebugRow(
                    title: tr('DLNA 投放弹窗'),
                    subtitle: tr('测试局域网设备发现与投放选择弹窗'),
                    onTap: () => showDlnaDeviceDialog(context, ref),
                  ),
                ],
              ),
              _sectionHeader(context, tr('消息提示')),
              _CardGroup(
                children: [
                  _DebugRow(
                    title: tr('成功提示'),
                    subtitle: tr('底部居中胶囊成功提示'),
                    onTap: () => showXianYuToast(context, tr('这是一条成功的提示消息')),
                  ),
                  _DebugRow(
                    title: tr('普通提示'),
                    subtitle: tr('底部居中胶囊普通提示'),
                    onTap: () => showXianYuToast(context, tr('这是一条普通提示消息')),
                  ),
                  _DebugRow(
                    title: tr('失败提示'),
                    subtitle: tr('底部居中胶囊失败提示'),
                    onTap: () => showXianYuToast(context, tr('这是一条失败的提示消息')),
                  ),
                ],
              ),
            ],
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: GlassTopBar(
              leading: const BackButton(),
              title:   Text(tr('调试')),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(BuildContext context, String title) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
        child: Text(
          title,
          style: TextStyle(
            fontSize: 13,
            color: Theme.of(context).colorScheme.primary,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
}

class _DebugRow extends StatelessWidget {
  const _DebugRow({
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      title: Text(title, style: const TextStyle(fontSize: 15)),
      subtitle: Text(
        subtitle,
        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
      ),
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: scheme.primary.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          tr('弹出'),
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: scheme.primary,
          ),
        ),
      ),
      onTap: onTap,
    );
  }
}

class _CardGroup extends ConsumerWidget {
  const _CardGroup({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final items = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      items.add(children[i]);
      if (i != children.length - 1) {
        items.add(
          Divider(
            height: 1,
            indent: 52,
            endIndent: 16,
            thickness: 0.5,
            color: scheme.onSurface.withValues(alpha: 0.08),
          ),
        );
      }
    }

    return Material(
      color: appCardColor(context),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide.none,
      ),
      child: Column(children: items),
    );
  }
}
