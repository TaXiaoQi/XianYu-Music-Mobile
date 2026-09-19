import 'dart:convert';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/db_path.dart';
import '../device/device_info.dart' show fetchStableDeviceId;
import '../rust/api.dart';
import 'server_models.dart';
import '../i18n/i18n.dart';

const defaultAuthBaseUrl = 'https://api.xianyumusic.cn/api';
const defaultAuthApiSecret = 'bf027fedb4d1b4f969c10495f12f17042bf0de02de128200';

class AuthUser {
  final String id;
  final String username;
  final String nickname;
  final String email;
  final String? avatar;
  final String? ciyuanxiId;
  final String role;
  const AuthUser({
    required this.id,
    required this.username,
    required this.nickname,
    required this.email,
    this.avatar,
    this.ciyuanxiId,
    this.role = '',
  });

  factory AuthUser.fromJson(Map<String, dynamic> j) {
    final idRaw = j['user_id'] ?? j['id'] ?? '';
    final username = (j['username'] as String?) ?? '';
    final nickname = ((j['nickname'] as String?)?.isNotEmpty ?? false)
        ? (j['nickname'] as String)
        : username;
    final ciyuanxi = j['ciyuanxi_id'];
    return AuthUser(
      id: idRaw.toString(),
      username: username,
      nickname: nickname,
      email: (j['email'] as String?) ?? '',
      avatar: (j['avatar_url'] ?? j['avatar']) as String?,
      ciyuanxiId: ciyuanxi?.toString(),
      role: (j['role'] as String?) ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'username': username,
        'nickname': nickname,
        'email': email,
        'avatar': avatar,
        'ciyuanxi_id': ciyuanxiId,
        'role': role,
      };
}

class AuthState {
  final AuthUser? user;
  final bool loading;
  final String? error;
  final bool sessionExpired;
  const AuthState({
    this.user,
    this.loading = false,
    this.error,
    this.sessionExpired = false,
  });
  bool get isLoggedIn => user != null;

  AuthState copyWith({
    AuthUser? user,
    bool? loading,
    String? error,
    bool clearError = false,
  }) {
    return AuthState(
      user: user ?? this.user,
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
      sessionExpired: sessionExpired,
    );
  }
}

class AuthException implements Exception {
  final String message;
  AuthException(this.message);
  @override
  String toString() => message;
}

class TvLoginScanInfo {
  final String appName;
  final String deviceId;
  final String location;
  final String nickname;
  final String ciyuanxiId;
  const TvLoginScanInfo({
    this.appName = '',
    this.deviceId = '',
    this.location = '',
    this.nickname = '',
    this.ciyuanxiId = '',
  });

  factory TvLoginScanInfo.fromJson(Map<String, dynamic> j) {
    final nickname = ((j['nickname'] as String?)?.isNotEmpty ?? false)
        ? (j['nickname'] as String)
        : ((j['username'] as String?) ?? '');
    return TvLoginScanInfo(
      appName: (j['app_name'] as String?) ?? '',
      deviceId: (j['device_id'] as String?) ?? '',
      location: (j['location'] as String?) ?? '',
      nickname: nickname,
      ciyuanxiId: (j['ciyuanxi_id'] as String?) ?? '',
    );
  }
}

class HumanCaptcha {
  final String captchaId;
  final String question;
  final int? expireSeconds;
  const HumanCaptcha({
    required this.captchaId,
    required this.question,
    this.expireSeconds,
  });

  factory HumanCaptcha.fromJson(Map<String, dynamic> j) => HumanCaptcha(
        captchaId: (j['captcha_id'] ?? '').toString(),
        question: (j['question'] ?? '').toString(),
        expireSeconds: (j['expire_seconds'] as num?)?.toInt(),
      );
}

class HumanCaptchaConfig {
  final bool enabled;
  final String provider;
  final String siteKey;
  const HumanCaptchaConfig({
    this.enabled = false,
    this.provider = 'off',
    this.siteKey = '',
  });

