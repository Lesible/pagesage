import 'package:flutter_test/flutter_test.dart';
import 'package:pagesage/domain/web_books/web_book.dart';
import 'package:pagesage/domain/web_books/web_chapter_group.dart';

void main() {
  WebChapter chapter(String id, String url, String title) => WebChapter(
    id: id,
    bookId: 'book',
    url: url,
    title: title,
    sortOrder: 0,
    epoch: 0,
    state: 'ready',
  );

  test(
    'source grouping preserves page identity, title, stable site order and order inside sites',
    () {
      final chapters = [
        chapter(
          'persistence',
          'https://docs.langchain.com/oss/persistence',
          'Persistence',
        ),
        chapter(
          'anthropic',
          'https://www.anthropic.com/research/tools',
          'Writing tools',
        ),
        chapter(
          'checkpointers',
          'http://docs.langchain.com/oss/checkpointers',
          'Checkpointers',
        ),
        chapter(
          'other-port',
          'https://docs.langchain.com:8443/persistence',
          'Other service',
        ),
      ];
      final groups = groupWebChapters(chapters);
      expect(groups.map((group) => group.label), [
        'docs.langchain.com',
        'www.anthropic.com',
        'docs.langchain.com:8443',
      ]);
      expect(groups.first.chapters.map((chapter) => chapter.id), [
        'persistence',
        'checkpointers',
      ]);
      expect(identical(groups.first.chapters.first, chapters.first), isTrue);
      expect(
        groupWebChapters(
          chapters,
          filter: 'Checkpointers',
        ).single.chapters.single.id,
        'checkpointers',
      );
      expect(
        groupWebChapters(chapters, filter: 'langchain.com').first.chapters,
        hasLength(2),
      );
      expect(groupWebChapters(chapters, filter: 'missing'), isEmpty);
    },
  );
}
