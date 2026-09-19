import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../i18n/i18n.dart';
import '../plugin/plugin_provider.dart';
import 'glass_settings.dart';

class PageSearchBarBottom extends StatelessWidget implements PreferredSizeWidget {
  const PageSearchBarBottom({
    super.key,
    required this.onTap,
    this.onRecognize,
  });

  final VoidCallback onTap;

  final VoidCallback? onRecognize;

  @override
  Size get preferredSize => const Size.fromHeight(58);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 2, 18, 12),
      child: PageSearchBar(onTap: onTap, onRecognize: onRecognize),
    );
  }
}

class PageSearchBar extends ConsumerWidget {
  const PageSearchBar({super.key, required this.onTap, this.onRecognize});

  final VoidCallback onTap;

  final VoidCallback? onRecognize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: searchBoxFill(context, ref),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          height: 44,
          padding: const EdgeInsets.fromLTRB(18, 0, 6, 0),
          child: Row(
            children: [
              Icon(Icons.search, size: 18, color: scheme.onSurfaceVariant),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  tr('搜索歌曲、歌手、专辑'),
                  style: TextStyle(
                    fontSize: 14,
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                  ),
                ),
              ),
              if (onRecognize != null &&
                  ref.watch(pluginManagerProvider
                      .select((s) => s.sources.any((p) => p.enabled)))) ...[
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: onRecognize,
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 7, vertical: 5),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEC4141).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Icon(Icons.mic_none,
                        size: 17, color: Color(0xFFEC4141)),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
