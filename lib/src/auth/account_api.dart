import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';
import 'auth_provider.dart';
import 'server_models.dart';
import '../i18n/i18n.dart';

/// 应用版本（与 pubspec.yaml version 保持一致）。
const appVersion = '1.0.0-beta7';

/// 热搜条目（get_hot_search）。
class HotSearchItem {
  final String keyword;
  final int count;
  const HotSearchItem({required this.keyword, required this.count});

  factory HotSearchItem.fromJson(Map<String, dynamic> j) => HotSearchItem(
        keyword: (j['keyword'] ?? '').toString(),
        count: (j['count'] as num?)?.toInt() ?? 0,
      );
}

/// 账号 API 服务：公告/关于/版本/协议/热搜/反馈/排行榜/统计上报。
///
/// 复用 [AuthNotifier.requestAction]（自动注入 token + 会话失效处理），
/// 与桌面端 authService.ts / usageStats.ts / announcement.ts / leaderboardService.ts 对齐。
class AccountApi {
  AccountApi(this._ref);
  final Ref _ref;

  AuthNotifier get _auth => _ref.read(authProvider.notifier);

  Future<Map<String, dynamic>> _action(
          String action, Map<String, dynamic> body,
          {int? fetchTimeoutMs}) =>
      _auth.requestAction(action, body, fetchTimeoutMs: fetchTimeoutMs);

  String? get _ciyuanxiId =>
      _auth.currentState.user?.ciyuanxiId ?? _auth.currentState.user?.id;

  // ─── 公告 ───────────────────────────────────────────────

  Future<Announcement?> fetchAnnouncement() async {
    try {
      final data = await _action('get_announcement', {
        'ciyuanxi_id': _ciyuanxiId ?? '',
        'device_id': await _auth.deviceId(),
      }, fetchTimeoutMs: 15000);
      if (data['id'] == null ||
          data['title'] == null ||
          data['content'] == null) {
        return null;
      }
      return Announcement.fromJson(data);
    } catch (_) {
      return null;
    }
  }

  Future<void> confirmAnnouncement(Announcement ann) async {
    await _action('confirm_announcement', {
      'announcement_id': ann.id,
      'announcement_updated_at': ann.updatedAt,
      'ciyuanxi_id': _ciyuanxiId ?? '',
      'device_id': await _auth.deviceId(),
    }, fetchTimeoutMs: 15000);
  }

  // ─── 关于页配置 ─────────────────────────────────────────

  Future<AboutConfig> fetchAboutConfig() async {
    try {
      // platform=mobile：服务端据此把开源地址换成本仓库、参考项目换成桌面端仓库
      final data =
          await _action('get_about_config', {'platform': 'mobile'}, fetchTimeoutMs: 8000);
      return AboutConfig.fromJson(data);
    } catch (_) {
      return const AboutConfig();
    }
  }

  // ─── 版本更新 ───────────────────────────────────────────

  Future<LatestVersion?> fetchServerUpdate() async {
    try {
      final data = await _action('get_latest_version',
        {'platform': 'mobile'}, fetchTimeoutMs: 15000);
      if (data['version'] == null) return null;
      return LatestVersion.fromJson(data);
    } catch (_) {
      return null;
    }
  }

  // ─── 用户协议 ───────────────────────────────────────────

  Future<UserAgreement> getUserAgreement() async {
    final data = await _action('get_user_agreement', {});
    return UserAgreement.fromJson(data);
  }

  // ─── 热搜 ───────────────────────────────────────────────

