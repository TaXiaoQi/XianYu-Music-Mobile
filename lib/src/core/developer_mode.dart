import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DeveloperModeNotifier extends StateNotifier<bool> {
  DeveloperModeNotifier() : super(false) {
    _init();
  }

  static const _key = 'xianyu_developer_mode';

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getBool(_key) ?? false;
  }

  Future<void> enable() async {
    state = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, true);
  }

  Future<void> disable() async {
    state = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}

final developerModeProvider =
    StateNotifierProvider<DeveloperModeNotifier, bool>(
  (ref) => DeveloperModeNotifier(),
);
