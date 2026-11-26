import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:pagesage/app/theme/app_theme.dart';
import 'package:pagesage/core/database/database_providers.dart';
import 'package:pagesage/core/files/file_providers.dart';
import 'package:pagesage/core/security/secure_store.dart';
import 'package:pagesage/domain/books/book.dart';
import 'package:pagesage/domain/books/reader_settings.dart';
import 'package:pagesage/domain/books/reading_position.dart';
import 'package:pagesage/domain/translation/translation_models.dart';
import 'package:pagesage/features/translation/application/translation_providers.dart';
import 'package:pagesage/renderers/common/translation_pair.dart';
import 'package:pagesage/features/reader/presentation/reader_desktop_toc_pane.dart';
import 'package:pagesage/features/reader/presentation/reader_page.dart';
import 'package:pagesage/features/reader/presentation/reader_pdf_toolbar.dart';
import 'package:pagesage/features/reader/presentation/reader_mobile_chrome.dart';
import 'package:pagesage/features/settings/presentation/settings_page.dart';
import 'package:pagesage/features/web_books/data/article_extractor.dart';
import 'package:pagesage/features/web_books/application/web_book_providers.dart';
import 'package:pagesage/features/web_books/presentation/web_book_page.dart';
import 'package:pagesage/renderers/epub/epub_renderer_view.dart';
import 'package:pagesage/renderers/pdf/pdf_canvas_view.dart';

import '../../support/reader_workbench_capture.dart';
import '../translation/reading_translation_fixture.dart';
import 'web_book_fixture.dart';

