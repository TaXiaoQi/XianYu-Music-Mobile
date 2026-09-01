import 'package:xianyu_music_mobile/src/widgets/predictive_dialog_route.dart';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

import '../../src/auth/account_api.dart';
import '../../src/auth/auth_provider.dart';
import '../../src/auth/server_models.dart';
import '../../src/core/app_colors.dart';
import '../../src/core/application_logger.dart';
import '../../src/widgets/app_toast.dart';
import '../../src/widgets/flat_top_bar.dart';
import '../../src/widgets/glass_appbar.dart';
import '../../src/i18n/i18n.dart';

/// 意见反馈页：提交反馈 + 我的反馈列表。
class FeedbackPage extends ConsumerStatefulWidget {
  const FeedbackPage({super.key, this.embedded = false});

  /// 横屏嵌入 mode：隐藏自带标题栏，仅保留 TabBar 以切换「提交/我的」反馈。
  final bool embedded;

  @override
  ConsumerState<FeedbackPage> createState() => _FeedbackPageState();
}

class _FeedbackPageState extends ConsumerState<FeedbackPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;
  final _contentCtrl = TextEditingController();

  // 提交反馈
  String _feedbackType = 'problem'; // problem / suggestion
  final List<String> _images = [];
  bool _submitting = false;
  bool _compressing = false;
  bool _attachAllLogs = false;
  bool _attachErrorLogs = false;

  // 我的反馈
  List<FeedbackItem> _myFeedback = const [];
  bool _loadingFeedback = false;

  static const _maxImages = 6;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
    _tab.addListener(() {
      if (_tab.index == 1 && _myFeedback.isEmpty && !_loadingFeedback) {
        _loadMyFeedback();
      }
    });
  }

  @override
  void dispose() {
    _tab.dispose();
    _contentCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickImages() async {
    final remaining = _maxImages - _images.length;
    if (remaining <= 0) {
      _toast(tr('最多上传 {n} 张图片', {'n': _maxImages}));
      return;
    }
    final files = await ImagePicker().pickMultiImage(
      maxWidth: 1024,
      maxHeight: 1024,
      imageQuality: 85,
    );
    if (files.isEmpty || !mounted) return;
    setState(() => _compressing = true);
    try {
      for (final file in files) {
        if (_images.length >= _maxImages) break;
        final bytes = await file.readAsBytes();
        if (bytes.length > 8 * 1024 * 1024) {
          _toast(tr('图片超过 8MB，已跳过'));
          continue;
        }
        final dataUrl = await _compressImage(bytes);
        if (!mounted) return;
        setState(() => _images.add(dataUrl));
      }
    } catch (e) {
      if (!mounted) return;
      _toast(tr('图片处理失败'));
    } finally {
      if (mounted) setState(() => _compressing = false);
    }
  }

  /// 压缩图片：256px 宽度、JPEG 质量 75%（与桌面端一致）。
  Future<String> _compressImage(Uint8List bytes) async {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) throw   FormatException(tr('无法解析图片'));
    final resized = img.copyResize(decoded, width: 256);
    final jpg = img.encodeJpg(resized, quality: 75);
    return 'data:image/jpeg;base64,${base64Encode(jpg)}';
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final content = _contentCtrl.text.trim();
    if (content.isEmpty) {
      _toast(tr('请填写反馈内容'));
      return;
    }
    if (content.length > 1000) {
      _toast(tr('内容不能超过 1000 字'));
      return;
    }
    final api = ref.read(accountApiProvider);
    final title = _feedbackType == 'suggestion' ? tr('功能建议') : tr('问题反馈');
    final isProblem = _feedbackType == 'problem';
    // 勾选后格式化本地应用日志（仅问题反馈附带日志）。
    final errorLogs = isProblem && _attachErrorLogs
        ? ApplicationLogManager.instance.formatExport(onlyErrors: true)
        : null;
    final allLogs = isProblem && _attachAllLogs
        ? ApplicationLogManager.instance.formatExport(onlyErrors: false)
        : null;
    setState(() => _submitting = true);
    try {
      await api.submitFeedback(
        title: title,
        content: content,
        feedbackType: _feedbackType,
        errorLogs: errorLogs,
        allLogs: allLogs,
        images: _feedbackType == 'suggestion' ? [..._images] : null,
      );
      if (!mounted) return;
      _toast(tr('反馈已提交，感谢您的支持'));
      setState(() {
        _contentCtrl.clear();
        _images.clear();
      });
    } catch (e) {
      if (!mounted) return;
      _toast(e is AuthException ? e.message : tr('提交失败'));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _loadMyFeedback() async {
    final auth = ref.read(authProvider);
    if (!auth.isLoggedIn) {
      _toast(tr('请先登录后再查看反馈'));
      return;
    }
    setState(() => _loadingFeedback = true);
    try {
      final list = await ref.read(accountApiProvider).getMyFeedback();
      if (!mounted) return;
      setState(() => _myFeedback = list);
    } catch (e) {
      if (!mounted) return;
      _toast(e is AuthException ? e.message : tr('获取反馈失败'));
    } finally {
      if (mounted) setState(() => _loadingFeedback = false);
    }
  }

  void _toast(String msg) {
    showXianYuToast(context, msg, duration: const Duration(seconds: 2));
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final tabBar = TabBar(
      controller: _tab,
      tabs: [Tab(text: tr('提交反馈')), Tab(text: tr('我的反馈'))],
    );
    return Scaffold(
      backgroundColor: appScaffoldBackground(context, ref),
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          Padding(
            padding: EdgeInsets.only(
              top: widget.embedded
                  // 嵌入态（横屏 master-detail）：外层已渲染统一标题条并避开
                  // 状态栏，TabBar 直接顶在其下，不再补状态栏高度。
                  ? tabBar.preferredSize.height
                  : GlassTopBar.height(context, bottom: tabBar),
            ),
            child: RepaintBoundary(
              child: TabBarView(
                controller: _tab,
                children: [
                  _buildSubmitTab(context),
                  _buildMyFeedbackTab(context, auth),
                ],
              ),
            ),
          ),
          // 嵌入态（横屏 master-detail 右侧）：标题「意见反馈」由外层统一标题
          // 条承担并避开状态栏，此处仅保留 TabBar 切换条，直接顶在标题条之下。
          if (widget.embedded)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Material(color: Colors.transparent, child: tabBar),
            )
          else
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              // 竖屏路由：与横屏嵌入统一纯色平面顶栏（标题条 + TabBar）。
              child: FlatTopBar(
                leading: const BackButton(),
                title: tr('意见反馈'),
                bottom: tabBar,
                backgroundColor: appScaffoldBackground(context, ref),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSubmitTab(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final auth = ref.watch(authProvider);
    final logs = ref.watch(applicationLogsProvider);
    if (!auth.isLoggedIn) {
      return _emptyHint(
        icon: Icons.lock_outline,
        text: tr('登录后即可提交反馈'),
        action: () => _toast(tr('请先登录')),
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 反馈类型
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: appCardFill(context, ref),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                _typeButton('problem', tr('问题反馈')),
                _typeButton('suggestion', tr('功能建议')),
              ],
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _contentCtrl,
            maxLines: 6,
            maxLength: 1000,
            decoration: InputDecoration(
              hintText: _feedbackType == 'suggestion'
                  ? tr('请描述你的功能建议…')
                  : tr('请描述你遇到的问题…'),
              filled: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
          if (_feedbackType == 'suggestion') ...[
            const SizedBox(height: 8),
            Text(
              tr('可上传截图辅助说明（最多 {n} 张）', {'n': _maxImages}),
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            _buildImageGrid(),
          ],
          if (_feedbackType == 'problem') ...[
            const SizedBox(height: 16),
            _buildLogOptions(context, scheme, logs),
          ],
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _submitting || _compressing ? null : _submit,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: _submitting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                :   Text(tr('提交反馈'),
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  /// 问题反馈的日志勾选区：仅在有日志时展示对应勾选项，避免上传无用日志。
  Widget _buildLogOptions(
      BuildContext context, ColorScheme scheme, List<AppLogEntry> logs) {
    final errorLogs = logs.where((e) => e.level == LogLevel.error).toList();
    if (logs.isEmpty) return const SizedBox.shrink();
    return Container(
      decoration: BoxDecoration(
        color: appCardFill(context, ref),
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
            child: Row(
              children: [
                Icon(Icons.troubleshoot, size: 16, color: scheme.primary),
                const SizedBox(width: 6),
                Text(
                  tr('附带诊断日志，便于定位问题'),
                  style: TextStyle(
                      fontSize: 12.5, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          // 全部日志
          CheckboxListTile(
            dense: true,
            value: _attachAllLogs,
            title: Text(
              tr('全部日志（{n} 条）', {'n': logs.length}),
              style: const TextStyle(fontSize: 14),
            ),
            secondary:
                Icon(Icons.description_outlined, size: 20, color: scheme.primary),
            onChanged: (v) => setState(() => _attachAllLogs = v ?? false),
          ),
          // 错误日志（仅在存在错误日志时显示）
          if (errorLogs.isNotEmpty)
            CheckboxListTile(
              dense: true,
              value: _attachErrorLogs,
              title: Text(
                tr('错误日志（{n} 条）', {'n': errorLogs.length}),
                style: const TextStyle(fontSize: 14),
              ),
              secondary:
                  Icon(Icons.error_outline, size: 20, color: scheme.error),
              onChanged: (v) => setState(() => _attachErrorLogs = v ?? false),
            ),
        ],
      ),
    );
  }

  Widget _typeButton(String type, String label) {
    final scheme = Theme.of(context).colorScheme;
    final selected = _feedbackType == type;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _feedbackType = type),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected ? scheme.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: selected ? scheme.onPrimary : scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildImageGrid() {
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (var i = 0; i < _images.length; i++)
          Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.memory(
                  base64Decode(
                      _images[i].split(',').last),
                  width: 80,
                  height: 80,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => Container(
                    width: 80,
                    height: 80,
                    color: appCardColor(context),
                    child: Icon(Icons.broken_image,
                        color: scheme.outline),
                  ),
                ),
              ),
              Positioned(
                top: 2,
                right: 2,
                child: GestureDetector(
                  onTap: () => setState(() => _images.removeAt(i)),
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.close,
                        size: 14, color: Colors.white),
                  ),
                ),
              ),
            ],
          ),
        if (_images.length < _maxImages)
          GestureDetector(
            onTap: _compressing ? null : _pickImages,
            child: Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: appCardColor(context),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: _compressing
                  ? const Center(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : Icon(Icons.add_a_photo_outlined,
                      color: scheme.onSurfaceVariant),
            ),
          ),
      ],
    );
  }

  Widget _buildMyFeedbackTab(BuildContext context, AuthState auth) {
    if (!auth.isLoggedIn) {
      return _emptyHint(
        icon: Icons.lock_outline,
        text: tr('登录后即可查看反馈'),
        action: () => _toast(tr('请先登录')),
      );
    }
    if (_loadingFeedback) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_myFeedback.isEmpty) {
      return _emptyHint(
        icon: Icons.inbox_outlined,
        text: tr('暂无反馈记录'),
        action: _loadMyFeedback,
      );
    }
    return RefreshIndicator(
      onRefresh: _loadMyFeedback,
      child: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: _myFeedback.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          final item = _myFeedback[index];
          return _FeedbackCard(
            item: item,
            onTap: () => _showFeedbackDetail(item),
          );
        },
      ),
    );
  }

  Widget _emptyHint({
    required IconData icon,
    required String text,
    required VoidCallback action,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48, color: scheme.outline),
          const SizedBox(height: 12),
          Text(text,
              style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant)),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: action, child:   Text(tr('刷新'))),
        ],
      ),
    );
  }

  void _showFeedbackDetail(FeedbackItem item) {
    showPredictiveDialog<void>(
      context: context,
      builder: (ctx) => _FeedbackDetailDialog(item: item),
    );
  }
}

