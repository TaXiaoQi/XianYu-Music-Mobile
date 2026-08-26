import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/core/app_colors.dart';
import '../../src/core/developer_mode.dart';
import '../../src/notifications/notification_service.dart';
import '../../src/player/player_provider.dart';
import '../../src/playlist/playlist_store.dart';
import '../../src/plugin/plugin_backup_import.dart';
import '../../src/sync/settings_conflict_dialog.dart';
import '../../src/widgets/app_toast.dart';
import '../../src/widgets/glass_appbar.dart';
import '../../src/widgets/modern_dialog.dart';
import '../../src/widgets/song_actions_sheet.dart';
import '../../src/widgets/song_info_dialog.dart';
import '../../src/widgets/add_to_playlist_sheet.dart';
import '../../pages/account/account_dialogs.dart';

/// 调试页：集中展示所有弹窗（对齐桌面端 SettingsDebug）。
/// 通过「关于页」版本号连点 5 次进入。
class DebugPage extends ConsumerWidget {
  const DebugPage({super.key});

  /// 假在线歌曲，用于触发需要歌曲参数的弹窗调试。
  static final _fakeQueueItem = QueueItem(
    path: 'plugin://demo/测试歌曲',
    title: '测试歌曲',
    artist: '测试歌手',
    album: '测试专辑',
    durationMs: 240000,
    onlineQuality: '320k',
    source: 'kw',
    onlineSongJson: '{"pluginId":"mf_demo","source":"kw","musicInfo":{}}',
  );

  static final _fakeImportedSong = ImportedSong(
    title: '测试歌曲',
    artist: '测试歌手',
    album: '测试专辑',
    duration: 240,
    path: 'plugin://demo/测试歌曲',
    pluginId: 'mf_demo',
    source: 'kw',
    format: 'lx',
  );

