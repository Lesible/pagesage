import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pagesage/features/web_books/application/web_reading_source.dart';

import 'web_book_fixture.dart';

void main() {
  test(
    'user supplied articles persist and reopen as native offline chapters',
    () async {
      final fixture = await WebBookFixture.create();
      addTearDown(fixture.dispose);
      final book = await fixture.service.create('网页真实样本验收');
      final records = <Map<String, Object?>>[];
      for (final url in [
        'https://www.anthropic.com/research/writing-tools-for-agents',
        'https://docs.langchain.com/oss/python/langgraph/persistence',
      ]) {
        final time = Stopwatch()..start();
        await fixture.service.add(book.id, url);
        final chapter = (await fixture.repository.chapters(book.id)).last;
        final snapshot = (await fixture.repository.snapshot(
          chapter.snapshotId!,
        ))!;
        final source = (await WebReadingSource.resolve(
          bookId: book.id,
          repository: fixture.repository,
          store: fixture.store,
          locator: snapshot.locator,
        ))!;
        final document = await source.loader.load(source.path);
        expect(document.chapters, hasLength(1));
        expect(document.chapters.single.text.length, greaterThan(2000));
        expect(document.toc, isNotEmpty);
        records.add({
          'url': url,
          'finalUrl': snapshot.finalUrl,
          'title': snapshot.title,
          'textLength': document.chapters.single.text.length,
          'topLevelHeadings': document.toc.length,
          'bytes': snapshot.byteSize,
          'elapsedMs': time.elapsedMilliseconds,
          'notice': source.notice,
        });
      }
      await fixture.reopen();
      final chapters = await fixture.repository.chapters(book.id);
      expect(chapters, hasLength(2));
      for (final chapter in chapters) {
        final snapshot = (await fixture.repository.snapshot(
          chapter.snapshotId!,
        ))!;
        final source = (await WebReadingSource.resolve(
          bookId: book.id,
          repository: fixture.repository,
          store: fixture.store,
          locator: snapshot.locator,
        ))!;
        final document = await source.loader.load(source.path);
        expect(document.chapters.single.text.length, greaterThan(2000));
      }
      const output = String.fromEnvironment('WEB_BOOK_LIVE_REPORT');
      if (output.isNotEmpty) {
        await File(
          output,
        ).writeAsString(const JsonEncoder.withIndent('  ').convert(records));
      }
    },
    skip: !const bool.fromEnvironment('WEB_BOOK_LIVE'),
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