  bool get isProviderEnabled => enabled && siteKey.isNotEmpty && provider != 'off';
}

class HumanCaptchaPayload {
  final String captchaId;
  final String captchaAnswer;
  final String providerToken;
  final String provider;
  const HumanCaptchaPayload({
    this.captchaId = '',
    this.captchaAnswer = '',
    this.providerToken = '',
    this.provider = '',
  });

  bool get isProviderToken => providerToken.isNotEmpty;

  Map<String, dynamic> toBodyFields() => isProviderToken
      ? {
          'captcha_token': providerToken,
          'turnstile_token': providerToken,
          'captcha_provider': provider,
        }
      : {
          'captcha_id': captchaId,
          'captcha_answer': captchaAnswer,
        };
}

class AuthNotifier extends StateNotifier<AuthState> {
  AuthNotifier(this._ref) : super(const AuthState()) {
    init();
  }

  final Ref _ref;
  final Random _rand = Random();

  static (HumanCaptchaConfig, DateTime)? _captchaConfigCache;

  String? _token;

  AuthState get currentState => state;

  Future<String> _dataDir() => _ref.read(appDataDirProvider.future);

  Future<String> _deviceId() async {
    final prefs = await SharedPreferences.getInstance();
    final stable = await fetchStableDeviceId();
    if (stable != null && stable.isNotEmpty) {
      if (prefs.getString('deviceId') != stable) {
        await prefs.setString('deviceId', stable);
      }
      return stable;
    }
    var id = prefs.getString('deviceId');
    if (id == null || id.isEmpty) {
      id = _randHex(16);
      await prefs.setString('deviceId', id);
    }
    return id;
  }

  Future<String> deviceId() => _deviceId();

  String _randHex(int len) {
    const hex = '0123456789abcdef';
    final sb = StringBuffer();
    for (var i = 0; i < len; i++) {
      sb.write(hex[_rand.nextInt(16)]);
    }
    return sb.toString();
  }

  Future<void> init() async {
    try {
      final dir = await _dataDir();
      await authSetBaseUrl(dataDir: dir, baseUrl: defaultAuthBaseUrl);
      await authSetApiSecret(dataDir: dir, apiSecret: defaultAuthApiSecret);
      final credsJson = await authGetCredentials(dataDir: dir);
      if (credsJson.trim().isNotEmpty && credsJson != 'null') {
        final j = jsonDecode(credsJson) as Map<String, dynamic>;
        _token = (j['token'] as String?) ?? '';
        final userJson = j['user'];
        if (userJson is Map<String, dynamic>) {
          state = AuthState(user: AuthUser.fromJson(userJson));
        }
      }
    } catch (_) {
    }
  }

  Future<Map<String, dynamic>> requestAction(
      String action, Map<String, dynamic> body,
      {int? fetchTimeoutMs}) async {
    final dir = await _dataDir();
    final finalBody = Map<String, dynamic>.from(body);
    final token = _token;
    if (token != null && token.isNotEmpty && !finalBody.containsKey('token')) {
      finalBody['token'] = token;
    }
    final res = await authAuthedRequest(
      dataDir: dir,
      action: action,
      bodyJson: jsonEncode(finalBody),
      fetchTimeoutMs: fetchTimeoutMs == null ? null : BigInt.from(fetchTimeoutMs),
    );
    final j = jsonDecode(res) as Map<String, dynamic>;
    final code = (j['code'] as num?)?.toInt() ?? -1;
    final msg = (j['msg'] as String?) ?? '';
    if (_isSessionExpired(code, msg)) {
      await _handleSessionExpired();
    }
    if (code != 200) {
      throw AuthException(msg.isNotEmpty ? msg : '请求失败（code $code）');
    }
    return (j['data'] as Map<String, dynamic>?) ?? const {};
  }

