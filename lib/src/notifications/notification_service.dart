import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth/account_api.dart';
import '../auth/auth_provider.dart';
import '../auth/server_models.dart';

/// 公告已读指纹存储键。
const _announcementDismissedKey = 'announcement_dismissed_id';

/// 启动通知服务：检查公告、反馈完成通知与昵称变更通知并弹窗展示。
///
/// 与桌面端 announcement.ts / useFeedbackNotification.ts / useNicknameChangeNotification.ts 对齐：
/// - 公告：本地已读指纹（id + updatedAt）失效则重新弹出，关闭时上报 confirm_announcement
/// - 反馈完成通知：未确认时弹出，关闭时上报 confirm_feedback_notification
/// - 昵称变更通知：未确认时弹出，关闭时上报 confirm_nickname_change_notice 并同步本地昵称
class NotificationService {
  NotificationService(this._ref);
  final Ref _ref;

  AccountApi get _api => _ref.read(accountApiProvider);

  bool _checking = false;

  /// 应用启动后调用：依次检查公告、反馈通知与昵称变更通知，避免多个弹窗叠加。
  Future<void> checkOnStartup(BuildContext context) async {
    if (_checking) return;
    _checking = true;
    try {
      final ann = await _api.fetchAnnouncement();
      if (ann != null && !await _isAnnouncementDismissed(ann)) {
        if (!context.mounted) return;
        await _showAnnouncementDialog(context, ann);
        return;
      }
      final notifications = await _api.getMyFeedbackNotifications();
      if (notifications.isNotEmpty && context.mounted) {
        await _showFeedbackNotificationDialog(context, notifications.first);
        return;
      }
      final nicknameNotices = await _api.getNicknameChangeNotices();
      if (nicknameNotices.isNotEmpty && context.mounted) {
        await _showNicknameChangeDialog(context, nicknameNotices.first);
      }
    } finally {
      _checking = false;
    }
  }

  Future<bool> _isAnnouncementDismissed(Announcement ann) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_announcementDismissedKey) ==
          _fingerprint(ann);
    } catch (_) {
      return false;
    }
  }

  Future<void> _dismissAnnouncement(Announcement ann) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_announcementDismissedKey, _fingerprint(ann));
    } catch (_) {}
  }

  String _fingerprint(Announcement ann) => '${ann.id}_${ann.updatedAt}';

  Future<void> _showAnnouncementDialog(
      BuildContext context, Announcement ann) async {
    await showDialog<void>(
      context: context,
      useRootNavigator: true,
      barrierDismissible: false,
      builder: (ctx) => _NotificationDialog(
        title: ann.title,
        content: ann.content,
        type: ann.type,
        date: ann.date,
      ),
    );
    await _api.confirmAnnouncement(ann);
    await _dismissAnnouncement(ann);
  }

  Future<void> _showFeedbackNotificationDialog(
      BuildContext context, FeedbackNotification item) async {
    final isRejected = item.status == 'rejected';
    final operator = item.repliedBy.isNotEmpty
        ? item.repliedBy
        : (item.assignee.isNotEmpty ? item.assignee : '管理员');
    final reason = isRejected ? item.rejectReason : item.resolveNote;
    final reasonLabel = isRejected ? '拒绝理由' : '完成说明';
    final content = '您提交的反馈「${item.title.isEmpty ? '无标题' : item.title}」'
        '${isRejected ? '已被拒绝' : '已处理完成'}。\n\n'
        '处理管理员：$operator\n'
        '$reasonLabel：${reason.isEmpty ? '（无说明）' : reason}';
    await showDialog<void>(
      context: context,
      useRootNavigator: true,
      barrierDismissible: false,
      builder: (ctx) => _NotificationDialog(
        title: isRejected ? '反馈已被拒绝' : '反馈处理完成',
        content: content,
        type: isRejected ? 'warning' : 'info',
        date: _formatDate(item.repliedAt),
        images: isRejected ? const [] : item.resolveImages,
      ),
    );
    await _api.confirmFeedbackNotification(item.id);
  }

  String _formatDate(String value) {
    if (value.isEmpty) return '';
    final d = DateTime.tryParse(value);
    if (d == null) return value;
    String pad(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${pad(d.month)}-${pad(d.day)}';
  }

  /// 昵称变更通知：弹窗展示，关闭后确认已读并同步本地昵称。
  Future<void> _showNicknameChangeDialog(
      BuildContext context, NicknameChangeNotice notice) async {
    final content = '管理员已将您的昵称修改为「${notice.newNickname}」。\n\n'
        '原昵称：${notice.oldNickname.isEmpty ? '-' : notice.oldNickname}\n'
        '修改原因：${notice.reason.isEmpty ? '（未填写）' : notice.reason}';
    await showDialog<void>(
      context: context,
      useRootNavigator: true,
      barrierDismissible: false,
      builder: (ctx) => _NotificationDialog(
        title: '昵称已被修改',
        content: content,
        type: 'info',
        date: _formatDate(notice.createdAt),
      ),
    );
    await _api.confirmNicknameChangeNotice(notice.id);
    await _ref.read(authProvider.notifier).updateNicknameLocally(notice.newNickname);
  }
}

final notificationServiceProvider = Provider<NotificationService>(
  (ref) => NotificationService(ref),
);

/// 通用通知弹窗：公告 / 反馈完成通知共用。
class _NotificationDialog extends StatelessWidget {
  const _NotificationDialog({
    required this.title,
    required this.content,
    this.type = 'info',
    this.date = '',
    this.images = const [],
  });
  final String title;
  final String content;
  final String type;
  final String date;
  final List<String> images;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isWarning = type == 'warning';
    final accent = isWarning ? const Color(0xFFB45309) : scheme.primary;
    return AlertDialog(
      title: Row(
        children: [
          Icon(isWarning ? Icons.warning_amber : Icons.campaign,
              color: accent, size: 22),
          const SizedBox(width: 8),
          Expanded(
            child: Text(title,
                style: const TextStyle(
                    fontSize: 17, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (date.isNotEmpty) ...[
              Text(date,
                  style: TextStyle(fontSize: 12, color: scheme.outline)),
              const SizedBox(height: 8),
            ],
            Text(content, style: const TextStyle(fontSize: 14, height: 1.6)),
            if (images.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final url in images)
                    GestureDetector(
                      onTap: () => _showImageViewer(context, url),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.network(
                          url,
                          width: 90,
                          height: 90,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => Container(
                            width: 90,
                            height: 90,
                            color: scheme.surfaceContainerHighest,
                            child: Icon(Icons.broken_image,
                                color: scheme.outline),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('知道了'),
        ),
      ],
    );
  }

  void _showImageViewer(BuildContext context, String url) {
    showDialog<void>(
      context: context,
      useRootNavigator: true,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.black,
        child: Stack(
          children: [
            InteractiveViewer(
              child: Image.network(url, fit: BoxFit.contain),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: IconButton(
                onPressed: () => Navigator.pop(ctx),
                icon: const Icon(Icons.close, color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
