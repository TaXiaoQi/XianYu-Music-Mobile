import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';
import '../cloud/cloud_registry.dart';
import '../i18n/i18n.dart';
import '../plugin/plugin_models.dart';
import '../plugin/plugin_provider.dart';
import '../plugin/plugin_subscriptions.dart';

const Map<String, String> kSourceAliasToReal = {
  '小蜗': '酷我',
  '小枸': '酷狗',
  '小秋': 'QQ',
  '小芸': '网易云',
  '小蜜': '咪咕',
  '哔哩': '哔哩哔哩',
  '汽水': '汽水音乐',
  'K歌': '全民K歌',
};

String resolveRealSourceName(String name) {
  for (final entry in kSourceAliasToReal.entries) {
    if (name.contains(entry.key)) {
      return name.replaceAll(entry.key, entry.value);
    }
  }
  return name;
}

// 与桌面端对齐：桌面标签容器 w-16(64px)+CSS truncate，视觉约 5 个字符位
// （约 4 字+省略号）。此处按字符数硬截取到 4 字+'…'，合计 5 个字符位。
const int kSourceTagMaxChars = 4;

String truncateSource(String label) {
  if (label.length <= kSourceTagMaxChars) return label;
  final runes = label.runes.take(kSourceTagMaxChars);
  return '${String.fromCharCodes(runes)}…';
}

/// 付费订阅来源品牌：订阅/插件安装 URL 的 query 带 source=（聆澜/ikun 等）时，
/// 标签直接显示来源品牌名；仅带 key= 无来源名时回落显示「付费」。
const Map<String, String> kSubSourceBrandAlias = {
  'linglan': '聆澜',
};

/// baka 免费聚合音源品牌（全豆要/次合代等）：同样按 source=/名称识别，
/// 标签用 baka 配色渲染，与付费金色区分
const Map<String, String> kFreeSubSourceBrandAlias = {
  'quandouyao': '全豆要',
  'cihedai': '次合代',
  'ciheidai': '次合代',
};

String? _brandFromUrl(String? url, Map<String, String> alias) {
  if (url == null || url.isEmpty) return null;
  final v = Uri.tryParse(url)?.queryParameters['source']?.trim();
  if (v == null || v.isEmpty) return null;
  // 仅识别已知品牌别名：公开订阅也会用 source= 传自定义标识，
  // 未知值不视为任何来源品牌，避免免费插件被误标为付费
  return alias[v.toLowerCase()];
}

bool _urlHasKey(String? url) {
  if (url == null || url.isEmpty) return false;
  final v = Uri.tryParse(url)?.queryParameters['key']?.trim();
  return v != null && v.isNotEmpty;
}

String? _sourceValue(String? url) {
  if (url == null || url.isEmpty) return null;
  final v = Uri.tryParse(url)?.queryParameters['source']?.trim();
  return (v == null || v.isEmpty) ? null : v;
}

/// 订阅 URL 的 source 常带 .json 后缀（如 quandouyao.json），插件安装 URL 是去后缀的
/// 标识（如 quandouyao）——归属判定前统一去掉 .json 再比较
String _normSourceValue(String v) =>
    v.toLowerCase().replaceFirst(RegExp(r'\.json$'), '');

/// 插件名/作者内置品牌词（ikun 插件 URL 只有 key 无 source，靠名称识别）
const List<(String, String)> kSubSourceBrandKeywords = [
  ('聆澜', '聆澜'),
  ('ikun', 'ikun'),
];

/// baka 免费聚合音源名称关键词兜底
const List<(String, String)> kFreeSubSourceBrandKeywords = [
  ('全豆要', '全豆要'),
  ('次合代', '次合代'),
];

String? _brandFromIdentity(String name, String author,
    List<(String, String)> keywords) {
  final hay = '${name.trim()} ${author.trim()}'.toLowerCase();
  if (hay.trim().isEmpty) return null;
  for (final (kw, brand) in keywords) {
    if (hay.contains(kw)) return brand;
  }
  return null;
}

