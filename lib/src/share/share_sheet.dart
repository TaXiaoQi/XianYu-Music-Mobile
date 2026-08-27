// 歌曲分享弹层：分享到 QQ 好友 / QQ 空间（网页卡片）与复制分享链接。
//
// 分享以网页卡片落地页深链进行：接收方打开链接拉起重启并播放歌曲。
// 打开菜单不阻塞，点击对应目标时才现场生成分享链接与封面缩略图。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:tencent_kit/tencent_kit.dart';

import '../player/player_provider.dart';
import '../auth/auth_provider.dart';
import '../widgets/app_toast.dart';
import '../widgets/sheet_dialog.dart';
import 'qq_share_service.dart';
import 'share_service.dart';
import '../i18n/i18n.dart';

/// 弹出歌曲分享菜单：QQ 好友 / QQ 空间 / 复制链接。
Future<void> showSongShareSheet(
  BuildContext context, {
  required WidgetRef ref,
  required QueueItem song,
}) async {
  // 提前捕获 Overlay，避免 await 后跨 async 间隙使用 BuildContext。
  final overlay = Overlay.of(context, rootOverlay: true);

  await showSheetDialog<void>(
    context,
    (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
            child:   Text(
              tr('分享'),
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
          ),
          const Divider(height: 1, thickness: 0.5),
          const SizedBox(height: 6),
          ListTile(
            leading: _qqBadge('assets/icon/share_qq.png', fit: BoxFit.contain),
            title:   Text(tr('分享到 QQ 好友')),
            onTap: () {
              Navigator.pop(ctx);
              _shareViaQQ(overlay, ref, song, scene: TencentScene.kScene_QQ);
            },
          ),
          ListTile(
            leading: _qqBadge('assets/icon/share_qzone.jpg'),
            title:   Text(tr('分享到 QQ 空间')),
            subtitle:   Text(tr('QQ 空间支持网页分享，不支持音乐卡片')),
            onTap: () {
              Navigator.pop(ctx);
              _shareViaQQ(overlay, ref, song, scene: TencentScene.kScene_QZone);
            },
          ),
          ListTile(
            // 与桌面端底栏分享控件（lucide Share2）同款图形：三节点分享网络图标
            leading: _customBadge(
                context, _Share2Painter(Theme.of(context).colorScheme.primary)),
            title:   Text(tr('分享到更多应用')),
            subtitle:   Text(tr('调用手机系统原生分享，可发到微信/钉钉/短信等任意平台')),
            onTap: () async {
              Navigator.pop(ctx);
              await _shareToOtherApps(overlay, ref, song);
            },
          ),
          ListTile(
            // 与桌面端复制链接控件同款图形：链路图标（lucide Link）
            leading: _customBadge(
                context, _LinkPainter(Theme.of(context).colorScheme.primary)),
            title:   Text(tr('复制分享链接')),
            onTap: () async {
              Navigator.pop(ctx);
              await _copyLink(overlay, ref, song);
            },
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

/// QQ/QQ空间品牌徽章图标：白边圆形裁切，明暗弹窗下都清晰。
/// [fit] 控制图标填充方式：透明去底的品牌 logo（如 QQ 企鹅）用 contain 保留整体，
/// 满幅方形图标（如 QQ 空间）用默认 cover 裁满圆圈。
Widget _qqBadge(String asset, {BoxFit fit = BoxFit.cover}) => Container(
      width: 34,
      height: 34,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white,
      ),
      clipBehavior: Clip.antiAlias,
      child: Image.asset(asset, width: 34, height: 34, fit: fit),
    );

/// 自定义矢量图标徽章（与 QQ 徽章同尺寸同圆形裁切，背景随主题而非固定白底）。
/// 用于「分享到更多应用」「分享到更多设备」「复制分享链接」等自绘入口，
/// 替代 Material 默认图标的白色占位效果。
Widget _customBadge(BuildContext context, CustomPainter painter) {
  final scheme = Theme.of(context).colorScheme;
  return Container(
    width: 34,
    height: 34,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: scheme.surfaceContainerHighest,
    ),
    alignment: Alignment.center,
    child: SizedBox(width: 22, height: 22, child: CustomPaint(painter: painter)),
  );
}

/// lucide Share2：分享网络图标（三个节点两两相连），桌面端底栏分享控件同款。
class _Share2Painter extends CustomPainter {
  _Share2Painter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final u = size.shortestSide / 24;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = u * 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final r = 3 * u;
    canvas.drawCircle(Offset(18 * u, 5 * u), r, stroke);
    canvas.drawCircle(Offset(6 * u, 12 * u), r, stroke);
    canvas.drawCircle(Offset(18 * u, 19 * u), r, stroke);
    canvas.drawLine(
        Offset(8.59 * u, 13.51 * u), Offset(15.42 * u, 17.49 * u), stroke);
    canvas.drawLine(
        Offset(15.41 * u, 6.51 * u), Offset(8.59 * u, 10.49 * u), stroke);
  }

  @override
  bool shouldRepaint(covariant _Share2Painter old) => old.color != color;
}

/// lucide Link：链路图标（两段互扣的链接环），复制分享链接专用。
class _LinkPainter extends CustomPainter {
  _LinkPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final u = size.shortestSide / 24;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = u * 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final p1 = Path()
      ..moveTo(10 * u, 13 * u)
      ..arcToPoint(Offset(17.54 * u, 13.54 * u),
          radius: Radius.circular(5 * u), largeArc: false, clockwise: false)
      ..lineTo(20.54 * u, 10.54 * u)
      ..arcToPoint(Offset(13.47 * u, 3.47 * u),
          radius: Radius.circular(5 * u), largeArc: false, clockwise: false)
      ..lineTo(11.75 * u, 5.18 * u);

    final p2 = Path()
      ..moveTo(14 * u, 11 * u)
      ..arcToPoint(Offset(6.46 * u, 10.46 * u),
          radius: Radius.circular(5 * u), largeArc: false, clockwise: false)
      ..lineTo(3.46 * u, 13.46 * u)
      ..arcToPoint(Offset(10.53 * u, 20.53 * u),
          radius: Radius.circular(5 * u), largeArc: false, clockwise: false)
      ..lineTo(12.24 * u, 18.82 * u);

    canvas.drawPath(p1, stroke);
    canvas.drawPath(p2, stroke);
  }

  @override
  bool shouldRepaint(covariant _LinkPainter old) => old.color != color;
}

