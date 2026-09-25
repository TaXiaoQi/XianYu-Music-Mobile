import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';
import '../device/device_info.dart' show fetchDeviceInfo;
import 'auth_provider.dart';
import 'server_models.dart';
import '../i18n/i18n.dart';

const appVersion = '1.0.2';

class HotSearchItem {
  final String keyword;
  final int count;
  const HotSearchItem({required this.keyword, required this.count});

  factory HotSearchItem.fromJson(Map<String, dynamic> j) => HotSearchItem(
        keyword: (j['keyword'] ?? '').toString(),
        count: (j['count'] as num?)?.toInt() ?? 0,
      );
}

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

  String? get ciyuanxiId => _ciyuanxiId;

  Future<Announcement?> fetchAnnouncement() async {
    try {
      final data = await _action('get_announcement', {
        'ciyuanxi_id': _ciyuanxiId ?? '',
        'device_id': await _auth.deviceId(),
        'platform': 'mobile',
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

  /// 服务器下发的隐私政策。null 表示无下发（用客户端内置版本）。
  Future<PrivacyPolicyRemote?> fetchPrivacyPolicy() async {
    try {
      final data = await _action('get_privacy_policy', {
        'ciyuanxi_id': _ciyuanxiId ?? '',
        'device_id': await _auth.deviceId(),
        'platform': 'mobile',
      }, fetchTimeoutMs: 6000);
      final id = (data['id'] ?? '').toString();
      final content = (data['content'] ?? '').toString();
      final updatedAt = (data['updatedAt'] ?? '').toString();
      if (id.isEmpty || content.isEmpty || updatedAt.isEmpty) return null;
      return PrivacyPolicyRemote(id: id, content: content, updatedAt: updatedAt);
    } catch (_) {
      return null;
    }
  }

  /// 确认上报（失败忽略，弹窗与否由客户端本地 fingerprint 判断）。
  Future<void> confirmPrivacyPolicy(PrivacyPolicyRemote policy) async {
    try {
      await _action('confirm_privacy_policy', {
        'policy_id': policy.id,
        'policy_updated_at': policy.updatedAt,
        'ciyuanxi_id': _ciyuanxiId ?? '',
        'device_id': await _auth.deviceId(),
      }, fetchTimeoutMs: 6000);
    } catch (_) {}
  }

  Future<AboutConfig> fetchAboutConfig() async {
    try {
      final data =
          await _action('get_about_config', {'platform': 'mobile'}, fetchTimeoutMs: 8000);
      return AboutConfig.fromJson(data);
    } catch (_) {
      return const AboutConfig();
    }
  }

  Future<LatestVersion?> fetchServerUpdate() async {
    final data = await _auth.requestActionList('get_latest_version', {
      'platform': 'mobile',
      'device_id': await _auth.deviceId(),
    }, fetchTimeoutMs: 15000);
    if (data is! Map || data['version'] == null) return null;
    return LatestVersion.fromJson(Map<String, dynamic>.from(data));
  }

  Future<(bool, bool)> checkBetaAccess() async {
    final data = await _auth.requestActionList('check_beta_access', {
      'device_id': await _auth.deviceId(),
    }, fetchTimeoutMs: 15000);
    if (data is! Map) return (true, false);
    final allowed = (data['allowed'] as bool?) ?? false;
    final pending = (data['pending'] as bool?) ?? false;
    return (allowed, pending);
  }

  Future<UserAgreement> getUserAgreement() async {
    final data = await _action('get_user_agreement', {});
    return UserAgreement.fromJson(data);
  }

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
      ...await _deviceInfo(),
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

  Future<void> confirmFeedbackNotification(int id) async {
    final user = _auth.currentState.user;
    final ciyuanxiId = user?.ciyuanxiId?.trim() ?? '';
    try {
      await _action('confirm_feedback_notification', {
        'id': id,
        'ciyuanxi_id': ciyuanxiId,
      }, fetchTimeoutMs: 15000);
    } catch (_) {
    }
  }

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

  Future<void> confirmNicknameChangeNotice(int id) async {
    final ciyuanxiId = _ciyuanxiId ?? '';
    if (id <= 0) return;
    try {
      await _action('confirm_nickname_change_notice', {
        'id': id,
        'ciyuanxi_id': ciyuanxiId,
      }, fetchTimeoutMs: 15000);
    } catch (_) {
    }
  }

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

  Future<Map<String, dynamic>?> downloadSettings() async =>
      (await downloadSettingsCrossPlatform()).settings;

  Future<({Map<String, dynamic>? settings, DateTime? uploadedAt})>
      downloadSettingsCrossPlatform() async {
    final results = await Future.wait([
      _downloadSettingsSnapshot('mobile'),
      _downloadSettingsSnapshot('desktop'),
    ]);
    final own = results[0];
    final desktop = results[1];
    final ownOk = own.settings != null && own.settings!.isNotEmpty;
    final deskOk = desktop.settings != null && desktop.settings!.isNotEmpty;
    if (ownOk && deskOk) {
      final epoch = DateTime.fromMillisecondsSinceEpoch(0);
      final ownAt = own.uploadedAt ?? epoch;
      final deskAt = desktop.uploadedAt ?? epoch;
      return ownAt.isAfter(deskAt) ? own : desktop;
    }
    if (deskOk) return desktop;
    return own;
  }

  Future<({Map<String, dynamic>? settings, DateTime? uploadedAt})>
      _downloadSettingsSnapshot(String platform) async {
    final ciyuanxiId = _ciyuanxiId;
    if (ciyuanxiId == null || ciyuanxiId.isEmpty) {
      throw AuthException(tr('请先登录后再同步设置'));
    }
    final data = await _action('settings_sync_download', {
      'user_id': ciyuanxiId,
      'platform': platform,
    }, fetchTimeoutMs: 15000);
    final settings = data['settings'];
    DateTime? uploadedAt;
    final ts = data['timestamp'];
    if (ts is num && ts > 0) {
      uploadedAt = DateTime.fromMillisecondsSinceEpoch((ts * 1000).round());
    } else {
      final uploadedAtStr = data['uploaded_at'];
      if (uploadedAtStr is String && uploadedAtStr.isNotEmpty) {
        uploadedAt = DateTime.tryParse(uploadedAtStr);
      }
    }
    return (
      settings: settings is Map<String, dynamic> ? settings : null,
      uploadedAt: uploadedAt,
    );
  }

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

  Future<int> uploadFavorites(
    List<Map<String, dynamic>> favorites, {
    List<String> deletePaths = const [],
  }) async {
    final ciyuanxiId = _ciyuanxiId;
    if (ciyuanxiId == null || ciyuanxiId.isEmpty) {
      throw AuthException(tr('请先登录后再同步收藏'));
    }
    final data = await _action('favorites_sync_upload', {
      'user_id': ciyuanxiId,
      'favorites': favorites,
      if (deletePaths.isNotEmpty) 'delete_paths': deletePaths,
      'merge': true,
    }, fetchTimeoutMs: 15000);
    return (data['song_count'] as num?)?.toInt() ?? 0;
  }

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

  Future<void> deleteCloudPlaylist(String playlistId) async {
    final ciyuanxiId = _ciyuanxiId;
    if (ciyuanxiId == null || ciyuanxiId.isEmpty) {
      throw AuthException(tr('请先登录后再同步歌单'));
    }
    await _action('file_sync_delete_playlist', {
      'user_id': ciyuanxiId,
      'cloud_ids': [playlistId],
    }, fetchTimeoutMs: 15000);
  }

  Future<({int playlistCount, int songTotal, List<Map<String, dynamic>> idMap})>
      fileSyncUpload(List<Map<String, dynamic>> playlists) async {
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
      'merge': true,
    }, fetchTimeoutMs: 50000);
    final idMap = (finish['id_map'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
    return (
      playlistCount: (finish['playlist_count'] as num?)?.toInt() ?? 0,
      songTotal: (finish['song_total'] as num?)?.toInt() ?? 0,
      idMap: idMap,
    );
  }

  Future<Map<String, dynamic>?> fileSyncDownload() async {
    final ciyuanxiId = _ciyuanxiId;
    if (ciyuanxiId == null || ciyuanxiId.isEmpty) {
      throw AuthException(tr('请先登录后再同步歌单'));
    }
    final data = await _action('file_sync_download', {'user_id': ciyuanxiId},
        fetchTimeoutMs: 30000);
    return data.isEmpty ? null : data;
  }

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

  Future<Map<String, dynamic>> downloadPluginSnapshot() async {
    final ciyuanxiId = _ciyuanxiId;
    if (ciyuanxiId == null || ciyuanxiId.isEmpty) {
      throw AuthException(tr('请先登录后再同步插件'));
    }
    return _action('plugin_sync_download', {'user_id': ciyuanxiId},
        fetchTimeoutMs: 15000);
  }

  Future<void> deleteCloudPlugins(List<String> pluginIds) async {
    if (pluginIds.isEmpty) return;
    final ciyuanxiId = _ciyuanxiId;
    if (ciyuanxiId == null || ciyuanxiId.isEmpty) {
      throw AuthException(tr('请先登录后再同步插件'));
    }
    await _action('plugin_sync_delete', {
      'user_id': ciyuanxiId,
      'plugin_ids': pluginIds,
    }, fetchTimeoutMs: 15000);
  }

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
        'videoUrl': (w['videoUrl'] ?? w['video_url'] ?? '') as String,
        'videoSha256': (w['videoSha256'] ?? w['video_sha256'] ?? '') as String,
        'videoDuration':
            ((w['videoDuration'] ?? w['video_duration'] ?? 0) as dynamic) is num
                ? ((w['videoDuration'] ?? w['video_duration'] ?? 0) as num)
                        .toInt()
                : 0,
        'videoSize':
            ((w['videoSize'] ?? w['video_size'] ?? 0) as dynamic) is num
                ? ((w['videoSize'] ?? w['video_size'] ?? 0) as num).toInt()
                : 0,
        'mediaType': (w['mediaType'] ?? w['media_type'] ?? '') as String,
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

  Future<LeaderboardData> fetchLeaderboard({
    int limit = 50,
    String period = 'total',
  }) async {
    final ciyuanxiId = _ciyuanxiId;
    final data = await _action('get_leaderboard', {
      if (ciyuanxiId != null && ciyuanxiId.isNotEmpty) 'ciyuanxi_id': ciyuanxiId,
      'limit': limit,
      'period': period,
    }, fetchTimeoutMs: 12000);
    return LeaderboardData.fromJson(data);
  }

  Future<Map<String, dynamic>> reportListenStatsDelta({
    required int deltaTotal,
    required int deltaDaily,
  }) async {
    final ciyuanxiId = _ciyuanxiId;
    if (ciyuanxiId == null || ciyuanxiId.isEmpty) {
      return const {};
    }
    try {
      final data = await _action('report_listen_stats', {
        'ciyuanxi_id': ciyuanxiId,
        'stats_mode': 'delta',
        'delta_duration': deltaTotal.clamp(0, 1 << 31),
        'delta_daily_duration': deltaDaily.clamp(0, 1 << 31),
      }, fetchTimeoutMs: 8000);
      final resetAt = data['reset_at'];
      if (resetAt is String && resetAt.isNotEmpty) {
        return {'resetAt': resetAt};
      }
      return {
        'total': (data['server_total_duration'] as num?)?.toInt() ?? 0,
        'daily': (data['server_daily_duration'] as num?)?.toInt() ?? 0,
        'weekly': (data['server_weekly_duration'] as num?)?.toInt() ?? 0,
      };
    } catch (_) {
      return const {};
    }
  }

  Future<void> reportAppOpen() async {
    final info = await _deviceInfo();
    await _fireAndForget(
        'open', {...info, 'platform': 'mobile', 'ciyuanxi_id': _ciyuanxiId ?? ''});
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
    final dev = await fetchDeviceInfo();
    return {
      'device_id': await _auth.deviceId(),
      'app_version': appVersion,
      'os_version': dev.osVersion,
      'device_model': dev.model,
      'device_name': dev.marketName,
      'device_brand': dev.brand,
      'device_manufacturer': dev.manufacturer,
    };
  }

  Future<void> _fireAndForget(String action, Map<String, dynamic> body) async {
    try {
      await _action(action, body);
    } catch (_) {
    }
  }
}

final accountApiProvider = Provider<AccountApi>((ref) => AccountApi(ref));

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

Map<String, Object?> normalizeCloudSettingsMap(Map<String, dynamic> cloud) {
  Object? pick(String flatKey, [String? nestedPath]) {
    final flat = cloud[flatKey];
    if (flat != null) return flat;
    if (nestedPath == null) return null;
    Object? cur = cloud;
    for (final p in nestedPath.split('.')) {
      if (cur is Map) {
        cur = cur[p];
      } else {
        return null;
      }
    }
    return cur;
  }

  int? accentColorOf(Object? v) {
    if (v is num) return v.toInt();
    if (v is String) {
      var hex = v.trim().replaceFirst('#', '').replaceFirst('0x', '');
      if (hex.length == 6) hex = 'FF$hex';
      return int.tryParse(hex, radix: 16);
    }
    return null;
  }

  int? themeModeOf(Object? v) {
    if (v is int) return v;
    if (v is String) {
      return switch (v) {
        'light' => 1,
        'dark' => 2,
        'system' => 0,
        _ => null,
      };
    }
    return null;
  }

  bool? boolOf(Object? v) => v is bool ? v : null;
  String? strOf(Object? v) => v is String ? v : null;

  return {
    'volume': (pick('volume') as num?)?.toDouble(),
    'playMode': (pick('playMode') as num?)?.toInt(),
    'keepScreenOn': boolOf(pick('keepScreenOn')),
    'themeMode': themeModeOf(pick('themeMode', 'theme.mode')),
    'accentColor': accentColorOf(pick('accentColor', 'theme.accentColor')),
    'showQualityBadges': boolOf(pick('showQualityBadges')),
    'onlineDefaultQuality':
        strOf(pick('onlineDefaultQuality', 'audio.onlineDefaultQuality')),
    'libraryMinDurationSeconds':
        (pick('libraryMinDurationSeconds') as num?)?.toInt(),
    'showLyricsTranslation': boolOf(pick('showLyricsTranslation')),
    'enableWordEffect': boolOf(pick('enableWordEffect', 'lyrics.enableWordEffect')),
    'downloadQuality': strOf(pick('downloadQuality', 'download.quality')),
    'downloadLyrics': boolOf(pick('downloadLyrics')),
    'organizeRule': strOf(pick('organizeRule')),
  };
}

AppSettings applySyncedSettings(AppSettings local, Map<String, dynamic> cloud) {
  final m = normalizeCloudSettingsMap(cloud);
  final themeIdx = m['themeMode'] as int?;
  final maxIdx = ThemeModePreference.values.length - 1;
  return local.copyWith(
    volume: (m['volume'] as double?) ?? local.volume,
    playMode: (m['playMode'] as int?) ?? local.playMode,
    keepScreenOn: (m['keepScreenOn'] as bool?) ?? local.keepScreenOn,
    themeMode: themeIdx == null
        ? local.themeMode
        : ThemeModePreference.values[themeIdx.clamp(0, maxIdx)],
    accentColor: (m['accentColor'] as int?) ?? local.accentColor,
    showQualityBadges: (m['showQualityBadges'] as bool?) ?? local.showQualityBadges,
    onlineDefaultQuality:
        (m['onlineDefaultQuality'] as String?) ?? local.onlineDefaultQuality,
    libraryMinDurationSeconds:
        (m['libraryMinDurationSeconds'] as int?) ?? local.libraryMinDurationSeconds,
    showLyricsTranslation:
        (m['showLyricsTranslation'] as bool?) ?? local.showLyricsTranslation,
    enableWordEffect: (m['enableWordEffect'] as bool?) ?? local.enableWordEffect,
    downloadQuality: (m['downloadQuality'] as String?) ?? local.downloadQuality,
    downloadLyrics: (m['downloadLyrics'] as bool?) ?? local.downloadLyrics,
    organizeRule: (m['organizeRule'] as String?) ?? local.organizeRule,
  );
}

bool areSettingsEqual(AppSettings local, Map<String, dynamic> cloud) {
  final localMap = settingsToSyncMap(local);
  final m = normalizeCloudSettingsMap(cloud);
  for (final entry in localMap.entries) {
    final cloudVal = m[entry.key];
    if (cloudVal == null) continue;
    if (cloudVal != entry.value) return false;
  }
  return true;
}
