// 网盘注册表：集中注册 11 盘实现，提供按 id 查找与分享链接归属识别。

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'cloud_credentials_store.dart';
import 'cloud_provider.dart';
import 'providers/aliyun_provider.dart';
import 'providers/baidu_provider.dart';
import 'providers/ecloud189_provider.dart';
import 'providers/lanzou_provider.dart';
import 'providers/mobile139_provider.dart';
import 'providers/pan123_provider.dart';
import 'providers/pikpak_provider.dart';
import 'providers/quark_provider.dart';
import 'providers/thunder_provider.dart';
import 'providers/uc_provider.dart';
import 'providers/weiyun_provider.dart';

final List<CloudProvider> cloudProviders = [
  BaiduProvider(),
  AliyunProvider(),
  QuarkProvider(),
  UcProvider(),
  Ecloud189Provider(),
  Mobile139Provider(),
  ThunderProvider(),
  Pan123Provider(),
  PikpakProvider(),
  LanzouProvider(),
  WeiyunProvider(),
];

/// 按 id 查找；未注册返回 null。
CloudProvider? cloudProviderById(String id) {
  for (final p in cloudProviders) {
    if (p.id == id) return p;
  }
  return null;
}

/// 已绑定账号的网盘 provider 列表（响应式：凭据 store 变更即自动重算）。
/// 「我的」网盘入口显隐、本地页「下载」tab 显隐、网盘页来源栏共用。
final boundCloudProvidersProvider = FutureProvider<List<CloudProvider>>(
  (ref) async {
    final store = CloudCredentialsStore.instance;
    void onChanged() => ref.invalidateSelf();
    store.addListener(onChanged);
    ref.onDispose(() => store.removeListener(onChanged));
    final out = <CloudProvider>[];
    for (final p in cloudProviders) {
      if ((await store.accountsFor(p.id)).isNotEmpty) out.add(p);
    }
    return out;
  },
);
