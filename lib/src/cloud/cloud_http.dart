// 网盘引擎统一 HTTP 出口。
//
// 全部走 [appRequest] 收口（逐跳 SSRF 校验 + 手动重定向），在其上封装
// 网盘 API 最常用的三种形态：GET/POST-JSON/POST-FORM，附统一超时与
// CloudException 错误转换。响应头由调用方自行取用。

import 'dart:async';
import 'dart:convert';

import '../core/app_http.dart';
import 'cloud_types.dart';

class CloudHttpResponse {
  CloudHttpResponse._(this.status, this.headers, this.body, this.setCookies);

  final int status;
  final Map<String, String> headers;
  final String body;

  /// 原始 Set-Cookie 列表（dart:io HttpHeaders.forEach 保证逐条分开）。
  final List<String> setCookies;

  bool get isOk => status >= 200 && status < 300;

  /// Set-Cookie 解析成 name → value（取分号前的首段，忽略 Path/Expires 等
  /// 属性；同名后写覆盖前写，贴合浏览器语义）。
  Map<String, String> get setCookiePairs {
    final pairs = <String, String>{};
    for (final raw in setCookies) {
      final head = raw.split(';').first;
      final eq = head.indexOf('=');
      if (eq <= 0) continue;
      pairs[head.substring(0, eq).trim()] = head.substring(eq + 1).trim();
    }
    return pairs;
  }

  /// 懒解析 JSON；解析失败抛 CloudException。
  Map<String, dynamic> get json {
    try {
      final v = jsonDecode(body);
      if (v is Map<String, dynamic>) return v;
      throw const CloudException('接口返回格式异常');
    } on CloudException {
      rethrow;
    } catch (_) {
      throw const CloudException('接口返回格式异常');
    }
  }
}

/// 统一请求入口。body 优先级：json > form > raw。
Future<CloudHttpResponse> cloudRequest(
  String method,
  String url, {
  Map<String, String>? headers,
  Map<String, dynamic>? jsonBody,
  Map<String, String>? form,
  String? rawBody,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final h = <String, String>{...?headers};
  String? bodyStr;
  if (jsonBody != null) {
    h.putIfAbsent('Content-Type', () => 'application/json');
    bodyStr = jsonEncode(jsonBody);
  } else if (form != null) {
    h.putIfAbsent(
        'Content-Type', () => 'application/x-www-form-urlencoded');
    bodyStr = form.entries
        .map((e) =>
            '${Uri.encodeQueryComponent(e.key)}='
            '${Uri.encodeQueryComponent(e.value)}')
        .join('&');
  } else if (rawBody != null) {
    bodyStr = rawBody;
  }
  try {
    final redirectSetCookies = <String>[];
    final resp = await appRequest(
      method,
      Uri.parse(url),
      headers: h,
      body: bodyStr,
      redirectSetCookies: redirectSetCookies,
    ).timeout(timeout);
    final setCookies = <String>[
      ...redirectSetCookies, // 中间 3xx 跳上的 Set-Cookie（蓝奏 ylogin 等）
    ];
    final headerMap = <String, String>{};
    resp.headers.forEach((name, values) {
      if (name.toLowerCase() == 'set-cookie') {
        setCookies.addAll(values);
      } else {
        headerMap[name] = values.join(', ');
      }
    });
    final respBody = await utf8.decodeStream(resp);
    return CloudHttpResponse._(resp.statusCode, headerMap, respBody, setCookies);
  } on CloudException {
    rethrow;
  } on TimeoutException {
    throw const CloudException('请求超时');
  } catch (e) {
    throw CloudException('网络请求失败: $e');
  }
}

Future<CloudHttpResponse> cloudGet(
  String url, {
  Map<String, String>? headers,
  Duration timeout = const Duration(seconds: 15),
}) =>
    cloudRequest('GET', url, headers: headers, timeout: timeout);

Future<CloudHttpResponse> cloudPostJson(
  String url, {
  Map<String, dynamic>? body,
  Map<String, String>? headers,
  Duration timeout = const Duration(seconds: 15),
}) =>
    cloudRequest('POST', url,
        jsonBody: body, headers: headers, timeout: timeout);

Future<CloudHttpResponse> cloudPostForm(
  String url,
  Map<String, String> form, {
  Map<String, String>? headers,
  Duration timeout = const Duration(seconds: 15),
}) =>
    cloudRequest('POST', url, form: form, headers: headers, timeout: timeout);

/// 凭据 Cookie 键值拼请求头（各盘 cred 存 'cookie' 单键整串时用另一形态）。
String cookieHeader(Map<String, String> pairs) =>
    pairs.entries.map((e) => '${e.key}=${e.value}').join('; ');
