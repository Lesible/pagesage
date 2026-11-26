import 'package:flutter/material.dart';

import '../../../app/theme/app_tokens.dart';
import '../../../domain/books/reader_settings.dart';
import 'reader_chrome.dart';

/// Page-number prompt for the PDF toolbar.
///
/// The controller lives here rather than in `_showPageJump` because
/// `showDialog`'s future completes when the dialog starts dismissing, while
/// the route (and its `TextField`) is still animating out. Disposing the
/// controller at that point throws "used after being disposed" on the next
/// frame.
final class PageJumpDialog extends StatefulWidget {
  const PageJumpDialog({required this.initialPage, super.key});

  final int initialPage;

  @override
  State<PageJumpDialog> createState() => _PageJumpDialogState();
}

final class _PageJumpDialogState extends State<PageJumpDialog> {
  late final _controller = TextEditingController(
    text: widget.initialPage.toString(),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('跳转页码'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(
          labelText: '页码',
          hintText: '输入 PDF 页码',
        ),
        onSubmitted: (value) => Navigator.of(context).pop(value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('跳转'),
        ),
      ],
    );
  }
}

/// The compact toolbar shown above a PDF page.
final class PdfQuickToolbar extends StatefulWidget {
  const PdfQuickToolbar({
    required this.pageNumber,
    required this.totalPages,
    required this.settings,
    required this.onPageJump,
    required this.onZoomOut,
    required this.onZoomIn,
    required this.onFitWidth,
    required this.onFitPage,
    this.searchAvailable = true,
    this.textLayerAvailable = true,
    this.pageTextAvailable,
    this.capabilityReason,
    this.onOcrPage,
    this.onOcrRange,
    this.onOcrBook,
    this.onOcrMenuChanged,
    this.onCollapse,
    super.key,
  });

  final int? pageNumber;
  final int? totalPages;
  final ReaderSettings settings;
  final VoidCallback onPageJump;
  final VoidCallback onZoomOut;
  final VoidCallback onZoomIn;
  final VoidCallback onFitWidth;
  final VoidCallback onFitPage;
  final bool searchAvailable;
  final bool textLayerAvailable;
  final bool? pageTextAvailable;
  final String? capabilityReason;
  final VoidCallback? onOcrPage;
  final VoidCallback? onOcrRange;
  final VoidCallback? onOcrBook;
  final ValueChanged<bool>? onOcrMenuChanged;
  final VoidCallback? onCollapse;

  bool get _hasMoreActions =>
      onOcrPage != null || onOcrRange != null || onOcrBook != null;

  @override
  State<PdfQuickToolbar> createState() => _PdfQuickToolbarState();

