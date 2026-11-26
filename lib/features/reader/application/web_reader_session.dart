import '../../../domain/books/reading_position.dart';
import '../../../domain/web_books/web_book.dart';
import '../../web_books/application/web_reading_source.dart';
import '../../web_books/data/web_snapshot_store.dart';

final class WebReaderSession {
  WebReaderSession({
    required this.bookId,
    required this.repository,
    required this.store,
  });

  final String bookId;
  final WebBookRepository repository;
  final WebSnapshotStore store;
  WebReadingSource? _source;
  Future<WebReadingSource?>? _loading;
  int _epoch = 0;
  bool _disposed = false;

  WebReadingSource? get source => _source;

  Future<WebReadingSource?> load(ReadingLocator? locator) {
    return _loading ??= _resolve(locator, ++_epoch);
  }

  Future<WebReadingSource?> _resolve(ReadingLocator? locator, int epoch) async {
    final result = await WebReadingSource.resolve(
      bookId: bookId,
      repository: repository,
      store: store,
      locator: locator,
    );
    if (_disposed || epoch != _epoch) return null;
    _source = result;
    return result;
  }

  Future<bool> select(ReadingLocator locator) async {
    final result = await _resolve(locator, ++_epoch);
    if (_disposed || result == null) return false;
    _loading = Future.value(result);
    return true;
  }

  void reload() {
    _epoch++;
    _loading = null;
    _source = null;
  }

  ReadingProgressSnapshot? rendererProgress(ReadingProgressSnapshot? progress) {
    final current = source;
    if (current == null ||
        progress?.locator.snapshotId == current.snapshot.id) {
      return progress;
    }
    return ReadingProgressSnapshot(
      bookId: bookId,
      locator: current.locator,
      progress: current.locator.progress,
      chapterTitle: current.snapshot.title,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  void dispose() {
    _disposed = true;
    _epoch++;
  }
}
