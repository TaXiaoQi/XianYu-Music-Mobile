import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../i18n/i18n.dart';
import 'remote_theme.dart';

/// 主题列表项：广场与我的上传共用。
///
/// 只依赖 [RemoteTheme] 的字段，不碰页面状态，便于两处复用。
/// 刻意不引入页面级的卡片底色/玻璃基底工具——那些是各页自己的取舍，
/// 放进来会把这里绑死到某一种视觉。
class RemoteThemeTile extends StatelessWidget {
  const RemoteThemeTile({
    super.key,
    required this.theme,
    this.onTap,
    this.trailing,
  });

  final RemoteTheme theme;
  final VoidCallback? onTap;
  final Widget? trailing;

  /// 缩略图优先，缺则退到预览图；两者都空则显示占位图标。
  String get _imageUrl =>
      theme.thumbnailUrl.isNotEmpty ? theme.thumbnailUrl : theme.previewUrl;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: 48,
          height: 48,
          child: _imageUrl.isEmpty
              ? Container(
                  color: scheme.surfaceContainerHighest,
                  child: Icon(
                    Icons.palette_outlined,
                    size: 22,
                    color: scheme.onSurfaceVariant,
                  ),
                )
              : CachedNetworkImage(
                  imageUrl: _imageUrl,
                  fit: BoxFit.cover,
                  placeholder: (_, _) =>
                      Container(color: scheme.surfaceContainerHighest),
                  errorWidget: (_, _, _) => Container(
                    color: scheme.surfaceContainerHighest,
                    child: Icon(
                      Icons.broken_image_outlined,
                      size: 20,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
        ),
      ),
      title: Text(
        theme.name.isEmpty ? tr('未命名主题') : theme.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: _subtitle(scheme),
      trailing: trailing,
    );
  }

  /// 副标题：上传者（有则显示）+ 待审标记。
  ///
  /// 「待审」只在 `status != normal` 时出现；广场接口只会返回已过审条目，
  /// 所以这个标记实际只会在「我的上传」里看到。
  Widget _subtitle(ColorScheme scheme) {
    final parts = <String>[
      if (theme.uploaderNickname.isNotEmpty) theme.uploaderNickname,
      if (!theme.isApproved) tr('待审核'),
    ];
    final text = parts.isEmpty ? theme.description : parts.join(' · ');
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
    );
  }
}