/// 插件付费订阅/免费聚合音源标签：优先看插件自身安装 URL/来源订阅 URL 与内置品牌词；
/// 插件 URL 带 source 标识时按 source 值精确归属订阅——同一台主机可挂多个订阅
/// （公共+付费并存），禁止按 host/名称猜归属；都未命中返回 null，按普通音源显示。
/// paid=true 付费来源（金色高亮），paid=false 免费聚合音源品牌（baka 配色）。
({String label, bool paid})? _pluginSubTag(
  PluginSource p,
  List<PluginSubscription> subs,
) {
  final own = _brandFromUrl(p.sourceUrl, kSubSourceBrandAlias) ??
      _brandFromUrl(p.filePath, kSubSourceBrandAlias);
  if (own != null) return (label: own, paid: true);
  final named = _brandFromIdentity(p.name, p.author, kSubSourceBrandKeywords);
  if (named != null) return (label: named, paid: true);
  if (_urlHasKey(p.sourceUrl) || _urlHasKey(p.filePath)) {
    return (label: tr('付费'), paid: true);
  }
  // baka 免费聚合音源（全豆要/次合代）：同样按 source=/名称识别，普通配色渲染
  final freeOwn = _brandFromUrl(p.sourceUrl, kFreeSubSourceBrandAlias) ??
      _brandFromUrl(p.filePath, kFreeSubSourceBrandAlias);
  if (freeOwn != null) return (label: freeOwn, paid: false);
  final freeNamed =
      _brandFromIdentity(p.name, p.author, kFreeSubSourceBrandKeywords);
  if (freeNamed != null) return (label: freeNamed, paid: false);
  final ownSrc = _sourceValue(p.filePath) ?? _sourceValue(p.sourceUrl);
  if (ownSrc == null) return null;
  final ownKey = _normSourceValue(ownSrc);
  for (final sub in subs) {
    final subSrc = _sourceValue(sub.url);
    if (subSrc == null || _normSourceValue(subSrc) != ownKey) continue;
    final brand = _brandFromUrl(sub.url, kSubSourceBrandAlias);
    if (brand != null) return (label: brand, paid: true);
    if (_urlHasKey(sub.url)) return (label: tr('付费'), paid: true);
    final freeBrand = _brandFromUrl(sub.url, kFreeSubSourceBrandAlias);
    if (freeBrand != null) return (label: freeBrand, paid: false);
    break;
  }
  return null;
}

/// 插件管理页等直接持有 PluginSource 的场景使用
({String label, bool paid})? pluginSubTagInfo(
  PluginSource p,
  List<PluginSubscription> subs,
) {
  final tag = _pluginSubTag(p, subs);
  if (tag == null) return null;
  if (!tag.paid) return tag;
  // 付费品牌标签加「付费」前缀（付费聆澜/付费ikun）；回落「付费」不重复前缀
  final paid = tr('付费');
  if (tag.label == paid || tag.label == '付费') return tag;
  return (label: '$paid${tag.label}', paid: tag.paid);
}

/// SourceTag 专用：普通音源名之前先解析付费订阅品牌/付费标记（金色高亮）。
({String label, bool paid}) songSourceTagInfo(
  WidgetRef ref, {
  required String path,
  required bool isOnline,
  String? source,
  String? onlineSongJson,
  String? pluginId,
}) {
  // 歌曲页等场景维持原样（来源标签显示音源/插件名）；付费品牌标签只在插件管理页展示
  return (
    label: songSourceLabel(
      ref,
      path: path,
      isOnline: isOnline,
      source: source,
      onlineSongJson: onlineSongJson,
      pluginId: pluginId,
    ),
    paid: false,
  );
}

String songSourceLabel(
  WidgetRef ref, {
  required String path,
  required bool isOnline,
  String? source,
  String? onlineSongJson,
  String? pluginId,
}) {
  // 网盘来源：cloud:// 播放标识或 'cloud:<pid>' 来源值，显示盘名。
  // cloud:// 曲目 isOnline=false，必须先于本地判定，否则被标成「本地」。
  final src0 = (source != null && source.trim().isNotEmpty)
      ? source
      : (path.startsWith('cloud://')
          ? 'cloud:${path.substring(7).split('/').first}'
          : '');
  if (src0.startsWith('cloud:')) {
    final pid = src0.substring(6);
    if (pid.isNotEmpty) {
      return cloudProviderById(pid)?.displayName ?? tr('网盘');
    }
    return tr('网盘');
  }

  if (!isOnline) return tr('本地');

  final showReal = ref.watch(settingsProvider
          .select((s) => s.valueOrNull?.showRealSourceName ?? false));

  final pid = pluginId ?? _pluginIdFromJson(onlineSongJson);
  if (pid != null && pid.isNotEmpty) {
    final pluginState = ref.watch(pluginManagerProvider);
    // 插件更新即换 sha256 id（updateScript 销毁旧 id 并记录别名），
    // 收藏/队列行存的旧 pluginId 沿别名链换算后再匹配，避免标签
    // 降级「在线」；限深防环
    var effId = pid;
    for (var i = 0; i < 8; i++) {
      for (final p in pluginState.sources) {
        if (p.id == effId) {
          return showReal ? resolveRealSourceName(p.name) : p.name;
        }
      }
      final next = pluginState.idAliases[effId];
      if (next == null || next.isEmpty) break;
      effId = next;
    }
  }

  final src = (source != null && source.trim().isNotEmpty)
      ? source
      : _jsonSource(onlineSongJson);
  final raw = src?.trim();
  if (raw != null && raw.isNotEmpty) {
    final lower = raw.toLowerCase();
    final short = _shortSourceName(lower, showReal: showReal);
    if (short != null) return short;
    return raw.length <= 6 ? raw.toUpperCase() : raw;
  }

  if (path.startsWith('lx://')) {
    final parts = path.substring(5).split('/');
    if (parts.isNotEmpty && parts.first.isNotEmpty) {
      final short = _shortSourceName(parts.first.toLowerCase(), showReal: showReal);
      if (short != null) return short;
      return parts.first.toUpperCase();
    }
  }

  return tr('在线');
}

