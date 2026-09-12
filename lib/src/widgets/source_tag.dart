import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/settings.dart';
import '../i18n/i18n.dart';
import '../plugin/plugin_provider.dart';

/// 「小X」规避审查别名 → 平台真名映射。
/// 插件开发者常用同音字/形近字代指真实平台以规避应用商店审查，
/// 开启「显示真实音源名」后统一还原。
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

/// 把插件名/别名中的「小X」替换为真实平台名（如「小枸音乐」→「酷狗音乐」）。
/// 若未命中映射则原样返回。
String resolveRealSourceName(String name) {
  for (final entry in kSourceAliasToReal.entries) {
    if (name.contains(entry.key)) {
      return name.replaceAll(entry.key, entry.value);
    }
  }
  return name;
}

/// 来源标签最多显示的字数（对齐桌面端，与播放队列一致）。
const int kSourceTagMaxChars = 5;

/// 截断来源文案到最多 [kSourceTagMaxChars] 个字（超出加省略号）。
String truncateSource(String label) {
  if (label.length <= kSourceTagMaxChars) return label;
  final runes = label.runes.take(kSourceTagMaxChars);
  return '${String.fromCharCodes(runes)}…';
}

/// 计算歌曲的来源标签文案。
///
/// 需要音源/路径识别的能力（来源 key、lx:// 路径、已装插件名），与桌面端
/// `remoteSong.getSongSourceLabel` 行为对齐：在线歌曲显示来源名，本地歌曲显示「本地」。
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

  // 1. 优先匹配已安装插件名：QueueItem/收藏走 onlineSongJson.pluginId，
  //    歌单 ImportedSong 直接给插件 id。
  final pid = pluginId ?? _pluginIdFromJson(onlineSongJson);
  if (pid != null && pid.isNotEmpty) {
    final pluginState = ref.read(pluginManagerProvider);
    for (final p in pluginState.sources) {
      if (p.id == pid) {
        return showReal ? resolveRealSourceName(p.name) : p.name;
      }
    }
  }

  // 2. 识别短 key（LX 常用音源 / 平台）。
  //    收藏/榜单导入等场景来源 key 常只写在 onlineSongJson 里、顶层 source
  //    为空，从 json 兜底读取，避免来源落成「在线」。
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

  // 3. 从 lx:// 协议路径兜底
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

/// 简短音源 key -> 显示名（与播放队列 `_formatItemSource` 一致）。
/// [showReal] 为 true 时返回平台真名而非「小X」别名。
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

/// 从 onlineSongJson 读取来源 key（QueueItem/收藏常把 source 只写在 json 里）。
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

/// 歌曲来源标签：桌面端风格的小胶囊，展示来源名 / 「本地」，最多 [kSourceTagMaxChars] 字。
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
    final label = truncateSource(
      songSourceLabel(
        ref,
        path: path,
        isOnline: isOnline,
        source: source,
        onlineSongJson: onlineSongJson,
        pluginId: pluginId,
      ),
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.3),
          width: 0.5,
        ),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.clip,
        style: TextStyle(
          fontSize: 11,
          color: scheme.onSurfaceVariant,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}