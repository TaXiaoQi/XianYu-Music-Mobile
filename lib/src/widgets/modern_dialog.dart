import 'package:flutter/material.dart';
import 'predictive_dialog_route.dart';
import 'sheet_dialog.dart';
import '../i18n/i18n.dart';

/// 现代优雅弹窗组件与全局调用助手
/// 包含：单选/多选居中面板 (ChoiceSheet)、确认提示框 (AlertDialog)、输入框 (InputDialog)

class ModernChoiceOption<T> {
  final String label;
  final String? subtitle;
  final T value;
  final IconData? icon;

  const ModernChoiceOption({
    required this.label,
    required this.value,
    this.subtitle,
    this.icon,
  });
}

/// 1. 全局单选/多选现代居中弹窗（对齐「安装插件」弹窗风格，不再从底部滑出）
Future<T?> showModernChoiceSheet<T>({
  required BuildContext context,
  required String title,
  String? subtitle,
  required List<ModernChoiceOption<T>> options,
  T? currentValue,
}) {
  return showSheetDialog<T>(
    context,
    (ctx) => ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(ctx).size.height * 0.7,
      ),
      child: SingleChildScrollView(
        child: _ModernChoiceList<T>(
          title: title,
          subtitle: subtitle,
          options: options,
          currentValue: currentValue,
          onSelected: (val) => Navigator.of(ctx).pop(val),
        ),
      ),
    ),
  );
}

/// 2. 全局现代通用确认/提示弹窗
Future<bool> showModernConfirmDialog({
  required BuildContext context,
  required String title,
  required String message,
  String confirmText = '确定',
  String cancelText = '取消',
  bool isDanger = false,
  IconData? icon,
}) async {
  final res = await showPredictiveDialog<bool>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) {
      final scheme = Theme.of(ctx).colorScheme;
      final accentColor = isDanger ? scheme.error : scheme.primary;
      return ModernDialogCard(
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (icon != null) ...[
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: accentColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(icon, color: accentColor, size: 22),
                    ),
                    const SizedBox(width: 14),
                  ],
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                message,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.45,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 22),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(false),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 11,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: Text(tr(cancelText)),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => Navigator.of(ctx).pop(true),
                    style: FilledButton.styleFrom(
                      backgroundColor: accentColor,
                      foregroundColor: isDanger ? scheme.onError : scheme.onPrimary,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 11,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: Text(tr(confirmText)),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
  return res ?? false;
}

/// 3. 全局现代输入框弹窗
Future<String?> showModernInputDialog({
  required BuildContext context,
  required String title,
  String? subtitle,
  String initialValue = '',
  String? hintText,
  String confirmText = '确定',
  String cancelText = '取消',
  TextInputType keyboardType = TextInputType.text,
}) {
  final controller = TextEditingController(text: initialValue);
  return showPredictiveDialog<String>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) {
      final scheme = Theme.of(ctx).colorScheme;
      return ModernDialogCard(
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.2,
                ),
              ),
              if (subtitle != null && subtitle.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                autofocus: true,
                keyboardType: keyboardType,
                decoration: InputDecoration(
                  hintText: hintText,
                  filled: true,
                  fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(color: scheme.primary, width: 1.5),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 11,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: Text(tr(cancelText)),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 22,
                        vertical: 11,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: Text(tr(confirmText)),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
}

// ==================== 内部私有现代化组件 ====================

/// 现代居中对话框圆角外框（适配深色/浅色、毛玻璃防护与阴影）
class ModernDialogCard extends StatelessWidget {
  const ModernDialogCard({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
        constraints: const BoxConstraints(maxWidth: 380),
        decoration: BoxDecoration(
          color: isDark ? scheme.surfaceContainerHigh : scheme.surface,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: scheme.outlineVariant.withValues(alpha: 0.35),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.45 : 0.15),
              blurRadius: 30,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Material(
          color: Colors.transparent,
          child: child,
        ),
      ),
    );
  }
}

/// 现代单选列表内容视图（软色胶囊高亮、对勾指示、自适应层次）
class _ModernChoiceList<T> extends StatelessWidget {
  const _ModernChoiceList({
    required this.title,
    this.subtitle,
    required this.options,
    this.currentValue,
    required this.onSelected,
  });

  final String title;
  final String? subtitle;
  final List<ModernChoiceOption<T>> options;
  final T? currentValue;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.2,
                ),
              ),
            ),
            if (subtitle != null && subtitle!.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  subtitle!,
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 12),
          ],
          for (final opt in options) ...[
            ModernOptionTile<T>(
              option: opt,
              isSelected: currentValue == opt.value,
              onTap: () => onSelected(opt.value),
            ),
            const SizedBox(height: 6),
          ],
        ],
      ),
    );
  }
}

/// 现代单选列表项：软色胶囊高亮 + 对勾指示（设置页选择弹窗的通用样式）。
class ModernOptionTile<T> extends StatelessWidget {
  const ModernOptionTile({
    super.key,
    required this.option,
    required this.isSelected,
    required this.onTap,
  });

  final ModernChoiceOption<T> option;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final primary = scheme.primary;

    return Material(
      color: isSelected
          ? primary.withValues(alpha: 0.12)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              if (option.icon != null) ...[
                Icon(
                  option.icon,
                  size: 20,
                  color: isSelected ? primary : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      option.label,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                        color: isSelected ? primary : scheme.onSurface,
                      ),
                    ),
                    if (option.subtitle != null && option.subtitle!.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        option.subtitle!,
                        style: TextStyle(
                          fontSize: 12,
                          color: isSelected
                              ? primary.withValues(alpha: 0.8)
                              : scheme.onSurfaceVariant.withValues(alpha: 0.75),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (isSelected)
                Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    color: primary,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.check,
                    size: 14,
                    color: scheme.onPrimary,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
