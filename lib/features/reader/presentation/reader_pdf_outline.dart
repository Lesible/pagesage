import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../renderers/common/renderer_event.dart';
import 'reader_outline_row.dart';
import 'reader_pdf_outline_selection.dart';

final class ReaderPdfOutline extends StatefulWidget {
  const ReaderPdfOutline({
    required this.items,
    required this.currentPage,
    required this.onSelected,
    this.pageOffsetFraction,
    this.filter = '',
    super.key,
  });

  final List<RendererOutlineItem> items;
  final int? currentPage;
  final double? pageOffsetFraction;
  final String filter;
  final ValueChanged<RendererOutlineItem> onSelected;

  @override
  State<ReaderPdfOutline> createState() => _ReaderPdfOutlineState();
}

final class _ReaderPdfOutlineState extends State<ReaderPdfOutline> {
  final Set<int> _collapsed = {};
  final ScrollController _scroll = ScrollController();
  int? _lastActive;
  int? _lastScrolledPage;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ReaderPdfOutline oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!listEquals(oldWidget.items, widget.items)) {
      _collapsed.clear();
      _lastActive = null;
      _lastScrolledPage = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final active = activePdfOutlineIndex(
      items: widget.items,
      currentPage: widget.currentPage,
      currentPageOffsetFraction: widget.pageOffsetFraction,
    );
    final ancestors = <List<int>>[];
    final stack = <int>[];
    for (var index = 0; index < widget.items.length; index++) {
      while (stack.isNotEmpty &&
          widget.items[stack.last].level >= widget.items[index].level) {
        stack.removeLast();
      }
      ancestors.add(List.of(stack));
      stack.add(index);
    }
    if (_lastActive != active && active != null) {
      _collapsed.removeAll(ancestors[active]);
      _lastActive = active;
    }
    final query = widget.filter.trim().toLowerCase();
    final matches = <int>{};
    if (query.isNotEmpty) {
      for (var index = 0; index < widget.items.length; index++) {
        final item = widget.items[index];
        if (item.title.toLowerCase().contains(query) ||
            '${item.page}'.contains(query)) {
          matches.add(index);
          matches.addAll(ancestors[index]);
        }
      }
    }
    final visible = [
      for (var index = 0; index < widget.items.length; index++)
        if (query.isNotEmpty
            ? matches.contains(index)
            : !ancestors[index].any(_collapsed.contains))
          index,
    ];
    if (visible.isEmpty) return const Center(child: Text('没有匹配的目录项'));
    if (query.isEmpty && _lastScrolledPage != widget.currentPage) {
      _lastScrolledPage = widget.currentPage;
      scrollOutlineToIndex(_scroll, visible.indexOf(active ?? -1));
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
      itemCount: visible.length,
      itemBuilder: (context, rowIndex) {
        final index = visible[rowIndex];
        final item = widget.items[index];
        final hasChildren =
            index + 1 < widget.items.length &&
            widget.items[index + 1].level > item.level;
        return ReaderOutlineRow(
          title: item.title,
          level: item.level,
          selected: active == index,
          expanded: !_collapsed.contains(index),
          onToggle: !hasChildren || query.isNotEmpty
              ? null
              : () => setState(() {
                  if (!_collapsed.remove(index)) _collapsed.add(index);
                }),
          pageLabel: '${item.page}',
          onTap: () => widget.onSelected(item),
        );
      },
    );
  }
}
