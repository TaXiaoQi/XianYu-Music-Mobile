import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/application_logger.dart';
import '../core/app_http.dart';
import '../core/settings.dart';
import 'theme_package.dart';

/// 主题包壁纸资产获取失败（解码/下载）。toString 直接返回原因本身，
/// 供页面 toast 原样展示（不带 Exception: 前缀）。
class ThemeAssetException implements Exception {
  const ThemeAssetException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 壁纸资产落盘目录：{docs}/themes/{pkgId}/，随包删除一并清理。
Future<Directory> _themeAssetDir(String pkgId) async {
  final docs = await getApplicationDocumentsDirectory();
  return Directory(p.join(docs.path, 'themes', pkgId)).create(recursive: true);
}

Uint8List? _decodeDataUrl(String dataUrl) {
  final idx = dataUrl.indexOf(',');
  if (idx < 0) return null;
  try {
    return base64Decode(dataUrl.substring(idx + 1));
  } on FormatException {
    return null;
  }
}

/// 魔数嗅探图片扩展名；识别不出按 jpg 落盘（服务端壁纸统一压成 JPEG）。
String _sniffImageExt(Uint8List bytes) {
  if (bytes.length >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8) return 'jpg';
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    return 'png';
  }
  if (bytes.length >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return 'webp';
  }
  return 'jpg';
}

Future<Uint8List?> _downloadBytes(String url) async {
  try {
    final resp = await appGet(Uri.parse(url));
    if (resp.statusCode != HttpStatus.ok) return null;
    final builder = BytesBuilder(copy: false);
    await for (final chunk in resp) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  } catch (_) {
    return null;
  }
}

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
  /// v3 包的页面壁纸资产（data URL / 广场 URL）导入时归一化为本地文件并改写
  /// ref——避免把巨型 base64 存进 SharedPreferences；任一资产获取失败抛
  /// [ThemeAssetException]，由调用方按导入失败提示。
  /// 解析失败（格式非法 / platform 非 mobile / version 非 2|3）返回 null。
  Future<ThemePackage?> importJson(String text, {bool fromSquare = false}) async {
    final parsed = ThemePackage.parse(text);
    if (parsed == null) return null;
    var pkg = await _materializeWallpapers(parsed);
    // 图标/贴纸同样归一化：编辑器导出的本地包值是巨型 data URL，不落盘
    // 会原样进 SharedPreferences，且 CachedNetworkImage 无法渲染 data URL
    // （表现为主题图标永远回落内置图标）。
    pkg = await _materializeIconStickers(pkg);
    AppLog.debug('theme',
        '主题包导入: id=${pkg.id} name=${pkg.name} icons=${pkg.icons.keys.toList()} '
        'stickers=${pkg.stickers.keys.toList()} surfaces=${pkg.surfaces.keys.toList()} '
        'wallpapers=${pkg.wallpapers.keys.toList()}');
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

  /// 把包内 wallpapers 的 ref 归一化：data URL 解码落盘、http(s) 下载落盘，
  /// 已是本地路径的原样保留。无 v3 壁纸的包原样返回。
  Future<ThemePackage> _materializeWallpapers(ThemePackage pkg) async {
    if (pkg.wallpapers.isEmpty) return pkg;
    final Object? decoded;
    try {
      decoded = jsonDecode(pkg.raw);
    } on FormatException {
      return pkg;
    }
    if (decoded is! Map || decoded['payload'] is! Map) return pkg;
    final payload = decoded['payload'] as Map;
    final wallpapers = payload['wallpapers'];
    if (wallpapers is! Map || wallpapers.isEmpty) return pkg;

    final dir = await _themeAssetDir(pkg.id);
    var changed = false;
    for (final entry in wallpapers.entries) {
      final page = entry.key.toString();
      final wp = entry.value;
      if (wp is! Map) continue;
      final ref = wp['ref'];
      if (ref is! String || ref.isEmpty) continue;
      final String localPath;
      if (ref.startsWith('data:')) {
        final bytes = _decodeDataUrl(ref);
        if (bytes == null) throw const ThemeAssetException('页面壁纸数据无效');
        localPath = p.join(dir.path, 'wall_$page.${_sniffImageExt(bytes)}');
        await File(localPath).writeAsBytes(bytes, flush: true);
      } else if (ref.startsWith('http://') || ref.startsWith('https://')) {
        final bytes = await _downloadBytes(ref);
        if (bytes == null) throw ThemeAssetException('页面壁纸下载失败（$page）');
        localPath = p.join(dir.path, 'wall_$page.${_sniffImageExt(bytes)}');
        await File(localPath).writeAsBytes(bytes, flush: true);
      } else {
        continue;
      }
      wp['ref'] = localPath;
      changed = true;
    }
    if (!changed) return pkg;
    return ThemePackage.parse(jsonEncode(decoded)) ?? pkg;
  }

  /// 把包内 icons/stickers 的值归一化：data URL 解码落盘、http(s) 下载落盘，
  /// 已是本地路径的原样保留。与 wallpapers 的 {ref} 对象形态不同，图标/贴纸
  /// 的值直接是 URL 字符串。未变更原样返回。
  Future<ThemePackage> _materializeIconStickers(ThemePackage pkg) async {
    if (pkg.icons.isEmpty && pkg.stickers.isEmpty) return pkg;
    final Object? decoded;
    try {
      decoded = jsonDecode(pkg.raw);
    } on FormatException {
      return pkg;
    }
    if (decoded is! Map || decoded['payload'] is! Map) return pkg;
    final payload = decoded['payload'] as Map;
    final dir = await _themeAssetDir(pkg.id);
    var changed = false;
    for (final (slot, prefix) in const [('icons', 'icon'), ('stickers', 'sticker')]) {
      final map = payload[slot];
      if (map is! Map || map.isEmpty) continue;
      for (final entry in map.entries) {
        final key = entry.key.toString();
        final ref = entry.value;
        if (ref is! String || ref.isEmpty) continue;
        final String localPath;
        if (ref.startsWith('data:')) {
          final bytes = _decodeDataUrl(ref);
          if (bytes == null) {
            throw const ThemeAssetException('主题图标数据无效');
          }
          localPath = p.join(dir.path, '${prefix}_$key.${_sniffImageExt(bytes)}');
          await File(localPath).writeAsBytes(bytes, flush: true);
        } else if (ref.startsWith('http://') || ref.startsWith('https://')) {
          final bytes = await _downloadBytes(ref);
          if (bytes == null) {
            throw ThemeAssetException('主题图标下载失败（$slot.$key）');
          }
          localPath = p.join(dir.path, '${prefix}_$key.${_sniffImageExt(bytes)}');
          await File(localPath).writeAsBytes(bytes, flush: true);
        } else {
          continue;
        }
        map[key] = localPath;
        changed = true;
      }
    }
    if (!changed) return pkg;
    return ThemePackage.parse(jsonEncode(decoded)) ?? pkg;
  }

  Future<void> remove(String id) async {
    state = ThemeLibraryState(
      packages: state.packages.where((pkg) => pkg.id != id).toList(),
      activeId: state.activeId == id ? null : state.activeId,
      downloadedIds: <String>{...state.downloadedIds}..remove(id),
    );
    await _persist();
    // 清理该包落盘的壁纸资产目录；失败不阻断（目录可能已不存在）。
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(docs.path, 'themes', id));
      if (dir.existsSync()) await dir.delete(recursive: true);
    } catch (e) {
      AppLog.debug('theme', '清理主题壁纸资产目录失败: $e');
    }
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
