part of 'plugin_backup_import.dart';

class _PlatformDescriptor {
  final String displayName;
  final String normalized;
  final String canonical;
  final String? lxSource;

  _PlatformDescriptor({
    required this.displayName,
    required this.normalized,
    required this.canonical,
    this.lxSource,
  });
}

List<Map<String, Object?>> get _platformAliases => [
  {
    'canonical': 'netease',
    'displayName': tr('网易云音乐'),
    'lxSource': 'wy',
    'aliases': ['wy', 'netease', tr('网易'), tr('网易云'), tr('网易云音乐')],
  },
  {
    'canonical': 'qq',
    'displayName': tr('QQ音乐'),
    'lxSource': 'tx',
    'aliases': ['tx', 'qq', 'qqmusic', tr('腾讯'), tr('腾讯音乐'), tr('qq音乐')],
  },
  {
    'canonical': 'kuwo',
    'displayName': tr('酷我音乐'),
    'lxSource': 'kw',
    'aliases': ['kw', 'kuwo', tr('酷我'), tr('酷我音乐')],
  },
  {
    'canonical': 'kugou',
    'displayName': tr('酷狗音乐'),
    'lxSource': 'kg',
    'aliases': ['kg', 'kugou', tr('酷狗'), tr('酷狗音乐')],
  },
  {
    'canonical': 'migu',
    'displayName': tr('咪咕音乐'),
    'lxSource': 'mg',
    'aliases': ['mg', 'migu', tr('咪咕'), tr('咪咕音乐')],
  },
  {
    'canonical': 'bilibili',
    'displayName': tr('哔哩哔哩'),
    'aliases': ['bilibili', tr('b站'), tr('哔哩哔哩')],
  },
];

String _normalizePlatformLabel(Object? value) {
  return (value?.toString() ?? '')
      .replaceAll(RegExp(r'[\s_.\-—/\\()[\]（）【】·]+'), '')
      .replaceAll(RegExp(r'(?:音乐|music|音源|source|插件|plugin)+$'), '')
      .toLowerCase();
}

_PlatformDescriptor _describePlatform(Object? value) {
  final original = (value?.toString() ?? '').trim();
  final normalized = _normalizePlatformLabel(original);

  for (final definition in _platformAliases) {
    final aliases = (definition['aliases'] as List)
        .map((a) => _normalizePlatformLabel(a))
        .toList();
    for (final alias in aliases) {
      if (normalized == alias || (alias.length >= 2 && normalized.contains(alias))) {
        return _PlatformDescriptor(
          displayName: original.isEmpty ? definition['displayName'] as String : original,
          normalized: normalized,
          canonical: definition['canonical'] as String,
          lxSource: definition['lxSource'] as String?,
        );
      }
    }
  }

  return _PlatformDescriptor(
    displayName: original.isEmpty ? tr('未知来源') : original,
    normalized: normalized,
    canonical: normalized,
  );
}

int _pluginMatchScore(
  PluginSource plugin,
  _PlatformDescriptor platform,
  String? format,
) {
  if (!plugin.format.isMfCompatible && plugin.format != PluginFormat.lx) {
    return 0;
  }

  if (plugin.format == PluginFormat.lx &&
      platform.lxSource != null &&
      plugin.sources.contains(platform.lxSource)) {
    return format == 'lxmusic' ? 150 : 120;
  }

  var best = 0;
  final labels = [plugin.name, ...plugin.sources];
  for (final label in labels) {
    final normalized = _normalizePlatformLabel(label);
    if (normalized.isEmpty) continue;
    if (normalized == platform.normalized) {
      final score = plugin.format.isMfCompatible ? 140 : 110;
      if (score > best) best = score;
    }
    final descriptor = _describePlatform(label);
    if (descriptor.canonical.isNotEmpty &&
        descriptor.canonical == platform.canonical) {
      final score = plugin.format.isMfCompatible ? 130 : 100;
      if (score > best) best = score;
    }
  }

  return best;
}

PluginSource? _findMatchingPlugin(
  _PlatformDescriptor platform,
  List<PluginSource> installedPlugins,
  String? format,
) {
  final scored = <(PluginSource, int)>[];
  for (final plugin in installedPlugins) {
    final score = _pluginMatchScore(plugin, platform, format);
    if (score > 0) scored.add((plugin, score));
  }
  scored.sort((a, b) {
    if (a.$1.enabled != b.$1.enabled) return a.$1.enabled ? -1 : 1;
    if (a.$2 != b.$2) return b.$2 - a.$2;
    if (a.$1.format != b.$1.format) {
      if (format == 'lxmusic') {
        return a.$1.format == PluginFormat.lx ? -1 : 1;
      }
      return a.$1.format.isMfCompatible ? -1 : 1;
    }
    return 0;
  });
  return scored.isEmpty ? null : scored.first.$1;
}

PluginSource? findPluginForPlatform({
  required String platformLabel,
  required List<PluginSource> installedPlugins,
  required PluginFormat format,
  bool allowCrossFormat = false,
}) {
  final descriptor = _describePlatform(platformLabel);
  if (descriptor.normalized.isEmpty) return null;
  final candidates = allowCrossFormat
      ? installedPlugins
      : installedPlugins.where((p) => p.format == format).toList();
  return _findMatchingPlugin(
    descriptor,
    candidates,
    format == PluginFormat.lx ? 'lxmusic' : 'bakamusic',
  );
}

PluginSource? findPluginForPlatformCrossFormat({
  required String platformLabel,
  required List<PluginSource> installedPlugins,
  required PluginFormat originalFormat,
}) {
  return findPluginForPlatform(
    platformLabel: platformLabel,
    installedPlugins: installedPlugins,
    format: originalFormat,
    allowCrossFormat: true,
  );
}

List<PluginSource> listEnabledPluginsForPlatform({
  required String platformLabel,
  required List<PluginSource> installedPlugins,
  required PluginFormat format,
  String? excludeId,
}) {
  final descriptor = _describePlatform(platformLabel);
  if (descriptor.normalized.isEmpty) return const [];
  final formatTag = format == PluginFormat.lx ? 'lxmusic' : 'bakamusic';
  final scored = <(PluginSource, int)>[];
  for (final plugin in installedPlugins) {
    if (!plugin.enabled || plugin.id == excludeId) continue;
    final score = _pluginMatchScore(plugin, descriptor, formatTag);
    if (score > 0) scored.add((plugin, score));
  }
  scored.sort((a, b) {
    if (a.$2 != b.$2) return b.$2 - a.$2;
    return (a.$1.sortOrder ?? 0).compareTo(b.$1.sortOrder ?? 0);
  });
  return scored.map((e) => e.$1).toList();
}

String lxSourceKeyForPlatform(String platformLabel) {
  final desc = _describePlatform(platformLabel);
  return desc.lxSource ?? '';
}

