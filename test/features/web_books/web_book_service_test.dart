import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pagesage/core/database/app_database.dart' as db;
import 'package:pagesage/core/tasks/task_cancellation.dart';
import 'package:pagesage/core/tasks/task_models.dart';
import 'package:pagesage/domain/books/book.dart';
import 'package:pagesage/domain/books/locator_excerpt.dart';
import 'package:pagesage/domain/books/reading_position.dart';
import 'package:pagesage/domain/search/search_models.dart';
import 'package:pagesage/domain/web_books/web_book.dart';
import 'package:pagesage/features/ai/application/ai_context_range.dart';
import 'package:pagesage/features/ai/application/ai_context_source.dart';
import 'package:pagesage/features/reader/application/web_reader_session.dart';
import 'package:pagesage/features/web_books/application/web_reading_source.dart';
import 'package:pagesage/renderers/epub/epub_document.dart';
import 'package:pagesage/renderers/epub/epub_jump.dart';
import 'package:sqlite3/sqlite3.dart';

import 'web_book_fixture.dart';

void main() {
  late WebBookFixture fixture;
  setUp(() async => fixture = await WebBookFixture.create());
  tearDown(() => fixture.dispose());

  test(
    'legacy extraction stays readable and refresh bypasses 304 without rewriting old offsets',
    () async {
      final base = await fixture.serve();
      fixture.validators = true;
      final book = await fixture.service.create('旧版提取刷新');
      await fixture.service.add(book.id, '$base/one');
      final chapter = (await fixture.repository.chapters(book.id)).single;
      final initial = (await fixture.repository.snapshot(chapter.snapshotId!))!;
      final directory = await fixture.store.directory(book.id, initial.id);
      final manifestFile = File('${directory.path}/manifest.json');
      final manifest =
          jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;
      manifest.remove('extractorVersion');
      final bytes = utf8.encode(jsonEncode(manifest));
      await manifestFile.writeAsBytes(bytes);
      await (fixture.database.update(
        fixture.database.webSnapshots,
      )..where((row) => row.id.equals(initial.id))).write(
        db.WebSnapshotsCompanion(
          manifestHash: Value(sha256.convert(bytes).toString()),
        ),
      );
      final legacy = (await fixture.repository.snapshot(initial.id))!;
      expect(await fixture.store.usesCurrentExtractor(legacy), isFalse);
      final oldSource = (await WebReadingSource.resolve(
        bookId: book.id,
        repository: fixture.repository,
        store: fixture.store,
        locator: legacy.locator.withWebPosition(chapterOffset: 18),
      ))!;
      final oldText = (await oldSource.loader.load(
        oldSource.path,
      )).chapters.single.text;
      final refreshed = (await fixture.service.refresh(chapter))!;
      expect(refreshed.id, isNot(legacy.id));
      expect(fixture.conditionalHits, 0);
      expect(await fixture.store.usesCurrentExtractor(refreshed), isTrue);
      expect(await manifestFile.readAsBytes(), bytes);
      expect(
        (await oldSource.loader.load(oldSource.path)).chapters.single.text,
        oldText,
      );
      expect(
        (await fixture.repository.snapshot(legacy.id))!.textRevision,
        legacy.textRevision,
      );
      expect((await fixture.service.refresh(chapter))!.id, refreshed.id);
      expect(fixture.conditionalHits, 1);
    },
  );

  test(
    'conditional refresh validates local files and repairs corrupt snapshots with a full response',
    () async {
      final base = await fixture.serve();
      fixture.validators = true;
      final book = await fixture.service.create('条件刷新');
      await fixture.service.add(book.id, '$base/one');
      final chapter = (await fixture.repository.chapters(book.id)).single;
      final same = (await fixture.service.refresh(chapter))!;
      expect(same.id, chapter.snapshotId);
      expect(fixture.conditionalHits, 1);
      final directory = await fixture.store.directory(book.id, same.id);
      await File('${directory.path}/article.xhtml').writeAsString('corrupted');
      final repaired = (await fixture.service.refresh(chapter))!;
      expect(fixture.conditionalHits, 1);
      expect(repaired.id, isNot(same.id));
      final source = (await WebReadingSource.resolve(
        bookId: book.id,
        repository: fixture.repository,
        store: fixture.store,
        locator: repaired.locator,
      ))!;
      expect(
        (await source.loader.load(source.path)).chapters.single.text,
        contains('矩阵运算'),
      );
    },
  );

  test(
    'missing images are explicit and a later refresh repairs them',
    () async {
      final base = await fixture.serve();
      fixture.malformedImage = true;
      final book = await fixture.service.create('缺失资源');
      await fixture.service.add(book.id, '$base/one');
      final chapter = (await fixture.repository.chapters(book.id)).single;
      final partial = (await fixture.repository.snapshot(chapter.snapshotId!))!;
      expect(await fixture.store.notice(partial), contains('1 张图片未保存'));
      expect(
        (await fixture.tasks.getTasks()).first.status,
        PageSageTaskStatus.partial,
      );
      fixture.malformedImage = false;
      final repaired = (await fixture.service.refresh(chapter))!;
      expect(repaired.id, isNot(partial.id));
      expect(await fixture.store.notice(repaired), isNull);
    },
  );

  test(
    'cancelling a whole book stops the current capture and remaining chapters',
    () async {
      final base = await fixture.serve();
      final book = await fixture.service.create('整书取消');
      await fixture.repository.addChapter(book.id, '$base/one');
      await fixture.repository.addChapter(book.id, '$base/two');
      fixture.slow = true;
      final running = fixture.service.refreshBook(book.id);
      final assertion = expectLater(
        running,
        throwsA(isA<TaskCancelledException>()),
      );
      await fixture.arrived.future;
      final batch = (await fixture.tasks.getTasks()).singleWhere(
        (task) => task.sourcePath == null,
      );
      fixture.registry.cancel(batch.id);
      await assertion;
      expect(fixture.hits, 1);
      expect(
        (await fixture.repository.chapters(
          book.id,
        )).every((chapter) => chapter.snapshotId == null),
        isTrue,
      );
      expect(
        (await fixture.tasks.getTasks()).where(
          (task) => task.status == PageSageTaskStatus.running,
        ),
        isEmpty,
      );
    },
  );

  test(
    'capture two pages, search, close and reopen fully offline with image and locator',
    () async {
      final base = await fixture.serve();
      final book = await fixture.service.create('网络读书笔记');
      expect(book.format, BookFormat.web);
      await fixture.service.add(book.id, '$base/one');
      await fixture.service.add(book.id, '$base/two');
      final chapters = await fixture.repository.chapters(book.id);
      expect(chapters, hasLength(2));
      final old = (await fixture.repository.snapshot(
        chapters.first.snapshotId!,
      ))!;
      final locator = old.locator.withWebPosition(
        chapterOffset: 18,
        chapterEndOffset: 26,
        progress: .3,
      );
      await fixture.books.saveProgress(
        bookId: book.id,
        locator: locator,
        progress: .3,
      );
      final search = await fixture.search.search(
        SearchQuery(query: '矩阵运算', bookId: book.id),
      );
      expect(search.length, greaterThanOrEqualTo(2));
      expect(
        search.map((row) => row.locator?.webChapterId).toSet(),
        containsAll(chapters.map((row) => row.id)),
      );
      expect(
        search.every((row) => row.locator?.type == ReadingLocatorType.web),
        isTrue,
      );
      await fixture.offline();
      await fixture.reopen();
      final progress = await fixture.books.getProgress(book.id);
      expect(progress!.locator.toJsonText(), locator.toJsonText());
      final source = (await WebReadingSource.resolve(
        bookId: book.id,
        repository: fixture.repository,
        store: fixture.store,
        locator: progress.locator,
      ))!;
      final document = await source.loader.load(source.path);
      expect(document.chapters, hasLength(1));
      expect(document.chapters.single.text, contains('版本 1'));
      expect(document.chapters.single.text, isNot(contains('不应加入正文')));
      expect(
        document.chapters.single.blocks.whereType<EpubImageBlock>(),
        hasLength(1),
      );
      expect(document.sourceLocator!.snapshotId, old.id);
      expect(document.toc, isNotEmpty);
      expect(
        enrichLocatorForJump(locator, fallbackExcerpt: '矩阵运算').snapshotId,
        old.id,
      );
      expect(epubFocusRangeFor(locator), isNotNull);
      final ai = AiContextSource(
        webLoader: (_) => source.loader.load(source.path),
      );
      final context = await ai.load(
        range: AiContextRange.currentChapter,
        bookPath: book.libraryFilePath,
        locator: locator,
        format: BookFormat.web,
      );
      expect(context!.text, contains('矩阵运算'));
      expect(context.locator?.snapshotId, old.id);
    },
  );

  test(
    'unchanged content does not publish or leak candidate, failed refresh preserves snapshot',
    () async {
      final base = await fixture.serve();
      final book = await fixture.service.create('版本测试');
      await fixture.service.add(book.id, '$base/redirect');
      var chapter = (await fixture.repository.chapters(book.id)).single;
      final old = (await fixture.repository.snapshot(chapter.snapshotId!))!;
      expect(old.finalUrl, '$base/one');
      final same = await fixture.service.refresh(chapter);
      expect(same!.id, old.id);
      expect(
        await fixture.database.select(fixture.database.webSnapshots).get(),
        hasLength(1),
      );
      final directory = Directory('${book.libraryFilePath}/snapshots');
      expect(await directory.list().length, 1);
      fixture.fail = true;
      chapter = (await fixture.repository.chapters(book.id)).single;
      await expectLater(
        fixture.service.refresh(chapter),
        throwsA(isA<WebBookException>()),
      );
      final failed = (await fixture.repository.chapters(book.id)).single;
      expect(failed.snapshotId, old.id);
      expect(failed.state, 'failed');
      expect(failed.lastError, contains('503'));
      final source = await WebReadingSource.resolve(
        bookId: book.id,
        repository: fixture.repository,
        store: fixture.store,
        locator: old.locator,
      );
      expect(
        (await source!.loader.load(source.path)).chapters.single.text,
        contains('版本 1'),
      );
    },
  );

  test(
    'refresh keeps historical sources, independent chapter IDs, order and tombstones',
    () async {
      final base = await fixture.serve();
      final book = await fixture.service.create('历史与排序');
      await fixture.service.add(book.id, '$base/one');
      await fixture.service.add(book.id, '$base/two');
      await fixture.service.add(book.id, '$base/one#intro');
      var chapters = await fixture.repository.chapters(book.id);
      expect(chapters, hasLength(2));
      final old = (await fixture.repository.snapshot(
        chapters.first.snapshotId!,
      ))!;
      fixture.revision = 2;
      final updated = (await fixture.service.refresh(chapters.first))!;
      expect(updated.id, isNot(old.id));
      expect(updated.textRevision, isNot(old.textRevision));
      final history = (await WebReadingSource.resolve(
        bookId: book.id,
        repository: fixture.repository,
        store: fixture.store,
        locator: old.locator,
      ))!;
      expect(
        (await history.loader.load(history.path)).chapters.single.text,
        contains('版本 1'),
      );
      await fixture.repository.rename(chapters.first.id, '自定义章节名');
      await fixture.repository.reorder(
        book.id,
        chapters.reversed.map((row) => row.id).toList(),
      );
      chapters = await fixture.repository.chapters(book.id);
      expect(chapters.last.displayTitle, '自定义章节名');
      final expected = await fixture.repository.beginCapture(chapters.last.id);
      await fixture.repository.deleteChapter(chapters.last.id);
      await expectLater(
        fixture.repository.publish(expected, updated),
        throwsA(isA<WebBookException>()),
      );
      expect(await fixture.repository.chapters(book.id), hasLength(1));
      final wrong = old.locator.withWebPosition();
      await expectLater(
        WebReadingSource.resolve(
          bookId: 'different-book',
          repository: fixture.repository,
          store: fixture.store,
          locator: wrong,
        ),
        throwsA(isA<WebBookException>()),
      );
      await fixture.indexer.indexBook((await fixture.books.getBook(book.id))!);
      final hits = await fixture.search.search(
        SearchQuery(query: '矩阵运算', bookId: book.id),
      );
      expect(
        hits.every((hit) => hit.locator?.webChapterId == chapters.first.id),
        isTrue,
      );
    },
  );

  test(
    'cancel in flight, duplicate refresh and recovery have durable terminal states',
    () async {
      final base = await fixture.serve();
      final book = await fixture.service.create('取消');
      final chapter = await fixture.repository.addChapter(
        book.id,
        '$base/slow',
      );
      fixture.slow = true;
      final first = fixture.service.refresh(chapter);
      final assertion = expectLater(
        first,
        throwsA(isA<TaskCancelledException>()),
      );
      await fixture.arrived.future;
      final duplicate = fixture.service.refresh(chapter);
      final duplicateAssertion = expectLater(
        duplicate,
        throwsA(isA<TaskCancelledException>()),
      );
      final task = (await fixture.tasks.getTasks()).single;
      fixture.registry.cancel(task.id);
      await assertion;
      await duplicateAssertion;
      expect(
        (await fixture.tasks.getTasks()).single.status,
        PageSageTaskStatus.cancelled,
      );
      expect(
        (await fixture.repository.chapters(book.id)).single.snapshotId,
        isNull,
      );
      await fixture.tasks.saveTask(
        type: PageSageTaskType.webCapture,
        status: PageSageTaskStatus.running,
        bookId: book.id,
        sourcePath: chapter.id,
      );
      await fixture.service.recover(book.id);
      expect(
        (await fixture.tasks.getTasks()).where(
          (row) => row.status == PageSageTaskStatus.running,
        ),
        isEmpty,
      );
    },
  );

  test(
    'reader session ignores obsolete chapter load and pins version across refresh',
    () async {
      final base = await fixture.serve();
      final book = await fixture.service.create('会话');
      await fixture.service.add(book.id, '$base/one');
      await fixture.service.add(book.id, '$base/two');
      final chapters = await fixture.repository.chapters(book.id);
      final one = (await fixture.repository.snapshot(chapters[0].snapshotId!))!;
      final two = (await fixture.repository.snapshot(chapters[1].snapshotId!))!;
      final session = WebReaderSession(
        bookId: book.id,
        repository: fixture.repository,
        store: fixture.store,
      );
      addTearDown(session.dispose);
      await session.load(one.locator);
      final stale = session.select(one.locator);
      final latest = session.select(two.locator);
      await Future.wait([stale, latest]);
      expect(session.source!.snapshot.id, two.id);
      fixture.revision = 2;
      await fixture.service.refresh(chapters[1]);
      expect(session.source!.snapshot.id, two.id);
      expect(session.rendererProgress(null)?.locator.snapshotId, two.id);
    },
  );

  test('stale search generation cannot replace current webpage search', () async {
    final book = await fixture.service.create('索引竞争');
    final generation = await fixture.search.beginBookGeneration(book.id);
    await fixture.search.indexGenerationTexts(generation.id, [
      SearchIndexEntry(
        sourceType: 'book',
        sourceId: 'stale',
        bookId: book.id,
        text: '旧版本内容',
      ),
    ]);
    await fixture.database.customStatement(
      'UPDATE search_index_units SET requested_input_revision=? WHERE book_id=?',
      ['new-source', book.id],
    );
    await expectLater(
      fixture.search.publishBookGeneration(generation.id),
      throwsStateError,
    );
    expect(
      await fixture.search.search(SearchQuery(query: '旧版本', bookId: book.id)),
      isEmpty,
    );
  });

  test('v12 file upgrades to v13 preserving old book and locator', () async {
    final legacyFile = File('${fixture.root.path}/v12.sqlite');
    final current = db.AppDatabase.forTesting(NativeDatabase(legacyFile));
    await current
        .into(current.books)
        .insert(
          db.BooksCompanion.insert(
            id: 'legacy',
            title: '旧书',
            format: 'md',
            libraryFilePath: '/old.md',
            fileHash: 'old',
            fileSize: 20,
            createdAt: 1,
            updatedAt: 2,
          ),
        );
    final locator = ReadingLocator.markdown(chapterIndex: 2, chapterOffset: 8);
    await current
        .into(current.readingProgress)
        .insert(
          db.ReadingProgressCompanion.insert(
            bookId: 'legacy',
            locator: locator.toJsonText(),
            updatedAt: 3,
            progress: const Value(.5),
          ),
        );
    await current.close();
    final legacy = sqlite3.open(legacyFile.path);
    legacy.execute('DROP TABLE web_snapshots');
    legacy.execute('DROP TABLE web_chapters');
    legacy.userVersion = 12;
    legacy.close();
    final migrated = db.AppDatabase.forTesting(NativeDatabase(legacyFile));
    addTearDown(migrated.close);
    expect((await migrated.select(migrated.books).getSingle()).title, '旧书');
    expect(
      (await migrated.select(migrated.readingProgress).getSingle()).locator,
      locator.toJsonText(),
    );
    expect(await migrated.select(migrated.webChapters).get(), isEmpty);
    expect(await migrated.select(migrated.webSnapshots).get(), isEmpty);
    final roundTrip = ReadingLocator.fromJson(
      jsonDecode(locator.toJsonText()) as Map<String, dynamic>,
    );
    expect(roundTrip.chapterOffset, 8);
  });
}
