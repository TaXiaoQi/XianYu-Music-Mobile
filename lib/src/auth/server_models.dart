library;
import '../i18n/i18n.dart';

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

class AcknowledgementItem {
  final String name;
  final String url;
  const AcknowledgementItem({required this.name, this.url = ''});

  factory AcknowledgementItem.fromJson(Map<String, dynamic> j) =>
      AcknowledgementItem(
        name: (j['name'] ?? '').toString(),
        url: (j['url'] ?? '').toString(),
      );
}

class AboutConfig {
  final String officialSiteUrl;
  final bool updateEnabled;
  final String projectUrl;
  final String referenceProjectUrl;
  final String joinGroupUrl;
  final List<AcknowledgementItem> acknowledgements;
  const AboutConfig({
    this.officialSiteUrl = 'https://www.xianyumusic.cn',
    this.updateEnabled = true,
    this.projectUrl = 'https://github.com/TaXiaoQi/XianYu-Music-Mobile',
    this.referenceProjectUrl = 'https://github.com/TaXiaoQi/XianYu-Music-Desktop',
    this.joinGroupUrl = '',
    this.acknowledgements = const [],
  });

  factory AboutConfig.fromJson(Map<String, dynamic> j) => AboutConfig(
        officialSiteUrl: (j['officialSiteUrl'] ?? '').toString(),
        updateEnabled: (j['updateEnabled'] as bool?) ?? true,
        projectUrl:
            (j['projectUrl'] ?? 'https://github.com/TaXiaoQi/XianYu-Music-Mobile')
                .toString(),
        referenceProjectUrl:
            (j['referenceProjectUrl'] ?? 'https://github.com/TaXiaoQi/XianYu-Music-Desktop')
                .toString(),
        joinGroupUrl: (j['joinGroupUrl'] ?? '').toString(),
        acknowledgements: (j['acknowledgements'] as List?)
                ?.map((e) => AcknowledgementItem.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
      );
}

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

class UserAgreement {
  final String title;
  final String content;
  const UserAgreement({this.title = '弦予音乐用户协议', this.content = ''});

  factory UserAgreement.fromJson(Map<String, dynamic> j) => UserAgreement(
        title: (j['title'] ?? tr('弦予音乐用户协议')).toString(),
        content: (j['content'] ?? '').toString(),
      );
}

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

class ProfileChangeLimitStatus {
  final String status;
  final bool todayBlocked;
  final String blockMessage;
  const ProfileChangeLimitStatus({
    this.status = 'none',
    this.todayBlocked = false,
    this.blockMessage = '',
  });
}

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
