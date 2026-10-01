import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/settings.dart';
import 'theme_package.dart';

/// 已导入主题包 + 当前激活包。渲染层通过 [themeIcon] / [themeSticker] /
/// [themeSurface] 查询，未激活或该槽未设置时返回 null，调用方回落内置。
class ThemeLibraryState {
  const ThemeLibraryState({
    this.packages = const [],
    this.activeId,
    this.downloadedIds = const <String>{},
  });

  final List<ThemePackage> packages;
  final String? activeId;

  /// 从广场下载过的包 id 集合（「我的下载」Tab 数据源 = packages 的子集）。
  /// 只增不减：同 id 先下载后文件导入仍保留标记（见主题中心交接文档 §4.1）。
  final Set<String> downloadedIds;

  ThemePackage? get active {
    for (final pkg in packages) {
      if (pkg.id == activeId) return pkg;
    }
    return null;
  }

  /// 槽位 id → 图标 URL（未激活/未设置 → null）。
  String? themeIcon(String slotId) => active?.icons[slotId];

  /// 槽位 id → 贴纸 URL。
  String? themeSticker(String slotId) => active?.stickers[slotId];

  /// 槽位 id → 组件色块。
  ThemeSurface? themeSurface(String slotId) => active?.surfaces[slotId];
}

class ThemeLibraryNotifier extends StateNotifier<ThemeLibraryState> {
  ThemeLibraryNotifier(this._ref) : super(const ThemeLibraryState()) {
    ready = _init();
  }

  final Ref _ref;

  /// 初始载入完成。UI 与测试可 await 它，避免读到空状态。
  late final Future<void> ready;

  static const _packsKey = 'xianyu_theme_packs_v1';
  static const _activeKey = 'xianyu_active_theme_id_v1';
  static const _downloadedKey = 'xianyu_downloaded_theme_ids_v1';

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    final packages = <ThemePackage>[];
    for (final raw in prefs.getStringList(_packsKey) ?? const <String>[]) {
      final pkg = ThemePackage.parse(raw);
      if (pkg != null) packages.add(pkg);
    }
    final saved = prefs.getString(_activeKey);
    // 下载标记按 activeId 同款做法净化：包已删则不留残影。
    final known = packages.map((pkg) => pkg.id).toSet();
    final downloaded = (prefs.getStringList(_downloadedKey) ?? const <String>[])
        .where(known.contains)
        .toSet();
    state = ThemeLibraryState(
      packages: packages,
      activeId: packages.any((pkg) => pkg.id == saved) ? saved : null,
      downloadedIds: downloaded,
    );
  }

  /// 导入主题包。同一包（id 相同）重复导入为覆盖，不堆副本。
  /// [fromSquare] 为 true 表示来自广场下载（记入下载集合）；文件导入不传，
  /// 且不抹除既有标记——只增不减。
  /// 解析失败（格式非法 / platform 非 mobile / version 非 2）返回 null。
  Future<ThemePackage?> importJson(String text, {bool fromSquare = false}) async {
    final pkg = ThemePackage.parse(text);
    if (pkg == null) return null;
    state = ThemeLibraryState(
      packages: [...state.packages.where((item) => item.id != pkg.id), pkg],
      activeId: state.activeId,
      downloadedIds: fromSquare
          ? <String>{...state.downloadedIds, pkg.id}
          : state.downloadedIds,
    );
    await _persist();
    return pkg;
  }

  Future<void> remove(String id) async {
    state = ThemeLibraryState(
      packages: state.packages.where((pkg) => pkg.id != id).toList(),
      activeId: state.activeId == id ? null : state.activeId,
      downloadedIds: <String>{...state.downloadedIds}..remove(id),
    );
    await _persist();
  }

  /// 应用主题：强调色 / 深浅模式写回既有设置（立即生效，无需重启），
  /// 同时激活本包的槽位映射。壁纸推荐（`wallpaperRef`）不在此处应用，
  /// 由调用方按 `active.wallpaperId` 另行确认。
  Future<void> activate(String id) async {
    ThemePackage? pkg;
    for (final item in state.packages) {
      if (item.id == id) pkg = item;
    }
    if (pkg == null) return;

    // 先确保设置载入完成，否则写入可能被随后的初始载入覆盖。
    await _ref.read(settingsProvider.future);
    final settings = _ref.read(settingsProvider.notifier);
    if (pkg.accentColor != null) {
      await settings.setAccentColor(pkg.accentColor!);
    }
    final mode = _themeModeOf(pkg.themeMode);
    if (mode != null) await settings.setThemeMode(mode);

    state = ThemeLibraryState(
      packages: state.packages,
      activeId: id,
      downloadedIds: state.downloadedIds,
    );
    await _persist();
  }

  /// 取消激活：只解除槽位映射。已写入的强调色/深浅模式保持不动——
  /// 那是用户设置，取消主题不该把它改回去。
  Future<void> deactivate() async {
    state = ThemeLibraryState(
      packages: state.packages,
      downloadedIds: state.downloadedIds,
    );
    await _persist();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _packsKey,
      state.packages.map((pkg) => pkg.raw).toList(),
    );
    await prefs.setStringList(_downloadedKey, state.downloadedIds.toList());
    final activeId = state.activeId;
    if (activeId == null) {
      await prefs.remove(_activeKey);
    } else {
      await prefs.setString(_activeKey, activeId);
    }
  }

  ThemeModePreference? _themeModeOf(String? mode) => switch (mode) {
        'dark' => ThemeModePreference.dark,
        'light' => ThemeModePreference.light,
        'system' => ThemeModePreference.system,
        _ => null,
      };
}

final themeLibraryProvider =
    StateNotifierProvider<ThemeLibraryNotifier, ThemeLibraryState>(
  (ref) => ThemeLibraryNotifier(ref),
);
