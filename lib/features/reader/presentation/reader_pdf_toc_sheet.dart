import 'package:flutter/material.dart';

import '../../../domain/books/reading_position.dart';
import '../../../renderers/common/renderer_event.dart';
import 'reader_pdf_outline.dart';

final class PdfTocSheet extends StatelessWidget {
  const PdfTocSheet({
    required this.outline,
    required this.totalPages,
    required this.currentPage,
    this.currentPageOffsetFraction,
    super.key,
  });

  final List<RendererOutlineItem> outline;
  final int totalPages;
  final int? currentPage;
  final double? currentPageOffsetFraction;

  @override
  Widget build(BuildContext context) {
    final items = outline.isEmpty ? _fallbackPageItems() : outline;
    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              outline.isEmpty ? '页码' : 'PDF 目录',
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          Expanded(
            child: ReaderPdfOutline(
              items: items,
              currentPage: currentPage,
              pageOffsetFraction: currentPageOffsetFraction,
              onSelected: (item) => Navigator.of(context).pop(
                ReadingLocator.pdf(
                  page: item.page,
                  progress: _pageProgress(item.page),
                  pageOffsetFraction: item.offsetFraction,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<RendererOutlineItem> _fallbackPageItems() {
    return [
      for (var page = 1; page <= totalPages; page += 1)
        RendererOutlineItem(title: '第 $page 页', page: page),
    ];
  }

  double _pageProgress(int page) {
    if (totalPages <= 1) {
      return 1;
    }
    return ((page - 1) / (totalPages - 1)).clamp(0, 1).toDouble();
  }
}
