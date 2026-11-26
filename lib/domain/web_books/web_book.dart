import '../books/book.dart';
import '../books/reading_position.dart';

final class WebBookException implements Exception {
  const WebBookException(this.message);
  final String message;
  @override
  String toString() => message;
}

final class WebChapter {
  const WebChapter({
    required this.id, required this.bookId, required this.url,
    required this.title, required this.sortOrder, required this.epoch,
    required this.state, this.snapshotId, this.customTitle,
    this.lastError, this.checkedAt,
  });
  final String id;
  final String bookId;
  final String url;
  final String title;
  final String? customTitle;
  final int sortOrder;
  final int epoch;
  final String state;
  final String? snapshotId;
  final String? lastError;
  final int? checkedAt;
  String get displayTitle => customTitle ?? title;
}

final class WebSnapshot {
  const WebSnapshot({
    required this.id, required this.chapterId, required this.bookId,
    required this.title, required this.finalUrl, required this.sourceRevision,
    required this.textRevision, required this.byteSize, required this.createdAt,
    required this.manifestHash,
    this.etag, this.lastModified,
  });
  final String id;
  final String chapterId;
  final String bookId;
  final String title;
  final String finalUrl;
  final String sourceRevision;
  final String textRevision;
  final int byteSize;
  final int createdAt;
  final String manifestHash;
  final String? etag;
  final String? lastModified;
  ReadingLocator get locator => ReadingLocator.web(
    webChapterId: chapterId, snapshotId: id,
    sourceRevision: sourceRevision, textRevision: textRevision,
    href: 'web-chapter/$chapterId', chapterIndex: 0, chapterOffset: 0,
  );
}

abstract interface class WebBookRepository {
  Future<Book> createBook({required String title, required String id, required String rootPath});
  Stream<List<WebChapter>> watchChapters(String bookId);
  Future<List<WebChapter>> chapters(String bookId);
  Future<WebChapter> addChapter(String bookId, String url);
  Future<WebChapter> beginCapture(String chapterId);
  Future<WebSnapshot?> snapshot(String id);
  Future<void> publish(WebChapter expected, WebSnapshot snapshot);
  Future<void> finishCapture(WebChapter expected, {String? error});
  Future<void> rename(String chapterId, String title);
  Future<void> reorder(String bookId, List<String> ids);
  Future<void> deleteChapter(String chapterId);
}