/// 获取（必要时生成）分享链接；失败返回空串。
Future<String> _ensureUrl(WidgetRef ref, QueueItem song) async {
  final share = ref.read(shareServiceProvider);
  final cached = share.cached(song);
  if (cached != null && cached.isNotEmpty) return cached;
  try {
    return await share.create(song);
  } catch (_) {
    return '';
  }
}

/// 分享文案：第一行「用户名邀请你去弦予音乐听《歌名》」，第二行分享链接。
/// 未登录时第一行省略用户名。
String _buildShareText(WidgetRef ref, QueueItem song, String url) {
  final user = ref.read(authProvider).user;
  final nickname = (user?.nickname ?? '').trim();
  final name = nickname.isNotEmpty ? nickname : (user?.username ?? '').trim();
  final firstLine = name.isEmpty
      ? tr('邀请你去弦予音乐听《{song}》', {'song': song.title})
      : tr('{user}邀请你去弦予音乐听《{song}》', {'user': name, 'song': song.title});
  return '$firstLine\n$url';
}

/// 生成并复制分享链接。
Future<void> _copyLink(OverlayState overlay, WidgetRef ref, QueueItem song) async {
  final url = await _ensureUrl(ref, song);
  if (url.isEmpty) {
    showXianYuToastByOverlay(overlay, tr('生成分享链接失败'));
    return;
  }
  await Clipboard.setData(ClipboardData(text: _buildShareText(ref, song, url)));
  showXianYuToastByOverlay(overlay, tr('分享文案已复制'));
}

