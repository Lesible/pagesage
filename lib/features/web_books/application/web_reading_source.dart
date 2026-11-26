import '../../../domain/books/reading_position.dart';
import '../../../domain/web_books/web_book.dart';
import '../../../renderers/web/web_document_loader.dart';
import '../data/web_snapshot_store.dart';

final class WebReadingSource {
  const WebReadingSource(this.snapshot, this.path, this.locator, {this.notice});

  final WebSnapshot snapshot;
  final String path;
  final ReadingLocator locator;
  final String? notice;

  WebDocumentLoader get loader => WebDocumentLoader(snapshot, path);

  static Future<WebReadingSource?> resolve({
    required String bookId,
    required WebBookRepository repository,
    required WebSnapshotStore store,
    ReadingLocator? locator,
  }) async {
    WebSnapshot? snapshot;
    final requestedId = locator?.snapshotId;
    if (requestedId != null && requestedId.isNotEmpty) {
      snapshot = await repository.snapshot(requestedId);
      if (snapshot == null ||
          snapshot.bookId != bookId ||
          snapshot.chapterId != locator?.webChapterId ||
          snapshot.sourceRevision != locator?.sourceRevision ||
          snapshot.textRevision != locator?.textRevision) {
        throw const WebBookException('原文版本不可用，请从章节列表打开已保存版本');
      }
    } else {
      for (final chapter in await repository.chapters(bookId)) {
        if (chapter.snapshotId != null) {
          snapshot = await repository.snapshot(chapter.snapshotId!);
          if (snapshot != null) break;
        }
      }
    }
    if (snapshot == null) return null;
    final directory = await store.directory(bookId, snapshot.id);
    return WebReadingSource(
      snapshot,
      directory.path,
      requestedId == snapshot.id ? locator! : snapshot.locator,
      notice: await store.notice(snapshot),
    );
  }
}