String? _shortSourceName(String lower, {bool showReal = false}) {
  switch (lower) {
    case 'kw':
      return showReal ? '酷我' : tr('小蜗');
    case 'kg':
      return showReal ? '酷狗' : tr('小枸');
    case 'tx':
      return showReal ? 'QQ' : tr('小秋');
    case 'wy':
      return showReal ? '网易云' : tr('小芸');
    case 'mg':
      return showReal ? '咪咕' : tr('小蜜');
    case 'qs':
      return showReal ? '汽水音乐' : tr('汽水');
    case 'bilibili':
    case 'bili':
      return showReal ? '哔哩哔哩' : tr('哔哩');
    case 'qishui':
      return showReal ? '汽水音乐' : tr('汽水');
    case 'qmkg':
      return showReal ? '全民K歌' : tr('K歌');
    case 'kuaishou':
      return tr('快手');
    case 'youtube':
      return 'YouTube';
    case 'xmly':
      return tr('喜马拉雅');
    default:
      return null;
  }
}

String? _jsonSource(String? onlineSongJson) {
  if (onlineSongJson == null || onlineSongJson.isEmpty) return null;
  try {
    final json = jsonDecode(onlineSongJson) as Map<String, dynamic>;
    final s = json['source'];
    return s is String && s.isNotEmpty ? s : null;
  } catch (_) {
    return null;
  }
}

String? _pluginIdFromJson(String? onlineSongJson) {
  if (onlineSongJson == null || onlineSongJson.isEmpty) return null;
  try {
    final json = jsonDecode(onlineSongJson) as Map<String, dynamic>;
    return json['pluginId'] as String?;
  } catch (_) {
    return null;
  }
}

class SourceTag extends ConsumerWidget {
  const SourceTag({
    super.key,
    required this.path,
    required this.isOnline,
    this.source,
    this.onlineSongJson,
    this.pluginId,
  });

  final String path;
  final bool isOnline;
  final String? source;
  final String? onlineSongJson;
  final String? pluginId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final info = songSourceTagInfo(
      ref,
      path: path,
      isOnline: isOnline,
      source: source,
      onlineSongJson: onlineSongJson,
      pluginId: pluginId,
    );
    // 付费订阅来源（聆澜/ikun 等品牌或「付费」）用金色高亮，与普通音源区分
    const highlightColor = Color(0xFFE6A23C);
    final highlight = info.paid;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: highlight
            ? highlightColor.withValues(alpha: 0.15)
            : scheme.surfaceContainerHigh.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: highlight
              ? highlightColor.withValues(alpha: 0.4)
              : scheme.outlineVariant.withValues(alpha: 0.3),
          width: 0.5,
        ),
      ),
      child: Text(
        truncateSource(info.label),
        maxLines: 1,
        overflow: TextOverflow.clip,
        style: TextStyle(
          fontSize: 11,
          color: highlight ? highlightColor : scheme.onSurfaceVariant,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

/// 歌曲行行尾「来源标 + 时长」上下叠放（收藏页歌曲行同款），供各歌曲列表复用
class SongTrailingMeta extends StatelessWidget {
  const SongTrailingMeta({
    super.key,
    required this.path,
    required this.isOnline,
    this.source,
    this.onlineSongJson,
    this.pluginId,
    this.durationText,
    this.fontSize = 12,
  });

  final String path;
  final bool isOnline;
  final String? source;
  final String? onlineSongJson;
  final String? pluginId;

  /// 已格式化的时长文本（m:ss），空/null 不显示时长行
  final String? durationText;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SourceTag(
          path: path,
          isOnline: isOnline,
          source: source,
          onlineSongJson: onlineSongJson,
          pluginId: pluginId,
        ),
        if (durationText != null && durationText!.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(
            durationText!,
            style: TextStyle(
              fontSize: fontSize,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}