/// 服务端接口数据模型（与桌面端 authService.ts / usageStats.ts 对齐）。
library;
import '../i18n/i18n.dart';

/// 公告（get_announcement 返回的单条公告）。
class Announcement {
  final String id;
  final String title;
  final String content;
  final String type;
  final String date;
  final String actionUrl;
  final String actionText;
  final String updatedAt;
  const Announcement({
    required this.id,
    required this.title,
    required this.content,
    this.type = 'info',
    this.date = '',
    this.actionUrl = '',
    this.actionText = '',
    this.updatedAt = '',
  });

  factory Announcement.fromJson(Map<String, dynamic> j) => Announcement(
        id: (j['id'] ?? '').toString(),
        title: (j['title'] ?? '').toString(),
        content: (j['content'] ?? '').toString(),
        type: (j['type'] ?? 'info').toString(),
        date: (j['date'] ?? '').toString(),
        actionUrl: (j['actionUrl'] ?? '').toString(),
        actionText: (j['actionText'] ?? '').toString(),
        updatedAt: (j['updatedAt'] ?? '').toString(),
      );
}

/// 关于页配置（get_about_config）。
class AboutConfig {
  final String officialSiteUrl;
  final String officialSiteText;
  final bool updateEnabled;
  final String updateText;
  final String projectUrl;
  final String projectText;
  final String referenceProjectUrl;
  final String referenceProjectText;
  final String joinGroupUrl;
  final String joinGroupText;
  const AboutConfig({
    this.officialSiteUrl = 'https://www.xianyumusic.cn',
    this.officialSiteText = '前往官网',
    this.updateEnabled = true,
    this.updateText = '检查更新',
    this.projectUrl = 'https://github.com/TaXiaoQi/XianYu-Music-Mobile',
    this.projectText = '开源地址',
    this.referenceProjectUrl = 'https://github.com/TaXiaoQi/XianYu-Music-Desktop',
    this.referenceProjectText = '参考项目',
    this.joinGroupUrl = '',
    this.joinGroupText = '加入群组',
  });

  factory AboutConfig.fromJson(Map<String, dynamic> j) => AboutConfig(
        officialSiteUrl: (j['officialSiteUrl'] ?? '').toString(),
        officialSiteText: (j['officialSiteText'] ?? tr('前往官网')).toString(),
        updateEnabled: (j['updateEnabled'] as bool?) ?? true,
        updateText: (j['updateText'] ?? tr('检查更新')).toString(),
        projectUrl: (j['projectUrl'] ?? 'https://github.com/TaXiaoQi/XianYu-Music-Mobile')
            .toString(),
        projectText: (j['projectText'] ?? tr('开源地址')).toString(),
        referenceProjectUrl:
            (j['referenceProjectUrl'] ?? 'https://github.com/TaXiaoQi/XianYu-Music-Desktop')
                .toString(),
        referenceProjectText: (j['referenceProjectText'] ?? tr('参考项目')).toString(),
        joinGroupUrl: (j['joinGroupUrl'] ?? '').toString(),
        joinGroupText: (j['joinGroupText'] ?? tr('加入群组')).toString(),
      );
}

/// 最新版本信息（get_latest_version）。
class LatestVersion {
  final int id;
  final String appName;
  final String version;
  final String content;
  final String downloadUrl;
  final int fileSize;
  final String status;
  final String updatedAt;
  const LatestVersion({
    this.id = 0,
    this.appName = '',
    this.version = '',
    this.content = '',
    this.downloadUrl = '',
    this.fileSize = 0,
    this.status = 'normal',
    this.updatedAt = '',
  });

  factory LatestVersion.fromJson(Map<String, dynamic> j) => LatestVersion(
        id: (j['id'] as num?)?.toInt() ?? 0,
        appName: (j['app_name'] ?? '').toString(),
        version: (j['version'] ?? '').toString(),
        content: (j['content'] ?? '').toString(),
        downloadUrl: (j['download_url'] ?? '').toString(),
        fileSize: (j['file_size'] as num?)?.toInt() ?? 0,
        status: (j['status'] ?? 'normal').toString(),
        updatedAt: (j['updated_at'] ?? '').toString(),
      );
}

/// 用户协议（get_user_agreement）。
class UserAgreement {
  final String title;
  final String content;
  const UserAgreement({this.title = '弦予音乐用户协议', this.content = ''});

