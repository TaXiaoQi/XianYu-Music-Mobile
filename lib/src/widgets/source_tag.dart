import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';
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

const int kSourceTagMaxChars = 5;

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

String? _brandFromUrl(String? url) {
  if (url == null || url.isEmpty) return null;
  final v = Uri.tryParse(url)?.queryParameters['source']?.trim();
  if (v == null || v.isEmpty) return null;
  return kSubSourceBrandAlias[v.toLowerCase()] ?? v;
}

bool _urlHasKey(String? url) {
  if (url == null || url.isEmpty) return false;
  final v = Uri.tryParse(url)?.queryParameters['key']?.trim();
  return v != null && v.isNotEmpty;
}

String? _urlHost(String? url) {
  final host = Uri.tryParse(url ?? '')?.host;
  return (host == null || host.isEmpty) ? null : host;
}

/// 插件名/作者内置品牌词（ikun 插件 URL 只有 key 无 source，靠名称识别）
const List<(String, String)> kSubSourceBrandKeywords = [
  ('聆澜', '聆澜'),
  ('ikun', 'ikun'),
];

String? _brandFromIdentity(String name, String author) {
  final hay = '${name.trim()} ${author.trim()}'.toLowerCase();
  if (hay.trim().isEmpty) return null;
  for (final (kw, brand) in kSubSourceBrandKeywords) {
    if (hay.contains(kw)) return brand;
  }
  return null;
}

/// 插件付费订阅标签：优先看插件自身安装 URL 与内置品牌词；否则按「订阅名=插件名」或
/// 「订阅 host=安装 URL host」匹配订阅记录（订阅条目 URL 常不带 key/source，
/// 如咪咕/汽水/bilibili）；都未命中返回 null，按普通音源显示。
({String label, bool highlight})? _pluginSubTag(
  PluginSource p,
  List<PluginSubscription> subs,
) {
  final own = _brandFromUrl(p.sourceUrl) ?? _brandFromUrl(p.filePath);
  if (own != null) return (label: own, highlight: true);
  final named = _brandFromIdentity(p.name, p.author);
  if (named != null) return (label: named, highlight: true);
  if (_urlHasKey(p.sourceUrl) || _urlHasKey(p.filePath)) {
    return (label: tr('付费'), highlight: true);
  }
  final ownHost = _urlHost(p.sourceUrl.isNotEmpty ? p.sourceUrl : p.filePath);
  final pname = p.name.trim();
  for (final sub in subs) {
    final subName = sub.name.trim();
    final matched = (subName.isNotEmpty && subName == pname) ||
        (ownHost != null && _urlHost(sub.url) == ownHost);
    if (!matched) continue;
    final brand = _brandFromUrl(sub.url);
    if (brand != null) return (label: brand, highlight: true);
    if (_urlHasKey(sub.url)) return (label: tr('付费'), highlight: true);
    break;
  }
  return null;
}

/// 插件管理页等直接持有 PluginSource 的场景使用
({String label, bool highlight})? pluginSubTagInfo(
  PluginSource p,
  List<PluginSubscription> subs,
) {
  return _pluginSubTag(p, subs);
}

/// SourceTag 专用：普通音源名之前先解析付费订阅品牌/付费标记（金色高亮）。
({String label, bool highlight}) songSourceTagInfo(
  WidgetRef ref, {
  required String path,
  required bool isOnline,
  String? source,
  String? onlineSongJson,
  String? pluginId,
}) {
  if (isOnline) {
    final pid = pluginId ?? _pluginIdFromJson(onlineSongJson);
    if (pid != null && pid.isNotEmpty) {
      final pluginState = ref.watch(pluginManagerProvider);
      for (final p in pluginState.sources) {
        if (p.id != pid) continue;
        final tag =
            _pluginSubTag(p, ref.watch(pluginSubscriptionsProvider));
        if (tag != null) return tag;
        break;
      }
    }
  }
  return (
    label: songSourceLabel(
      ref,
      path: path,
      isOnline: isOnline,
      source: source,
      onlineSongJson: onlineSongJson,
      pluginId: pluginId,
    ),
    highlight: false,
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
  if (!isOnline) return tr('本地');

  final showReal = ref.watch(settingsProvider
          .select((s) => s.valueOrNull?.showRealSourceName ?? false));

  final pid = pluginId ?? _pluginIdFromJson(onlineSongJson);
  if (pid != null && pid.isNotEmpty) {
    final pluginState = ref.watch(pluginManagerProvider);
    for (final p in pluginState.sources) {
      if (p.id == pid) {
        return showReal ? resolveRealSourceName(p.name) : p.name;
      }
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
    final highlight = info.highlight;
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