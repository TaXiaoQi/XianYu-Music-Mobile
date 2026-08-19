import 'dart:convert';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/db_path.dart';
import '../rust/api.dart';

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
  const AuthState({this.user, this.loading = false, this.error});
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
  Future<Map<String, dynamic>> _requestAction(
      String action, Map<String, dynamic> body) async {
    final dir = await _dataDir();
    final res = await authAuthedRequest(
      dataDir: dir,
      action: action,
      bodyJson: jsonEncode(body),
    );
    final j = jsonDecode(res) as Map<String, dynamic>;
    final code = (j['code'] as num?)?.toInt() ?? -1;
    if (code != 200) {
      throw AuthException((j['msg'] as String?)?.isNotEmpty == true
          ? j['msg'] as String
          : '请求失败（code $code）');
    }
    return (j['data'] as Map<String, dynamic>?) ?? const {};
  }

  Future<void> _saveAuth(String token, Map<String, dynamic> data) async {
    final dir = await _dataDir();
    final user = AuthUser.fromJson(data);
    await authSaveCredentials(
      dataDir: dir,
      token: token,
      userJson: jsonEncode(user.toJson()),
    );
    state = AuthState(user: user);
  }

  /// 获取一次性人机验证题（算术题，purpose=auth）。
  Future<HumanCaptcha> fetchCaptcha() async {
    final data = await _requestAction('get_captcha', {'purpose': 'auth'});
    return HumanCaptcha.fromJson(data);
  }

  /// 预校验人机验证答案。答案正确返回，错误抛 AuthException。
  /// 此接口只确认答案，不消费验证码；后续登录/注册/发码请求会再次校验并消费。
  Future<void> verifyCaptcha(HumanCaptchaPayload payload) async {
    await _requestAction('verify_captcha', {
      'purpose': 'auth',
      'captcha_id': payload.captchaId,
      'captcha_answer': payload.captchaAnswer,
    });
  }

  /// 发送邮箱验证码（注册/找回密码等场景），需先通过人机验证。
  Future<String> sendCode(String email, String type,
      {HumanCaptchaPayload? captcha}) async {
    final data = await _requestAction('send_verify_code', {
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
      final data = await _requestAction('user_login', {
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
      final data = await _requestAction('register', {
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
    state = const AuthState();
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