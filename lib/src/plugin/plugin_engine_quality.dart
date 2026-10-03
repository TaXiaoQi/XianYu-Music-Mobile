// 音质档位映射（part 拆分自 plugin_engine.dart，实现顶层化，PluginEngine 类内保留薄别名）
part of 'plugin_engine.dart';

const List<String> pluginQualityLadder = [
  'mgg', '128k', '192k', '320k', 'flac', 'flac24bit',
  'hires', 'vinyl', 'dolby', 'atmos', 'atmos_plus', 'master',
];

const Map<String, String> pluginQualityAliases = {
  '96k': 'mgg', 'ogg96': 'mgg', 'mgg': 'mgg',
  '128': '128k', '128k': '128k',
  '192': '192k', '192k': '192k', 'ogg192': '192k',
  '320': '320k', '320k': '320k', 'ogg320': '320k', 'exhigh': '320k',
  'flac': 'flac', 'sq': 'flac', 'super': 'flac', 'lossless': 'flac',
  'flac24': 'flac24bit', '24bit': 'flac24bit', '24bits': 'flac24bit',
  '24_bit': 'flac24bit', 'flac24bit': 'flac24bit',
  'hires': 'hires', 'hi-res': 'hires', 'hi_res': 'hires', 'hr': 'hires',
  'vinyl': 'vinyl', 'dolby': 'dolby', 'atmos': 'atmos',
  'galaxy': 'atmos', 'atmosplus': 'atmos_plus', 'atmos_plus': 'atmos_plus',
  'atmos+': 'atmos_plus', 'galaxy51': 'atmos_plus', 'master': 'master',
};

const List<String> _mfQualityOrder = ['low', 'standard', 'high', 'super'];

String? _pluginNormalizeQualityKey(dynamic raw) {
  if (raw is! String) return null;
  final normalized =
      raw.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '').replaceAll('-', '_');
  if (normalized.isEmpty) return null;
  return pluginQualityLadder.contains(normalized)
      ? normalized
      : pluginQualityAliases[normalized];
}

String _pluginQualityKeyToPluginString(String q) => q == 'mgg' ? '96k' : q;

bool _pluginIsLossless(String q) =>
    pluginQualityLadder.indexOf(q) >= pluginQualityLadder.indexOf('flac');

String _pluginQualityKeyToMfQuality(String q) {
  final rank = pluginQualityLadder.indexOf(q);
  if (rank < 0) return 'standard';
  if (rank >= 5) return 'super';
  if (rank >= 4) return 'high';
  if (rank >= 3) return 'standard';
  return 'low';
}

List<String> _pluginMusicFreeQualityCandidates(
  String preferred,
  String fallback,
  Set<String> declaredKeys,
) {
  final baseMf = _pluginQualityKeyToMfQuality(preferred);
  if (fallback == 'pause') return [baseMf];
  final baseIdx = _mfQualityOrder.indexOf(baseMf);
  final order = <String>[baseMf];
  for (var i = baseIdx + 1; i < _mfQualityOrder.length; i++) {
    order.add(_mfQualityOrder[i]);
  }
  for (var i = baseIdx - 1; i >= 0; i--) {
    order.add(_mfQualityOrder[i]);
  }
  return order;
}

List<String> _pluginMusicFreeNativeCandidates(
  String preferred,
  String fallback,
  Set<String> declaredKeys,
) {
  final ladderDesc = pluginQualityLadder.reversed.toList();
  final candidates = <String>[];
  final seen = <String>{};
  void add(String qk) {
    final pluginQ = _pluginQualityKeyToPluginString(qk);
    if (seen.add(pluginQ)) candidates.add(pluginQ);
    if (_pluginIsLossless(qk) && seen.add('super')) candidates.add('super');
  }

  if (fallback == 'pause') {
    add(preferred);
  } else if (fallback == 'higher') {
    final start = pluginQualityLadder.indexOf(preferred);
    if (start >= 0) {
      for (var i = start; i < pluginQualityLadder.length; i++) {
        add(pluginQualityLadder[i]);
      }
    } else {
      add(preferred);
    }
  } else {
    final start = ladderDesc.indexOf(preferred);
    if (start >= 0) {
      for (var i = start; i < ladderDesc.length; i++) {
        add(ladderDesc[i]);
      }
    } else {
      add(preferred);
    }
  }

  if (declaredKeys.isNotEmpty) {
    final filtered = candidates.where((c) {
      final norm = _pluginNormalizeQualityKey(c);
      return norm != null && declaredKeys.contains(norm);
    }).toList();
    if (filtered.isNotEmpty) return filtered;
  }
  return candidates.take(1).toList();
}
