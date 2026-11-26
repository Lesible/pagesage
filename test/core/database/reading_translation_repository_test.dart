import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pagesage/core/database/app_database.dart';
import 'package:pagesage/domain/books/reading_position.dart';
import 'package:pagesage/domain/translation/reading_translation.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../features/translation/reading_translation_fixture.dart';

void main() {
  test(
    'real v13 structure upgrades without changing web snapshots or saved locators; translation rows cascade with book',
    () async {
      final fixture = await ReadingTranslationFixture.create();
      addTearDown(fixture.dispose);
      final database = fixture.database;
      await database
          .into(database.webChapters)
          .insert(
            WebChaptersCompanion.insert(
              id: 'chapter',
              bookId: 'book',
              url: 'https://fixture.test/article',
              title: 'Article',
              sortOrder: 0,
            ),
          );
      await database
          .into(database.webSnapshots)
          .insert(
            WebSnapshotsCompanion.insert(
              id: 'snapshot',
              chapterId: 'chapter',
              bookId: 'book',
              title: 'Article',
              finalUrl: 'https://fixture.test/article',
              sourceRevision: 'source',
              textRevision: 'text',
              manifestHash: 'manifest',
              byteSize: 10,
              createdAt: 1,
            ),
          );
      final locator = ReadingLocator.web(
        webChapterId: 'chapter',
        snapshotId: 'snapshot',
        sourceRevision: 'source',
        textRevision: 'text',
        chapterIndex: 0,
        chapterOffset: 12,
      ).toJsonText();
      await database
          .into(database.readingProgress)
          .insert(
            ReadingProgressCompanion.insert(
              bookId: 'book',
              locator: locator,
              updatedAt: 2,
            ),
          );
      await database.close();
      final raw = sqlite3.open('${fixture.directory.path}/test.sqlite');
      raw.execute('DROP TABLE reading_translations');
      raw.userVersion = 13;
      raw.close();
      fixture.database = AppDatabase.forTesting(
        NativeDatabase(File('${fixture.directory.path}/test.sqlite')),
      );
      final migrated = fixture.database;
      expect(
        (await migrated.customSelect('PRAGMA user_version').get()).single
            .read<int>('user_version'),
        14,
      );
      expect(
        (await migrated.select(migrated.webSnapshots).getSingle()).id,
        'snapshot',
      );
      expect(
        (await migrated.select(migrated.readingProgress).getSingle()).locator,
        locator,
      );
      const saved = SavedReadingTranslation(
        id: 'saved',
        bookId: 'book',
        sourceKey: 'source',
        unitId: '0:12',
        original: 'Original',
        translated: '译文',
        profileId: 'service',
        profileLabel: '服务',
        fingerprint: 'output',
        targetLanguage: 'zh',
        createdAt: 3,
      );
      await fixture.repository.save(saved);
      await fixture.repository.save(saved);
      expect(await fixture.repository.load('book', 'source'), hasLength(1));
      await migrated.delete(migrated.books).go();
      expect(await fixture.repository.load('book', 'source'), isEmpty);
      expect(await migrated.select(migrated.webSnapshots).get(), isEmpty);
    },
  );
}