  factory UserAgreement.fromJson(Map<String, dynamic> j) => UserAgreement(
        title: (j['title'] ?? tr('弦予音乐用户协议')).toString(),
        content: (j['content'] ?? '').toString(),
      );
}

/// 排行榜条目（get_leaderboard）。
class LeaderboardEntry {
  final int rank;
  final String username;
  final String nickname;
  final String ciyuanxiId;
  final String avatar;
  final int duration;
  final bool isMe;
  const LeaderboardEntry({
    required this.rank,
    required this.username,
    required this.nickname,
    required this.ciyuanxiId,
    required this.avatar,
    required this.duration,
    this.isMe = false,
  });

  factory LeaderboardEntry.fromJson(Map<String, dynamic> j) => LeaderboardEntry(
        rank: (j['rank'] as num?)?.toInt() ?? 0,
        username: (j['username'] ?? '').toString(),
        nickname: (j['nickname'] ?? '').toString(),
        ciyuanxiId: (j['ciyuanxi_id'] ?? '').toString(),
        avatar: (j['avatar'] ?? '').toString(),
        duration: (j['duration'] as num?)?.toInt() ?? 0,
        isMe: (j['is_me'] as bool?) ?? false,
      );
}

/// 排行榜数据。
class LeaderboardData {
  final List<LeaderboardEntry> leaderboard;
  final LeaderboardEntry? me;
  final int totalUsers;
  final String period;
  const LeaderboardData({
    required this.leaderboard,
    this.me,
    required this.totalUsers,
    this.period = 'total',
  });

