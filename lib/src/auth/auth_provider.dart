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
      ciyuanxiId: ciyuanxi != null ? ciyuanxi.toString() : null,
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

  AuthState copyWith({AuthUser? user, bool? loading, String? error}) {
    return AuthState(
      user: user ?? this.user,
      loading: loading ?? this.loading,
      error: error ?? this.error,
    );
  }
}

class AuthException implements Exception {
  final String message;
  AuthException(this.message);
  @override
  String toString() => message;
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
      if (credsJson != null && credsJson.trim().isNotEmpty && credsJson != 'null') {
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

  /// 发送邮箱验证码（注册/找回密码等场景）。
  Future<String> sendCode(String email, String type) async {
    final data = await _requestAction('send_verify_code', {
      'email': email,
      'type': type,
    });
    return (data['message'] as String?) ??
        (data['msg'] as String?) ??
        '验证码已发送到邮箱';
  }

  /// 弦予号登录。
  Future<void> login({
    required String ciyuanxiId,
    required String password,
  }) async {
    state = state.copyWith(loading: true, error: null);
    try {
      final data = await _requestAction('user_login', {
        'ciyuanxi_id': ciyuanxiId.trim(),
        'password': password,
        'device_id': await _deviceId(),
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
  }) async {
    state = state.copyWith(loading: true, error: null);
    try {
      final data = await _requestAction('register', {
        'ciyuanxi_id': ciyuanxiId.trim(),
        'nickname': nickname.trim(),
        'password': password,
        'email': email.trim(),
        'verify_code': code.trim(),
        'device_id': await _deviceId(),
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