  Future<List<HotSearchItem>> fetchHotSearch({int limit = 10}) async {
    try {
      final data =
          await _action('get_hot_search', {'limit': limit}, fetchTimeoutMs: 8000);
      final list = (data['list'] as List?) ?? const [];
      return list
          .whereType<Map<String, dynamic>>()
          .map(HotSearchItem.fromJson)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  // ─── 反馈 ───────────────────────────────────────────────

  Future<int> submitFeedback({
    required String title,
    required String content,
    String feedbackType = 'problem',
    String? errorLogs,
    String? allLogs,
    List<String>? images,
  }) async {
    final user = _auth.currentState.user;
    final ciyuanxiId = user?.ciyuanxiId?.trim();
    if (ciyuanxiId == null || ciyuanxiId.isEmpty) {
      throw AuthException(tr('请先登录后再提交反馈'));
    }
    final payload = <String, dynamic>{
      'ciyuanxi_id': ciyuanxiId,
      'nickname': user?.nickname.trim() ?? '',
      'title': title.trim(),
      'content': content.trim(),
      'feedback_type': feedbackType,
      'platform': 'mobile',
      'app_version': appVersion,
      'device_id': await _auth.deviceId(),
      if (errorLogs != null && errorLogs.isNotEmpty) 'error_logs': errorLogs,
      if (allLogs != null && allLogs.isNotEmpty) 'all_logs': allLogs,
      if (images != null && images.isNotEmpty) 'images': images,
    };
    final data = await _action('submit_feedback', payload);
    return (data['id'] as num?)?.toInt() ?? 0;
  }

  Future<List<FeedbackItem>> getMyFeedback() async {
    final user = _auth.currentState.user;
    final ciyuanxiId = user?.ciyuanxiId?.trim();
    if (ciyuanxiId == null || ciyuanxiId.isEmpty) {
      throw AuthException(tr('请先登录后再查看反馈'));
    }
    final data = await _action('list_my_feedback', {'ciyuanxi_id': ciyuanxiId});
    final list = (data['list'] as List?) ?? const [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(FeedbackItem.fromJson)
        .toList();
  }

  Future<int> submitAppeal({
    required String ciyuanxiId,
    required String nickname,
    required String content,
  }) async {
    final data = await _action('submit_appeal', {
      'ciyuanxi_id': ciyuanxiId,
      'nickname': nickname.trim(),
      'content': content.trim(),
      'device_id': await _auth.deviceId(),
    });
    return (data['id'] as num?)?.toInt() ?? 0;
  }

  /// 获取未确认的反馈完成通知列表。
  Future<List<FeedbackNotification>> getMyFeedbackNotifications() async {
    final user = _auth.currentState.user;
    final ciyuanxiId = user?.ciyuanxiId?.trim();
    if (ciyuanxiId == null || ciyuanxiId.isEmpty) return const [];
    try {
      final data = await _action('get_my_feedback_notifications', {
        'ciyuanxi_id': ciyuanxiId,
        'device_id': await _auth.deviceId(),
      }, fetchTimeoutMs: 15000);
      final list = (data['list'] as List?) ?? const [];
      return list
          .whereType<Map<String, dynamic>>()
          .map(FeedbackNotification.fromJson)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// 确认反馈完成通知已读，避免重复弹出。
  Future<void> confirmFeedbackNotification(int id) async {
    final user = _auth.currentState.user;
    final ciyuanxiId = user?.ciyuanxiId?.trim() ?? '';
    try {
      await _action('confirm_feedback_notification', {
        'id': id,
        'ciyuanxi_id': ciyuanxiId,
      }, fetchTimeoutMs: 15000);
    } catch (_) {
      // 确认失败静默，下次启动仍会弹出。
    }
  }

  // ─── 昵称变更通知 ───────────────────────────────────────

  /// 获取未确认的昵称变更通知（管理员修改昵称后）。
  Future<List<NicknameChangeNotice>> getNicknameChangeNotices() async {
    final ciyuanxiId = _ciyuanxiId;
    if (ciyuanxiId == null || ciyuanxiId.isEmpty) return const [];
    try {
      final data = await _action('get_nickname_change_notices', {
        'ciyuanxi_id': ciyuanxiId,
      }, fetchTimeoutMs: 15000);
      final list = (data['list'] as List?) ?? const [];
      return list
          .whereType<Map<String, dynamic>>()
          .map(NicknameChangeNotice.fromJson)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// 确认昵称变更通知已读，避免重复弹出。
  Future<void> confirmNicknameChangeNotice(int id) async {
    final ciyuanxiId = _ciyuanxiId ?? '';
    if (id <= 0) return;
    try {
      await _action('confirm_nickname_change_notice', {
        'id': id,
        'ciyuanxi_id': ciyuanxiId,
      }, fetchTimeoutMs: 15000);
    } catch (_) {
      // 确认失败静默，下次启动仍会弹出。
    }
  }

  // ─── 设置同步 ───────────────────────────────────────────

  /// 上传本地设置到云端（排除设备相关字段）。
  Future<void> uploadSettings(AppSettings settings) async {
    final ciyuanxiId = _ciyuanxiId;
    if (ciyuanxiId == null || ciyuanxiId.isEmpty) {
      throw AuthException(tr('请先登录后再同步设置'));
    }
    await _action('settings_sync_upload', {
      'user_id': ciyuanxiId,
      'platform': 'mobile',
      'settings': settingsToSyncMap(settings),
    }, fetchTimeoutMs: 20000);
  }

  /// 从云端下载设置。
  Future<Map<String, dynamic>?> downloadSettings() async {
    final ciyuanxiId = _ciyuanxiId;
    if (ciyuanxiId == null || ciyuanxiId.isEmpty) {
      throw AuthException(tr('请先登录后再同步设置'));
    }
    final data = await _action('settings_sync_download', {
      'user_id': ciyuanxiId,
      'platform': 'mobile',
    }, fetchTimeoutMs: 15000);
    final settings = data['settings'];
    if (settings is! Map<String, dynamic>) return null;
    return settings;
  }

  /// 从云端下载设置（含上传时间元数据，供冲突弹窗展示）。
  Future<({Map<String, dynamic>? settings, DateTime? uploadedAt})>
      downloadSettingsWithMeta() async {
    final ciyuanxiId = _ciyuanxiId;
    if (ciyuanxiId == null || ciyuanxiId.isEmpty) {
      throw AuthException(tr('请先登录后再同步设置'));
    }
    final data = await _action('settings_sync_download', {
      'user_id': ciyuanxiId,
      'platform': 'mobile',
    }, fetchTimeoutMs: 15000);
    final settings = data['settings'];
    DateTime? uploadedAt;
    final uploadedAtStr = data['uploaded_at'];
    if (uploadedAtStr is String && uploadedAtStr.isNotEmpty) {
      uploadedAt = DateTime.tryParse(uploadedAtStr);
    }
    return (
      settings: settings is Map<String, dynamic> ? settings : null,
      uploadedAt: uploadedAt,
    );
  }

  // ─── 服务器负载（自动同步用） ───────────────────────────

  /// 查询服务器负载状态；失败返回 null。
  Future<ServerLoadStatus?> getServerLoad() async {
    final ciyuanxiId = _ciyuanxiId;
    if (ciyuanxiId == null || ciyuanxiId.isEmpty) return null;
    try {
      final data = await _action('get_server_load', {
        'user_id': ciyuanxiId,
      }, fetchTimeoutMs: 8000);
      return ServerLoadStatus.fromJson(data);
    } catch (_) {
      return null;
    }
  }

  // ─── 收藏同步 ───────────────────────────────────────────

  /// 上传收藏歌曲到云端。
  Future<int> uploadFavorites(List<Map<String, dynamic>> favorites) async {
    final ciyuanxiId = _ciyuanxiId;
    if (ciyuanxiId == null || ciyuanxiId.isEmpty) {
      throw AuthException(tr('请先登录后再同步收藏'));
    }
    final data = await _action('favorites_sync_upload', {
      'user_id': ciyuanxiId,
      'favorites': favorites,
    }, fetchTimeoutMs: 15000);
    return (data['song_count'] as num?)?.toInt() ?? 0;
  }

  /// 从云端下载收藏歌曲。
  Future<List<Map<String, dynamic>>> downloadFavorites() async {
    final ciyuanxiId = _ciyuanxiId;
    if (ciyuanxiId == null || ciyuanxiId.isEmpty) {
      throw AuthException(tr('请先登录后再同步收藏'));
    }
    final data = await _action('favorites_sync_download', {
      'user_id': ciyuanxiId,
    }, fetchTimeoutMs: 15000);
    return ((data['favorites'] as List?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
  }

  // ─── 播放历史同步 ───────────────────────────────────────

  /// 上传播放历史到云端。
  Future<int> uploadHistory(List<Map<String, dynamic>> history) async {
    final ciyuanxiId = _ciyuanxiId;
    if (ciyuanxiId == null || ciyuanxiId.isEmpty) {
      throw AuthException(tr('请先登录后再同步播放历史'));
    }
    final data = await _action('history_sync_upload', {
      'user_id': ciyuanxiId,
      'history': history,
    }, fetchTimeoutMs: 30000);
    return (data['history_count'] as num?)?.toInt() ?? 0;
  }

  /// 从云端下载播放历史。
  Future<List<Map<String, dynamic>>> downloadHistory() async {
    final ciyuanxiId = _ciyuanxiId;
    if (ciyuanxiId == null || ciyuanxiId.isEmpty) {
      throw AuthException(tr('请先登录后再同步播放历史'));
    }
    final data = await _action('history_sync_download', {
      'user_id': ciyuanxiId,
    }, fetchTimeoutMs: 15000);
    return ((data['history'] as List?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
  }

  // ─── 歌单同步 ───────────────────────────────────────────

  /// 删除云端歌单。
  Future<void> deleteCloudPlaylist(int playlistId) async {
    final ciyuanxiId = _ciyuanxiId;
    if (ciyuanxiId == null || ciyuanxiId.isEmpty) {
      throw AuthException(tr('请先登录后再同步歌单'));
    }
    await _action('delete_playlist', {
      'user_id': ciyuanxiId,
      'playlist_id': playlistId,
    }, fetchTimeoutMs: 15000);
  }

  /// 歌单分片上传（start → chunk×N → finish）。
  Future<({int playlistCount, int songTotal})> fileSyncUpload(
      List<Map<String, dynamic>> playlists) async {
    final ciyuanxiId = _ciyuanxiId;
    if (ciyuanxiId == null || ciyuanxiId.isEmpty) {
      throw AuthException(tr('请先登录后再同步歌单'));
    }
    await _action('file_sync_upload_start', {'user_id': ciyuanxiId},
        fetchTimeoutMs: 50000);
    const maxSongsPerChunk = 1500;
    final chunks = <List<Map<String, dynamic>>>[];
    var current = <Map<String, dynamic>>[];
    var currentSongs = 0;
    for (final p in playlists) {
      final songs = (p['songs'] as List?) ?? const [];
      if (current.isNotEmpty && currentSongs + songs.length > maxSongsPerChunk) {
        chunks.add(current);
        current = [];
        currentSongs = 0;
      }
      current.add(p);
      currentSongs += songs.length;
    }
    if (current.isNotEmpty) chunks.add(current);
    for (var i = 0; i < chunks.length; i++) {
      await _action('file_sync_upload_chunk', {
        'user_id': ciyuanxiId,
        'chunk_index': i,
        'total_chunks': chunks.length,
        'chunk_data': chunks[i],
      }, fetchTimeoutMs: 65000);
    }
    final finish = await _action('file_sync_upload_finish', {
      'user_id': ciyuanxiId,
    }, fetchTimeoutMs: 50000);
    return (
      playlistCount: (finish['playlist_count'] as num?)?.toInt() ?? 0,
      songTotal: (finish['song_total'] as num?)?.toInt() ?? 0,
    );
  }

  /// 从云端下载完整歌单数据。
  Future<Map<String, dynamic>?> fileSyncDownload() async {
    final ciyuanxiId = _ciyuanxiId;
    if (ciyuanxiId == null || ciyuanxiId.isEmpty) {
      throw AuthException(tr('请先登录后再同步歌单'));
    }
    final data = await _action('file_sync_download', {'user_id': ciyuanxiId},
        fetchTimeoutMs: 30000);
    return data.isEmpty ? null : data;
  }

  // ─── 插件同步 ───────────────────────────────────────────

  /// 上传单个插件到云端（subscriptions 随每个请求整包替换云端订阅列表）。
  Future<void> uploadPlugin(
    Map<String, dynamic> plugin, {
    bool isFirst = false,
    List<Map<String, dynamic>>? subscriptions,
  }) async {
    final ciyuanxiId = _ciyuanxiId;
    if (ciyuanxiId == null || ciyuanxiId.isEmpty) {
      throw AuthException(tr('请先登录后再同步插件'));
    }
    await _action('plugin_sync_upload_one', {
      'user_id': ciyuanxiId,
      'plugin': plugin,
      'is_first': isFirst,
      'subscriptions': ?subscriptions,
    }, fetchTimeoutMs: 60000);
  }

  /// 从云端下载插件同步快照（含 plugins 与 subscriptions）。
  Future<Map<String, dynamic>> downloadPluginSnapshot() async {
    final ciyuanxiId = _ciyuanxiId;
    if (ciyuanxiId == null || ciyuanxiId.isEmpty) {
      throw AuthException(tr('请先登录后再同步插件'));
    }
    return _action('plugin_sync_download', {'user_id': ciyuanxiId},
        fetchTimeoutMs: 15000);
  }

  // ─── 壁纸中心 ───────────────────────────────────────────

  /// 壁纸列表原始字段映射（camelCase 优先、snake_case 兜底，
  /// 与桌面端 WallpaperGallery 容错逻辑一致）。
  static Map<String, dynamic> normalizeWallpaper(Map<dynamic, dynamic> w) => {
        'id': (w['id'] as num?)?.toInt() ?? 0,
        'title': (w['title'] as String?) ?? '',
        'description': (w['description'] as String?) ?? '',
        'imageUrl': (w['imageUrl'] ?? w['image_url'] ?? w['image'] ?? '')
            as String,
        'thumbnailUrl': (w['thumbnailUrl'] ??
            w['thumbnail_url'] ??
            w['imageUrl'] ??
            w['image_url'] ??
            w['image'] ??
            '') as String,
        'category': (w['category'] as String?) ?? '',
        'status': (w['status'] as String?) ?? 'pending',
        'uploaderId':
            (w['uploaderId'] ?? w['uploader_id'] ?? w['ciyuanxi_id'] ?? '')
                as String,
        'uploaderNickname':
            (w['uploaderNickname'] ?? w['uploaded_by_nickname'] ?? w['nickname'] ?? '')
                as String,
        'createdAt': (w['createdAt'] ?? w['created_at'] ?? '') as String,
      };

  /// 获取移动端壁纸广场列表（无需登录）。
  Future<List<Map<String, dynamic>>> fetchWallpapers() async {
    final data = await _auth.requestActionList(
        'list_wallpapers', {'platform': 'mobile'},
        fetchTimeoutMs: 15000);
    final list = data is List ? data : const [];
    return list
        .whereType<Map>()
        .map((m) => normalizeWallpaper(m.cast<String, dynamic>()))
        .toList();
  }

  /// 获取当前登录用户的上传列表（含审核状态）。
  Future<List<Map<String, dynamic>>> fetchMyWallpapers() async {
    final ciyuanxiId = _ciyuanxiId;
    if (ciyuanxiId == null || ciyuanxiId.isEmpty) {
      throw AuthException(tr('请先登录账号后再查看我的上传'));
    }
    final data = await _auth.requestActionList('my_wallpapers', {
      'ciyuanxi_id': ciyuanxiId,
      'platform': 'mobile',
    }, fetchTimeoutMs: 15000);
    final list = data is List ? data : const [];
    return list
        .whereType<Map>()
        .map((m) => normalizeWallpaper(m.cast<String, dynamic>()))
        .toList();
  }

  /// 上传壁纸（imageData 为 data URL base64 JPEG）。
  Future<void> uploadWallpaper({
    required String title,
    required String description,
    required String category,
    required String imageData,
  }) async {
    final ciyuanxiId = _ciyuanxiId;
    if (ciyuanxiId == null || ciyuanxiId.isEmpty) {
      throw AuthException(tr('请先登录账号后再上传壁纸'));
    }
    await _action('upload_wallpaper', {
      'ciyuanxi_id': ciyuanxiId,
      'nickname': _auth.currentState.user?.nickname ?? '',
      'title': title,
      'description': description,
      'category': category.trim().isEmpty ? tr('用户上传') : category.trim(),
      'platform': 'mobile',
      'image_data': imageData,
    }, fetchTimeoutMs: 90000);
  }

  // ─── 排行榜 ─────────────────────────────────────────────

  /// 获取排行榜。登录用户先上报本地听歌时长（日/周/总）再拉取。
  Future<LeaderboardData> fetchLeaderboard({
    int limit = 50,
    String period = 'total',
    Map<String, int>? durations,
  }) async {
    final ciyuanxiId = _ciyuanxiId;
    if (ciyuanxiId != null && ciyuanxiId.isNotEmpty && durations != null) {
      await _reportListenStats(ciyuanxiId, durations);
    }
    final data = await _action('get_leaderboard', {
      if (ciyuanxiId != null && ciyuanxiId.isNotEmpty) 'ciyuanxi_id': ciyuanxiId,
      'limit': limit,
      'period': period,
    }, fetchTimeoutMs: 12000);
    return LeaderboardData.fromJson(data);
  }

  Future<void> _reportListenStats(
      String ciyuanxiId, Map<String, int> durations) async {
    try {
      await _action('report_listen_stats', {
        'ciyuanxi_id': ciyuanxiId,
        'duration': durations['total'] ?? 0,
        'daily_duration': durations['daily'] ?? 0,
        'weekly_duration': durations['weekly'] ?? 0,
        'total_duration': durations['total'] ?? 0,
        'unique_songs_count': 0,
      }, fetchTimeoutMs: 8000);
    } catch (_) {
      // 上报失败不影响排行榜获取。
    }
  }

  /// 上报本地听歌时长到账号（服务端按 MAX 合并，跨端累计总时长）。
  /// 登录态下播放落库 / 首页统计读取时调用。
  Future<void> reportListenStats(Map<String, int> durations) async {
    final ciyuanxiId = _ciyuanxiId;
    if (ciyuanxiId == null || ciyuanxiId.isEmpty) return;
    await _reportListenStats(ciyuanxiId, durations);
  }

  /// 获取账号累计听歌时长（秒）与唯一歌曲数，登录后合并进本地统计（跨端同步）。
  Future<Map<String, dynamic>> fetchListenStats() async {
    final ciyuanxiId = _ciyuanxiId;
    if (ciyuanxiId == null || ciyuanxiId.isEmpty) return const {};
    try {
      return await _action(
          'get_listen_stats', {'ciyuanxi_id': ciyuanxiId},
          fetchTimeoutMs: 10000);
    } catch (_) {
      return const {};
    }
  }

  // ─── 统计上报（fire-and-forget） ────────────────────────

  Future<void> reportAppOpen() async {
    final info = await _deviceInfo();
    await _fireAndForget('open', {...info, 'ciyuanxi_id': _ciyuanxiId ?? ''});
  }

  Future<void> reportSearch(
      String keyword, String source, int resultCount) async {
    final trimmed = keyword.trim();
    if (trimmed.isEmpty) return;
    final info = await _deviceInfo();
    await _fireAndForget('search', {
      'device_id': info['device_id'],
      'keyword': trimmed,
      'source': source,
      'result_count': resultCount,
    });
  }

  Future<void> reportInputStats(int charCount) async {
    if (charCount <= 0) return;
    final info = await _deviceInfo();
    await _fireAndForget('input_stats', {
      'device_id': info['device_id'],
      'char_count': charCount,
    });
  }

  Future<void> reportError({
    required String errorType,
    required String errorMessage,
    String errorStack = '',
    String page = '',
  }) async {
    final info = await _deviceInfo();
    await _fireAndForget('error', {
      ...info,
      'platform': 'android',
      'device_brand': '',
      'error_type': errorType,
      'error_message': errorMessage,
      'error_stack': errorStack,
      'page': page,
    });
  }

  Future<void> reportUserBehavior({
    required String songId,
    required String songName,
    required String singer,
    required String songHash,
    required String source,
    required String action,
    required int listenDuration,
    required int playCount,
  }) async {
    final info = await _deviceInfo();
    await _fireAndForget('report_user_behavior', {
      ...info,
      'song_id': songId,
      'song_name': songName,
      'singer': singer,
      'song_hash': songHash,
      'source': source,
      'action': action,
      'listen_duration': listenDuration,
      'play_count': playCount,
    });
  }

  Future<Map<String, dynamic>> _deviceInfo() async {
    return {
      'device_id': await _auth.deviceId(),
      'app_version': appVersion,
      'os_version': 'Android',
      'device_model': 'Android',
    };
  }

  Future<void> _fireAndForget(String action, Map<String, dynamic> body) async {
    try {
      await _action(action, body);
    } catch (_) {
      // 上报失败静默。
    }
  }
}

final accountApiProvider = Provider<AccountApi>((ref) => AccountApi(ref));

/// 设置同步序列化：排除设备相关字段（下载路径），与桌面端 settingsSync.ts 对齐。
Map<String, dynamic> settingsToSyncMap(AppSettings s) => {
      'volume': s.volume,
      'playMode': s.playMode,
      'keepScreenOn': s.keepScreenOn,
      'themeMode': s.themeMode.index,
      'accentColor': s.accentColor,
      'showQualityBadges': s.showQualityBadges,
      'onlineDefaultQuality': s.onlineDefaultQuality,
      'libraryMinDurationSeconds': s.libraryMinDurationSeconds,
      'showLyricsTranslation': s.showLyricsTranslation,
      'enableWordEffect': s.enableWordEffect,
      'downloadQuality': s.downloadQuality,
      'downloadLyrics': s.downloadLyrics,
      'organizeRule': s.organizeRule,
    };

/// 将云端设置映射合并回本地 AppSettings（缺失字段保留本地值）。
AppSettings applySyncedSettings(AppSettings local, Map<String, dynamic> cloud) {
  int themeIndex(String key) {
    final v = cloud[key];
    if (v is int) return v;
    if (v is String) {
      return switch (v) {
        'light' => 1,
        'dark' => 2,
        _ => 0,
      };
    }
    return local.themeMode.index;
  }

  return local.copyWith(
    volume: (cloud['volume'] as num?)?.toDouble() ?? local.volume,
    playMode: (cloud['playMode'] as num?)?.toInt() ?? local.playMode,
    keepScreenOn: (cloud['keepScreenOn'] as bool?) ?? local.keepScreenOn,
    themeMode: ThemeModePreference.values[themeIndex('themeMode')],
    accentColor: (cloud['accentColor'] as num?)?.toInt() ?? local.accentColor,
    showQualityBadges:
        (cloud['showQualityBadges'] as bool?) ?? local.showQualityBadges,
    onlineDefaultQuality:
        (cloud['onlineDefaultQuality'] as String?) ?? local.onlineDefaultQuality,
    libraryMinDurationSeconds: (cloud['libraryMinDurationSeconds'] as num?)
            ?.toInt() ??
        local.libraryMinDurationSeconds,
    showLyricsTranslation:
        (cloud['showLyricsTranslation'] as bool?) ?? local.showLyricsTranslation,
    enableWordEffect:
        (cloud['enableWordEffect'] as bool?) ?? local.enableWordEffect,
    downloadQuality:
        (cloud['downloadQuality'] as String?) ?? local.downloadQuality,
    downloadLyrics: (cloud['downloadLyrics'] as bool?) ?? local.downloadLyrics,
    organizeRule: (cloud['organizeRule'] as String?) ?? local.organizeRule,
  );
}

/// 比较本地设置与云端设置是否一致（排除设备相关字段，与桌面端 areSettingsEqual 对齐）。
///
/// 仅比较同步字段（settingsToSyncMap 的键集合）；云端缺字段视为与本地一致
/// （本地保留）；themeMode 兼容 int/string 两种存储表示。
bool areSettingsEqual(AppSettings local, Map<String, dynamic> cloud) {
  final localMap = settingsToSyncMap(local);
  for (final entry in localMap.entries) {
    var cloudVal = cloud[entry.key];
    if (cloudVal == null) continue;
    if (entry.key == 'themeMode' && cloudVal is String) {
      cloudVal = switch (cloudVal) {
        'light' => 1,
        'dark' => 2,
        _ => 0,
      };
    }
    if (cloudVal != entry.value) return false;
  }
  return true;
}
