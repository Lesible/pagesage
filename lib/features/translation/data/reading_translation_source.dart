import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:pdf_document/pdf_document.dart';
import 'package:pdf_graphics/pdf_graphics.dart';

import '../../../domain/books/book.dart';
import '../../../domain/books/reading_position.dart';
import '../../../domain/translation/reading_translation.dart';
import '../../../domain/translation/translation_models.dart';
import '../../../renderers/common/book_document_loader.dart';
import '../../../renderers/epub/epub_document.dart';
import '../../ocr/application/ocr_page_store.dart';

final class ReadingTranslationSourceLoader {
  ReadingTranslationSourceLoader({required this.ocrStore, this.pdfPageReader});
  final OcrPageStore ocrStore;
  final Future<String> Function(String path, int page)? pdfPageReader;
  Future<void> _pdfLane = Future.value();

  Future<ReadingTranslationSource> load({
    required Book book,
    required ReadingLocator? locator,
    String? documentPath,
    BookDocumentLoader? documentLoader,
    bool Function()? isCurrent,
  }) async {
    if (book.format == BookFormat.web) {
      if (documentLoader == null) {
        throw const TranslationException('请先打开已保存的网页');
      }
      final document = await documentLoader.load(
        documentPath ?? book.libraryFilePath,
      );
      final identity = document.sourceLocator;
      if (identity?.snapshotId == null || identity?.textRevision == null) {
        throw const TranslationException('网页来源身份缺失，请重新保存网页后重试');
      }
      final units = [
        for (final chapter in document.chapters)
          for (final block in chapter.blocks)
            if (block is EpubTextBlock &&
                const {
                  EpubBlockType.paragraph,
                  EpubBlockType.heading,
                  EpubBlockType.caption,
                  EpubBlockType.quote,
                }.contains(block.type) &&
                block.text.trim().isNotEmpty)
              ReadingTranslationUnit(
                id: '${chapter.index}:${block.startOffset}',
                original: block.text,
                parts: protectedTranslationParts(block),
              ),
      ];
      return ReadingTranslationSource(
        bookId: book.id,
        key: _hash(
          jsonEncode([
            'web-v1',
            identity?.snapshotId,
            identity?.textRevision,
            units.map((unit) => unit.original).toList(),
          ]),
        ),
        label: document.chapters.firstOrNull?.title ?? '当前网页',
        units: units,
      );
    }
    if (book.format != BookFormat.pdf) {
      throw const TranslationException('当前支持网页与 PDF 本页对照');
    }
    final page = locator?.page ?? 1;
    var text = await _readPdfText(book.libraryFilePath, page, isCurrent);
    var origin = 'native-v1';
    if (text.trim().isEmpty) {
      final ocr = await ocrStore.getPage(book.id, page);
      if (ocr == null ||
          ocr.sourceRevision != book.fileHash ||
          ocr.isLegacyOrUnverified ||
          ocr.resultState != 'recognized' ||
          !ocr.hasText) {
        throw const TranslationException('本页没有可用文本，请先识别本页，再打开对照翻译');
      }
      text = ocr.text;
      origin = 'ocr:${ocr.textRevision}:${ocr.cacheSignature}';
    }
    final paragraphs = text
        .split(RegExp(r'\n\s*\n'))
        .where((part) => part.trim().isNotEmpty)
        .toList();
    return ReadingTranslationSource(
      bookId: book.id,
      key: _hash(jsonEncode(['pdf-v1', book.fileHash, page, origin, text])),
      label: '第 $page 页',
      units: [
        for (var index = 0; index < paragraphs.length; index++)
          ReadingTranslationUnit(
            id: 'page:$page:$index',
            original: paragraphs[index],
            parts: protectedTranslationParts(
              EpubTextBlock(
                startOffset: 0,
                endOffset: paragraphs[index].length,
                text: paragraphs[index],
                type: EpubBlockType.paragraph,
              ),
            ),
          ),
      ],
    );
  }

  Future<String> _readPdfText(
    String path,
    int page,
    bool Function()? isCurrent,
  ) async {
    final previous = _pdfLane;
    final release = Completer<void>();
    _pdfLane = release.future;
    try {
      await previous;
      if (isCurrent?.call() == false) {
        throw const TranslationException('翻译来源已切换');
      }
      final text =
          await (pdfPageReader?.call(path, page) ??
              Isolate.run(() => readTranslationPdfPage(path, page)));
      if (isCurrent?.call() == false) {
        throw const TranslationException('翻译来源已切换');
      }
      return text;
    } finally {
      release.complete();
    }
  }
}

String readTranslationPdfPage(String path, int page) {
  final document = PdfDocument.open(File(path).readAsBytesSync());
  if (page < 1 || page > document.pageCount) {
    throw const TranslationException('PDF 页码超出范围');
  }
  return PdfTextExtractor.reflowPage(document, page - 1).text;
}

List<TranslationSourcePart> protectedTranslationParts(EpubTextBlock block) {
  final ranges = <({int start, int end})>[
    if (block.listMarker?.isNotEmpty == true)
      (start: 0, end: block.listMarker!.length.clamp(0, block.text.length)),
    for (final run in block.runs)
      if (run.style == EpubInlineStyle.code ||
          run.style == EpubInlineStyle.math)
        (
          start: (run.start - block.startOffset).clamp(0, block.text.length),
          end: (run.end - block.startOffset).clamp(0, block.text.length),
        ),
    for (final match in RegExp(r'https?://[^\s<>]+').allMatches(block.text))
      (start: match.start, end: match.end),
  ]..sort((first, second) => first.start.compareTo(second.start));
  final parts = <TranslationSourcePart>[];
  var offset = 0;
  for (final range in ranges) {
    if (range.end <= offset) continue;
    if (range.start > offset) {
      parts.add(
        TranslationSourcePart(block.text.substring(offset, range.start)),
      );
    }
    final start = range.start < offset ? offset : range.start;
    parts.add(
      TranslationSourcePart(
        block.text.substring(start, range.end),
        protected: true,
      ),
    );
    offset = range.end;
  }
  if (offset < block.text.length) {
    parts.add(TranslationSourcePart(block.text.substring(offset)));
  }
  return parts;
}

String _hash(String text) => sha256.convert(utf8.encode(text)).toString();