  Future<dynamic> requestActionList(
      String action, Map<String, dynamic> body,
      {int? fetchTimeoutMs}) async {
    final dir = await _dataDir();
    final finalBody = Map<String, dynamic>.from(body);
    final token = _token;
    if (token != null && token.isNotEmpty && !finalBody.containsKey('token')) {
      finalBody['token'] = token;
    }
    final res = await authAuthedRequest(
      dataDir: dir,
      action: action,
      bodyJson: jsonEncode(finalBody),
      fetchTimeoutMs:
          fetchTimeoutMs == null ? null : BigInt.from(fetchTimeoutMs),
    );
    final j = jsonDecode(res) as Map<String, dynamic>;
    final code = (j['code'] as num?)?.toInt() ?? -1;
    final msg = (j['msg'] as String?) ?? '';
    if (_isSessionExpired(code, msg)) {
      await _handleSessionExpired();
    }
    if (code != 200) {
      throw AuthException(msg.isNotEmpty ? msg : '请求失败（code $code）');
    }
    return j['data'];
  }

  static final _sessionExpiredRe =
      RegExp(r'登录状态已失效|登录已过期|登录状态与账号不匹配');

  bool _isSessionExpired(int code, String msg) =>
      code == 401 && _sessionExpiredRe.hasMatch(msg);

  Future<void> _handleSessionExpired() async {
    try {
      final dir = await _dataDir();
      await authClearCredentials(dataDir: dir);
    } catch (_) {}
    _token = null;
    state = const AuthState(sessionExpired: true);
  }

  void consumeSessionExpired() {
    if (state.sessionExpired) {
      state = const AuthState();
    }
  }

  Future<void> _saveAuth(String token, Map<String, dynamic> data) async {
    final user = AuthUser.fromJson(data);
    await _persistAuth(token, user);
  }

  Future<void> _persistAuth(String token, AuthUser user) async {
    final dir = await _dataDir();
    _token = token;
    await authSaveCredentials(
      dataDir: dir,
      token: token,
      userJson: jsonEncode(user.toJson()),
    );
    state = AuthState(user: user);
  }

  Future<HumanCaptcha> fetchCaptcha() async {
    final data = await requestAction('get_captcha', {'purpose': 'auth'});
    return HumanCaptcha.fromJson(data);
  }

  Future<HumanCaptchaConfig> fetchCaptchaConfig() async {
    final cached = _captchaConfigCache;
    if (cached != null &&
        DateTime.now().difference(cached.$2) < const Duration(minutes: 10)) {
      return cached.$1;
    }
    try {
      final data = await requestAction('email_get_captcha_config', {});
      final cfg = HumanCaptchaConfig(
        enabled: (data['enabled'] == true) &&
            (data['site_key'] ?? '').toString().isNotEmpty,
        provider: (data['provider'] ?? 'off').toString(),
        siteKey: (data['site_key'] ?? '').toString(),
      );
      _captchaConfigCache = (cfg, DateTime.now());
      return cfg;
    } catch (_) {
      if (cached != null) return cached.$1;
      return const HumanCaptchaConfig();
    }
  }

  Future<void> verifyCaptcha(HumanCaptchaPayload payload) async {
    if (payload.isProviderToken) return;
    await requestAction('verify_captcha', {
      'purpose': 'auth',
      'captcha_id': payload.captchaId,
      'captcha_answer': payload.captchaAnswer,
    });
  }

  Future<String> sendCode(String email, String type,
      {HumanCaptchaPayload? captcha}) async {
    final data = await requestAction('send_verify_code', {
      'email': email,
      'type': type,
      if (captcha != null) ...captcha.toBodyFields(),
    });
    return (data['message'] as String?) ??
        (data['msg'] as String?) ??
        tr('验证码已发送到邮箱');
  }

  Future<void> login({
    required String ciyuanxiId,
    required String password,
    HumanCaptchaPayload? captcha,
  }) async {
    state = state.copyWith(loading: true, clearError: true);
    try {
      final data = await requestAction('user_login', {
        'ciyuanxi_id': ciyuanxiId.trim(),
        'password': password,
        'device_id': await _deviceId(),
        if (captcha != null) ...captcha.toBodyFields(),
      });
      final token = data['token'];
      if (token == null || token.toString().isEmpty) {
        throw AuthException(tr('登录响应无效'));
      }
      await _saveAuth(token.toString(), data);
    } catch (e) {
      state = state.copyWith(loading: false, error: _msg(e, tr('登录失败')));
    }
  }

