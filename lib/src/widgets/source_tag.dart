import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../i18n/i18n.dart';
import '../plugin/plugin_provider.dart';

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

  // 1. 优先匹配已安装插件名：QueueItem/收藏走 onlineSongJson.pluginId，
  //    歌单 ImportedSong 直接给插件 id。
  final pid = pluginId ?? _pluginIdFromJson(onlineSongJson);
  if (pid != null && pid.isNotEmpty) {
    final pluginState = ref.read(pluginManagerProvider);
    for (final p in pluginState.sources) {
      if (p.id == pid) return p.name;
    }
  }

  // 2. 识别短 key（LX 常用音源 / 平台）
  final raw = source?.trim();
  if (raw != null && raw.isNotEmpty) {
    final lower = raw.toLowerCase();
    final short = _shortSourceName(lower);
    if (short != null) return short;
    return raw.length <= 6 ? raw.toUpperCase() : raw;
  }

  // 3. 从 lx:// 协议路径兜底
  if (path.startsWith('lx://')) {
    final parts = path.substring(5).split('/');
    if (parts.isNotEmpty && parts.first.isNotEmpty) {
      final short = _shortSourceName(parts.first.toLowerCase());
      if (short != null) return short;
      return parts.first.toUpperCase();
    }
  }

  return tr('在线');
}

/// 简短音源 key -> 显示名（与播放队列 `_formatItemSource` 一致）。
String? _shortSourceName(String lower) {
  switch (lower) {
    case 'kw':
      return tr('小蜗');
    case 'kg':
      return tr('小枸');
    case 'tx':
      return tr('小秋');
    case 'wy':
      return tr('小芸');
    case 'mg':
      return tr('小蜜');
    case 'bilibili':
    case 'bili':
      return tr('哔哩');
    case 'qishui':
      return tr('汽水');
    case 'qmkg':
      return tr('K歌');
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