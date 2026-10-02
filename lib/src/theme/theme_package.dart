import 'dart:convert';

/// 主题包 v2 的组件色块：`{ "c": "#RRGGBB", "o": 0~1 }`。
class ThemeSurface {
  const ThemeSurface({required this.color, required this.opacity});

  /// 0xFFRRGGBB，由 `#RRGGBB` 补不透明 alpha 得到。
  final int color;

  /// 0~1，缺省 0.5；`o <= 0` 视为关闭，解析时已剔除。
  final double opacity;
}

/// 主题包 v3 的页面壁纸：`{ "ref": "资产引用", "blur": 20, ... }`。
/// 参数与客户端 CustomBackground 同语义（0~100 整数：scale=100 即原大、
/// 位移为相对页面宽高百分比、blur 渲染 ×0.6、maskAlpha 黑遮罩不透明度）。
/// ref 为 data URL（文件导入原样保留，由导入层落盘改写）、http(s) URL
/// （广场下发，由导入层下载落盘）或本地路径（已归一化的持久化形态）。
class PageWallpaper {
  const PageWallpaper({
    required this.ref,
    this.blur,
    this.opacity,
    this.maskAlpha,
    this.scale,
    this.translateX,
    this.translateY,
    this.landscapeScale,
    this.landscapeTranslateX,
    this.landscapeTranslateY,
  });

  final String ref;

  final int? blur;
  final int? opacity;
  final int? maskAlpha;
  final int? scale;
  final int? translateX;
  final int? translateY;
  final int? landscapeScale;
  final int? landscapeTranslateX;
  final int? landscapeTranslateY;
}

/// 主题包 v2/v3。未知字段一律忽略；`platform != mobile` 不收。
///
/// v3 在 v2 基础上新增 `payload.wallpapers`（每页独立壁纸 + 调整参数）。
/// 契约见《主题中心-移动端客户端对接说明》§2。解析失败返回 null，不抛异常。
class ThemePackage {
  const ThemePackage({
    required this.id,
    required this.name,
    required this.author,
    required this.preview,
    required this.accentColor,
    required this.themeMode,
    required this.wallpaperId,
    required this.quickEntryShape,
    required this.icons,
    required this.stickers,
    required this.surfaces,
    required this.wallpapers,
    required this.raw,
  });

  /// 包身份。schema 没有 id 字段，用 name|author|preview|version 派生稳定值，
  /// 保证重复导入同一个包是覆盖而不是堆积副本。
  final String id;

  final String name;
  final String author;
  final String preview;

  /// 0xFFRRGGBB；缺省或格式非法为 null（表示不改动既有强调色）。
  final int? accentColor;

  /// `dark` / `light` / `system`；未知取值或缺失为 null。
  final String? themeMode;

  /// `wallpaperRef.id`，可选推荐壁纸。
  final int? wallpaperId;

  /// `circle` / `squircle` / `pill`。本仓库当前没有该设置项，先原样存下。
  final String? quickEntryShape;

  /// 槽位 id → 资源 URL。
  final Map<String, String> icons;
  final Map<String, String> stickers;

  /// 槽位 id → 组件色块。
  final Map<String, ThemeSurface> surfaces;

  /// 页面 id → 页面壁纸（v3；v2 包为空）。
  final Map<String, PageWallpaper> wallpapers;

  /// 原始 JSON 文本，原样存盘与二次导出用。
  final String raw;

  static ThemePackage? parse(String text) {
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;

    if (decoded['platform'] != 'mobile') return null;
    final version = decoded['version'];
    if (version != 2 && version != 3) return null;

    final payload = decoded['payload'];
    if (payload is! Map) return null;

    final name = _str(decoded['name']) ?? '';
    final author = _str(decoded['author']) ?? '';
    final preview = _str(decoded['preview']) ?? '';

    return ThemePackage(
      id: _deriveId(name, author, preview, version),
      name: name.isEmpty ? '未命名主题' : name,
      author: author,
      preview: preview,
      accentColor: parseHexColor(payload['accentColor']),
      themeMode: _themeMode(payload['themeMode']),
      wallpaperId: _wallpaperId(payload['wallpaperRef']),
      quickEntryShape: _str(payload['quickEntryShape']),
      icons: _slotUrls(payload['icons']),
      stickers: _slotUrls(payload['stickers']),
      surfaces: _surfaces(payload['surfaces']),
      wallpapers: _wallpapers(payload['wallpapers']),
      raw: text,
    );
  }