  Future<void> loginByEmail({
    required String email,
    required String code,
    HumanCaptchaPayload? captcha,
  }) async {
    state = state.copyWith(loading: true, clearError: true);
    try {
      final data = await requestAction('login_by_code', {
        'email': email.trim(),
        'verify_code': code.trim(),
        'device_id': await _deviceId(),
        if (captcha != null) ...captcha.toBodyFields(),
      });
      final token = data['token'];
      if (token == null || token.toString().isEmpty) {
        throw AuthException(tr('登录响应无效'));
      }
      await _saveAuth(token.toString(), data);
    } catch (e) {
      state = state.copyWith(loading: false, error: _msg(e, tr('登录失败')));
    }
  }

  Future<void> register({
    required String ciyuanxiId,
    required String nickname,
    required String password,
    required String email,
    required String code,
    HumanCaptchaPayload? captcha,
  }) async {
    state = state.copyWith(loading: true, clearError: true);
    try {
      final data = await requestAction('register', {
        'ciyuanxi_id': ciyuanxiId.trim(),
        'nickname': nickname.trim(),
        'password': password,
        'email': email.trim(),
        'verify_code': code.trim(),
        'device_id': await _deviceId(),
        if (captcha != null) ...captcha.toBodyFields(),
      });
      final token = data['token'];
      if (token == null || token.toString().isEmpty) {
        throw AuthException(tr('注册响应无效'));
      }
      await _saveAuth(token.toString(), data);
    } catch (e) {
      state = state.copyWith(loading: false, error: _msg(e, tr('注册失败')));
    }
  }

  Future<TvLoginScanInfo?> scanTvLogin(String code) async {
    final user = state.user;
    final ciyuanxiId = user?.ciyuanxiId;
    if (ciyuanxiId == null || ciyuanxiId.isEmpty) return null;
    final data = await requestAction('scan_tv_login', {
      'code': code.trim(),
      'ciyuanxi_id': ciyuanxiId,
    });
    final info = TvLoginScanInfo.fromJson(data);
    if (info.nickname.isEmpty) {
      return TvLoginScanInfo(
        appName: info.appName,
        deviceId: info.deviceId,
        location: info.location,
        nickname: ciyuanxiId,
        ciyuanxiId: ciyuanxiId,
      );
    }
    return info;
  }

  Future<void> confirmTvLogin(String code) async {
    final user = state.user;
    final ciyuanxiId = user?.ciyuanxiId;
    if (ciyuanxiId == null || ciyuanxiId.isEmpty) {
      throw AuthException(tr('请先登录'));
    }
    await requestAction('confirm_tv_login', {
      'code': code.trim(),
      'ciyuanxi_id': ciyuanxiId,
    });
  }

  void setError(String message) {
    state = state.copyWith(loading: false, error: message);
  }

  void clearError() {
    if (state.error == null) return;
    state = state.copyWith(clearError: true);
  }

  Future<void> logout() async {
    try {
      final dir = await _dataDir();
      await authClearCredentials(dataDir: dir);
    } catch (_) {}
    _token = null;
    state = const AuthState();
  }

  Future<void> updateNicknameLocally(String newNickname) async {
    final user = state.user;
    final token = _token;
    if (user == null || token == null || token.isEmpty) return;
    final next = AuthUser(
      id: user.id,
      username: user.username,
      nickname: newNickname,
      email: user.email,
      avatar: user.avatar,
      ciyuanxiId: user.ciyuanxiId,
      role: user.role,
    );
    await _persistAuth(token, next);
  }

  Future<String> updateCiyuanxiId({
    required String oldCiyuanxiId,
    required String newCiyuanxiId,
    required String password,
  }) async {
    final data = await requestAction('update_ciyuanxi_id', {
      'ciyuanxi_id': oldCiyuanxiId,
      'new_ciyuanxi_id': newCiyuanxiId,
      'password': password,
    });
    final newId = (data['ciyuanxi_id'] ?? newCiyuanxiId).toString();
    final user = state.user;
    if (user != null) {
      await _persistAuth(
        _token ?? '',
        AuthUser(
          id: user.id,
          username: user.username,
          nickname: user.nickname,
          email: user.email,
          avatar: user.avatar,
          ciyuanxiId: newId,
          role: user.role,
        ),
      );
    }
    return newId;
  }