  factory LeaderboardData.fromJson(Map<String, dynamic> j) => LeaderboardData(
        leaderboard: ((j['leaderboard'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(LeaderboardEntry.fromJson)
            .toList(),
        me: j['me'] is Map<String, dynamic>
            ? LeaderboardEntry.fromJson(j['me'] as Map<String, dynamic>)
            : null,
        totalUsers: (j['total_users'] as num?)?.toInt() ?? 0,
        period: (j['period'] ?? 'total').toString(),
      );
}

/// 反馈条目（list_my_feedback）。
class FeedbackItem {
  final int id;
  final String title;
  final String content;
  final String feedbackType;
  final List<String> images;
  final String status;
  final String category;
  final String assignee;
  final String repliedBy;
  final String resolveNote;
  final String rejectReason;
  final List<String> resolveImages;
  final bool hasErrorLogs;
  final bool hasAllLogs;
  final String createdAt;
  final String repliedAt;
  final String updatedAt;
  const FeedbackItem({
    required this.id,
    required this.title,
    required this.content,
    required this.feedbackType,
    required this.images,
    required this.status,
    required this.category,
    required this.assignee,
    required this.repliedBy,
    required this.resolveNote,
    required this.rejectReason,
    required this.resolveImages,
    required this.hasErrorLogs,
    required this.hasAllLogs,
    required this.createdAt,
    required this.repliedAt,
    required this.updatedAt,
  });

  factory FeedbackItem.fromJson(Map<String, dynamic> j) => FeedbackItem(
        id: (j['id'] as num?)?.toInt() ?? 0,
        title: (j['title'] ?? '').toString(),
        content: (j['content'] ?? '').toString(),
        feedbackType: (j['feedbackType'] ?? 'problem').toString(),
        images: ((j['images'] as List?) ?? const [])
            .whereType<String>()
            .toList(),
        status: (j['status'] ?? '').toString(),
        category: (j['category'] ?? '').toString(),
        assignee: (j['assignee'] ?? '').toString(),
        repliedBy: (j['repliedBy'] ?? '').toString(),
        resolveNote: (j['resolveNote'] ?? '').toString(),
        rejectReason: (j['rejectReason'] ?? '').toString(),
        resolveImages: ((j['resolveImages'] as List?) ?? const [])
            .whereType<String>()
            .toList(),
        hasErrorLogs: (j['hasErrorLogs'] as bool?) ?? false,
        hasAllLogs: (j['hasAllLogs'] as bool?) ?? false,
        createdAt: (j['createdAt'] ?? '').toString(),
        repliedAt: (j['repliedAt'] ?? '').toString(),
        updatedAt: (j['updatedAt'] ?? '').toString(),
      );
}

/// 反馈处理通知（get_my_feedback_notifications）。
class FeedbackNotification {
  final int id;
  final String title;
  final String content;
  final String status;
  final String assignee;
  final String repliedBy;
  final String resolveNote;
  final String rejectReason;
  final List<String> resolveImages;
  final String repliedAt;
  final String updatedAt;
  const FeedbackNotification({
    required this.id,
    required this.title,
    required this.content,
    required this.status,
    required this.assignee,
    required this.repliedBy,
    required this.resolveNote,
    required this.rejectReason,
    required this.resolveImages,
    required this.repliedAt,
    required this.updatedAt,
  });

  factory FeedbackNotification.fromJson(Map<String, dynamic> j) =>
      FeedbackNotification(
        id: (j['id'] as num?)?.toInt() ?? 0,
        title: (j['title'] ?? '').toString(),
        content: (j['content'] ?? '').toString(),
        status: (j['status'] ?? '').toString(),
        assignee: (j['assignee'] ?? '').toString(),
        repliedBy: (j['repliedBy'] ?? '').toString(),
        resolveNote: (j['resolve_note'] ?? '').toString(),
        rejectReason: (j['reject_reason'] ?? '').toString(),
        resolveImages: ((j['resolve_images'] as List?) ?? const [])
            .whereType<String>()
            .toList(),
        repliedAt: (j['replied_at'] ?? '').toString(),
        updatedAt: (j['updated_at'] ?? '').toString(),
      );
}

/// 昵称变更通知（get_nickname_change_notices）。
class NicknameChangeNotice {
  final int id;
  final String oldNickname;
  final String newNickname;
  final String reason;
  final String changedBy;
  final String createdAt;
  const NicknameChangeNotice({
    required this.id,
    required this.oldNickname,
    required this.newNickname,
    required this.reason,
    required this.changedBy,
    required this.createdAt,
  });

  factory NicknameChangeNotice.fromJson(Map<String, dynamic> j) =>
      NicknameChangeNotice(
        id: (j['id'] as num?)?.toInt() ?? 0,
        oldNickname: (j['old_nickname'] ?? '').toString(),
        newNickname: (j['new_nickname'] ?? '').toString(),
        reason: (j['reason'] ?? '').toString(),
        changedBy: (j['changed_by'] ?? '').toString(),
        createdAt: (j['created_at'] ?? '').toString(),
      );
}

/// 封禁检查结果（check_ban_status）。
class BanStatus {
  final bool banned;
  final String type;
  final String reason;
  const BanStatus({this.banned = false, this.type = 'account', this.reason = ''});

  factory BanStatus.fromJson(Map<String, dynamic> j) => BanStatus(
        banned: (j['banned'] as bool?) ?? false,
        type: (j['type'] ?? 'account').toString(),
        reason: (j['reason'] ?? '').toString(),
      );
}

/// 昵称/头像变更审核状态 + 今日变更限制（get_nickname_status / get_avatar_status）。
class ProfileChangeLimitStatus {
  final String status; // pending / rejected / none
  final bool todayBlocked;
  final String blockMessage;
  const ProfileChangeLimitStatus({
    this.status = 'none',
    this.todayBlocked = false,
    this.blockMessage = '',
  });
}

/// 服务器负载状态（get_server_load，自动同步用）。
class ServerLoadStatus {
  final bool rateLimited;
  final int activeSyncCount;
  final bool busy;
  final int suggestedDelaySeconds;
  final int bandwidthUsagePercent;
  const ServerLoadStatus({
    this.rateLimited = false,
    this.activeSyncCount = 0,
    this.busy = false,
    this.suggestedDelaySeconds = 60,
    this.bandwidthUsagePercent = 0,
  });

  factory ServerLoadStatus.fromJson(Map<String, dynamic> j) => ServerLoadStatus(
        rateLimited: (j['rateLimited'] as bool?) ?? false,
        activeSyncCount: (j['activeSyncCount'] as num?)?.toInt() ?? 0,
        busy: (j['busy'] as bool?) ?? false,
        suggestedDelaySeconds:
            (j['suggestedDelaySeconds'] as num?)?.toInt() ?? 60,
        bandwidthUsagePercent:
            (j['bandwidthUsagePercent'] as num?)?.toInt() ?? 0,
      );
}