  Widget _build(BuildContext context, bool expanded, VoidCallback onExpand) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
        if (constraints.maxWidth < 700 * textScale) {
          return _buildCompact(context, expanded, onExpand);
        }
        return _buildWide(context, expanded, onExpand);
      },
    );
  }

  Widget _buildCompact(
    BuildContext context,
    bool expanded,
    VoidCallback onExpand,
  ) {
    final showOcrTools =
        _hasMoreActions && (expanded || pageTextAvailable == false);
    return ReaderFloatingChrome(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.x2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: PdfToolbarChip(
                    icon: Icons.pin_outlined,
                    label: _pdfPageLabel(pageNumber, totalPages),
                    tooltip: '跳转页码',
                    onPressed: onPageJump,
                  ),
                ),
                if (_hasMoreActions && !showOcrTools) ...[
                  const SizedBox(width: AppSpacing.x1),
                  _PdfExpandTools(onPressed: onExpand),
                ],
                if (onCollapse != null)
                  PdfToolbarIconButton(
                    icon: Icons.keyboard_arrow_up,
                    tooltip: '收起阅读工具',
                    onPressed: onCollapse,
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.x1),
            Wrap(
              alignment: WrapAlignment.center,
              children: [
                PdfToolbarIconButton(
                  icon: Icons.zoom_out,
                  tooltip: '缩小 PDF',
                  onPressed: onZoomOut,
                ),
                PdfToolbarIconButton(
                  icon: Icons.zoom_in,
                  tooltip: '放大 PDF',
                  onPressed: onZoomIn,
                ),
                PdfToolbarIconButton(
                  icon: Icons.fit_screen_outlined,
                  tooltip: '适合宽度',
                  selected: settings.pdfZoomMode == PdfZoomMode.fitWidth,
                  onPressed: onFitWidth,
                ),
                PdfToolbarIconButton(
                  icon: Icons.fullscreen_outlined,
                  tooltip: '适合页面',
                  selected: settings.pdfZoomMode == PdfZoomMode.fitPage,
                  onPressed: onFitPage,
                ),
              ],
            ),
            if (showOcrTools)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.x1),
                child: _PdfOcrTools(
                  autofocus: expanded,
                  onPage: onOcrPage,
                  onRange: onOcrRange,
                  onBook: onOcrBook,
                  onMenuChanged: onOcrMenuChanged,
                ),
              ),
            if (!textLayerAvailable || !searchAvailable)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.x1),
                child: Tooltip(
                  message: capabilityReason ?? '此 PDF 的文本或搜索能力不可用',
                  child: Text(
                    !textLayerAvailable ? '无文本层' : '搜索不可用',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildWide(
    BuildContext context,
    bool expanded,
    VoidCallback onExpand,
  ) {
    final showOcrTools =
        _hasMoreActions && (expanded || pageTextAvailable == false);
    final colorScheme = Theme.of(context).colorScheme;
    final pageLabel = _pdfPageLabel(pageNumber, totalPages);
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!textLayerAvailable || !searchAvailable)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.x2,
              AppSpacing.x1,
              AppSpacing.x2,
              0,
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Tooltip(
                message: capabilityReason ?? '此 PDF 的文本或搜索能力不可用',
                child: Text(
                  // Compact status, not a sticky warning paragraph.
                  !textLayerAvailable
                      ? (onOcrPage != null ? '无文本层 · 可识别（标注为近似）' : '无文本层')
                      : '搜索不可用',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.all(AppSpacing.x2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    PdfToolbarChip(
                      icon: Icons.pin_outlined,
                      label: pageLabel,
                      tooltip: '跳转页码',
                      onPressed: onPageJump,
                    ),
                    const SizedBox(width: AppSpacing.x1),
                    PdfToolbarIconButton(
                      icon: Icons.zoom_out,
                      tooltip: '缩小 PDF',
                      onPressed: onZoomOut,
                    ),
                    PdfToolbarIconButton(
                      icon: Icons.zoom_in,
                      tooltip: '放大 PDF',
                      onPressed: onZoomIn,
                    ),
                    const SizedBox(width: AppSpacing.x1),
                    PdfToolbarIconButton(
                      icon: Icons.fit_screen_outlined,
                      tooltip: '适合宽度',
                      selected: settings.pdfZoomMode == PdfZoomMode.fitWidth,
                      onPressed: onFitWidth,
                    ),
                    PdfToolbarIconButton(
                      icon: Icons.fullscreen_outlined,
                      tooltip: '适合页面',
                      selected: settings.pdfZoomMode == PdfZoomMode.fitPage,
                      onPressed: onFitPage,
                    ),
                    if (showOcrTools) ...[
                      const SizedBox(width: AppSpacing.x2),
                      _PdfOcrTools(
                        autofocus: expanded,
                        onPage: onOcrPage,
                        onRange: onOcrRange,
                        onBook: onOcrBook,
                        onMenuChanged: onOcrMenuChanged,
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (_hasMoreActions && !showOcrTools)
              Padding(
                padding: EdgeInsets.only(
                  right: onCollapse == null ? AppSpacing.x2 : AppSpacing.x1,
                ),
                child: _PdfExpandTools(onPressed: onExpand),
              ),
            if (onCollapse != null)
              Padding(
                padding: const EdgeInsets.only(right: AppSpacing.x2),
                child: PdfToolbarIconButton(
                  icon: Icons.keyboard_arrow_up,
                  tooltip: '收起阅读工具',
                  onPressed: onCollapse!,
                ),
              ),
          ],
        ),
      ],
    );

    return ReaderFloatingChrome(child: content);
  }
}

final class _PdfQuickToolbarState extends State<PdfQuickToolbar> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return widget._build(
      context,
      _expanded,
      () => setState(() => _expanded = true),
    );
  }
}

final class _PdfExpandTools extends StatelessWidget {
  const _PdfExpandTools({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: '展开识别工具',
      icon: const Icon(Icons.more_horiz, size: 20, semanticLabel: '展开识别工具'),
      style: IconButton.styleFrom(
        minimumSize: const Size(48, 48),
        foregroundColor: colors.onSurfaceVariant,
        backgroundColor: colors.surfaceSubtle,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
      ),
      onPressed: onPressed,
    );
  }
}

final class _PdfOcrTools extends StatefulWidget {
  const _PdfOcrTools({
    this.autofocus = false,
    this.onPage,
    this.onRange,
    this.onBook,
    this.onMenuChanged,
  });

  final bool autofocus;
  final VoidCallback? onPage;
  final VoidCallback? onRange;
  final VoidCallback? onBook;
  final ValueChanged<bool>? onMenuChanged;

  @override
  State<_PdfOcrTools> createState() => _PdfOcrToolsState();
}

final class _PdfOcrToolsState extends State<_PdfOcrTools> {
  bool _rangeMenuOpen = false;
  bool _reportedOpen = false;

  void _reportMenuState() {
    if (!mounted) return;
    final open = _rangeMenuOpen;
    if (open == _reportedOpen) return;
    _reportedOpen = open;
    widget.onMenuChanged?.call(open);
  }

  void _run(VoidCallback action) {
    if (!mounted) return;
    _rangeMenuOpen = false;
    _reportMenuState();
    action();
  }