  static final _fakePlaylist = ImportedPlaylist(
    id: 'demo-playlist-id',
    name: '测试歌单',
    songs: [_fakeImportedSong],
    importedAt: DateTime.now().millisecondsSinceEpoch,
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: appSurfaceBg(context),
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
              _sectionHeader(context, '开发者模式'),
              _CardGroup(
                children: [
                  ListTile(
                    title: const Text('开发者模式'),
                    subtitle: Text(
                      '当前已开启，退出后设置页将隐藏调试入口',
                      style: TextStyle(
                          fontSize: 12, color: scheme.onSurfaceVariant),
                    ),
                    trailing: FilledButton(
                      onPressed: () {
                        ref.read(developerModeProvider.notifier).disable();
                        showXianYuToast(context, '已退出调试模式');
                      },
                      child: const Text('退出'),
                    ),
                  ),
                ],
              ),
              _sectionHeader(context, '通用弹窗'),
              _CardGroup(
                children: [
                  _DebugRow(
                    title: '通用确认弹窗',
                    subtitle: '测试 ModernDialogCard 通用确认弹窗',
                    onTap: () => showModernConfirmDialog(
                      context: context,
                      title: '通用确认弹窗',
                      message: '这是移动端通用确认弹窗的调试内容，用于验证弹窗样式与交互。',
                      icon: Icons.help_outline,
                    ),
                  ),
                  _DebugRow(
                    title: '危险确认弹窗',
                    subtitle: '测试红色危险操作的确认弹窗',
                    onTap: () => showModernConfirmDialog(
                      context: context,
                      title: '危险操作',
                      message: '此操作不可恢复，确定要继续吗？',
                      confirmText: '继续',
                      isDanger: true,
                      icon: Icons.warning_amber_rounded,
                    ),
                  ),
                  _DebugRow(
                    title: '通用输入弹窗',
                    subtitle: '测试 ModernDialogCard 通用输入弹窗',
                    onTap: () => showModernInputDialog(
                      context: context,
                      title: '通用输入弹窗',
                      subtitle: '请输入内容',
                      hintText: '请输入内容',
                      initialValue: '调试初始值',
                    ),
                  ),
                  _DebugRow(
                    title: '单选弹窗',
                    subtitle: '测试居中单选列表弹窗',
                    onTap: () => showModernChoiceSheet<String>(
                      context: context,
                      title: '单选弹窗',
                      subtitle: '请选择一个选项',
                      options: const [
                        ModernChoiceOption(
                            label: '选项一', value: '1', subtitle: '第一个选项'),
                        ModernChoiceOption(
                            label: '选项二', value: '2', subtitle: '第二个选项'),
                        ModernChoiceOption(label: '选项三', value: '3'),
                      ],
                      currentValue: '1',
                    ),
                  ),
                ],
              ),
              _sectionHeader(context, '账号与系统'),
              _CardGroup(
                children: [
                  _DebugRow(
                    title: '设置同步冲突弹窗',
                    subtitle: '测试云端设置冲突时的选择弹窗',
                    onTap: () => showSettingsConflictDialog(
                      context: context,
                      localTime: DateTime.now(),
                      cloudTime: DateTime.now().subtract(const Duration(hours: 2)),
                    ),
                  ),
                  _DebugRow(
                    title: '资料修改前置确认',
                    subtitle: '测试修改资料前的次数限制与审核提示',
                    onTap: () => showProfileEditGate(
                      context,
                      title: '更换头像',
                      desc: '今日剩余修改机会：0 次。头像修改需管理员审核，审核通过后生效。',
                      confirmText: '知道了',
                      blocked: true,
                    ),
                  ),
                  _DebugRow(
                    title: '公告展示框',
                    subtitle: '测试公告弹窗显示',
                    onTap: () => ref
                        .read(notificationServiceProvider)
                        .showAnnouncementForDebug(context),
                  ),
                ],
              ),
              _sectionHeader(context, '歌曲相关'),
              _CardGroup(
                children: [
                  _DebugRow(
                    title: '歌曲操作弹层',
                    subtitle: '测试收藏/加歌单/歌曲信息/下载操作弹窗（假歌曲）',
                    onTap: () => showSongActionsSheet(
                      context,
                      ref: ref,
                      item: _fakeQueueItem,
                    ),
                  ),
                  _DebugRow(
                    title: '添加到歌单弹窗',
                    subtitle: '测试选择歌单并添加歌曲的弹窗（假歌曲）',
                    onTap: () => showAddToPlaylistSheet(
                      context,
                      ref,
                      [_fakeImportedSong],
                    ),
                  ),
                  _DebugRow(
                    title: '歌曲信息弹窗',
                    subtitle: '测试歌曲信息/标签/歌词查看弹窗（假歌曲）',
                    onTap: () => showSongInfoDialog(context, ref, _fakeQueueItem),
                  ),
                  _DebugRow(
                    title: '歌单操作菜单',
                    subtitle: '测试歌单重命名/删除操作菜单（假歌单）',
                    onTap: () => showPlaylistActionsSheet(context, ref, _fakePlaylist),
                  ),
                ],
              ),
              _sectionHeader(context, '消息提示'),
              _CardGroup(
                children: [
                  _DebugRow(
                    title: '成功提示',
                    subtitle: '底部居中胶囊成功提示',
                    onTap: () => showXianYuToast(context, '这是一条成功的提示消息'),
                  ),
                  _DebugRow(
                    title: '普通提示',
                    subtitle: '底部居中胶囊普通提示',
                    onTap: () => showXianYuToast(context, '这是一条普通提示消息'),
                  ),
                  _DebugRow(
                    title: '失败提示',
                    subtitle: '底部居中胶囊失败提示',
                    onTap: () => showXianYuToast(context, '这是一条失败的提示消息'),
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
              title: const Text('调试'),
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
          '弹出',
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

/// 分组圆角卡片包裹容器（与设置页一致）。
class _CardGroup extends StatelessWidget {
  const _CardGroup({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
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
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Column(children: items),
    );
  }
}
