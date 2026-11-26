import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pagesage/domain/books/book.dart';
import 'package:pagesage/domain/books/reader_settings.dart';
import 'package:pagesage/renderers/common/book_document_loader.dart';
import 'package:pagesage/renderers/epub/epub_document.dart';
import 'package:pagesage/renderers/epub/epub_renderer_view.dart';
import 'package:pagesage_web_capture_eval/article_extractor.dart';
import 'package:pagesage_web_capture_eval/native_article.dart';

import '../../../test/support/reader_workbench_capture.dart'
    show loadWorkbenchCaptureFonts;

void main() {
  final fixtures =
      (jsonDecode(File('fixtures/cases.json').readAsStringSync())
              as List<Object?>)
          .cast<Map<String, Object?>>();
  ArticleExtraction extract(String id) {
    return const ArticleExtractor().extract(
      source:
          fixtures.firstWhere((fixture) => fixture['id'] == id)['html']!
              as String,
      pageUrl: Uri.parse('https://example.test/articles/page.html'),
    );
  }

  test('native paragraphs use exact UTF-16 source intervals', () {
    final document = toNativeDocument(extract('unicode'));
    final chapter = document.chapters.single;
    expect(chapter.text, contains('👨‍👩‍👧'));
    for (final block in chapter.blocks.whereType<EpubTextBlock>()) {
      expect(
        chapter.text.substring(block.startOffset, block.endOffset),
        block.text,
      );
    }
    expect(document.toc.single.title, '字符 📚');
    expect(chapter.anchors, isEmpty);
  });

  test('duplicate heading labels retain distinct offsets', () {
    final document = toNativeDocument(extract('duplicate-headings'));
    final repeated = document.toc.single.children;
    expect(repeated, hasLength(2));
    expect(repeated.map((heading) => heading.title), everyElement('示例'));
    expect(
      repeated.first.chapterOffset,
      lessThan(repeated.last.chapterOffset!),
    );
    expect(
      document.chapters.single.anchors.keys,
      containsAll(['first', 'second']),
    );
    final chapter = document.chapters.single;
    expect(chapter.anchors['first'], repeated.first.chapterOffset);
    expect(chapter.anchors['second'], repeated.last.chapterOffset);
  });

  test('code indentation and literal characters reach the native model', () {
    final document = toNativeDocument(extract('code-layout'));
    final code = document.chapters.single.blocks
        .whereType<EpubTextBlock>()
        .singleWhere((block) => block.type == EpubBlockType.code);
    expect(code.text, 'if (ready) {\n  print("<done> & saved");\n}');
  });

  test('table cells retain a grid and exact source intervals', () {
    final chapter = toNativeDocument(
      extract('table-structure'),
    ).chapters.single;
    final table = chapter.blocks.whereType<EpubTableBlock>().single;
    expect(table.hasHeader, isTrue);
    expect(table.rows, [
      ['Kind', 'Count'],
      ['Article', '12'],
      ['Image', '40'],
    ]);
    for (final row in table.cells) {
      for (final cell in row) {
        expect(
          chapter.text.substring(
            cell.chapterOffset,
            cell.chapterOffset + cell.text.length,
          ),
          cell.text,
        );
      }
    }
    expect(
      chapter.text.substring(table.startOffset, table.endOffset),
      table.text,
    );
  });

  test('inline emphasis and link targets retain precise intervals', () {
    final article = const ArticleExtractor().extract(
      source:
          '<article><p>Before <strong>bold 🧪</strong> '
          '<a href="/next?x=1">link</a> after.</p></article>',
      pageUrl: Uri.parse('https://example.test/page'),
    );
    final chapter = toNativeDocument(article).chapters.single;
    final paragraph = chapter.blocks.whereType<EpubTextBlock>().single;
    final bold = paragraph.runs.singleWhere(
      (run) => run.style == EpubInlineStyle.strong,
    );
    final link = paragraph.runs.singleWhere(
      (run) => run.style == EpubInlineStyle.link,
    );
    expect(chapter.text.substring(bold.start, bold.end), 'bold 🧪');
    expect(chapter.text.substring(link.start, link.end), 'link');
    expect(link.target, 'https://example.test/next?x=1');
  });

  test('explicit line breaks differ from source formatting whitespace', () {
    final article = const ArticleExtractor().extract(
      source: '<article><p>First\n line<br>Second line.</p></article>',
      pageUrl: Uri.parse('https://example.test/page'),
    );
    final chapter = toNativeDocument(article).chapters.single;
    expect(chapter.text, 'First line\nSecond line.');
  });

  test('code in table cells preserves whitespace and link ranges', () {
    final article = const ArticleExtractor().extract(
      source:
          '<article><table><tr><td><pre>if (ready) {\n'
          '  <a href="/api">open</a>();\n}</pre></td></tr></table></article>',
      pageUrl: Uri.parse('https://example.test/page'),
    );
    final chapter = toNativeDocument(article).chapters.single;
    final cell = chapter.blocks
        .whereType<EpubTableBlock>()
        .single
        .cells
        .single
        .single;
    expect(cell.text, 'if (ready) {\n  open();\n}');
    final link = cell.runs.singleWhere(
      (run) => run.style == EpubInlineStyle.link,
    );
    expect(cell.text.substring(link.start, link.end), 'open');
    expect(link.target, 'https://example.test/api');
    expect(
      chapter.text.substring(
        cell.chapterOffset,
        cell.chapterOffset + cell.text.length,
      ),
      cell.text,
    );
  });

  test('links inside standalone code preserve source intervals', () {
    final article = const ArticleExtractor().extract(
      source:
          '<article><pre><a href="/api">open</a>();\n  close();</pre></article>',
      pageUrl: Uri.parse('https://example.test/page'),
    );
    final block = toNativeDocument(
      article,
    ).chapters.single.blocks.whereType<EpubTextBlock>().single;
    expect(block.text, 'open();\n  close();');
    final link = block.runs.singleWhere(
      (run) => run.style == EpubInlineStyle.link,
    );
    expect(block.text.substring(link.start, link.end), 'open');
  });

  test('missing local images report a placeholder without network', () {
    final document = toNativeDocument(extract('lazy-image'));
    final image = document.chapters.single.blocks
        .whereType<EpubImageBlock>()
        .single
        .image;
    expect(image.isAvailable, isFalse);
    expect(image.unavailableReason, '图片不在书中');
    expect(image.alt, '关系图');
  });

  test('provided image bytes enter the native document', () async {
    final article = extract('lazy-image');
    final bytes = await _pngBytes();
    final document = toNativeDocument(
      article,
      imageBytes: {article.images.single.localPath: bytes},
    );
    final image = document.chapters.single.blocks
        .whereType<EpubImageBlock>()
        .single
        .image;
    expect(image.isAvailable, isTrue);
    expect(image.pixelWidth, 120);
    expect(image.pixelHeight, 60);
    expect(image.bytes, bytes);
  });

  final samples = Platform.environment['PAGESAGE_WEB_SAMPLES_DIR'];
  final sampleManifest = samples == null
      ? <Map<String, Object?>>[]
      : (jsonDecode(File('$samples/manifest.json').readAsStringSync())
                as List<Object?>)
            .cast<Map<String, Object?>>();
  final captures = <({String id, ArticleExtraction article})>[
    (id: 'fixture', article: extract('english-article')),
    if (samples != null)
      for (final id in ['anthropic-writing-tools', 'langgraph-persistence'])
        (
          id: id,
          article: const ArticleExtractor().extract(
            source: File('$samples/$id.html').readAsStringSync(),
            pageUrl: Uri.parse(
              sampleManifest.singleWhere(
                    (sample) => sample['id'] == id,
                  )['finalUrl']!
                  as String,
            ),
          ),
        ),
  ];
  for (final captureCase in captures) {
    for (final theme in [ThemeData.light(), ThemeData.dark()]) {
      testWidgets(
        'native article paints offscreen: ${captureCase.id} ${theme.brightness.name}',
        (tester) async {
          final output = Platform.environment['PAGESAGE_WEB_CAPTURE_DIR'];
          if (output != null) {
            await tester.runAsync(loadWorkbenchCaptureFonts);
            await tester.runAsync(() async {
              final monoFont = Platform.environment['PAGESAGE_WEB_MONO_FONT'];
              if (monoFont == null) {
                throw StateError('离屏截图需要 PAGESAGE_WEB_MONO_FONT 字体路径');
              }
              await (FontLoader('monospace')..addFont(
                    Future.value(
                      ByteData.sublistView(await File(monoFont).readAsBytes()),
                    ),
                  ))
                  .load();
            });
          }
          tester.view.physicalSize = const Size(1100, 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          expect(captureCase.article.isReadable, isTrue);
          final document = toNativeDocument(captureCase.article);
          final capture = GlobalKey();
          await tester.pumpWidget(
            MaterialApp(
              theme: theme,
              home: RepaintBoundary(
                key: capture,
                child: Scaffold(
                  body: EpubRendererView(
                    book: const Book(
                      id: 'eval-book',
                      title: 'Web extraction prototype',
                      format: BookFormat.epub,
                      libraryFilePath: '/unused.xhtml',
                      fileHash: 'evaluation',
                      fileSize: 0,
                      createdAt: 0,
                      updatedAt: 0,
                    ),
                    settings: ReaderSettings(
                      fontSize: 20,
                      lineHeight: 1.7,
                      themePreset: theme.brightness == Brightness.dark
                          ? ReaderThemePreset.night
                          : ReaderThemePreset.day,
                    ),
                    initialProgress: null,
                    annotations: const [],
                    onEvent: (_) {},
                    documentLoader: _MemoryLoader(document),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          if (captureCase.id == 'fixture') {
            expect(
              find.textContaining('Books deserve a quiet place.'),
              findsOneWidget,
            );
          }
          if (output != null) {
            final boundary =
                capture.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            await tester.runAsync(() async {
              final image = await boundary.toImage();
              try {
                final data = await image.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                if (data == null) {
                  throw StateError('离屏截图编码失败');
                }
                final folder = Directory(output);
                await folder.create(recursive: true);
                await File(
                  '$output/${captureCase.id}-${theme.brightness.name}.png',
                ).writeAsBytes(data.buffer.asUint8List(), flush: true);
              } finally {
                image.dispose();
              }
            });
          }
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }
}

Future<Uint8List> _pngBytes() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 120, 60),
    Paint()..color = Colors.teal,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(120, 60);
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) {
      throw StateError('测试图片编码失败');
    }
    return data.buffer.asUint8List();
  } finally {
    image.dispose();
    picture.dispose();
  }
}

final class _MemoryLoader implements BookDocumentLoader {
  const _MemoryLoader(this.document);

  final EpubDocument document;

  @override
  Future<EpubDocument> load(String filePath) async => document;
}
