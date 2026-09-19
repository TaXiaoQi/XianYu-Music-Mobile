import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:tencent_kit/tencent_kit.dart';

import '../online/cover_proxy.dart';
import '../core/db_path.dart';
import '../core/platform_caps.dart';
import '../library/saf_channel.dart';
import '../rust/api.dart';
import '../player/player_provider.dart';
import '../auth/auth_provider.dart';
import '../widgets/app_toast.dart';
import '../widgets/dlna_device_dialog.dart';
import '../widgets/sheet_dialog.dart';
import 'qq_share_service.dart';
import 'share_service.dart';
import 'system_share.dart';
import '../i18n/i18n.dart';

Future<void> showSongShareSheet(
  BuildContext context, {
  required WidgetRef ref,
  required QueueItem song,
}) async {
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
          if (PlatformCaps.supportsQQShare) ...[
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
          ],
          ListTile(
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
            leading: _customBadge(
                context, _LinkPainter(Theme.of(context).colorScheme.primary)),
            title:   Text(tr('复制分享链接')),
            onTap: () async {
              Navigator.pop(ctx);
              await _copyLink(overlay, ref, song);
            },
          ),
          ListTile(
            leading: _customBadge(
                context, _CastPainter(Theme.of(context).colorScheme.primary)),
            title:   Text(tr('投屏到 DLNA 设备')),
            subtitle:   Text(tr('在局域网电视/音箱上播放这首歌')),
            onTap: () {
              Navigator.pop(ctx);
              final current = ref.read(playerProvider).current;
              if (current == null || current.path != song.path) {
                ref.read(playerProvider.notifier).playQueue([song]);
              }
              showDlnaDeviceDialog(context, ref);
            },
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

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

class _CastPainter extends CustomPainter {
  _CastPainter(this.color);
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

    final screen = Path()
      ..moveTo(2 * u, 8 * u)
      ..lineTo(2 * u, 6 * u)
      ..arcToPoint(Offset(4 * u, 4 * u),
          radius: Radius.circular(2 * u), clockwise: true)
      ..lineTo(20 * u, 4 * u)
      ..arcToPoint(Offset(22 * u, 6 * u),
          radius: Radius.circular(2 * u), clockwise: true)
      ..lineTo(22 * u, 18 * u)
      ..arcToPoint(Offset(20 * u, 20 * u),
          radius: Radius.circular(2 * u), clockwise: true)
      ..lineTo(16 * u, 20 * u);
    canvas.drawPath(screen, stroke);

    final wave1 = Path()
      ..moveTo(2 * u, 12 * u)
      ..arcToPoint(Offset(10 * u, 20 * u),
          radius: Radius.circular(9 * u), clockwise: true);
    canvas.drawPath(wave1, stroke);
    final wave2 = Path()
      ..moveTo(2 * u, 16 * u)
      ..arcToPoint(Offset(6 * u, 20 * u),
          radius: Radius.circular(5 * u), clockwise: true);
    canvas.drawPath(wave2, stroke);
    canvas.drawCircle(
        Offset(2 * u, 20 * u),
        u * 0.9,
        Paint()
          ..color = color
          ..style = PaintingStyle.fill);
  }

  @override
  bool shouldRepaint(covariant _CastPainter old) => old.color != color;
}

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

Future<(QueueItem, File?)> _resolveLocalCover(
    WidgetRef ref, QueueItem song) async {
  var updated = song;
  if (!song.isOnline && (song.coverPath == null || song.coverPath!.isEmpty)) {
    try {
      final dbPath = await ref.read(dbPathProvider.future);
      final cacheRoot = await ref.read(coverCacheRootProvider.future);
      var p = await getSongCoverThumbnail(
        dbPath: dbPath,
        cacheRoot: cacheRoot,
        path: song.path,
      );
      if (p.isEmpty && SafChannel.isSafPath(song.path)) {
        final healed =
            await SafChannel.extractCoverToCache(song.path, cacheRoot);
        if (healed.isNotEmpty) {
          p = await getSongCoverThumbnail(
            dbPath: dbPath,
            cacheRoot: cacheRoot,
            path: song.path,
          );
        }
      }
      if (p.isNotEmpty) updated = song.copyWith(coverPath: p);
    } catch (_) {}
  }
  final file = await _localCoverFile(updated);
  return (updated, file);
}

String _buildShareText(WidgetRef ref, QueueItem song, String url) {
  final user = ref.read(authProvider).user;
  final nickname = (user?.nickname ?? '').trim();
  final name = nickname.isNotEmpty ? nickname : (user?.username ?? '').trim();
  final firstLine = name.isEmpty
      ? tr('邀请你去弦予音乐听《{song}》', {'song': song.title})
      : tr('{user}邀请你去弦予音乐听《{song}》', {'user': name, 'song': song.title});
  return '$firstLine\n$url';
}

Future<void> _copyLink(OverlayState overlay, WidgetRef ref, QueueItem song) async {
  final (song2, _) = await _resolveLocalCover(ref, song);
  final url = await _ensureUrl(ref, song2);
  if (url.isEmpty) {
    showXianYuToastByOverlay(overlay, tr('生成分享链接失败'));
    return;
  }
  ref.read(shareServiceProvider).reportShareAction();
  await Clipboard.setData(ClipboardData(text: url));
  showXianYuToastByOverlay(overlay, tr('分享链接已复制'));
}

Future<void> _shareViaQQ(
  OverlayState overlay,
  WidgetRef ref,
  QueueItem song, {
  required int scene,
}) async {
  final (song2, coverFile) = await _resolveLocalCover(ref, song);

  final url = await _ensureUrl(ref, song2);
  if (url.isEmpty) {
    showXianYuToastByOverlay(overlay, tr('生成分享链接失败'));
    return;
  }
  ref.read(shareServiceProvider).reportShareAction();

  final qq = ref.read(qqShareServiceProvider);
  if (!await qq.isQQInstalled()) {
    await Clipboard.setData(ClipboardData(text: _buildShareText(ref, song2, url)));
    showXianYuToastByOverlay(overlay, tr('未安装 QQ，分享链接已复制'));
    return;
  }

  var coverPath = '';
  try {
    if (coverFile != null) {
      coverPath = (await _resizeCoverForShare(coverFile))?.path ?? coverFile.path;
    }
  } catch (_) {}

  final artist = song.artist.isEmpty ? tr('未知歌手') : song.artist;
  final useMusicCard = scene == TencentScene.kScene_QQ;
  final result = await qq.share(
    scene: scene,
    title: song.title,
    summary: artist,
    targetUrl: url,
    coverPath: coverPath,
    musicUrl: useMusicCard ? url : null,
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

Future<void> _shareToOtherApps(
  OverlayState overlay,
  WidgetRef ref,
  QueueItem song,
) async {
  final (song2, cover) = await _resolveLocalCover(ref, song);
  final url = await _ensureUrl(ref, song2);
  if (url.isEmpty) {
    showXianYuToastByOverlay(overlay, tr('生成分享链接失败'));
    return;
  }
  ref.read(shareServiceProvider).reportShareAction();

  final artist = song.artist.isEmpty ? tr('未知歌手') : song.artist;
  final shareText =
      tr('{title} · {artist}\n来自弦予音乐\n{url}', {'title': song.title, 'artist': artist, 'url': url});

  try {
    final sent = await shareViaSystem(text: shareText, filePath: cover?.path);
    if (sent != null) {
      if (!sent) {
        await Clipboard.setData(ClipboardData(text: _buildShareText(ref, song2, url)));
        showXianYuToastByOverlay(overlay, tr('分享失败，链接已复制'));
      }
      return;
    }
    await SharePlus.instance.share(ShareParams(
      files: cover == null ? null : [XFile(cover.path)],
      text: shareText,
    ));
  } catch (_) {
    await Clipboard.setData(ClipboardData(text: _buildShareText(ref, song2, url)));
    showXianYuToastByOverlay(overlay, tr('分享失败，链接已复制'));
  }
}

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
      final f = await _downloadCoverToTemp(c);
      if (f != null) return f;
    }
  }
  return null;
}

Future<File?> _downloadCoverToTemp(String url) async {
  try {
    final bytes = await CoverProxy.fetch(url);
    if (bytes != null && bytes.isNotEmpty) {
      final dir = await getTemporaryDirectory();
      final file = File(
          '${dir.path}/xiuxwe_share_${DateTime.now().millisecondsSinceEpoch}.jpg');
      await file.writeAsBytes(bytes);
      return file;
    }
  } catch (_) {}
  return _downloadToTemp(url);
}

Future<File?> _resizeCoverForShare(File src) async {
  try {
    final decoded = img.decodeImage(await src.readAsBytes());
    if (decoded == null) return null;
    final longer =
        decoded.width > decoded.height ? decoded.width : decoded.height;
    img.Image out = decoded;
    if (longer > 256) {
      final scale = 256 / longer;
      out = img.copyResize(
        decoded,
        width: (decoded.width * scale).round(),
        height: (decoded.height * scale).round(),
      );
    }
    final dir = await getTemporaryDirectory();
    final file = File(
        '${dir.path}/xiuxwe_qq_${DateTime.now().millisecondsSinceEpoch}.jpg');
    await file.writeAsBytes(img.encodeJpg(out, quality: 85));
    return file;
  } catch (_) {
    return null;
  }
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