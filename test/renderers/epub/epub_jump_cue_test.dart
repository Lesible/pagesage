import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pagesage/domain/annotations/annotation.dart';
import 'package:pagesage/domain/books/book.dart';
import 'package:pagesage/domain/books/reader_settings.dart';
import 'package:pagesage/domain/books/reading_position.dart';
import 'package:pagesage/renderers/common/book_document_loader.dart';
import 'package:pagesage/renderers/epub/epub_document.dart';
import 'package:pagesage/renderers/epub/epub_renderer_view.dart';

import '../../support/reader_workbench_capture.dart';

const _text = 'Persistence\n\nRead, understand, and keep your notes.';
const _document = EpubDocument(
  chapters: [
    EpubChapter(
      index: 0,
      href: 'article.xhtml',
      title: 'Persistence',
      text: _text,
      blocks: [
        EpubTextBlock(
          startOffset: 0,
          endOffset: 11,
          text: 'Persistence',
          type: EpubBlockType.heading,
          headingLevel: 1,
        ),
        EpubTextBlock(
          startOffset: 13,
          endOffset: _text.length,
          text: 'Read, understand, and keep your notes.',
          type: EpubBlockType.paragraph,
        ),
      ],
    ),
  ],
);
const _book = Book(
  id: 'jump-book',
  title: 'Persistence',
  format: BookFormat.web,
  libraryFilePath: '/unused',
  fileHash: 'hash',
  fileSize: 0,
  createdAt: 0,
  updatedAt: 0,
);

void main() {
  setUpAll(() async {
    if (captureWorkbench) await loadWorkbenchCaptureFonts();
  });

  for (final mode in ReaderMode.values) {
    testWidgets(
      'section cue covers a block without tinting its first letter: ${mode.name}',
      (tester) async {
        Future<void> mount(ReadingLocator? focus) => tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: EpubRendererView(
                book: _book,
                settings: ReaderSettings(readerMode: mode),
                initialProgress: null,
                annotations: const [],
                focusLocator: focus,
                onEvent: (_) {},
                documentLoader: const _Loader(),
              ),
            ),
          ),
        );
        await mount(null);
        await tester.pumpAndSettle();
        final heading = find.descendant(
          of: find.byKey(const ValueKey('epub-jump-cue-0-0')),
          matching: find.byType(RichText),
        );
        final originalRect = tester.getRect(heading);
        await mount(ReadingLocator.epub(chapterIndex: 0, chapterOffset: 0));
        await tester.pumpAndSettle();
        expect(tester.getRect(heading), originalRect);
        final cue = tester.widget<AnimatedContainer>(
          find.byKey(const ValueKey('epub-jump-cue-0-0')),
        );
        expect((cue.decoration! as BoxDecoration).color!.a, greaterThan(0));
        final span = tester.widget<RichText>(heading).text as TextSpan;
        expect(
          _textSpans(
            span,
          ).where((child) => child.style?.backgroundColor != null),
          isEmpty,
        );
        await mount(null);
        await tester.pumpAndSettle();
        final cleared = tester.widget<AnimatedContainer>(
          find.byKey(const ValueKey('epub-jump-cue-0-0')),
        );
        expect((cleared.decoration! as BoxDecoration).color?.a ?? 0, 0);
        expect(tester.getRect(heading), originalRect);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'permanent highlight keeps its paint and recognizer during a jump cue',
    (tester) async {
      final annotation = Annotation(
        id: 'annotation',
        bookId: 'jump-book',
        locator: ReadingLocator.epub(
          chapterIndex: 0,
          chapterOffset: 0,
          chapterEndOffset: 11,
        ),
        selectedText: 'Persistence',
        color: AnnotationColor.yellow,
        style: AnnotationStyle.highlight,
        createdAt: 0,
        updatedAt: 0,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EpubRendererView(
              book: _book,
              settings: const ReaderSettings(),
              initialProgress: null,
              annotations: [annotation],
              focusLocator: ReadingLocator.epub(
                chapterIndex: 0,
                chapterOffset: 0,
              ),
              onEvent: (_) {},
              documentLoader: const _Loader(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final rich = tester.widget<RichText>(
        find.byWidgetPredicate(
          (widget) =>
              widget is RichText && widget.text.toPlainText() == 'Persistence',
        ),
      );
      final painted = _textSpans(
        rich.text,
      ).where((span) => span.style?.backgroundColor != null);
      expect(painted.single.style!.backgroundColor, const Color(0x99FFE58A));
      expect(painted.single.recognizer, isNotNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('precise focus stays scoped and search keeps its own paint', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EpubRendererView(
            book: _book,
            settings: const ReaderSettings(reduceMotion: true),
            initialProgress: null,
            annotations: const [],
            searchQuery: 'Read',
            focusLocator: ReadingLocator.epub(
              chapterIndex: 0,
              chapterOffset: 0,
              chapterEndOffset: 11,
            ),
            onEvent: (_) {},
            documentLoader: const _Loader(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final cue = tester.widget<AnimatedContainer>(
      find.byKey(const ValueKey('epub-jump-cue-0-0')),
    );
    expect(cue.duration, Duration.zero);
    expect((cue.decoration! as BoxDecoration).color?.a ?? 0, 0);
    final richText = tester.widgetList<RichText>(
      find.descendant(
        of: find.byType(EpubRendererView),
        matching: find.byType(RichText),
      ),
    );
    final painted = richText
        .expand((widget) => _textSpans(widget.text))
        .where((span) => span.style?.backgroundColor != null);
    expect(
      painted
          .singleWhere((span) => span.text == 'Persistence')
          .style!
          .backgroundColor,
      ReaderThemePreset.day.link.withValues(alpha: .15),
    );
    expect(
      painted.singleWhere((span) => span.text == 'Read').style!.backgroundColor,
      const Color(0x99FFD659),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final preset in [
    ReaderThemePreset.day,
    ReaderThemePreset.paper,
    ReaderThemePreset.warm,
    ReaderThemePreset.amber,
    ReaderThemePreset.green,
    ReaderThemePreset.sage,
    ReaderThemePreset.night,
  ]) {
    testWidgets('reading palette capture ${preset.value}', (tester) async {
      await tester.binding.setSurfaceSize(const Size(840, 520));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: preset == ReaderThemePreset.night
              ? ThemeData.dark()
              : ThemeData.light(),
          home: RepaintBoundary(
            key: workbenchCaptureKey,
            child: Scaffold(
              body: EpubRendererView(
                book: _book,
                settings: ReaderSettings(themePreset: preset, fontSize: 22),
                initialProgress: null,
                annotations: const [],
                focusLocator: ReadingLocator.epub(
                  chapterIndex: 0,
                  chapterOffset: 0,
                ),
                onEvent: (_) {},
                documentLoader: const _Loader(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await captureWorkbenchWidget(tester, 'reading-palette-${preset.value}');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}

Iterable<TextSpan> _textSpans(InlineSpan span) sync* {
  if (span is TextSpan) {
    yield span;
    for (final child in span.children ?? const <InlineSpan>[]) {
      yield* _textSpans(child);
    }
  }
}

final class _Loader implements BookDocumentLoader {
  const _Loader();

  @override
  Future<EpubDocument> load(String filePath) async => _document;
}
