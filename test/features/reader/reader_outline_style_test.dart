import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pagesage/app/theme/app_theme.dart';
import 'package:pagesage/domain/books/reading_position.dart';
import 'package:pagesage/features/reader/presentation/reader_document_outline.dart';
import 'package:pagesage/features/reader/presentation/reader_pdf_outline.dart';
import 'package:pagesage/renderers/common/renderer_event.dart';
import 'package:pagesage/renderers/epub/epub_document.dart';

import '../../support/reader_workbench_capture.dart';

const _document = EpubDocument(
  chapters: [
    EpubChapter(
      index: 0,
      href: 'chapter.xhtml',
      title: 'Chapter',
      text: 'Source text',
    ),
  ],
  toc: [
    EpubTocItem(
      title: '第一章 · 阅读与理解',
      href: 'chapter.xhtml',
      chapterIndex: 0,
      children: [
        EpubTocItem(
          title: '1.1 基础概念',
          href: 'chapter.xhtml#concepts',
          chapterIndex: 0,
          chapterOffset: 10,
          children: [
            EpubTocItem(
              title: '1.1.1 核心定义',
              href: 'chapter.xhtml#definitions',
              chapterIndex: 0,
              chapterOffset: 20,
            ),
          ],
        ),
        EpubTocItem(
          title: '1.2 应用与示例',
          href: 'chapter.xhtml#examples',
          chapterIndex: 0,
          chapterOffset: 40,
        ),
      ],
    ),
  ],
);