void main() {
  late WebBookFixture fixture;
  late ProviderContainer container;
  var webRepositoryReads = 0;
  late FakeReadingTranslator translator;
  setUpAll(() async {
    if (captureWorkbench) {
      await loadWorkbenchCaptureFonts();
      final path = Platform.environment['PAGESAGE_WEB_MONO_FONT'];
      if (path == null) throw StateError('截图需设置 PAGESAGE_WEB_MONO_FONT');
      final bytes = await File(path).readAsBytes();
      await (FontLoader(
        'monospace',
      )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
    }
  });
  setUp(() async {
    fixture = await WebBookFixture.create();
    webRepositoryReads = 0;
    translator = FakeReadingTranslator();
    container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(fixture.database),
        appPathsProvider.overrideWithValue(fixture.paths),
        secureStoreProvider.overrideWithValue(SecureStore.memory()),
        translationGatewayProvider.overrideWithValue(translator),
        webBookRepositoryProvider.overrideWith((ref) {
          webRepositoryReads++;
          return fixture.repository;
        }),
      ],
    );
  });
  tearDown(() async {
    container.dispose();
    await fixture.dispose();
  });

  Future<void> settle(WidgetTester tester) async {
    for (var round = 0; round < 25; round++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  Future<Book> seed() async {
    final book = await fixture.service.create('网络书阅读验证');
    for (final name in ['甲', '乙']) {
      final chapter = await fixture.repository.addChapter(
        book.id,
        'https://fixture.test/$name',
      );
      final expected = await fixture.repository.beginCapture(chapter.id);
      final article = const ArticleExtractor().extract(
        source:
            '<html><head><title>$name 网页</title></head><body><article>'
            '<h1>$name 网页阅读</h1><h2>结构与来源</h2><p>${'这是一段离线阅读正文，保留章节身份和原文版本。' * 20}</p>'
            '<h2>代码示例</h2><pre><code>final chapter = "$name";</code></pre>'
            '</article></body></html>',
        pageUrl: Uri.parse(chapter.url),
      );
      final snapshot = await fixture.store.write(
        chapter: expected,
        article: article,
        finalUrl: Uri.parse(chapter.url),
        images: const {},
      );
      await fixture.repository.publish(expected, snapshot);
    }
    return book;
  }

  Future<void> mount(
    WidgetTester tester,
    Widget page, {
    bool dark = false,
    Size size = const Size(1280, 850),
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: dark ? AppTheme.dark() : AppTheme.light(),
          home: MediaQuery(
            data: MediaQueryData(size: size),
            child: RepaintBoundary(key: workbenchCaptureKey, child: page),
          ),
        ),
      ),
    );
    await settle(tester);
  }

  testWidgets(
    'ordinary Markdown reading and disposal never instantiate a web repository',
    (tester) async {
      await tester.runAsync(() async {
        final file = File('${fixture.root.path}/ordinary.md');
        await file.writeAsString('# 普通 Markdown\n\n原有阅读路径仍独立工作。');
        await fixture.books.createImportedBook(
          NewBookDraft(
            id: 'ordinary',
            title: '普通文档',
            format: BookFormat.markdown,
            originalFilePath: file.path,
            libraryFilePath: file.path,
            fileHash: 'ordinary-hash',
            fileSize: await file.length(),
            createdAt: 1,
          ),
        );
      });
      await mount(tester, const ReaderPage(bookId: 'ordinary'));
      expect(find.byType(EpubRendererView), findsOneWidget);
      expect(webRepositoryReads, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(webRepositoryReads, 0);
    },
  );

  testWidgets('create action opens manager and writes a real web book', (
    tester,
  ) async {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, _) => Scaffold(
            body: Consumer(
              builder: (context, ref, _) => FilledButton(
                onPressed: () => createWebBook(context, ref),
                child: const Text('新建网络书'),
              ),
            ),
          ),
        ),
        GoRoute(
          path: '/web-book/:id',
          builder: (_, state) =>
              WebBookPage(bookId: state.pathParameters['id']!),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: router,
          theme: AppTheme.light(),
        ),
      ),
    );
    await tester.tap(find.text('新建网络书'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '我的网络书');
    await tester.tap(find.text('创建'));
    await settle(tester);
    expect(find.text('网络书章节'), findsOneWidget);
    expect(find.text('还没有章节，先添加一个网页地址'), findsOneWidget);
    final books = await tester.runAsync(fixture.books.getLibrary);
    expect(books!.single.book.format, BookFormat.web);
    expect(books.single.book.title, '我的网络书');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final size in [const Size(1280, 850), const Size(430, 900)]) {
    testWidgets(
      'network chapter manager fits $size and keeps actions accessible',
      (tester) async {
        final book = (await tester.runAsync(seed))!;
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await mount(
          tester,
          WebBookPage(bookId: book.id),
          dark: size.width < 500,
          size: size,
        );
        expect(find.text('甲 网页阅读'), findsOneWidget);
        expect(find.text('乙 网页阅读'), findsOneWidget);
        expect(find.byTooltip('添加并保存网页'), findsOneWidget);
        await tester.tap(find.byTooltip('章节操作').first);
        await tester.pumpAndSettle();
        expect(find.text('刷新这一章'), findsOneWidget);
        await tester.tap(find.text('修改章节名'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).last, '重新命名的章节');
        await tester.tap(find.text('保存'));
        await settle(tester);
        expect(find.text('重新命名的章节'), findsOneWidget);
        await captureWorkbenchWidget(
          tester,
          'web-manager-${size.width.toInt()}',
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'reader opens one native page, separates outline and changes chapter without sidebar jump',
    (tester) async {
      final book = (await tester.runAsync(seed))!;
      await tester.binding.setSurfaceSize(const Size(1280, 850));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.runAsync(
        () => container
            .read(settingsRepositoryProvider)
            .saveReaderSettings(const ReaderSettings(desktopTocOpen: true)),
      );
      await tester.runAsync(() async {
        final chapters = await fixture.repository.chapters(book.id);
        for (final chapter in chapters) {
          final snapshot = (await fixture.repository.snapshot(
            chapter.snapshotId!,
          ))!;
          await container
              .read(annotationRepositoryProvider)
              .saveAnnotation(
                bookId: book.id,
                locator: snapshot.locator.withWebPosition(
                  chapterOffset: 0,
                  chapterEndOffset: 2,
                ),
                selectedText: '网页',
              );
        }
        final first = (await fixture.repository.snapshot(
          chapters.first.snapshotId!,
        ))!;
        await container
            .read(annotationRepositoryProvider)
            .saveAnnotation(
              bookId: book.id,
              locator: ReadingLocator.web(
                webChapterId: first.chapterId,
                snapshotId: 'historical-snapshot',
                sourceRevision: 'historical-source',
                textRevision: 'historical-text',
                chapterIndex: 0,
                chapterOffset: 0,
                chapterEndOffset: 2,
              ),
              selectedText: '历史批注',
            );
      });
      await mount(tester, ReaderPage(bookId: book.id));
      expect(find.byType(EpubRendererView), findsOneWidget);
      expect(
        tester
            .widget<EpubRendererView>(find.byType(EpubRendererView))
            .annotations,
        hasLength(1),
      );
      expect(find.text('章节'), findsOneWidget);
      expect(find.text('本页大纲'), findsOneWidget);
      final firstPath = tester
          .widget<EpubRendererView>(find.byType(EpubRendererView))
          .documentPath;
      await tester.tap(find.widgetWithText(ListTile, '乙 网页阅读'));
      await settle(tester);
      final nextPath = tester
          .widget<EpubRendererView>(find.byType(EpubRendererView))
          .documentPath;
      expect(nextPath, isNot(firstPath));
      expect(nextPath, contains('/snapshots/'));
      expect(
        tester
            .widget<EpubRendererView>(find.byType(EpubRendererView))
            .annotations,
        hasLength(1),
      );
      await tester.tap(find.text('本页大纲'));
      await settle(tester);
      final selected = tester
          .widgetList<ListTile>(
            find.descendant(
              of: find.byType(DesktopTocPane),
              matching: find.byType(ListTile),
            ),
          )
          .where((tile) => tile.selected);
      expect(selected, hasLength(1));
      final expand = find.descendant(
        of: find.byType(DesktopTocPane),
        matching: find.byTooltip('展开'),
      );
      if (expand.evaluate().isNotEmpty) {
        await tester.tap(expand.first);
        await tester.pump();
      }
      final beforeJump = tester
          .widget<EpubRendererView>(find.byType(EpubRendererView))
          .jumpToken;
      final heading = find.descendant(
        of: find.byType(DesktopTocPane),
        matching: find.widgetWithText(ListTile, '代码示例'),
      );
      expect(heading, findsOneWidget);
      await tester.tap(heading);
      await settle(tester);
      expect(
        tester
            .widget<EpubRendererView>(find.byType(EpubRendererView))
            .jumpToken,
        greaterThan(beforeJump),
      );
      final locator = tester
          .widget<EpubRendererView>(find.byType(EpubRendererView))
          .focusLocator!;
      expect(locator.type, ReadingLocatorType.web);
      expect(locator.chapterOffset, greaterThan(0));
      await tester.pump(const Duration(milliseconds: 1700));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<EpubRendererView>(find.byType(EpubRendererView))
            .focusLocator,
        isNull,
      );
      await tester.tap(find.byTooltip('收起目录').first);
      await settle(tester);
      expect(
        tester
            .widget<EpubRendererView>(find.byType(EpubRendererView))
            .documentPath,
        nextPath,
      );
      await tester.tap(find.byTooltip('目录').first);
      await settle(tester);
      await captureWorkbenchWidget(tester, 'web-reader-desktop');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(
        () => container.read(bookRepositoryProvider).getProgress(book.id),
      );
    },
  );

  testWidgets(
    'PDF reader comparison replaces floating tools and closing restores them without losing the native canvas',
    (tester) async {
      const bookId = 'pdf-comparison-root';
      await tester.runAsync(() async {
        final file = File('poc_pdf_canvas/samples/standard-text.pdf').absolute;
        await fixture.books.createImportedBook(
          NewBookDraft(
            id: bookId,
            title: 'PDF 对照阅读',
            format: BookFormat.pdf,
            originalFilePath: file.path,
            libraryFilePath: file.path,
            fileHash: 'sample',
            fileSize: await file.length(),
            createdAt: 1,
          ),
        );
      });
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await mount(
        tester,
        const ReaderPage(bookId: bookId),
        size: const Size(1440, 900),
      );
      expect(find.byType(PdfQuickToolbar), findsOneWidget);
      final originalState = tester.state(find.byType(PdfCanvasView));
      await tester.tap(find.byTooltip('对照翻译'));
      await settle(tester);
      expect(find.byType(PdfQuickToolbar), findsNothing);
      expect(find.byTooltip('关闭对照翻译'), findsOneWidget);
      expect(tester.state(find.byType(PdfCanvasView)), same(originalState));
      await tester.tap(find.byTooltip('翻译设置'));
      await settle(tester);
      expect(find.byType(SettingsPage), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '返回阅读'));
      await settle(tester);
      expect(find.byType(SettingsPage), findsNothing);
      expect(tester.state(find.byType(PdfCanvasView)), same(originalState));
      await tester.tap(find.byTooltip('关闭对照翻译'));
      await settle(tester);
      expect(find.byType(PdfQuickToolbar), findsOneWidget);
      expect(tester.state(find.byType(PdfCanvasView)), same(originalState));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'real web reader exposes paired translation, preserves native renderer and reuses saved units',
    (tester) async {
      final book = (await tester.runAsync(seed))!;
      await tester.runAsync(
        () => container
            .read(translationSettingsRepositoryProvider)
            .saveProfile(
              const TranslationProfile(
                id: 'service',
                name: '本地测试翻译',
                provider: TranslationProvider.custom,
                protocol: TranslationProtocol.libreTranslate,
                endpoint: 'http://127.0.0.1:1234/translate',
                requestIntervalMs: 0,
              ),
            ),
      );
      await tester.binding.setSurfaceSize(const Size(1500, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await mount(
        tester,
        ReaderPage(bookId: book.id),
        size: const Size(1500, 900),
      );
      final originalState = tester.state(find.byType(EpubRendererView));
      await tester.tap(find.byTooltip('对照翻译'));
      await settle(tester);
      expect(tester.state(find.byType(EpubRendererView)), same(originalState));
      expect(find.byType(TranslationPair), findsWidgets);
      expect(translator.calls, isEmpty);
      await tester.tap(find.text('翻译当前网页'));
      await settle(tester);
      for (
        var round = 0;
        round < 80 && find.text('取消').evaluate().isNotEmpty;
        round++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 15)),
        );
        await tester.pump(const Duration(milliseconds: 25));
      }
      expect(find.text('取消'), findsNothing);
      final requests = translator.calls.length;
      expect(requests, greaterThan(0));
      expect(
        translator.calls.any((text) => text.contains('final chapter')),
        isFalse,
      );
      final renderer = tester.widget<EpubRendererView>(
        find.byType(EpubRendererView),
      );
      expect(renderer.translation?.texts, isNotEmpty);
      final readerScroll = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byType(EpubRendererView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(readerScroll.position.maxScrollExtent, greaterThan(0));
      readerScroll.position.jumpTo(
        readerScroll.position.maxScrollExtent.clamp(0, 120).toDouble(),
      );
      await settle(tester);
      final offsetBeforeSettings = readerScroll.position.pixels;
      await tester.tap(find.byTooltip('翻译设置'));
      await settle(tester);
      expect(find.byType(SettingsPage), findsOneWidget);
      await tester.tap(find.text('阅读').first);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '返回阅读'));
      await settle(tester);
      expect(tester.state(find.byType(EpubRendererView)), same(originalState));
      expect(
        tester
            .widget<EpubRendererView>(find.byType(EpubRendererView))
            .documentPath,
        renderer.documentPath,
      );
      expect(readerScroll.position.pixels, closeTo(offsetBeforeSettings, 1));
      expect(translator.calls.length, requests);
      await captureWorkbenchWidget(tester, 'web-reader-bilingual');
      await tester.tap(find.byTooltip('关闭对照翻译'));
      await settle(tester);
      expect(tester.state(find.byType(EpubRendererView)), same(originalState));
      await tester.tap(find.byTooltip('对照翻译'));
      await settle(tester);
      expect(
        tester
            .widget<EpubRendererView>(find.byType(EpubRendererView))
            .translation
            ?.texts,
        isNotEmpty,
      );
      expect(translator.calls.length, requests);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'mobile reader opens chapter and page outline sheet after component extraction',
    (tester) async {
      final book = (await tester.runAsync(seed))!;
      await tester.binding.setSurfaceSize(const Size(430, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await mount(
        tester,
        ReaderPage(bookId: book.id),
        size: const Size(430, 900),
      );
      expect(find.byType(MobileReaderBottomBar), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byType(MobileReaderBottomBar),
          matching: find.text('目录'),
        ),
      );
      await settle(tester);
      expect(find.widgetWithText(Tab, '章节'), findsOneWidget);
      expect(find.widgetWithText(Tab, '本页大纲'), findsOneWidget);
      await tester.tap(find.widgetWithText(Tab, '本页大纲'));
      await settle(tester);
      await captureWorkbenchWidget(tester, 'web-reader-mobile-outline');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
