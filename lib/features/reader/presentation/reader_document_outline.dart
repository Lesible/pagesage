import 'package:flutter/material.dart';

import '../../../renderers/epub/epub_document.dart';
import 'reader_toc_tree.dart';
import 'reader_outline_row.dart';

final class ReaderDocumentOutline extends StatefulWidget {
  const ReaderDocumentOutline({
    required this.document,
    required this.chapterIndex,
    required this.chapterOffset,
    required this.onSelected,
    this.filter = '',
    super.key,
  });
  final EpubDocument document;
  final int? chapterIndex;
  final int chapterOffset;
  final ValueChanged<EpubTocItem> onSelected;
  final String filter;

  @override
  State<ReaderDocumentOutline> createState() => _ReaderDocumentOutlineState();
}

final class _ReaderDocumentOutlineState extends State<ReaderDocumentOutline> {
  final Set<String> _expanded = {};
  final ScrollController _scroll = ScrollController();
  String? _lastActiveKey;
  bool _seeded = false;
  int? _lastScrolledChapter;

  @override
  void didUpdateWidget(covariant ReaderDocumentOutline oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.document, widget.document)) {
      _expanded.clear();
      _seeded = false;
      _lastActiveKey = null;
      _lastScrolledChapter = null;
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final allKeys = <String>{};
    void gather(List<EpubTocItem> nodes, String prefix) {
      for (var index = 0; index < nodes.length; index++) {
        final key = prefix.isEmpty ? '$index' : '$prefix.$index';
        allKeys.add(key);
        if (!_seeded &&
            widget.document.sourceLocator != null &&
            nodes[index].children.isNotEmpty) {
          _expanded.add(key);
        }
        gather(nodes[index].children, key);
      }
    }

    gather(widget.document.toc, '');
    _seeded = true;
    final fullRows = flattenTocRows(
      widget.document.toc,
      expanded: allKeys,
      filter: '',
    );
    final active = activeTocRowKey(
      fullRows,
      chapterIndex: widget.chapterIndex,
      chapterOffset: widget.chapterOffset,
    );
    if (active != _lastActiveKey && active != null) {
      final pieces = active.split('.');
      for (var depth = 1; depth < pieces.length; depth++) {
        _expanded.add(pieces.take(depth).join('.'));
      }
      _lastActiveKey = active;
    }
    final rows = flattenTocRows(
      widget.document.toc,
      expanded: _expanded,
      filter: widget.filter.trim().toLowerCase(),
    );
    if (rows.isEmpty) return const Center(child: Text('没有匹配的标题'));
    if (widget.filter.isEmpty && _lastScrolledChapter != widget.chapterIndex) {
      _lastScrolledChapter = widget.chapterIndex;
      scrollOutlineToIndex(
        _scroll,
        rows.indexWhere((row) => row.key == active),
      );
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
      itemCount: rows.length,
      itemBuilder: (context, index) {
        final row = rows[index];
        final selected = row.key == active;
        final expandable = row.item.children.isNotEmpty;
        final expanded =
            widget.filter.isNotEmpty || _expanded.contains(row.key);
        return ReaderOutlineRow(
          title: row.item.title,
          level: row.level,
          selected: selected,
          expanded: expanded,
          onToggle: !expandable || widget.filter.isNotEmpty
              ? null
              : () => setState(() {
                  if (!_expanded.remove(row.key)) _expanded.add(row.key);
                }),
          onTap: row.item.chapterIndex == null
              ? null
              : () => widget.onSelected(row.item),
        );
      },
    );
  }
}