void main() {
  setUpAll(() async {
    if (captureWorkbench) await loadWorkbenchCaptureFonts();
  });

  testWidgets(
    'web outline initially expands every branch and respects manual collapse',
    (tester) async {
      final document = EpubDocument(
        chapters: _document.chapters,
        toc: [
          ..._document.toc,
          const EpubTocItem(
            title: '未读分支',
            href: 'article.xhtml',
            chapterIndex: 0,
            chapterOffset: 80,
            children: [
              EpubTocItem(
                title: '未读分支第二层',
                href: 'article.xhtml',
                chapterIndex: 0,
                chapterOffset: 90,
                children: [
                  EpubTocItem(
                    title: '未读分支第三层',
                    href: 'article.xhtml',
                    chapterIndex: 0,
                    chapterOffset: 100,
                  ),
                ],
              ),
            ],
          ),
        ],
        sourceLocator: ReadingLocator.web(
          webChapterId: 'web-chapter',
          snapshotId: 'snapshot',
          sourceRevision: 'source',
          textRevision: 'text',
        ),
      );
      Future<void> mount(EpubDocument value, int offset) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReaderDocumentOutline(
              document: value,
              chapterIndex: 0,
              chapterOffset: offset,
              onSelected: (_) {},
            ),
          ),
        ),
      );
      await mount(document, 0);
      await tester.pumpAndSettle();
      expect(find.text('1.1.1 核心定义'), findsOneWidget);
      expect(find.text('未读分支第三层'), findsOneWidget);
      final branch = find.ancestor(
        of: find.text('未读分支'),
        matching: find.byType(ListTile),
      );
      await tester.tap(
        find.descendant(of: branch, matching: find.byTooltip('折叠')),
      );
      await tester.pump();
      await mount(document, 2);
      await tester.pumpAndSettle();
      expect(find.text('未读分支第二层'), findsNothing);
      await mount(
        EpubDocument(
          chapters: document.chapters,
          toc: document.toc,
          sourceLocator: document.sourceLocator,
        ),
        0,
      );
      await tester.pumpAndSettle();
      expect(find.text('未读分支第三层'), findsOneWidget);
    },
  );

  testWidgets(
    'reflow outline has one active heading, visible ancestors and no percentage/path/icon noise',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: SizedBox(
              width: 320,
              child: ReaderDocumentOutline(
                document: _document,
                chapterIndex: 0,
                chapterOffset: 25,
                onSelected: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final tiles = tester.widgetList<ListTile>(find.byType(ListTile));
      expect(tiles.where((tile) => tile.selected), hasLength(1));
      expect(find.text('0%'), findsNothing);
      expect(find.text('chapter.xhtml'), findsNothing);
      expect(find.byIcon(Icons.article_outlined), findsNothing);
      expect(
        tester.getTopLeft(find.text('1.1.1 核心定义')).dx,
        greaterThan(tester.getTopLeft(find.text('1.1 基础概念')).dx),
      );
      expect(
        tester.getTopLeft(find.text('1.1 基础概念')).dx,
        greaterThan(tester.getTopLeft(find.text('第一章 · 阅读与理解')).dx),
      );
      await tester.tap(find.byTooltip('折叠').first);
      await tester.pump();
      expect(find.text('1.1 基础概念'), findsNothing);
      await tester.pump();
      expect(find.text('1.1 基础概念'), findsNothing);
    },
  );

  testWidgets(
    'filtered PDF outline keeps ancestor context and shows page numbers once',
    (tester) async {
      const items = [
        RendererOutlineItem(title: '第一章 · 阅读与理解', page: 1),
        RendererOutlineItem(title: '1.1 基础概念', page: 2, level: 1),
        RendererOutlineItem(
          title: '1.1.1 核心定义',
          page: 2,
          level: 2,
          offsetFraction: .4,
        ),
        RendererOutlineItem(title: '第二章', page: 5),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReaderPdfOutline(
              items: items,
              currentPage: 2,
              pageOffsetFraction: .5,
              filter: '核心',
              onSelected: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('第一章 · 阅读与理解'), findsOneWidget);
      expect(find.text('1.1 基础概念'), findsOneWidget);
      expect(find.text('第二章'), findsNothing);
      expect(find.byType(CircleAvatar), findsNothing);
      expect(find.text('第 2 页'), findsNothing);
      final selected = tester
          .widgetList<ListTile>(find.byType(ListTile))
          .where((row) => row.selected);
      expect(selected, hasLength(1));
      expect((selected.single.title as Text).data, '1.1.1 核心定义');
    },
  );

  testWidgets(
    'PDF collapse survives location rebuild and nested destinations remain exact',
    (tester) async {
      const items = [
        RendererOutlineItem(title: '章', page: 1),
        RendererOutlineItem(title: '节', page: 2, level: 1, offsetFraction: .4),
      ];
      final selected = <RendererOutlineItem>[];
      Future<void> mount(double offset) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReaderPdfOutline(
              items: items,
              currentPage: 2,
              pageOffsetFraction: offset,
              onSelected: selected.add,
            ),
          ),
        ),
      );
      await mount(.5);
      await tester.pumpAndSettle();
      await tester.tap(find.text('节'));
      expect(selected.single.offsetFraction, .4);
      await tester.tap(find.byTooltip('折叠'));
      await tester.pump();
      expect(find.text('节'), findsNothing);
      await mount(.6);
      expect(find.text('节'), findsNothing);
    },
  );

  for (final dark in [false, true]) {
    testWidgets(
      'outline capture ${dark ? 'mobile dark large type' : 'desktop light'}',
      (tester) async {
        final size = dark ? const Size(360, 760) : const Size(740, 760);
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          MaterialApp(
            theme: dark ? AppTheme.dark() : AppTheme.light(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(dark ? 1.7 : 1)),
              child: child!,
            ),
            home: RepaintBoundary(
              key: workbenchCaptureKey,
              child: Scaffold(
                appBar: AppBar(title: const Text('目录')),
                body: ReaderDocumentOutline(
                  document: _document,
                  chapterIndex: 0,
                  chapterOffset: 25,
                  onSelected: (_) {},
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await captureWorkbenchWidget(
          tester,
          dark ? 'outline-mobile-dark' : 'outline-desktop-light',
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
