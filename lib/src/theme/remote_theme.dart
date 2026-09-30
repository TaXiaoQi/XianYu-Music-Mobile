/// 服务端主题条目的客户端模型，对应 `/api/` 的 `list_themes`（广场）与
/// `my_themes`（我的上传）两条 action 返回的数组元素。
///
/// 字段名取自服务端实现 `XianYu-Music-Server/server/src/handlers/theme.rs`
/// 的 `row_to_theme`，逐字对齐，勿凭印象改写。
///
/// 说明：本类只负责单个条目的映射，不涉及响应外层信封——外层结构需读客户端
/// `AccountApi._action` 的实现后另行处理，避免凭猜测解析。
class RemoteTheme {
  const RemoteTheme({
    required this.id,
    required this.name,
    required this.description,
    required this.platform,
    required this.payload,
    required this.previewUrl,
    required this.thumbnailUrl,
    required this.uploaderId,
    required this.uploaderNickname,
    required this.status,
    this.reviewedAt,
    this.reviewedBy = '',
    this.createdAt,
  });

  final int id;
  final String name;
  final String description;
  final String platform;

  /// 服务端存的原样 v2 payload（服务端字段名即 `theme`）。
  ///
  /// 可直接交给 [ThemePackage.parse]——注意它收的是 **JSON 字符串**，
  /// 故调用方需先 `jsonEncode(payload)`。
  final Map<String, dynamic> payload;

  final String previewUrl;
  final String thumbnailUrl;
  final String uploaderId;
  final String uploaderNickname;

  /// `normal` 表示已过审。广场只会返回该状态；我的上传会含待审条目。
  final String status;

  final String? reviewedAt;
  final String reviewedBy;
  final String? createdAt;

  bool get isApproved => status == 'normal';

  /// 单个条目映射；缺关键字段或类型不符时返回 null，交由调用方跳过。
  static RemoteTheme? fromJson(Map<String, dynamic> j) {
    final id = j['id'];
    final payload = j['theme'];
    if (id is! num || payload is! Map) return null;
    return RemoteTheme(
      id: id.toInt(),
      name: _str(j['name']),
      description: _str(j['description']),
      platform: _str(j['platform']),
      payload: Map<String, dynamic>.from(payload),
      previewUrl: _str(j['previewUrl']),
      thumbnailUrl: _str(j['thumbnailUrl']),
      uploaderId: _str(j['uploaderId']),
      uploaderNickname: _str(j['uploaderNickname']),
      status: _str(j['status']),
      reviewedAt: j['reviewedAt'] is String ? j['reviewedAt'] as String : null,
      reviewedBy: _str(j['reviewedBy']),
      createdAt: j['createdAt'] is String ? j['createdAt'] as String : null,
    );
  }

  static String _str(Object? v) => v is String ? v : '';

  /// 把 action 返回的 `data` 映射为模型列表。
  ///
  /// `data` 来自 `AuthNotifier.requestActionList`，形状是 `List<dynamic>`
  /// （不是 Map——两个主题 action 都返回数组）。元素非 Map 或关键字段缺失时
  /// 跳过该条，不抛异常；整体不是数组时返回空列表。
  static List<RemoteTheme> listFrom(Object? data) {
    if (data is! List) return const <RemoteTheme>[];
    final out = <RemoteTheme>[];
    for (final e in data) {
      if (e is! Map) continue;
      final t = RemoteTheme.fromJson(Map<String, dynamic>.from(e));
      if (t != null) out.add(t);
    }
    return out;
  }
}
