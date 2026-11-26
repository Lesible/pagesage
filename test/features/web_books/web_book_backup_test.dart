import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pagesage/core/database/drift_bookmark_repository.dart';
import 'package:pagesage/core/database/drift_reading_translation_repository.dart';
import 'package:pagesage/domain/translation/reading_translation.dart';
import 'package:pagesage/domain/search/search_models.dart';
import 'package:pagesage/features/web_books/application/web_reading_source.dart';

import 'web_book_fixture.dart';

void main() {
  late WebBookFixture source;
  late WebBookFixture target;
  setUp(() async {
    source = await WebBookFixture.create();
    target = await WebBookFixture.create();
  });
  tearDown(() async {
    await source.dispose();
    await target.dispose();
  });

  test(
    'v2 portable backup restores independent offline chapters, images and history under new root',
    () async {
      final base = await source.serve();
      final book = await source.service.create('跨设备网络书');
      await source.service.add(book.id, '$base/one');
      final chapter = (await source.repository.chapters(book.id)).single;
      final old = (await source.repository.snapshot(chapter.snapshotId!))!;
      source.revision = 2;
      await source.service.refresh(chapter);
      await DriftBookmarkRepository(
        source.database.bookmarkDao,
        source.search,
      ).saveBookmark(
        bookId: book.id,
        locator: old.locator.withWebPosition(chapterOffset: 15),
        title: '旧版本书签',
      );
      await source.books.saveProgress(
        bookId: book.id,
        locator: old.locator,
        progress: .2,
      );
      await DriftReadingTranslationRepository(source.database).save(
        SavedReadingTranslation(
          id: 'saved-translation',
          bookId: book.id,
          sourceKey: old.id,
          unitId: '0:0',
          original: 'Original',
          translated: '离线译文',
          profileId: 'removed-service',
          profileLabel: '旧翻译服务',
          fingerprint: 'output',
          targetLanguage: 'zh',
          createdAt: 1,
        ),
      );
      final backup = await source.exporter.backupDatabaseZip(
        targetPath: '${source.root.path}/backup.zip',
      );
      final archive = ZipDecoder().decodeBytes(await backup.readAsBytes());
      final manifest =
          jsonDecode(utf8.decode(archive.findFile('manifest.json')!.content))
              as Map;
      expect(manifest['version'], 2);
      expect((manifest['webFiles'] as Map).length, 6);
      expect(
        archive.files.any((entry) => entry.name.contains('/staging/')),
        isFalse,
      );
      await source.offline();
      final result = await target.exporter.restoreDatabaseBackup(backup);
      await target.reopen();
      final restoredBook = (await target.books.getBook(book.id))!;
      expect(restoredBook.libraryFilePath, startsWith(target.root.path));
      expect(restoredBook.libraryFilePath, isNot(startsWith(source.root.path)));
      final chapters = await target.repository.chapters(book.id);
      expect(chapters.single.snapshotId, isNot(old.id));
      final progress = (await target.books.getProgress(book.id))!;
      final history = (await WebReadingSource.resolve(
        bookId: book.id,
        repository: target.repository,
        store: target.store,
        locator: progress.locator,
      ))!;
      final document = await history.loader.load(history.path);
      expect(document.chapters.single.text, contains('版本 1'));
      final current = (await WebReadingSource.resolve(
        bookId: book.id,
        repository: target.repository,
        store: target.store,
      ))!;
      expect(
        (await current.loader.load(current.path)).chapters.single.text,
        contains('版本 2'),
      );
      expect(await File(result.rollbackPath).exists(), isTrue);
      final bookmark =
          (await target.database.select(target.database.bookmarks).get())
              .single;
      expect(bookmark.locator, contains(old.id));
      final translations = await DriftReadingTranslationRepository(
        target.database,
      ).load(book.id, old.id);
      expect(translations.single.translated, '离线译文');
      expect(
        await target.search.search(SearchQuery(query: '矩阵运算', bookId: book.id)),
        isNotEmpty,
      );
    },
  );

  test(
    'missing, tampered and traversal resource backups fail before replacing live data',
    () async {
      final base = await source.serve();
      final sourceBook = await source.service.create('来源网络书');
      await source.service.add(sourceBook.id, '$base/one');
      final sentinel = await target.service.create('目标保留');
      final backup = await source.exporter.backupDatabaseZip(
        targetPath: '${source.root.path}/valid.zip',
      );
      final original = ZipDecoder().decodeBytes(await backup.readAsBytes());
      final resource = original.files
          .firstWhere((entry) => entry.name.contains('/resources/'))
          .name;
      for (final mode in ['missing', 'tampered', 'traversal', 'legacy']) {
        final invalid = Archive();
        for (final entry in original.files) {
          if (entry.name == resource) {
            if (mode == 'missing') continue;
            if (mode == 'tampered') {
              invalid.add(ArchiveFile.string(resource, 'damaged image'));
              continue;
            }
          }
          if (entry.name == 'manifest.json' && mode == 'legacy') {
            final manifest =
                jsonDecode(utf8.decode(entry.content)) as Map<String, dynamic>;
            manifest['version'] = 1;
            manifest.remove('webFiles');
            invalid.add(
              ArchiveFile.string('manifest.json', jsonEncode(manifest)),
            );
            continue;
          }
          invalid.add(entry);
        }
        if (mode == 'traversal') {
          invalid.add(ArchiveFile.string('web/../escape', 'invalid'));
        }
        final file = File('${source.root.path}/$mode.zip');
        await file.writeAsBytes(ZipEncoder().encode(invalid));
        await expectLater(
          target.exporter.restoreDatabaseBackup(file),
          throwsA(isA<FormatException>()),
          reason: mode,
        );
        expect((await target.books.getBook(sentinel.id))?.title, '目标保留');
        expect(await target.books.getBook(sourceBook.id), isNull);
      }
    },
  );
}