  Future<String> bindEmail({
    required String ciyuanxiId,
    required String email,
    required String verifyCode,
  }) async {
    final data = await requestAction('bind_email', {
      'ciyuanxi_id': ciyuanxiId,
      'email': email,
      'verify_code': verifyCode,
    });
    final bound = (data['email'] ?? email).toString();
    final user = state.user;
    if (user != null) {
      await _persistAuth(
        _token ?? '',
        AuthUser(
          id: user.id,
          username: user.username,
          nickname: user.nickname,
          email: bound,
          avatar: user.avatar,
          ciyuanxiId: user.ciyuanxiId,
          role: user.role,
        ),
      );
    }
    return bound;
  }

  Future<void> resetPassword({
    required String email,
    required String verifyCode,
    required String newPassword,
    HumanCaptchaPayload? captcha,
  }) async {
    await requestAction('reset_password', {
      'email': email,
      'verify_code': verifyCode,
      'new_password': newPassword,
      if (captcha != null) ...captcha.toBodyFields(),
    });
  }

  Future<void> preVerifyDeleteAccount({
    required String verifyCode,
    required String password,
  }) async {
    final user = state.user;
    if (user == null) throw AuthException(tr('未登录'));
    final ciyuanxiId = user.ciyuanxiId ?? user.id;
    if (ciyuanxiId.isEmpty) throw AuthException(tr('未获取到当前账号信息，请重新登录'));
    if (password.isEmpty) throw AuthException(tr('请输入登录密码'));
    if (verifyCode.isEmpty) throw AuthException(tr('请输入邮箱验证码'));
    await requestAction('preverify_delete_account', {
      'ciyuanxi_id': ciyuanxiId,
      'email': user.email,
      'verify_code': verifyCode,
      'password': password,
    });
  }

  Future<void> deleteAccount({
    required String verifyCode,
    required String password,
  }) async {
    final user = state.user;
    if (user == null) throw AuthException(tr('未登录'));
    final ciyuanxiId = user.ciyuanxiId ?? user.id;
    if (ciyuanxiId.isEmpty) throw AuthException(tr('未获取到当前账号信息，请重新登录'));
    if (password.isEmpty) throw AuthException(tr('请输入登录密码'));
    await requestAction('delete_account', {
      'ciyuanxi_id': ciyuanxiId,
      'email': user.email,
      'verify_code': verifyCode,
      'password': password,
    });
    await logout();
  }

  Future<void> changePassword({
    required String oldPassword,
    required String newPassword,
    required String code,
  }) async {
    final user = state.user;
    final ciyuanxiId = user?.ciyuanxiId;
    if (ciyuanxiId == null || ciyuanxiId.isEmpty) {
      throw AuthException(tr('未获取到弦予号，无法修改密码，请重新登录'));
    }
    await requestAction('change_password', {
      'ciyuanxi_id': ciyuanxiId,
      'old_password': oldPassword,
      'new_password': newPassword,
      'code': code,
    });
  }

  Future<AuthUser?> getProfile() async {
    final user = state.user;
    if (user == null) return null;
    try {
      final data = await requestAction('get_user_info', {
        'ciyuanxi_id': user.ciyuanxiId ?? user.id,
      }, fetchTimeoutMs: 15000);
      final next = AuthUser.fromJson(data);
      final token = _token;
      if (token != null && token.isNotEmpty) {
        await _persistAuth(token, next);
      }
      return next;
    } catch (_) {
      return null;
    }
  }

  Future<({AuthUser user, bool nicknamePending})> updateProfile({
    required String nickname,
    String? avatar,
  }) async {
    final user = state.user;
    final token = _token;
    if (user == null || token == null || token.isEmpty) {
      throw AuthException(tr('未登录'));
    }
    final data = await requestAction('update_profile', {
      'token': token,
      'ciyuanxi_id': user.ciyuanxiId ?? '',
      'username': nickname,
      'nickname': nickname,
      'avatar': avatar ?? '',
    });
    final nicknamePending =
        data['nickname_pending'] == true || data['status'] == 'pending';
    final nextUser = data['user'] is Map<String, dynamic>
        ? AuthUser.fromJson(data['user'] as Map<String, dynamic>)
        : AuthUser(
            id: user.id,
            username: user.username,
            nickname: user.nickname,
            email: user.email,
            avatar: avatar ?? user.avatar,
            ciyuanxiId: user.ciyuanxiId,
            role: user.role,
          );
    await _persistAuth(token, nextUser);
    return (user: nextUser, nicknamePending: nicknamePending);
  }