  @override
  void dispose() {
    if (_reportedOpen) widget.onMenuChanged?.call(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    PopupMenuItem<VoidCallback> item({
      required VoidCallback action,
      required IconData icon,
      required String label,
      required String detail,
    }) => PopupMenuItem(
      value: action,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.x2),
        child: Row(
          children: [
            Icon(icon, size: 20, color: colors.onSurfaceVariant),
            const SizedBox(width: AppSpacing.x3),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: textTheme.bodyMedium),
                  const SizedBox(height: AppSpacing.x1),
                  Text(
                    detail,
                    style: textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.onPage != null)
          Flexible(
            child: Tooltip(
              message: '识别当前可见页（双页模式会识别对开两页）',
              child: OutlinedButton.icon(
                autofocus: widget.autofocus,
                onPressed: () => _run(widget.onPage!),
                style: OutlinedButton.styleFrom(
                  foregroundColor: colors.onSurface,
                  side: BorderSide(color: colors.outlineVariant),
                  minimumSize: const Size(0, 48),
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.x3,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                ),
                icon: const Icon(Icons.document_scanner_outlined, size: 18),
                label: const Text('识别文字'),
              ),
            ),
          ),
        if (widget.onRange != null || widget.onBook != null)
          PopupMenuButton<VoidCallback>(
            tooltip: '选择识别范围',
            icon: const Icon(Icons.arrow_drop_down, size: 20),
            padding: EdgeInsets.zero,
            style: IconButton.styleFrom(
              minimumSize: const Size(48, 48),
              foregroundColor: colors.onSurfaceVariant,
            ),
            constraints: const BoxConstraints(minWidth: 232, maxWidth: 320),
            position: PopupMenuPosition.under,
            requestFocus: true,
            onOpened: () {
              _rangeMenuOpen = true;
              _reportMenuState();
            },
            onCanceled: () {
              _rangeMenuOpen = false;
              _reportMenuState();
            },
            onSelected: _run,
            itemBuilder: (_) => [
              if (widget.onRange != null)
                item(
                  action: widget.onRange!,
                  icon: Icons.pin_outlined,
                  label: '识别指定页',
                  detail: '选择起止页码',
                ),
              if (widget.onBook != null)
                item(
                  action: widget.onBook!,
                  icon: Icons.menu_book_outlined,
                  label: '识别整本书',
                  detail: '在后台逐页处理',
                ),
            ],
          ),
      ],
    );
  }
}

/// The small page pill shown after the PDF toolbar recedes.
final class PdfQuickToolbarReveal extends StatelessWidget {
  const PdfQuickToolbarReveal({
    required this.pageNumber,
    required this.totalPages,
    required this.onReveal,
    super.key,
  });

  final int? pageNumber;
  final int? totalPages;
  final VoidCallback onReveal;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final label = _pdfPageLabel(pageNumber, totalPages);
    return Tooltip(
      message: '显示阅读工具',
      child: Semantics(
        button: true,
        label: '显示阅读工具',
        child: ReaderFloatingChrome(
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            onTap: onReveal,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.x3,
                vertical: AppSpacing.x2,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.unfold_more,
                    size: 17,
                    color: colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: AppSpacing.x2),
                  Text(
                    label,
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: colorScheme.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class PdfToolbarChip extends StatelessWidget {
  const PdfToolbarChip({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onPressed,
    super.key,
  });

  final IconData icon;
  final String label;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        label: tooltip,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.md),
          onTap: onPressed,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colorScheme.surfaceSubtle,
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: Border.all(color: colorScheme.outlineVariant),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.x3,
                vertical: AppSpacing.x2,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 18, color: colorScheme.onSurfaceVariant),
                  const SizedBox(width: AppSpacing.x2),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: colorScheme.onSurface,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class PdfToolbarIconButton extends StatelessWidget {
  const PdfToolbarIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.selected = false,
    super.key,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1),
      child: Tooltip(
        message: tooltip,
        child: Semantics(
          button: true,
          selected: selected,
          label: tooltip,
          child: IconButton.filledTonal(
            tooltip: tooltip,
            visualDensity: VisualDensity.compact,
            style: IconButton.styleFrom(
              fixedSize: const Size(40, 40),
              backgroundColor: selected
                  ? colorScheme.secondaryContainer
                  : colorScheme.surfaceSubtle,
              foregroundColor: selected
                  ? colorScheme.onSecondaryContainer
                  : colorScheme.onSurfaceVariant,
            ),
            onPressed: onPressed,
            icon: Icon(icon, size: 19),
          ),
        ),
      ),
    );
  }
}

String _pdfPageLabel(int? pageNumber, int? totalPages) {
  if (pageNumber != null && totalPages != null && totalPages > 0) {
    return '$pageNumber / $totalPages';
  }
  if (pageNumber != null) {
    return '第 $pageNumber 页';
  }
  return '页码';
}
