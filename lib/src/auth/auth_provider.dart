import 'dart:convert';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/db_path.dart';
import '../rust/api.dart';
import 'server_models.dart';

/// 默认后端地址与签名密钥（与桌面端一致）。
const defaultAuthBaseUrl = 'https://back.xymusic.cc/api';
const defaultAuthApiSecret = 'bf027fedb4d1b4f969c10495f12f17042bf0de02de128200';

/// 认证用户（弦予号登录）。
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
  /// 登录态失效（token 被服务端判定无效/过期）时置 true，UI 据此弹窗并引导重新登录。
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

/// 人机验证题目（内置算术题模式，与桌面端 get_captcha 一致）。
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

/// 人机验证结果载荷（算术题：id + 答案）。
class HumanCaptchaPayload {
  final String captchaId;
  final String captchaAnswer;
  const HumanCaptchaPayload({
    required this.captchaId,
    required this.captchaAnswer,
  });

  /// 并入请求体的 captcha 字段（与桌面端 withCaptcha 一致）。
  Map<String, dynamic> toBodyFields() => {
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

  /// 当前登录 token（仅内存持有，持久化在 Rust 侧）。
  String? _token;

  /// 公开当前状态（供外部读取，避免直接访问受保护的 state）。
  AuthState get currentState => state;

  Future<String> _dataDir() => _ref.read(appDataDirProvider.future);

  /// 设备 ID（持久化，用于登录签名）。
  Future<String> _deviceId() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString('deviceId');
    if (id == null || id.isEmpty) {
      id = _randHex(16);
      await prefs.setString('deviceId', id);
    }
    return id;
  }

  /// 公开设备 ID（供统计上报等复用）。
  Future<String> deviceId() => _deviceId();

  String _randHex(int len) {
    const hex = '0123456789abcdef';
    final sb = StringBuffer();
    for (var i = 0; i < len; i++) {
      sb.write(hex[_rand.nextInt(16)]);
    }
    return sb.toString();
  }