  Future<String> getNicknameStatus() async {
    final user = state.user;
    if (user == null) return 'none';
    try {
      final data = await requestAction('get_nickname_status', {
        'ciyuanxi_id': user.ciyuanxiId ?? user.id,
      }, fetchTimeoutMs: 15000);
      final status = (data['status'] ?? 'none').toString();
      if (status == 'pending' || status == 'rejected') return status;
      return 'none';
    } catch (_) {
      return 'none';
    }
  }

  Future<ProfileChangeLimitStatus> getNicknameChangeLimitStatus() async {
    final user = state.user;
    if (user == null) return const ProfileChangeLimitStatus();
    try {
      final data = await requestAction('get_nickname_status', {
        'ciyuanxi_id': user.ciyuanxiId ?? user.id,
      }, fetchTimeoutMs: 15000);
      final raw = (data['status'] ?? 'none').toString();
      final status = (raw == 'pending' || raw == 'rejected') ? raw : 'none';
      return ProfileChangeLimitStatus(
        status: status,
        todayBlocked: data['today_blocked'] == true,
        blockMessage: (data['block_message'] ?? '').toString(),
      );
    } catch (_) {
      return const ProfileChangeLimitStatus();
    }
  }

  Future<void> uploadAvatar(String avatarData) async {
    final user = state.user;
    if (user == null) throw AuthException(tr('未登录'));
    await requestAction('upload_avatar', {
      'ciyuanxi_id': user.ciyuanxiId ?? user.id,
      'avatar_data': avatarData,
    }, fetchTimeoutMs: 55000);
  }

  Future<String> getAvatarStatus() async {
    final user = state.user;
    if (user == null) return 'none';
    try {
      final data = await requestAction('get_avatar_status', {
        'ciyuanxi_id': user.ciyuanxiId ?? user.id,
      }, fetchTimeoutMs: 15000);
      final status = (data['status'] ?? 'none').toString();
      if (status == 'pending' || status == 'rejected') return status;
      return 'none';
    } catch (_) {
      return 'none';
    }
  }

  Future<ProfileChangeLimitStatus> getAvatarChangeLimitStatus() async {
    final user = state.user;
    if (user == null) return const ProfileChangeLimitStatus();
    try {
      final data = await requestAction('get_avatar_status', {
        'ciyuanxi_id': user.ciyuanxiId ?? user.id,
      }, fetchTimeoutMs: 15000);
      final raw = (data['status'] ?? 'none').toString();
      final status = (raw == 'pending' || raw == 'rejected') ? raw : 'none';
      return ProfileChangeLimitStatus(
        status: status,
        todayBlocked: data['today_blocked'] == true,
        blockMessage: (data['block_message'] ?? '').toString(),
      );
    } catch (_) {
      return const ProfileChangeLimitStatus();
    }
  }

  Future<BanStatus> checkBanStatus() async {
    final user = state.user;
    if (user == null) return const BanStatus();
    try {
      final data = await requestAction('check_ban_status', {
        'ciyuanxi_id': user.ciyuanxiId ?? user.id,
        'device_id': await _deviceId(),
      }, fetchTimeoutMs: 15000);
      return BanStatus.fromJson(data);
    } catch (_) {
      return const BanStatus();
    }
  }

  String _msg(Object e, String fallback) {
    if (e is AuthException) return e.message;
    final s = e.toString();
    if (s.contains('network') || s.contains('Failed to fetch')) {
      return tr('网络异常，请检查网络连接');
    }
    if (s.contains('timeout')) return tr('请求超时，请稍后重试');
    return fallback;
  }
}

final authProvider = StateNotifierProvider<AuthNotifier, AuthState>(
  (ref) => AuthNotifier(ref),
);