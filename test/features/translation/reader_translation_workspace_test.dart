import 'dart:io';

import 'package:dart_pdf_editor/dart_pdf_editor.dart' show PdfBundledSubstitute;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pagesage/app/theme/app_theme.dart';
import 'package:pagesage/core/database/database_providers.dart';
import 'package:pagesage/domain/books/book.dart';
import 'package:pagesage/domain/books/reading_position.dart';
import 'package:pagesage/domain/books/reader_settings.dart';
import 'package:pagesage/features/ocr/application/ocr_page_store.dart';
import 'package:pagesage/features/translation/application/translation_providers.dart';
import 'package:pagesage/features/translation/data/reading_translation_source.dart';
import 'package:pagesage/features/translation/presentation/reader_translation_workspace.dart';
import 'package:pagesage/renderers/common/renderer_event.dart';
import 'package:pagesage/renderers/pdf/pdf_canvas_view.dart';

import '../../support/reader_workbench_capture.dart';
import 'reading_translation_fixture.dart';

void main() {
  late ReadingTranslationFixture fixture;
  late ProviderContainer container;
  ValueChanged<RendererEvent>? rendererEvent;
  var repositoryReads = 0;
  final nativeEvents = <RendererEvent>[];
  setUpAll(() async {
    if (captureWorkbench) {
      await loadWorkbenchCaptureFonts();
      final font = File(
        '/usr/share/fonts/liberation-sans-fonts/LiberationSans-Regular.ttf',
      );
      if (await font.exists()) {
        final bytes = ByteData.sublistView(await font.readAsBytes());
        for (final family in [
          'Liberation Sans',
          PdfBundledSubstitute.heros.packageFamily,
        ]) {
          await (FontLoader(family)..addFont(Future.value(bytes))).load();
        }
      }
    }
  });
  setUp(() async {
    fixture = await ReadingTranslationFixture.create();
    repositoryReads = 0;
    nativeEvents.clear();
    container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(fixture.database),
        secureStoreProvider.overrideWithValue(fixture.secrets),
        translationSettingsRepositoryProvider.overrideWithValue(
          fixture.settings,
        ),
        translationServiceProvider.overrideWith((ref) => fixture.service),
        readingTranslationRepositoryProvider.overrideWith((ref) {
          repositoryReads++;
          return fixture.repository;
        }),
        readingTranslationSourceLoaderProvider.overrideWithValue(
          ReadingTranslationSourceLoader(
            ocrStore: DriftOcrPageStore(fixture.database.ocrPageDao),
            pdfPageReader: (_, page) async =>
                'Page $page source paragraph.\n\nSecond paragraph on page $page.',
          ),
        ),
      ],
    );
  });
  tearDown(() async {
    container.dispose();
    await fixture.dispose();
  });

  Future<void> settle(WidgetTester tester) async {
    for (var round = 0; round < 20; round++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 12)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  Future<void> mount(
    WidgetTester tester,
    int request, {
    bool dark = false,
    double scale = 1,
    bool native = false,
  }) async {
    final book = Book(
      id: 'book',
      title: 'PDF fixture',
      format: BookFormat.pdf,
      libraryFilePath: native
          ? 'poc_pdf_canvas/samples/standard-text.pdf'
          : '/fixture.pdf',
      fileHash: 'file-v1',
      fileSize: 1,
      createdAt: 1,
      updatedAt: 1,
    );
    final locator = ReadingLocator.pdf(page: native ? 2 : 1);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: dark ? AppTheme.dark() : AppTheme.light(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: RepaintBoundary(
            key: workbenchCaptureKey,
            child: Scaffold(
              body: ReaderTranslationWorkspace(
                book: book,
                request: request,
                initialLocator: locator,
                onEvent: nativeEvents.add,
                builder: (onEvent, translation) {
                  rendererEvent = onEvent;
                  if (native) {
                    return PdfCanvasView(
                      key: const ValueKey('native-pdf-comparison'),
                      book: book,
                      settings: const ReaderSettings(),
                      initialProgress: ReadingProgressSnapshot(
                        bookId: 'book',
                        locator: locator,
                        progress: .5,
                        updatedAt: 1,
                      ),
                      annotations: const [],
                      onEvent: onEvent,
                    );
                  }
                  return const ColoredBox(
                    color: Color(0xFFEEEDE7),
                    child: Center(
                      child: Text(
                        'PDF original page',
                        style: TextStyle(color: Colors.black),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    await settle(tester);
    if (native) {
      await tester.runAsync(() async {
        for (var round = 0; round < 60; round++) {
          await tester.pump(const Duration(milliseconds: 25));
          await Future<void>.delayed(const Duration(milliseconds: 25));
          if (nativeEvents.whereType<RendererLocationChanged>().isNotEmpty) {
            break;
          }
        }
      });
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  testWidgets(
    'PDF comparison initializes lazily, follows pages, saves locally and reopens without a request',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1100, 850));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await mount(tester, 0);
      expect(repositoryReads, 0);
      await mount(tester, 1);
      expect(repositoryReads, 1);
      expect(fixture.gateway.calls, isEmpty);
      await tester.tap(find.text('翻译本页'));
      await settle(tester);
      expect(fixture.gateway.calls, hasLength(2));
      expect(find.text('译文：Page 1 source paragraph.'), findsOneWidget);
      final original = tester.getRect(find.text('PDF original page'));
      final translated = tester.getRect(
        find.text('译文：Page 1 source paragraph.'),
      );
      expect(original.center.dx, lessThan(translated.left));
      await captureWorkbenchWidget(tester, 'pdf-translation-desktop');
      await tester.tap(find.byTooltip('关闭对照翻译'));
      await settle(tester);
      await mount(tester, 2);
      expect(find.text('译文：Page 1 source paragraph.'), findsOneWidget);
      expect(fixture.gateway.calls, hasLength(2));
      rendererEvent!(
        RendererLocationChanged(
          locator: ReadingLocator.pdf(page: 2),
          progress: .5,
          pageNumber: 2,
        ),
      );
      await settle(tester);
      expect(find.text('第 2 页 · 译文'), findsOneWidget);
      expect(find.text('译文：Page 1 source paragraph.'), findsNothing);
      expect(fixture.gateway.calls, hasLength(2));
      await tester.tap(find.text('翻译本页'));
      await settle(tester);
      expect(fixture.gateway.calls, hasLength(4));
      expect(find.text('译文：Page 2 source paragraph.'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'closing PDF comparison from translated-only mode restores the original canvas',
    (tester) async {
      await mount(tester, 0);
      await mount(tester, 1);
      await tester.tap(find.byTooltip('阅读方式'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(MenuItemButton, '仅译文'));
      await settle(tester);
      expect(find.text('PDF original page'), findsNothing);
      await tester.tap(find.byTooltip('关闭对照翻译'));
      await settle(tester);
      expect(find.text('PDF original page').hitTestable(), findsOneWidget);
      expect(find.text('第 1 页 · 译文'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'native PDF canvas retains page and instance while opening and closing comparison',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1100, 850));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await mount(tester, 0, native: true);
      final state = tester.state(find.byType(PdfCanvasView));
      expect(
        nativeEvents.whereType<RendererLocationChanged>(),
        isNotEmpty,
        reason: nativeEvents.map((event) => event.runtimeType).join(', '),
      );
      expect(
        nativeEvents.whereType<RendererLocationChanged>().last.locator.page,
        2,
      );
      await mount(tester, 1, native: true);
      expect(tester.state(find.byType(PdfCanvasView)), same(state));
      expect(
        nativeEvents.whereType<RendererLocationChanged>().last.locator.page,
        2,
      );
      await tester.tap(find.text('翻译本页'));
      await settle(tester);
      expect(find.text('译文：Page 2 source paragraph.'), findsOneWidget);
      await captureWorkbenchWidget(tester, 'native-pdf-bilingual');
      await tester.tap(find.byTooltip('关闭对照翻译'));
      await settle(tester);
      expect(tester.state(find.byType(PdfCanvasView)), same(state));
      expect(
        nativeEvents.whereType<RendererLocationChanged>().last.locator.page,
        2,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'narrow dark comparison wraps controls and stacks PDF and translation without overflow',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await mount(tester, 0, dark: true, scale: 1.4);
      await mount(tester, 1, dark: true, scale: 1.4);
      await tester.tap(find.text('翻译本页'));
      await settle(tester);
      expect(
        tester.getRect(find.text('PDF original page')).bottom,
        lessThan(tester.getRect(find.text('第 1 页 · 译文')).top),
      );
      await captureWorkbenchWidget(tester, 'pdf-translation-mobile-dark');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
