import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/account_api.dart';
import 'remote_theme.dart';

/// 主题广场列表。
///
/// 服务端 `list_themes` 只返回已过审（`status='normal'`）的 mobile 主题，
/// 故这里不需要再过滤。失败时按 Riverpod 惯例暴露为 `AsyncValue.error`，
/// 由页面决定如何提示——不吞掉错误。
final themeSquareProvider = FutureProvider<List<RemoteTheme>>((ref) async {
  final api = ref.watch(accountApiProvider);
  final data = await api.listThemes();
  return RemoteTheme.listFrom(data);
});

/// 我的上传列表（服务端不过滤 status，含待审条目）。
///
/// 该 action 必须带弦予号，未登录时没有弦予号：直接返回空列表，
/// 而不是发一个必然被服务端以 400 拒绝的请求。
final myThemesProvider = FutureProvider<List<RemoteTheme>>((ref) async {
  final api = ref.watch(accountApiProvider);
  final id = api.ciyuanxiId;
  if (id == null || id.isEmpty) return const <RemoteTheme>[];
  final data = await api.myThemes(ciyuanxiId: id);
  return RemoteTheme.listFrom(data);
});