  /// 启动时确保默认基地址/密钥并加载已有凭证。
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
      // 无凭证或初始化失败，保持未登录。
    }
  }

  /// 发送带签名的账号请求，校验 code===200 并返回 data。
  /// 已登录时自动注入 token（供服务端 dispatch 层做用户资源属主校验）。
  /// 响应为登录态失效（401 + 特定文案）时自动登出并标记 sessionExpired。
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

  /// 同 [requestAction]，但 data 允许为任意 JSON（数组/对象），
  /// 供壁纸列表等返回数组的接口使用。
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

  /// 服务端在硬模式下统一返回的 token 失效文案。
  static final _sessionExpiredRe =
      RegExp(r'登录状态已失效|登录已过期|登录状态与账号不匹配');

  bool _isSessionExpired(int code, String msg) =>
      code == 401 && _sessionExpiredRe.hasMatch(msg);

  /// 登录态失效：清理本地凭证并标记 sessionExpired，UI 据此弹窗引导重新登录。
  Future<void> _handleSessionExpired() async {
    try {
      final dir = await _dataDir();
      await authClearCredentials(dataDir: dir);
    } catch (_) {}
    _token = null;
    state = const AuthState(sessionExpired: true);
  }

  /// UI 在展示完会话失效弹窗后调用，清除标记。
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

  /// 获取一次性人机验证题（算术题，purpose=auth）。
  Future<HumanCaptcha> fetchCaptcha() async {
    final data = await requestAction('get_captcha', {'purpose': 'auth'});
    return HumanCaptcha.fromJson(data);
  }

  /// 预校验人机验证答案。答案正确返回，错误抛 AuthException。
  /// 此接口只确认答案，不消费验证码；后续登录/注册/发码请求会再次校验并消费。
  Future<void> verifyCaptcha(HumanCaptchaPayload payload) async {
    await requestAction('verify_captcha', {
      'purpose': 'auth',
      'captcha_id': payload.captchaId,
      'captcha_answer': payload.captchaAnswer,
    });
  }

  /// 发送邮箱验证码（注册/找回密码等场景），需先通过人机验证。
  Future<String> sendCode(String email, String type,
      {HumanCaptchaPayload? captcha}) async {
    final data = await requestAction('send_verify_code', {
      'email': email,
      'type': type,
      if (captcha != null) ...captcha.toBodyFields(),
    });
    return (data['message'] as String?) ??
        (data['msg'] as String?) ??
        '验证码已发送到邮箱';
  }

  /// 弦予号登录。
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
        throw AuthException('登录响应无效');
      }
      await _saveAuth(token.toString(), data);
    } catch (e) {
      state = state.copyWith(loading: false, error: _msg(e, '登录失败'));
    }
  }

  /// 用户注册（注册成功后自动登录）。
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
        throw AuthException('注册响应无效');
      }
      await _saveAuth(token.toString(), data);
    } catch (e) {
      state = state.copyWith(loading: false, error: _msg(e, '注册失败'));
    }
  }

  /// 设置内联错误信息（供 UI 展示本地校验错误，如两次密码不一致）。
  void setError(String message) {
    state = state.copyWith(loading: false, error: message);
  }

  /// 清除内联错误（切换登录/注册页时调用）。
  void clearError() {
    if (state.error == null) return;
    state = state.copyWith(clearError: true);
  }

  /// 退出登录（仅清理本地凭证）。
  Future<void> logout() async {
    try {
      final dir = await _dataDir();
      await authClearCredentials(dataDir: dir);
    } catch (_) {}
    _token = null;
    state = const AuthState();
  }

  /// 本地更新昵称（管理员改昵称通知确认后同步显示）。
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

  // ═══════════════════════════════════════════════════════
  //  账号类 API（与桌面端 authService.ts 对齐）
  // ═══════════════════════════════════════════════════════

  /// 修改弦予号（每月限一次），返回新弦予号。
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

  /// 绑定邮箱（需 type='bind' 的邮箱验证码）。
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

  /// 找回密码（重置密码）。
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

  /// 预验证注销凭据（密码 + 邮箱验证码），不执行实际注销。
  Future<void> preVerifyDeleteAccount({
    required String verifyCode,
    required String password,
  }) async {
    final user = state.user;
    if (user == null) throw AuthException('未登录');
    final ciyuanxiId = user.ciyuanxiId ?? user.id;
    if (ciyuanxiId.isEmpty) throw AuthException('未获取到当前账号信息，请重新登录');
    if (password.isEmpty) throw AuthException('请输入登录密码');
    if (verifyCode.isEmpty) throw AuthException('请输入邮箱验证码');
    await requestAction('preverify_delete_account', {
      'ciyuanxi_id': ciyuanxiId,
      'email': user.email,
      'verify_code': verifyCode,
      'password': password,
    });
  }

  /// 注销当前账号（双重验证），成功后自动登出。
  Future<void> deleteAccount({
    required String verifyCode,
    required String password,
  }) async {
    final user = state.user;
    if (user == null) throw AuthException('未登录');
    final ciyuanxiId = user.ciyuanxiId ?? user.id;
    if (ciyuanxiId.isEmpty) throw AuthException('未获取到当前账号信息，请重新登录');
    if (password.isEmpty) throw AuthException('请输入登录密码');
    await requestAction('delete_account', {
      'ciyuanxi_id': ciyuanxiId,
      'email': user.email,
      'verify_code': verifyCode,
      'password': password,
    });
    await logout();
  }

  /// 修改密码（需登录，弦予号 + 旧密码验证）。
  Future<void> changePassword({
    required String oldPassword,
    required String newPassword,
    required String code,
  }) async {
    final user = state.user;
    final ciyuanxiId = user?.ciyuanxiId;
    if (ciyuanxiId == null || ciyuanxiId.isEmpty) {
      throw AuthException('未获取到弦予号，无法修改密码，请重新登录');
    }
    await requestAction('change_password', {
      'ciyuanxi_id': ciyuanxiId,
      'old_password': oldPassword,
      'new_password': newPassword,
      'code': code,
    });
  }

  /// 获取个人资料（get_user_info），成功后刷新本地用户缓存。
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

  /// 更新个人资料（昵称/头像）。改名走审核流程，返回是否待审核。
  Future<({AuthUser user, bool nicknamePending})> updateProfile({
    required String nickname,
    String? avatar,
  }) async {
    final user = state.user;
    final token = _token;
    if (user == null || token == null || token.isEmpty) {
      throw AuthException('未登录');
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

  /// 查询改名审核状态：pending / rejected / none。
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

  /// 查询改名审核状态 + 今日是否受限。
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

  /// 上传头像（base64 data URL，走审核流程，不立即生效）。
  Future<void> uploadAvatar(String avatarData) async {
    final user = state.user;
    if (user == null) throw AuthException('未登录');
    await requestAction('upload_avatar', {
      'ciyuanxi_id': user.ciyuanxiId ?? user.id,
      'avatar_data': avatarData,
    }, fetchTimeoutMs: 55000);
  }

  /// 查询头像审核状态：pending / rejected / none。
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

  /// 查询头像审核状态 + 今日是否受限。
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

  /// 检查当前账号/设备封禁状态。
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
      return '网络异常，请检查网络连接';
    }
    if (s.contains('timeout')) return '请求超时，请稍后重试';
    return fallback;
  }
}

final authProvider = StateNotifierProvider<AuthNotifier, AuthState>(
  (ref) => AuthNotifier(ref),
);