/// 反馈状态徽章。
class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});
  final String status;

  @override
  Widget build(BuildContext context) {
    final (label, color, bg) = switch (status) {
      'pending' => (tr('待处理'), const Color(0xFFB45309), const Color(0x1AB45309)),
      'processing' => (tr('处理中'), const Color(0xFF2563EB), const Color(0x1A2563EB)),
      'resolved' => (tr('已完成'), const Color(0xFF16A34A), const Color(0x1A16A34A)),
      'rejected' => (tr('已拒绝'), const Color(0xFFE11D48), const Color(0x1AE11D48)),
      _ => (status, const Color(0xFF6B7280), const Color(0x1A6B7280)),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
      child: Text(label, style: TextStyle(fontSize: 11, color: color)),
    );
  }
}

/// 我的反馈列表卡片。
class _FeedbackCard extends ConsumerWidget {
  const _FeedbackCard({required this.item, required this.onTap});
  final FeedbackItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: appCardColor(context),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      item.title.isEmpty ? tr('未命名反馈') : item.title,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  _StatusBadge(status: item.status),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                item.content,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 13, color: scheme.onSurfaceVariant),
              ),
              if (item.resolveImages.isNotEmpty) ...[
                const SizedBox(height: 8),
                SizedBox(
                  height: 56,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: item.resolveImages.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 6),
                    itemBuilder: (_, i) => ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.network(
                        item.resolveImages[i],
                        width: 56,
                        height: 56,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Container(
                          width: 56,
                          height: 56,
                          color: appCardColor(context),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 8),
              Text(
                _formatDate(item.createdAt),
                style: TextStyle(fontSize: 11, color: scheme.outline),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatDate(String value) {
    if (value.isEmpty) return '';
    return value.replaceFirst('T', ' ').split('.').first;
  }
}

/// 反馈详情弹窗：展示完整内容、处理说明、完成图片。
class _FeedbackDetailDialog extends StatelessWidget {
  const _FeedbackDetailDialog({required this.item});
  final FeedbackItem item;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(item.title.isEmpty ? tr('反馈详情') : item.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _StatusBadge(status: item.status),
                const SizedBox(width: 8),
                Text(
                  _formatDate(item.createdAt),
                  style: TextStyle(fontSize: 12, color: scheme.outline),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(item.content,
                style: const TextStyle(fontSize: 14, height: 1.5)),
            if (item.rejectReason.isNotEmpty) ...[
              const SizedBox(height: 14),
              Text(tr('拒绝理由'),
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: scheme.error)),
              const SizedBox(height: 4),
              Text(item.rejectReason,
                  style: TextStyle(fontSize: 13, color: scheme.error)),
            ],
            if (item.resolveNote.isNotEmpty) ...[
              const SizedBox(height: 14),
              Text(tr('完成说明'),
                  style: TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(item.resolveNote,
                  style: const TextStyle(fontSize: 13, height: 1.5)),
            ],
            if (item.resolveImages.isNotEmpty) ...[
              const SizedBox(height: 14),
              Text(tr('处理图片'),
                  style: TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final url in item.resolveImages)
                    GestureDetector(
                      onTap: () => _showImageViewer(context, url),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.network(
                          url,
                          width: 90,
                          height: 90,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => Container(
                            width: 90,
                            height: 90,
                            color: appCardColor(context),
                            child: Icon(Icons.broken_image,
                                color: scheme.outline),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child:   Text(tr('关闭')),
        ),
      ],
    );
  }

  void _showImageViewer(BuildContext context, String url) {
    showPredictiveDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.black,
        child: Stack(
          children: [
            InteractiveViewer(
              child: Image.network(url, fit: BoxFit.contain),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: IconButton(
                onPressed: () => Navigator.pop(ctx),
                icon: const Icon(Icons.close, color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDate(String value) {
    if (value.isEmpty) return '';
    return value.replaceFirst('T', ' ').split('.').first;
  }
}
