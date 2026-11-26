import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pagesage/domain/books/book.dart';
import 'package:pagesage/domain/books/reader_settings.dart';
import 'package:pagesage/renderers/common/book_document_loader.dart';
import 'package:pagesage/renderers/common/renderer_event.dart';
import 'package:pagesage/renderers/epub/epub_document.dart';
import 'package:pagesage/renderers/epub/epub_renderer_view.dart';

void main() {
  for (final mode in ReaderMode.values) {
    for (final marker in ['• ', '10. ']) {
      testWidgets('list link covers all characters: ${mode.name} $marker', (
        tester,
      ) async {
        const label = 'Engineering';
        final body = '${marker}Before $label after';
        final start = body.indexOf(label);
        final document = EpubDocument(
          chapters: [
            EpubChapter(
              index: 0,
              href: 'chapter.xhtml',
              title: 'List',
              text: body,
              blocks: [
                EpubTextBlock(
                  startOffset: 0,
                  endOffset: body.length,
                  text: body,
                  type: EpubBlockType.paragraph,
                  listMarker: marker,
                  runs: [
                    EpubInlineRun(
                      start: start,
                      end: start + label.length,
                      style: EpubInlineStyle.link,
                      target: 'https://example.test/article',
                    ),
                  ],
                ),
              ],
            ),
          ],
        );
        final events = <RendererEvent>[];
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: EpubRendererView(
                book: const Book(
                  id: 'list-book',
                  title: 'List',
                  format: BookFormat.epub,
                  libraryFilePath: '/unused.epub',
                  fileHash: 'hash',
                  fileSize: 0,
                  createdAt: 0,
                  updatedAt: 0,
                ),
                settings: ReaderSettings(readerMode: mode),
                initialProgress: null,
                annotations: const [],
                onEvent: events.add,
                documentLoader: _MemoryLoader(document),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final paragraph = tester
            .widgetList<Text>(find.byType(Text))
            .singleWhere(
              (widget) =>
                  widget.textSpan?.toPlainText() == 'Before $label after',
            );
        final linked = StringBuffer();
        final colored = StringBuffer();
        paragraph.textSpan!.visitChildren((span) {
          if (span is TextSpan) {
            if (span.recognizer is TapGestureRecognizer) {
              linked.write(span.text ?? '');
            }
            if (span.style?.color == ReaderThemePreset.day.link) {
              colored.write(span.text ?? '');
            }
          }
          return true;
        });
        expect(colored.toString(), label);
        expect(linked.toString(), label);
        await tester.tapOnText(
          find.textRange.ofSubstring(
            label,
            descendentOf: find.byType(EpubRendererView),
          ),
        );
        expect(
          events.whereType<RendererExternalLinkRequested>().single.uri,
          'https://example.test/article',
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}

final class _MemoryLoader implements BookDocumentLoader {
  const _MemoryLoader(this.document);

  final EpubDocument document;

  @override
  Future<EpubDocument> load(String filePath) async => document;
}
