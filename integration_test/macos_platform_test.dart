import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pagesage/core/database/app_database.dart';
import 'package:pagesage/core/database/database_providers.dart';
import 'package:pagesage/core/files/app_paths.dart';
import 'package:pagesage/core/files/file_providers.dart';
import 'package:pagesage/core/platform/macos_folder_access.dart';
import 'package:pagesage/core/security/secure_store.dart';
import 'package:pagesage/domain/books/book.dart';
import 'package:pagesage/domain/search/search_models.dart';
import 'package:pagesage/features/import/application/import_providers.dart';
import 'package:pagesage/features/import/application/import_result.dart';
import 'package:pagesage/renderers/epub/epub_renderer_view.dart';
import 'package:pagesage/renderers/pdf/pdf_canvas_view.dart';
import 'package:path/path.dart' as p;

import '../tool/generate_manual_samples.dart';
import 'support/reader_harness.dart';

/// macOS arm64 runtime acceptance.
///
/// Everything here runs inside the sandboxed macOS application: real SQLite
/// through native assets, the real Keychain, the real Swift bookmark channel,
/// and the production reader in a real window. Samples are generated inside
/// the app container so the test never depends on reading repository files
/// that App Sandbox does not grant.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<File> writeSample(Directory dir, String name, List<int> bytes) async {
    final file = File(p.join(dir.path, name));
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  Book bookFor(
    String id,
    FileSystemEntity file,
    BookFormat format,
    String title,
  ) {
    final stat = file.statSync();
    return Book(
      id: id,
      title: title,
      format: format,
      libraryFilePath: file.absolute.path,
      fileHash: 'macos-$id',
      fileSize: stat.size,
      createdAt: stat.modified.millisecondsSinceEpoch,
      updatedAt: stat.modified.millisecondsSinceEpoch,
    );
  }

  testWidgets('imports EPUB, PDF and Markdown into the real library', (
    tester,
  ) async {
    final root = await Directory.systemTemp.createTemp(
      'pagesage_macos_import_',
    );
    final sources = await Directory.systemTemp.createTemp(
      'pagesage_macos_sources_',
    );
    addTearDown(() async {
      await root.delete(recursive: true);
      await sources.delete(recursive: true);
    });

    final epub = await writeSample(
      sources,
      'acceptance.epub',
      buildEpub(
        title: 'macOS Acceptance EPUB',
        includeNav: true,
        chapters: const [
          EpubSampleChapter(
            fileName: 'chapter1.xhtml',
            title: '第一章 macOS',
            body:
                '<h1>第一章 macOS</h1>'
                '<p>RunbookToken 用于验证真实的 macOS 导入与全文检索。</p>',
          ),
          EpubSampleChapter(
            fileName: 'chapter2.xhtml',
            title: '第二章 阅读循环',
            body: '<h1>第二章 阅读循环</h1><p>关闭后重开应恢复进度。</p>',
          ),
        ],
      ),
    );
    final pdf = await writeSample(
      sources,
      'acceptance.pdf',
      buildTextPdf(['RunbookToken page one', 'Page two', 'Page three']),
    );
    final markdown = File(p.join(sources.path, 'acceptance.md'));
    await markdown.writeAsString(
      '# macOS Markdown\n\nRunbookToken 本地 Markdown 正文。',
      flush: true,
    );

    final databaseFile = File(p.join(root.path, 'database', 'pagesage.sqlite'));
    await databaseFile.parent.create(recursive: true);
    final database = AppDatabase.forTesting(NativeDatabase(databaseFile));
    final container = ProviderContainer(
      overrides: [
        appPathsProvider.overrideWithValue(AppPaths(overrideRoot: root)),
        appDatabaseProvider.overrideWithValue(database),
        secureStoreProvider.overrideWithValue(SecureStore.memory()),
      ],
    );
    addTearDown(database.close);
    addTearDown(container.dispose);

    final imported = <Book>[];
    for (final source in [epub, pdf, markdown]) {
      final result = await container
          .read(importUseCaseProvider)
          .importPath(source.path);
      expect(result, isA<ImportBookSuccess>(), reason: '$source => $result');
      imported.add((result as ImportBookSuccess).book);
    }
    expect(
      imported.map((book) => book.format),
      containsAll([BookFormat.epub, BookFormat.pdf, BookFormat.markdown]),
    );
    for (final book in imported) {
      expect(p.isWithin(root.path, book.libraryFilePath), isTrue);
      expect(await File(book.libraryFilePath).exists(), isTrue);
    }

    final search = container.read(searchRepositoryProvider);
    var results = await search.search(const SearchQuery(query: 'RunbookToken'));
    for (var attempt = 0; attempt < 100 && results.isEmpty; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      results = await search.search(const SearchQuery(query: 'RunbookToken'));
    }
    if (results.isEmpty) {
      final indexer = container.read(searchIndexerProvider);
      for (final book in imported) {
        await indexer.indexBook(book);
      }
      results = await search.search(const SearchQuery(query: 'RunbookToken'));
    }
    expect(results, isNotEmpty);

    // Import indexing continues in the background. Let every task reach a
    // terminal state before teardown closes the database and removes the
    // temporary library.
    final books = container.read(bookRepositoryProvider);
    for (final book in imported) {
      for (var attempt = 0; attempt < 100; attempt++) {
        final status = (await books.getBook(book.id))?.indexingStatus;
        if (status == 'done' || status == 'failed') break;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('opens PDF, jumps pages and restores progress after reopen', (
    tester,
  ) async {
    final dir = await Directory.systemTemp.createTemp('pagesage_macos_pdf_');
    addTearDown(() => dir.delete(recursive: true));
    final file = await writeSample(
      dir,
      'reading.pdf',
      buildTextPdf(['Page one', 'Page two', 'Page three']),
    );
    final book = bookFor('macos-pdf', file, BookFormat.pdf, 'macOS PDF');
    final harness = await ReaderHarness.create(books: [book]);
    addTearDown(harness.dispose);

    await harness.pumpReader(tester, book.id, size: const Size(1280, 800));
    expect(find.byType(PdfCanvasView), findsOneWidget);
    expect(find.textContaining('1 / 3'), findsWidgets);

    final reveal = find.byTooltip('显示阅读工具').hitTestable();
    if (reveal.evaluate().isNotEmpty) {
      await tester.tap(reveal);
      await tester.pump(const Duration(milliseconds: 250));
    }
    await tester.tap(find.byTooltip('跳转页码').hitTestable().first);
    await harness.settle(tester, rounds: 10);
    await tester.enterText(find.byType(TextField).last, '3');
    await tester.tap(find.text('跳转'));
    await harness.settle(tester);
    expect(find.textContaining('3 / 3'), findsWidgets);

    await harness.closeReader(tester);
    final stored = await harness.database.progressDao.getProgress(book.id);
    expect(stored?.pageNumber, 3);

    await harness.pumpReader(tester, book.id, size: const Size(1280, 800));
    expect(find.textContaining('3 / 3'), findsWidgets);
    expect(tester.takeException(), isNull);
    await harness.capture('macos-01-pdf-restored');
    await harness.closeReader(tester);
  });

  testWidgets('opens an EPUB and a Markdown folder in the real window', (
    tester,
  ) async {
    final dir = await Directory.systemTemp.createTemp('pagesage_macos_epub_');
    final folder = await Directory.systemTemp.createTemp(
      'pagesage_macos_md_folder_',
    );
    addTearDown(() async {
      await dir.delete(recursive: true);
      await folder.delete(recursive: true);
    });
    final epub = await writeSample(
      dir,
      'reading.epub',
      buildEpub(
        title: 'macOS EPUB',
        includeNav: true,
        chapters: const [
          EpubSampleChapter(
            fileName: 'chapter1.xhtml',
            title: '第一章 macOS',
            body: '<h1>第一章 macOS</h1><p>EPUB 正文在真实窗口中渲染。</p>',
          ),
        ],
      ),
    );
    await File(p.join(folder.path, 'a.md')).writeAsString('# 甲章\n\n正文甲。');
    await Directory(p.join(folder.path, 'sub')).create();
    await File(
      p.join(folder.path, 'sub', 'b.md'),
    ).writeAsString('# 乙章\n\n## 乙小节\n\n正文乙。');

    final harness = await ReaderHarness.create(
      books: [
        bookFor('macos-epub', epub, BookFormat.epub, 'macOS EPUB'),
        bookFor(
          'macos-md-folder',
          Directory(folder.path),
          BookFormat.markdown,
          'macOS 笔记库',
        ),
      ],
    );
    addTearDown(harness.dispose);

    await harness.pumpReader(tester, 'macos-epub', size: const Size(1280, 900));
    await harness.settle(tester, rounds: 20);
    expect(find.byType(EpubRendererView), findsOneWidget);
    expect(find.textContaining('第一章 macOS'), findsWidgets);
    await harness.closeReader(tester);

    await harness.pumpReader(
      tester,
      'macos-md-folder',
      size: const Size(1280, 900),
    );
    await harness.settle(tester, rounds: 20);
    expect(find.byType(EpubRendererView), findsOneWidget);
    expect(find.textContaining('正文甲'), findsWidgets);
    await tester.tap(find.text('文件').first);
    await tester.pump();
    expect(find.text('sub'), findsWidgets);
    await tester.tap(find.text('sub').first);
    await tester.pump();
    expect(find.text('b'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await harness.capture('macos-02-markdown-folder');
    await harness.closeReader(tester);
  });

  testWidgets('round-trips an API key through the macOS Keychain', (
    tester,
  ) async {
    const key = 'pagesage.acceptance.keychain';
    const value = 'acceptance-only-not-a-real-key';
    final store = SecureStore();
    await store.delete(key);
    try {
      await store.write(key, value);
      expect(await store.read(key), value);
    } finally {
      await store.delete(key);
    }
    expect(await store.read(key), isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('persists a native folder bookmark across instances', (
    tester,
  ) async {
    final folder = await Directory.systemTemp.createTemp(
      'pagesage_macos_bookmark_',
    );
    addTearDown(() => folder.delete(recursive: true));
    final note = File(p.join(folder.path, 'note.md'));
    await note.writeAsString('RunbookToken');

    final access = MacOSFolderAccess(
      appPaths: AppPaths(overrideRoot: folder),
      isMacOS: true,
    );
    expect(await access.remember(folder.path), isTrue);

    final resumed = MacOSFolderAccess(
      appPaths: AppPaths(overrideRoot: folder),
      isMacOS: true,
    );
    await resumed.restoreAll();
    expect(resumed.activePaths, contains(p.normalize(p.absolute(folder.path))));
    expect(await note.readAsString(), 'RunbookToken');

    await resumed.forget(folder.path);
    expect(resumed.activePaths, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
