import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pagesage/domain/books/book.dart';
import 'package:pagesage/domain/books/reading_position.dart';
import 'package:pagesage/domain/ocr/ocr_models.dart';
import 'package:pagesage/domain/translation/translation_models.dart';
import 'package:pagesage/domain/translation/reading_translation.dart';
import 'package:pagesage/features/ocr/application/ocr_page_store.dart';
import 'package:pagesage/features/translation/data/reading_translation_source.dart';
import 'package:pagesage/renderers/common/book_document_loader.dart';
import 'package:pagesage/renderers/epub/epub_document.dart';

import 'reading_translation_fixture.dart';

void main() {
  late ReadingTranslationFixture fixture;
  setUp(() async => fixture = await ReadingTranslationFixture.create());
  tearDown(() => fixture.dispose());
  Book book(String path, {BookFormat format = BookFormat.pdf}) => Book(
    id: 'book',
    title: 'Fixture',
    format: format,
    libraryFilePath: path,
    fileHash: 'file-v1',
    fileSize: 1,
    createdAt: 1,
    updatedAt: 1,
  );

  test(
    'native PDF source reads only the requested page and page identities differ',
    () async {
      final file = File('${fixture.directory.path}/two.pdf')
        ..writeAsBytesSync(_twoPagePdf());
      final loader = ReadingTranslationSourceLoader(
        ocrStore: DriftOcrPageStore(fixture.database.ocrPageDao),
      );
      final first = await loader.load(
        book: book(file.path),
        locator: ReadingLocator.pdf(page: 1),
      );
      final second = await loader.load(
        book: book(file.path),
        locator: ReadingLocator.pdf(page: 2),
      );
      expect(first.units.single.original, contains('First page only'));
      expect(first.units.single.original, isNot(contains('Second')));
      expect(second.units.single.original, contains('Second page only'));
      expect(second.label, '第 2 页');
      expect(second.key, isNot(first.key));
    },
  );

  test(
    'rapid page changes keep one PDF extraction active and skip superseded queued pages',
    () async {
      final release = Completer<String>();
      final arrived = Completer<void>();
      var current = 1;
      final pages = <int>[];
      final loader = ReadingTranslationSourceLoader(
        ocrStore: DriftOcrPageStore(fixture.database.ocrPageDao),
        pdfPageReader: (_, page) {
          pages.add(page);
          if (page == 1) {
            arrived.complete();
            return release.future;
          }
          return Future.value('Page $page');
        },
      );
      Future<ReadingTranslationSource> load(int page) => loader.load(
        book: book('/fixture.pdf'),
        locator: ReadingLocator.pdf(page: page),
        isCurrent: () => current == page,
      );
      final first = load(1);
      await arrived.future;
      current = 2;
      final second = load(2);
      current = 3;
      final third = load(3);
      final firstCancelled = expectLater(
        first,
        throwsA(isA<TranslationException>()),
      );
      final secondCancelled = expectLater(
        second,
        throwsA(isA<TranslationException>()),
      );
      expect(pages, [1]);
      release.complete('Page 1');
      await firstCancelled;
      await secondCancelled;
      expect((await third).label, '第 3 页');
      expect(pages, [1, 3]);
    },
  );

  test(
    'blank page accepts only verified OCR from the same file version; changed OCR invalidates binding',
    () async {
      final store = DriftOcrPageStore(fixture.database.ocrPageDao);
      final loader = ReadingTranslationSourceLoader(
        ocrStore: store,
        pdfPageReader: (_, _) async => '',
      );
      Future<void> put(String revision, String text, String signature) =>
          store.putPage(
            bookId: 'book',
            pageNumber: 2,
            sourceRevision: revision,
            cacheSignature: signature,
            textRevision: signature,
            result: OcrPageResult(
              text: text,
              language: 'en',
              engine: 'fixture',
            ),
          );
      await put('different-file', 'Old OCR', 'one');
      await expectLater(
        loader.load(
          book: book('/fixture.pdf'),
          locator: ReadingLocator.pdf(page: 2),
        ),
        throwsA(isA<TranslationException>()),
      );
      await put('file-v1', 'Verified OCR', 'two');
      final verified = await loader.load(
        book: book('/fixture.pdf'),
        locator: ReadingLocator.pdf(page: 2),
      );
      expect(verified.units.single.original, 'Verified OCR');
      await put('file-v1', 'Updated OCR', 'three');
      final updated = await loader.load(
        book: book('/fixture.pdf'),
        locator: ReadingLocator.pdf(page: 2),
      );
      expect(updated.key, isNot(verified.key));
    },
  );

  test(
    'web source follows snapshot identity and excludes code, formula and table blocks',
    () async {
      final loader = ReadingTranslationSourceLoader(
        ocrStore: DriftOcrPageStore(fixture.database.ocrPageDao),
      );
      Future<ReadingTranslationSource> load(String snapshot) async {
        final source = await loader.load(
          book: book('/web', format: BookFormat.web),
          locator: null,
          documentLoader: _Loader(
            EpubDocument(
              sourceLocator: ReadingLocator.web(
                webChapterId: 'chapter',
                snapshotId: snapshot,
                sourceRevision: 'rev',
                textRevision: 'text',
              ),
              chapters: const [
                EpubChapter(
                  index: 0,
                  href: 'web',
                  title: 'Article',
                  text: 'HelloCode',
                  blocks: [
                    EpubTextBlock(
                      startOffset: 0,
                      endOffset: 5,
                      text: 'Hello',
                      type: EpubBlockType.paragraph,
                    ),
                    EpubTextBlock(
                      startOffset: 5,
                      endOffset: 9,
                      text: 'Code',
                      type: EpubBlockType.code,
                    ),
                    EpubTextBlock(
                      startOffset: 9,
                      endOffset: 12,
                      text: 'x+y',
                      type: EpubBlockType.math,
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
        return source;
      }

      final first = await load('one');
      final second = await load('two');
      expect(first.units.map((unit) => unit.original), ['Hello']);
      expect(first.key, isNot(second.key));
    },
  );
}

final class _Loader implements BookDocumentLoader {
  const _Loader(this.document);
  final EpubDocument document;
  @override
  Future<EpubDocument> load(String filePath) async => document;
}

List<int> _twoPagePdf() {
  const first = 'BT /F1 12 Tf 72 720 Td (First page only) Tj ET';
  const second = 'BT /F1 12 Tf 72 720 Td (Second page only) Tj ET';
  final objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 5 0 R /Resources << /Font << /F1 7 0 R >> >> >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 6 0 R /Resources << /Font << /F1 7 0 R >> >> >>',
    '<< /Length ${first.length} >>\nstream\n$first\nendstream',
    '<< /Length ${second.length} >>\nstream\n$second\nendstream',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
  ];
  final buffer = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[];
  for (var index = 0; index < objects.length; index++) {
    offsets.add(buffer.length);
    buffer.write('${index + 1} 0 obj\n${objects[index]}\nendobj\n');
  }
  final xref = buffer.length;
  buffer.write('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
  for (final offset in offsets) {
    buffer.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  buffer.write(
    'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n',
  );
  return ascii.encode(buffer.toString());
}