  /// 本包是否携带任何可生效的槽位（用于"空包"提示）。
  bool get hasSlots =>
      icons.isNotEmpty ||
      stickers.isNotEmpty ||
      surfaces.isNotEmpty ||
      wallpapers.isNotEmpty;

  /// `#RRGGBB` 或 `#AARRGGBB` → 0xAARRGGBB。非法返回 null。
  static int? parseHexColor(Object? value) {
    if (value is! String) return null;
    final hex = value.trim().replaceFirst('#', '');
    if (hex.length != 6 && hex.length != 8) return null;
    final parsed = int.tryParse(hex, radix: 16);
    if (parsed == null) return null;
    return hex.length == 6 ? 0xFF000000 | parsed : parsed;
  }

  static String? _str(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static String? _themeMode(Object? value) {
    final mode = _str(value)?.toLowerCase();
    return switch (mode) {
      'dark' || 'light' || 'system' => mode,
      _ => null,
    };
  }

  static int? _wallpaperId(Object? value) {
    if (value is! Map) return null;
    final id = value['id'];
    if (id is int) return id;
    if (id is String) return int.tryParse(id.trim());
    return null;
  }

  static Map<String, String> _slotUrls(Object? value) {
    if (value is! Map) return const {};
    final result = <String, String>{};
    value.forEach((key, url) {
      if (key is! String || key.trim().isEmpty) return;
      final text = _str(url);
      if (text != null) result[key.trim()] = text;
    });
    return result;
  }

  static Map<String, ThemeSurface> _surfaces(Object? value) {
    if (value is! Map) return const {};
    final result = <String, ThemeSurface>{};
    value.forEach((key, raw) {
      if (key is! String || key.trim().isEmpty || raw is! Map) return;
      final color = parseHexColor(raw['c']);
      if (color == null) return;
      // o 缺省 0.5；o <= 0 视为关闭，直接不收录。
      final opacity = raw['o'] is num ? (raw['o'] as num).toDouble() : 0.5;
      if (opacity <= 0) return;
      result[key.trim()] = ThemeSurface(
        color: color,
        opacity: opacity > 1 ? 1 : opacity,
      );
    });
    return result;
  }

  static Map<String, PageWallpaper> _wallpapers(Object? value) {
    if (value is! Map) return const {};
    final result = <String, PageWallpaper>{};
    value.forEach((key, raw) {
      if (key is! String || key.trim().isEmpty || raw is! Map) return;
      final ref = _str(raw['ref']);
      if (ref == null) return;
      result[key.trim()] = PageWallpaper(
        ref: ref,
        blur: _pct(raw['blur'], 0, 100),
        opacity: _pct(raw['opacity'], 0, 100),
        maskAlpha: _pct(raw['maskAlpha'], 0, 100),
        scale: _pct(raw['scale'], 80, 240),
        translateX: _pct(raw['translateX'], -100, 100),
        translateY: _pct(raw['translateY'], -100, 100),
        landscapeScale: _pct(raw['landscapeScale'], 80, 240),
        landscapeTranslateX: _pct(raw['landscapeTranslateX'], -100, 100),
        landscapeTranslateY: _pct(raw['landscapeTranslateY'], -100, 100),
      );
    });
    return result;
  }

  /// 整数参数钳制到 [min, max]；非法或缺省返回 null（渲染层取默认值）。
  static int? _pct(Object? value, int min, int max) {
    if (value is! num) return null;
    return value.round().clamp(min, max);
  }

  /// FNV-1a 64 位。用它而不是 Object.hash：后者对字符串带进程随机种子，
  /// 跨次启动不稳定，不能拿来当持久化 id。
  static String _deriveId(String name, String author, String preview, Object? version) {
    const offset = 0xcbf29ce484222325;
    const prime = 0x100000001b3;
    var hash = offset;
    for (final unit in '$name|$author|$preview|$version'.codeUnits) {
      hash ^= unit;
      hash = (hash * prime) & 0xFFFFFFFFFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }
}
