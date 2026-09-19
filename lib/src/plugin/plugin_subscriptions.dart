import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PluginSubscription {
  final String id;
  final String name;
  final String url;
  final int addedAt;

  const PluginSubscription({
    required this.id,
    required this.name,
    required this.url,
    required this.addedAt,
  });

  factory PluginSubscription.fromJson(Map<String, dynamic> j) =>
      PluginSubscription(
        id: (j['id'] as String?) ?? '',
        name: (j['name'] as String?) ?? '',
        url: (j['url'] as String?) ?? '',
        addedAt: (j['addedAt'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'addedAt': addedAt,
      };
}

class PluginSubscriptionsNotifier
    extends StateNotifier<List<PluginSubscription>> {
  PluginSubscriptionsNotifier() : super(const []) {
    _load();
  }

  static const _key = 'xianyu_plugin_subscriptions';

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null || raw.isEmpty) return;
      final list = jsonDecode(raw) as List;
      state = list
          .whereType<Map>()
          .map((e) => PluginSubscription.fromJson(e.cast<String, dynamic>()))
          .where((s) => s.url.isNotEmpty)
          .toList();
    } catch (_) {
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _key, jsonEncode(state.map((e) => e.toJson()).toList()));
    } catch (_) {
    }
  }

  String _fallbackName(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    final lastSeg = uri.pathSegments.isNotEmpty ? uri.pathSegments.last : '';
    return '${uri.host}${lastSeg.isNotEmpty ? '/$lastSeg' : ''}';
  }

  Future<void> addFromInstall(String url, {String? name}) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return;
    if (state.any((s) => s.url == trimmed)) return;
    state = [
      ...state,
      PluginSubscription(
        id: 'sub_${DateTime.now().millisecondsSinceEpoch}',
        name: (name != null && name.trim().isNotEmpty)
            ? name.trim()
            : _fallbackName(trimmed),
        url: trimmed,
        addedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    ];
    await _persist();
  }

  Future<void> remove(String id) async {
    state = state.where((s) => s.id != id).toList();
    await _persist();
  }

  Future<int> mergeFromCloud(
      List<Map<String, dynamic>> cloud) async {
    final knownUrls = state.map((s) => s.url).toSet();
    var added = 0;
    for (final raw in cloud) {
      final url = (raw['url'] as String?)?.trim() ?? '';
      if (url.isEmpty || knownUrls.contains(url)) continue;
      state = [
        ...state,
        PluginSubscription(
          id: (raw['id'] as String?)?.isNotEmpty == true
              ? raw['id'] as String
              : 'sub_${DateTime.now().millisecondsSinceEpoch}_$added',
          name: ((raw['name'] as String?)?.trim().isNotEmpty ?? false)
              ? raw['name'] as String
              : _fallbackName(url),
          url: url,
          addedAt: (raw['addedAt'] as num?)?.toInt() ??
              DateTime.now().millisecondsSinceEpoch,
        ),
      ];
      knownUrls.add(url);
      added++;
    }
    if (added > 0) await _persist();
    return added;
  }
}

final pluginSubscriptionsProvider =
    StateNotifierProvider<PluginSubscriptionsNotifier, List<PluginSubscription>>(
        (ref) => PluginSubscriptionsNotifier());