/// 分享网页卡片到指定 QQ 场景（好友 / 空间）。
Future<void> _shareViaQQ(
  OverlayState overlay,
  WidgetRef ref,
  QueueItem song, {
  required int scene,
}) async {
  final url = await _ensureUrl(ref, song);
  if (url.isEmpty) {
    showXianYuToastByOverlay(overlay, tr('生成分享链接失败'));
    return;
  }

  final qq = ref.read(qqShareServiceProvider);
  if (!await qq.isQQInstalled()) {
    await Clipboard.setData(ClipboardData(text: _buildShareText(ref, song, url)));
    showXianYuToastByOverlay(overlay, tr('未安装 QQ，分享链接已复制'));
    return;
  }

  var cover = '';
  try {
    cover = await ref.read(shareServiceProvider).resolveCover(song);
  } catch (_) {}

  final artist = song.artist.isEmpty ? tr('未知歌手') : song.artist;
  final result = await qq.share(
    scene: scene,
    title: song.title,
    summary: tr('{artist} · 来自弦予音乐', {'artist': artist}),
    targetUrl: url,
    coverUrl: cover,
  );

  switch (result) {
    case QqShareResult.success:
      showXianYuToastByOverlay(overlay, tr('分享成功'));
    case QqShareResult.canceled:
      showXianYuToastByOverlay(overlay, tr('已取消分享'));
    default:
      await Clipboard.setData(ClipboardData(text: _buildShareText(ref, song, url)));
      showXianYuToastByOverlay(overlay, tr('分享失败，链接已复制'));
  }
}

/// 调用 Android 系统分享面板（ACTION_SEND）：封面图 + 「歌名 · 歌手 + 落地页链接」。
/// 覆盖微信/钉钉/短信等任意平台；封面缺失或下载失败时退化为纯文本。
Future<void> _shareToOtherApps(
  OverlayState overlay,
  WidgetRef ref,
  QueueItem song,
) async {
  final url = await _ensureUrl(ref, song);
  if (url.isEmpty) {
    showXianYuToastByOverlay(overlay, tr('生成分享链接失败'));
    return;
  }

  final artist = song.artist.isEmpty ? tr('未知歌手') : song.artist;

  final cover = await _localCoverFile(song);
  try {
    await SharePlus.instance.share(ShareParams(
      files: cover == null ? null : [XFile(cover.path)],
      text: tr('{title} · {artist}\n来自弦予音乐\n{url}', {'title': song.title, 'artist': artist, 'url': url}),
    ));
  } catch (_) {
    await Clipboard.setData(ClipboardData(text: _buildShareText(ref, song, url)));
    showXianYuToastByOverlay(overlay, tr('分享失败，链接已复制'));
  }
}

/// 取封面本地文件：优先本地封面文件（coverPath），其次在线封面下载到临时目录。
/// 拿不到返回 null（此时仅分享文本链接）。
Future<File?> _localCoverFile(QueueItem song) async {
  final path = song.coverPath;
  if (path != null && path.isNotEmpty && !path.contains('content://')) {
    try {
      final f = File(_stripFileScheme(path));
      if (await f.exists()) return f;
    } catch (_) {}
  }

  final online = _decodeMap(song.onlineSongJson);
  final candidates = <String?>[
    song.coverUrl,
    online?['picture']?.toString(),
  ];
  for (final c in candidates) {
    if (c != null && c.isNotEmpty && _isRemoteHttp(c)) {
      final f = await _downloadToTemp(c);
      if (f != null) return f;
    }
  }
  return null;
}

Future<File?> _downloadToTemp(String url) async {
  try {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8);
    final req = await client.getUrl(Uri.parse(url));
    final res = await req.close();
    if (res.statusCode != 200) {
      client.close();
      return null;
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in res) {
      builder.add(chunk);
    }
    client.close();
    final bytes = builder.takeBytes();
    if (bytes.isEmpty) return null;
    final dir = await getTemporaryDirectory();
    final file = File(
        '${dir.path}/xiuxwe_share_${DateTime.now().millisecondsSinceEpoch}.jpg');
    await file.writeAsBytes(bytes);
    return file;
  } catch (_) {
    return null;
  }
}

String _stripFileScheme(String path) {
  if (path.startsWith('file://')) return path.substring('file://'.length);
  return path;
}

Map<String, dynamic>? _decodeMap(String? json) {
  if (json == null || json.isEmpty) return null;
  try {
    final v = jsonDecode(json);
    return v is Map ? v.cast<String, dynamic>() : null;
  } catch (_) {
    return null;
  }
}

bool _isRemoteHttp(String s) {
  if (!(s.startsWith('http://') || s.startsWith('https://'))) return false;
  final lower = s.toLowerCase();
  return !(lower.contains('asset.localhost') ||
      lower.contains('localhost') ||
      lower.contains('127.0.0.1'));
}